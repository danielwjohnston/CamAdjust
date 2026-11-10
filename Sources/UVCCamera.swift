import Foundation
import IOKit
import IOKit.usb

// USB Video Class (UVC) control access.
// Controls live on the Processing Unit (image quality) and the Camera
// Terminal (exposure, focus, zoom). Requests are class-specific control
// transfers addressed to the entity ID and the VideoControl interface.

enum UVCEntityKind {
    case processingUnit
    case cameraTerminal
}

struct UVCControlSpec {
    let key: String          // stable key used in saved profiles
    let title: String
    let entity: UVCEntityKind
    let selector: UInt8      // UVC control selector
    let size: Int            // bytes on the wire (little-endian)
    let signed: Bool
}

let uvcControlSpecs: [UVCControlSpec] = [
    UVCControlSpec(key: "brightness",   title: "Brightness",                entity: .processingUnit, selector: 0x02, size: 2, signed: true),
    UVCControlSpec(key: "contrast",     title: "Contrast",                  entity: .processingUnit, selector: 0x03, size: 2, signed: false),
    UVCControlSpec(key: "hue",          title: "Hue",                       entity: .processingUnit, selector: 0x06, size: 2, signed: true),
    UVCControlSpec(key: "saturation",   title: "Saturation",                entity: .processingUnit, selector: 0x07, size: 2, signed: false),
    UVCControlSpec(key: "sharpness",    title: "Sharpness",                 entity: .processingUnit, selector: 0x08, size: 2, signed: false),
    UVCControlSpec(key: "gamma",        title: "Gamma",                     entity: .processingUnit, selector: 0x09, size: 2, signed: false),
    UVCControlSpec(key: "whiteBalance", title: "White Balance Temperature", entity: .processingUnit, selector: 0x0A, size: 2, signed: false),
    UVCControlSpec(key: "backlight",    title: "Backlight Compensation",    entity: .processingUnit, selector: 0x01, size: 2, signed: false),
    UVCControlSpec(key: "gain",         title: "Gain",                      entity: .processingUnit, selector: 0x04, size: 2, signed: false),
    UVCControlSpec(key: "exposure",     title: "Exposure Time (Absolute)",  entity: .cameraTerminal, selector: 0x04, size: 4, signed: false),
    UVCControlSpec(key: "focus",        title: "Focus (Absolute)",          entity: .cameraTerminal, selector: 0x06, size: 2, signed: false),
    UVCControlSpec(key: "zoom",         title: "Zoom (Absolute)",           entity: .cameraTerminal, selector: 0x0B, size: 2, signed: false),
]

enum UVCRequest: UInt8 {
    case setCur = 0x01
    case getCur = 0x81
    case getMin = 0x82
    case getMax = 0x83
    case getDef = 0x87
}

enum UVCError: Error {
    case noEntity
    case shortRead
    case io(IOReturn)
}

// The IOUSBLib UUIDs are C macros that Swift does not import.
private func uvcUUID(_ string: String) -> CFUUID {
    CFUUIDCreateFromString(kCFAllocatorDefault, string as CFString)
}
private let kUVCInterfaceUserClientTypeID = uvcUUID("2D9786C6-9EF3-11D4-AD51-000A27052861") // kIOUSBInterfaceUserClientTypeID
private let kUVCCFPlugInInterfaceID       = uvcUUID("C244E858-109C-11D4-91D4-0050E4C6426F") // kIOCFPlugInInterfaceID
private let kUVCInterfaceInterfaceID      = uvcUUID("73C97AE8-9EF3-11D4-B1D0-000A27052861") // kIOUSBInterfaceInterfaceID

private typealias USBInterfaceRef = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>

struct UVCControlState {
    let spec: UVCControlSpec
    let min: Int
    let max: Int
    let def: Int
    let cur: Int
}

// Little-endian two's-complement helpers.
func uvcDecode(_ bytes: [UInt8], signed: Bool) -> Int {
    var raw: UInt32 = 0
    for (i, b) in bytes.enumerated() {
        raw |= UInt32(b) << UInt32(8 * i)
    }
    if signed {
        let shift = UInt32(32 - 8 * bytes.count)
        return Int(Int32(bitPattern: raw << shift) >> Int32(shift))
    }
    return Int(raw)
}

func uvcEncode(_ value: Int, size: Int) -> [UInt8] {
    let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
    return (0..<size).map { UInt8(truncatingIfNeeded: raw >> UInt32(8 * $0)) }
}

// Walks the configuration descriptor and finds the VideoControl interface
// plus the camera terminal and processing unit IDs.
struct UVCTopology {
    var controlInterface: UInt8 = 0
    var processingUnit: UInt8?
    var cameraTerminal: UInt8?
}

func uvcParseTopology(_ d: [UInt8]) -> UVCTopology? {
    var topo = UVCTopology()
    var inVideoControl = false
    var found = false
    var i = 0
    while i + 2 <= d.count {
        let len = Int(d[i])
        guard len >= 2, i + len <= d.count else { break }
        let type = d[i + 1]
        if type == 0x04 && len >= 9 {                       // INTERFACE
            inVideoControl = d[i + 5] == 0x0E && d[i + 6] == 0x01
            if inVideoControl {
                topo.controlInterface = d[i + 2]
                found = true
            }
        } else if type == 0x24 && inVideoControl && len >= 4 { // CS_INTERFACE
            switch d[i + 2] {
            case 0x02 where len >= 6:                        // VC_INPUT_TERMINAL
                let terminalType = UInt16(d[i + 4]) | (UInt16(d[i + 5]) << 8)
                if terminalType == 0x0201 {                  // ITT_CAMERA
                    topo.cameraTerminal = d[i + 3]
                }
            case 0x05:                                       // VC_PROCESSING_UNIT
                topo.processingUnit = d[i + 3]
            default:
                break
            }
        }
        i += len
    }
    return found ? topo : nil
}

final class UVCCamera {
    let name: String
    private let interface: USBInterfaceRef
    private let topology: UVCTopology
    private let queue: DispatchQueue

    private init(name: String, interface: USBInterfaceRef, topology: UVCTopology) {
        self.name = name
        self.interface = interface
        self.topology = topology
        self.queue = DispatchQueue(label: "uvc.control.\(name)")
    }

    deinit {
        _ = interface.pointee?.pointee.Release(interface)
    }

    // MARK: Discovery

    // Matches each camera's VideoControl interface (class 14, subclass 1).
    // Control requests go through the interface user client, which does not
    // need exclusive access, so they work while macOS's UVC driver owns the camera.
    static func discover() -> [UVCCamera] {
        guard let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return [] }
        matching["bInterfaceClass"] = 14
        matching["bInterfaceSubClass"] = 1
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var cameras: [UVCCamera] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let camera = open(service: service) {
                cameras.append(camera)
            }
        }
        return cameras
    }

    private static func open(service: io_service_t) -> UVCCamera? {
        guard let interface = interfaceRef(for: service) else { return nil }
        guard let config = try? readConfiguration(interface),
              var topology = uvcParseTopology(config),
              topology.processingUnit != nil || topology.cameraTerminal != nil else {
            _ = interface.pointee?.pointee.Release(interface)
            return nil
        }
        if let number = registryProperty(service, "bInterfaceNumber") as? Int {
            topology.controlInterface = UInt8(truncatingIfNeeded: number)
        }
        let name = productName(service) ?? "UVC Camera"
        return UVCCamera(name: name, interface: interface, topology: topology)
    }

    private static func interfaceRef(for service: io_service_t) -> USBInterfaceRef? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, kUVCInterfaceUserClientTypeID, kUVCCFPlugInInterfaceID,
                                                &plugin, &score) == KERN_SUCCESS,
              let plugin else { return nil }
        defer { IODestroyPlugInInterface(plugin) }
        var raw: LPVOID?
        guard plugin.pointee?.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(kUVCInterfaceInterfaceID), &raw) == S_OK,
              let raw else { return nil }
        return raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBInterfaceInterface>?.self)
    }

    private static func registryProperty(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // The product name lives on the parent device, not the interface.
    private static func productName(_ service: io_service_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return registryProperty(parent, "USB Product Name") as? String
    }

    private static func readConfiguration(_ interface: USBInterfaceRef) throws -> [UInt8] {
        let header = try getDescriptor(interface, length: 9)
        guard header.count >= 4 else { throw UVCError.shortRead }
        let total = Int(header[2]) | (Int(header[3]) << 8)
        return try getDescriptor(interface, length: total)
    }

    private static func getDescriptor(_ interface: USBInterfaceRef, length: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        let done = try controlRequest(interface,
                                      bmRequestType: 0x80,  // device-to-host, standard, device
                                      request: 0x06,        // GET_DESCRIPTOR
                                      value: 0x0200,        // configuration descriptor, index 0
                                      index: 0,
                                      buffer: &bytes)
        return Array(bytes.prefix(done))
    }

    /// Sends a request on the default control pipe and returns the bytes transferred.
    private static func controlRequest(_ interface: USBInterfaceRef, bmRequestType: UInt8, request: UInt8,
                                       value: UInt16, index: UInt16, buffer: inout [UInt8]) throws -> Int {
        try buffer.withUnsafeMutableBytes { raw -> Int in
            var req = IOUSBDevRequest(bmRequestType: bmRequestType, bRequest: request,
                                      wValue: value, wIndex: index, wLength: UInt16(raw.count),
                                      pData: raw.baseAddress, wLenDone: 0)
            guard let vtable = interface.pointee?.pointee else { throw UVCError.io(kIOReturnNotOpen) }
            let result = vtable.ControlRequest(interface, 0, &req)
            guard result == kIOReturnSuccess else { throw UVCError.io(result) }
            return Int(req.wLenDone)
        }
    }

    // MARK: Control transfers

    private func entityID(_ kind: UVCEntityKind) throws -> UInt8 {
        switch kind {
        case .processingUnit:
            if let id = topology.processingUnit { return id }
        case .cameraTerminal:
            if let id = topology.cameraTerminal { return id }
        }
        throw UVCError.noEntity
    }

    private func windex(for spec: UVCControlSpec) throws -> UInt16 {
        let entity = try entityID(spec.entity)
        return (UInt16(entity) << 8) | UInt16(topology.controlInterface)
    }

    private func send(_ bmRequestType: UInt8, _ request: UInt8, value: UInt16, index: UInt16, data: NSMutableData) throws {
        var bytes = [UInt8](data as Data)
        let done = try UVCCamera.controlRequest(interface, bmRequestType: bmRequestType, request: request,
                                                value: value, index: index, buffer: &bytes)
        data.setData(Data(bytes.prefix(done)))
    }

    private func read(_ spec: UVCControlSpec, _ request: UVCRequest) throws -> Int {
        let index = try windex(for: spec)
        let data = NSMutableData(length: spec.size)!
        try send(0xA1, request.rawValue, value: UInt16(spec.selector) << 8, index: index, data: data)
        let bytes = [UInt8](data as Data)
        guard bytes.count == spec.size else { throw UVCError.shortRead }
        return uvcDecode(bytes, signed: spec.signed)
    }

    private func set(_ spec: UVCControlSpec, value: Int) throws {
        let index = try windex(for: spec)
        let bytes = uvcEncode(value, size: spec.size)
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        try send(0x21, UVCRequest.setCur.rawValue, value: UInt16(spec.selector) << 8, index: index, data: data)
    }

    // MARK: Public API

    /// Returns every control this camera supports with a usable range.
    func controlStates() -> [UVCControlState] {
        uvcControlSpecs.compactMap { spec in
            guard let mn = try? read(spec, .getMin),
                  let mx = try? read(spec, .getMax),
                  mx > mn else { return nil }
            let def = (try? read(spec, .getDef)) ?? mn
            let cur = (try? read(spec, .getCur)) ?? def
            return UVCControlState(spec: spec, min: mn, max: mx, def: def, cur: cur)
        }
    }

    /// Writes a value on the camera's serial queue so the UI never blocks.
    func setValue(_ spec: UVCControlSpec, _ value: Int) {
        queue.async { [weak self] in
            do {
                try self?.set(spec, value: value)
            } catch {
                NSLog("UVC write failed for \(spec.key): \(error)")
            }
        }
    }

    /// Applies a saved profile, clamping each value to the camera's range.
    func apply(_ values: [String: Int]) {
        queue.sync {
            for state in controlStates() {
                guard let v = values[state.spec.key] else { continue }
                let clamped = Swift.min(Swift.max(v, state.min), state.max)
                do {
                    try set(state.spec, value: clamped)
                } catch {
                    NSLog("UVC apply failed for \(state.spec.key): \(error)")
                }
            }
        }
    }
}
