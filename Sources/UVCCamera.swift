import Foundation
import IOKit
import IOKit.usb

// USB Video Class (UVC) control access through the IOKit USB interface user
// client. Requests go to the default control pipe of the camera's
// VideoControl interface. The interface is never opened, so this works while
// macOS's own UVC driver is using the camera.

enum UVCRequest: UInt8 {
    case setCur = 0x01
    case getCur = 0x81
    case getMin = 0x82
    case getMax = 0x83
    case getRes = 0x84
    case getInfo = 0x86
    case getDef = 0x87
}

enum UVCError: Error {
    case noEntity
    case shortRead
    case unsupported
    case io(IOReturn)
}

// The IOUSBLib UUIDs are C macros that Swift does not import.
private func uvcUUID(_ string: String) -> CFUUID {
    CFUUIDCreateFromString(kCFAllocatorDefault, string as CFString)
}
private let kInterfaceUserClientTypeID = uvcUUID("2D9786C6-9EF3-11D4-AD51-000A27052861") // kIOUSBInterfaceUserClientTypeID
private let kDeviceUserClientTypeID    = uvcUUID("9DC7B780-9EC0-11D4-A54F-000A27052861") // kIOUSBDeviceUserClientTypeID
private let kCFPlugInInterfaceID       = uvcUUID("C244E858-109C-11D4-91D4-0050E4C6426F") // kIOCFPlugInInterfaceID
private let kInterfaceInterfaceID      = uvcUUID("73C97AE8-9EF3-11D4-B1D0-000A27052861") // kIOUSBInterfaceInterfaceID
private let kDeviceInterfaceID         = uvcUUID("5C8187D0-9EF3-11D4-8B45-000A27052861") // kIOUSBDeviceInterfaceID

private typealias USBInterfaceRef = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>
private typealias USBDeviceRef = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>

private let kNotResponding = IOReturn(bitPattern: 0xE00002ED)

// MARK: Topology

struct UVCTopology {
    var controlInterface: UInt8 = 0
    var processingUnit: UInt8?
    var cameraTerminal: UInt8?
    var extensionUnits: [UInt8] = []
}

/// Walks a configuration descriptor for the VideoControl interface, the
/// camera terminal, the processing unit and any extension units.
func uvcParseTopology(_ d: [UInt8]) -> UVCTopology? {
    var topo = UVCTopology()
    var inVideoControl = false
    var found = false
    var i = 0
    while i + 2 <= d.count {
        let len = Int(d[i])
        guard len >= 2, i + len <= d.count else { break }
        let type = d[i + 1]
        if type == 0x04 && len >= 9 {                           // INTERFACE
            inVideoControl = d[i + 5] == 0x0E && d[i + 6] == 0x01
            if inVideoControl && !found {
                topo.controlInterface = d[i + 2]
                found = true
            }
        } else if type == 0x24 && inVideoControl && len >= 4 {  // CS_INTERFACE
            switch d[i + 2] {
            case 0x02 where len >= 6:                            // VC_INPUT_TERMINAL
                let terminalType = UInt16(d[i + 4]) | (UInt16(d[i + 5]) << 8)
                if terminalType == 0x0201 { topo.cameraTerminal = d[i + 3] }
            case 0x05:                                           // VC_PROCESSING_UNIT
                topo.processingUnit = d[i + 3]
            case 0x06:                                           // VC_EXTENSION_UNIT
                topo.extensionUnits.append(d[i + 3])
            default:
                break
            }
        }
        i += len
    }
    return found ? topo : nil
}

// MARK: Control state

struct ControlState {
    let spec: ControlSpec
    var min: Int
    var max: Int
    var res: Int
    var def: Int
    var cur: Int
    /// For choice controls: the options this camera supports.
    var choices: [ControlChoice] = []
}

// MARK: Vendor quirks

enum LEDMode: Int, CaseIterable {
    case auto = 0, on = 1, off = 2
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }
    /// Value the Logitech firmware expects.
    var wire: UInt8 {
        switch self {
        case .auto: return 3
        case .on: return 1
        case .off: return 0
        }
    }
}

enum PanTiltStep {
    case left, right, up, down, reset
}

private enum LogitechLEDFamily {
    case a, b
}

private let logitechVendor: UInt16 = 0x046D
private let logitechLEDFamilyA: Set<UInt16> = [
    0x802, 0x803, 0x804, 0x805, 0x807, 0x808, 0x809, 0x80A, 0x80D, 0x80F, 0x817, 0x824,
    0x8B5, 0x8C1, 0x8C2, 0x8C3, 0x8C5, 0x8C9, 0x8CA, 0x8CB, 0x8CC, 0x8CE,
    0x990, 0x991, 0x994, 0x9A1, 0x9A2, 0x9A4, 0x9A5, 0x9A6, 0x9C1, 0x9C2,
]
private let logitechLEDFamilyB: Set<UInt16> = [
    0x80C, 0x819, 0x81A, 0x81B, 0x81D, 0x821, 0x825, 0x826, 0x82C, 0x82D, 0x837, 0x841, 0x843, 0x85C, 0x85E,
]

/// Cameras whose exposure control is a 1–15 knob rather than a time.
private let exposureKnobCameras: Set<UInt32> = [
    0x045E_075D, 0x045E_076D, 0x045E_076E, 0x045E_076F, 0x045E_0772, 0x045E_0779,
    0x041E_4080, 0x041E_4086, 0x03F0_8E07, 0x19FF_0218,
]
private let exposureKnobTable = [1, 2, 5, 9, 19, 39, 78, 156, 312, 625, 1250, 2500, 5000, 10000, 20000]
private let lifeCamStudio: UInt32 = 0x045E_0772

// MARK: Camera

final class UVCCamera {
    let name: String
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32
    /// Matches AVCaptureDevice.modelID, so profiles carry over between apps.
    var modelID: String { "UVC Camera VendorID_\(vendorID) ProductID_\(productID)" }
    /// Matches AVCaptureDevice.uniqueID for USB cameras.
    var uniqueID: String { String(format: "0x%x%04x%04x", locationID, vendorID, productID) }

    private let interface: USBInterfaceRef
    private let deviceService: io_service_t
    private let topology: UVCTopology
    private let queue: DispatchQueue

    private init(name: String, vendorID: UInt16, productID: UInt16, locationID: UInt32,
                 interface: USBInterfaceRef, deviceService: io_service_t, topology: UVCTopology) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.interface = interface
        self.deviceService = deviceService
        self.topology = topology
        self.queue = DispatchQueue(label: "uvc.control.\(locationID)")
    }

    deinit {
        _ = interface.pointee?.pointee.Release(interface)
        IOObjectRelease(deviceService)
    }

    private var vidpid: UInt32 { UInt32(vendorID) << 16 | UInt32(productID) }
    private var usesExposureKnob: Bool { exposureKnobCameras.contains(vidpid) }

    private var ledFamily: LogitechLEDFamily? {
        guard vendorID == logitechVendor else { return nil }
        if logitechLEDFamilyA.contains(productID) { return .a }
        if logitechLEDFamilyB.contains(productID) { return .b }
        return nil
    }

    var supportsLED: Bool { ledFamily != nil }

    /// Logitech motorized pan/tilt (extension unit 9), or the Orbit's relative control.
    var supportsMotorPanTilt: Bool {
        vendorID == logitechVendor && (productID == 0x837 || topology.extensionUnits.contains(9))
    }

    // MARK: Discovery

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
        return cameras.sorted { $0.locationID < $1.locationID }
    }

    private static func open(service: io_service_t) -> UVCCamera? {
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &device) == KERN_SUCCESS else { return nil }
        guard let interface = interfaceRef(for: service) else {
            IOObjectRelease(device)
            return nil
        }
        guard let config = try? readConfiguration(interface),
              var topology = uvcParseTopology(config),
              topology.processingUnit != nil || topology.cameraTerminal != nil else {
            _ = interface.pointee?.pointee.Release(interface)
            IOObjectRelease(device)
            return nil
        }
        if let number = property(service, "bInterfaceNumber") as? Int {
            topology.controlInterface = UInt8(truncatingIfNeeded: number)
        }
        let name = property(device, "USB Product Name") as? String
            ?? property(device, "kUSBProductString") as? String
            ?? "UVC Camera"
        let vendor = UInt16(truncatingIfNeeded: property(device, "idVendor") as? Int ?? 0)
        let product = UInt16(truncatingIfNeeded: property(device, "idProduct") as? Int ?? 0)
        let location = UInt32(truncatingIfNeeded: property(device, "locationID") as? Int ?? 0)
        return UVCCamera(name: name, vendorID: vendor, productID: product, locationID: location,
                         interface: interface, deviceService: device, topology: topology)
    }

    private static func plugin(for service: io_service_t, type: CFUUID, interfaceID: CFUUID) -> LPVOID? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, type, kCFPlugInInterfaceID, &plugin, &score) == KERN_SUCCESS,
              let plugin else { return nil }
        defer { IODestroyPlugInInterface(plugin) }
        var raw: LPVOID?
        guard plugin.pointee?.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceID), &raw) == S_OK else {
            return nil
        }
        return raw
    }

    private static func interfaceRef(for service: io_service_t) -> USBInterfaceRef? {
        plugin(for: service, type: kInterfaceUserClientTypeID, interfaceID: kInterfaceInterfaceID)?
            .assumingMemoryBound(to: UnsafeMutablePointer<IOUSBInterfaceInterface>?.self)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func readConfiguration(_ interface: USBInterfaceRef) throws -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 9)
        let n = try rawRequest(interface, 0x80, 0x06, value: 0x0200, index: 0, buffer: &header)
        guard n >= 4 else { throw UVCError.shortRead }
        var full = [UInt8](repeating: 0, count: Int(header[2]) | (Int(header[3]) << 8))
        let done = try rawRequest(interface, 0x80, 0x06, value: 0x0200, index: 0, buffer: &full)
        return Array(full.prefix(done))
    }

    @discardableResult
    private static func rawRequest(_ interface: USBInterfaceRef, _ bmRequestType: UInt8, _ request: UInt8,
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

    // MARK: Transport (call on `queue`)

    /// Sends a request; if the camera is asleep, wakes it once and retries.
    @discardableResult
    private func request(_ bmRequestType: UInt8, _ request: UInt8, value: UInt16, index: UInt16,
                         buffer: inout [UInt8]) throws -> Int {
        do {
            return try UVCCamera.rawRequest(interface, bmRequestType, request, value: value, index: index,
                                            buffer: &buffer)
        } catch UVCError.io(let code) where code == kNotResponding {
            wakeDevice()
            return try UVCCamera.rawRequest(interface, bmRequestType, request, value: value, index: index,
                                            buffer: &buffer)
        }
    }

    private func wakeDevice() {
        guard let raw = UVCCamera.plugin(for: deviceService, type: kDeviceUserClientTypeID,
                                         interfaceID: kDeviceInterfaceID) else { return }
        let device = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
        defer { _ = device.pointee?.pointee.Release(device) }
        if device.pointee?.pointee.USBDeviceOpen(device) == kIOReturnSuccess {
            _ = device.pointee?.pointee.USBDeviceClose(device)
        }
    }

    private func entityID(_ entity: UVCEntity) throws -> UInt8 {
        switch entity {
        case .processingUnit: if let id = topology.processingUnit { return id }
        case .cameraTerminal: if let id = topology.cameraTerminal { return id }
        }
        throw UVCError.noEntity
    }

    private func getRaw(_ spec: ControlSpec, _ req: UVCRequest) throws -> [UInt8] {
        let unit = try entityID(spec.entity)
        var bytes = [UInt8](repeating: 0, count: spec.wireSize)
        let n = try request(0xA1, req.rawValue, value: UInt16(spec.selector) << 8,
                            index: UInt16(unit) << 8 | UInt16(topology.controlInterface), buffer: &bytes)
        guard n == spec.wireSize else { throw UVCError.shortRead }
        return bytes
    }

    private func getField(_ spec: ControlSpec, _ req: UVCRequest) throws -> Int {
        let bytes = try getRaw(spec, req)
        return leDecode(bytes[spec.offset..<spec.offset + spec.size], signed: spec.signed)
    }

    private func getInfo(_ spec: ControlSpec) throws -> UInt8 {
        let unit = try entityID(spec.entity)
        var byte: [UInt8] = [0]
        let n = try request(0xA1, UVCRequest.getInfo.rawValue, value: UInt16(spec.selector) << 8,
                            index: UInt16(unit) << 8 | UInt16(topology.controlInterface), buffer: &byte)
        guard n == 1 else { throw UVCError.shortRead }
        return byte[0]
    }

    private func setField(_ spec: ControlSpec, _ value: Int) throws {
        let unit = try entityID(spec.entity)
        var bytes: [UInt8]
        if spec.wireSize == spec.size {
            bytes = leEncode(value, size: spec.size)
        } else {
            // Multi-field control: keep the other fields at their current values.
            bytes = try getRaw(spec, .getCur)
            bytes.replaceSubrange(spec.offset..<spec.offset + spec.size, with: leEncode(value, size: spec.size))
        }
        try request(0x21, UVCRequest.setCur.rawValue, value: UInt16(spec.selector) << 8,
                    index: UInt16(unit) << 8 | UInt16(topology.controlInterface), buffer: &bytes)
    }

    private func setExtensionUnit(_ unit: UInt8, selector: UInt8, bytes: [UInt8]) throws {
        var data = bytes
        try request(0x21, UVCRequest.setCur.rawValue, value: UInt16(selector) << 8,
                    index: UInt16(unit) << 8 | UInt16(topology.controlInterface), buffer: &data)
    }

    // Exposure knob mapping for the cameras that need it.
    private func knob(fromExposure value: Int) -> Int {
        var best = 0
        for (i, t) in exposureKnobTable.enumerated() where abs(t - value) < abs(exposureKnobTable[best] - value) {
            best = i
        }
        return best + 1
    }

    private func exposure(fromKnob knob: Int) -> Int {
        exposureKnobTable[Swift.min(Swift.max(knob, 1), exposureKnobTable.count) - 1]
    }

    private func readState(_ spec: ControlSpec) -> ControlState? {
        switch spec.kind {
        case .toggle:
            guard let cur = try? getField(spec, .getCur) else { return nil }
            let def = (try? getField(spec, .getDef)) ?? cur
            return ControlState(spec: spec, min: 0, max: 1, res: 1, def: def, cur: cur)

        case .relative:
            // GET_INFO is one byte; bit 1 means SET_CUR is supported.
            guard let info = try? getInfo(spec), info & 0x02 != 0 else { return nil }
            return ControlState(spec: spec, min: -1, max: 1, res: 1, def: 0, cur: 0)

        case .choice(let all):
            guard let cur = try? getField(spec, .getCur) else { return nil }
            let def = (try? getField(spec, .getDef)) ?? cur
            var choices: [ControlChoice]
            if spec.key == "autoExposureMode" {
                // GET_RES is a bitmap of supported modes.
                let mask = (try? getField(spec, .getRes)) ?? 0xF
                choices = all.filter { mask & $0.value != 0 }
            } else {
                let mn = (try? getField(spec, .getMin)) ?? 0
                let mx = (try? getField(spec, .getMax)) ?? 2
                // Some cameras report a max below their own current value.
                choices = all.filter { ($0.value >= mn && $0.value <= mx) || $0.value == cur }
            }
            if choices.isEmpty { return nil }
            return ControlState(spec: spec, min: 0, max: 0, res: 1, def: def, cur: cur, choices: choices)

        case .slider:
            guard let mn = try? getField(spec, .getMin),
                  let mx = try? getField(spec, .getMax),
                  mx > mn else { return nil }
            var res = Swift.max((try? getField(spec, .getRes)) ?? 1, 1)
            // A few cameras report a step that covers most of the range; ignore it.
            if res * 4 > mx - mn { res = 1 }
            let def = (try? getField(spec, .getDef)) ?? mn
            let cur = (try? getField(spec, .getCur)) ?? def
            if spec.key == "exposure" && usesExposureKnob {
                return ControlState(spec: spec, min: 1, max: exposureKnobTable.count, res: 1,
                                    def: knob(fromExposure: def), cur: knob(fromExposure: cur))
            }
            return ControlState(spec: spec, min: mn, max: mx, res: res, def: def, cur: cur)
        }
    }

    private func writeValue(_ spec: ControlSpec, _ value: Int) throws {
        var value = value
        if spec.key == "exposure" && usesExposureKnob {
            value = exposure(fromKnob: value)
        }
        if spec.key == "zoom" && vidpid == lifeCamStudio {
            // The LifeCam Studio only zooms reliably when stepped up to the target.
            if value > 0 {
                for step in 0..<value { try? setField(spec, step) }
            }
        }
        try setField(spec, value)
    }

    // MARK: Public API (thread-safe)

    /// Reads every supported control.
    func readStates() -> [ControlState] {
        queue.sync { controlSpecs.compactMap(readState) }
    }

    /// Reads only the current values of the given keys.
    func readCurrent(_ keys: Set<String>) -> [String: Int] {
        queue.sync {
            var out: [String: Int] = [:]
            for spec in controlSpecs where keys.contains(spec.key) {
                guard var v = try? getField(spec, .getCur) else { continue }
                if spec.key == "exposure" && usesExposureKnob { v = knob(fromExposure: v) }
                out[spec.key] = v
            }
            return out
        }
    }

    /// Writes one value asynchronously so the UI never blocks.
    func write(_ key: String, _ value: Int) {
        guard let spec = controlSpecs.first(where: { $0.key == key }) else { return }
        queue.async { [weak self] in
            do {
                try self?.writeValue(spec, value)
            } catch {
                NSLog("UVC write failed for \(key): \(error)")
            }
        }
    }

    /// Writes a whole set of values in dependency order: modes and auto
    /// switches first, then manual values the camera is not driving itself.
    func apply(_ values: [String: Int], waitUntilDone: Bool = false) {
        let work = { [weak self] in
            guard let self else { return }
            for spec in controlSpecs {
                guard let v = values[spec.key] else { continue }
                if case .relative = spec.kind { continue }
                if let dep = spec.dependsOn, let depValue = values[dep], spec.isAutomatic?(depValue) == true {
                    continue
                }
                do { try self.writeValue(spec, v) } catch { NSLog("UVC apply failed for \(spec.key): \(error)") }
            }
        }
        if waitUntilDone { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Sends one relative step (-1 or +1) then stops (0).
    func stepRelative(_ key: String, direction: Int) {
        guard let spec = controlSpecs.first(where: { $0.key == key }) else { return }
        queue.async { [weak self] in
            try? self?.setField(spec, direction)
            usleep(100_000)
            try? self?.setField(spec, 0)
        }
    }

    func setLED(_ mode: LEDMode) {
        guard let family = ledFamily else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                switch family {
                case .a:
                    try self.setExtensionUnit(13, selector: 1, bytes: [mode.wire, 0, 0])
                case .b:
                    let (unit, length): (UInt8, Int)
                    switch self.productID {
                    case 0x80C, 0x819, 0x81A, 0x81B, 0x825: (unit, length) = (7, 10)
                    case 0x81D, 0x826, 0x82C: (unit, length) = (8, 3)
                    case 0x821: (unit, length) = (8, 5)
                    default: (unit, length) = (11, 3)
                    }
                    func frame(_ m: UInt8) -> [UInt8] {
                        var b = [UInt8](repeating: 0, count: length)
                        b[0] = 1; b[1] = m
                        if length > 2 { b[2] = 1 }
                        return b
                    }
                    if (self.productID == 0x837 || self.productID == 0x82D) && mode == .on {
                        try self.setExtensionUnit(unit, selector: 9, bytes: frame(3))
                        usleep(100_000)
                    }
                    try self.setExtensionUnit(unit, selector: 9, bytes: frame(mode.wire))
                }
            } catch {
                NSLog("LED change failed: \(error)")
            }
        }
    }

    func panTiltStep(_ step: PanTiltStep) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.productID == 0x837, let ct = self.topology.cameraTerminal {
                    // Orbit: UVC Pan/Tilt Relative pulse, then stop.
                    // bPanRelative, bPanSpeed, bTiltRelative, bTiltSpeed.
                    let pulse: [UInt8], duration: useconds_t
                    switch step {
                    case .left: (pulse, duration) = ([0xFF, 0, 0, 0], 20_000)
                    case .right: (pulse, duration) = ([0x01, 0, 0, 0], 20_000)
                    case .up: (pulse, duration) = ([0, 0, 0x01, 0], 40_000)
                    case .down: (pulse, duration) = ([0, 0, 0xFF, 0], 40_000)
                    case .reset: (pulse, duration) = ([0, 0, 0x01, 0], 40_000)
                    }
                    var b = pulse
                    try self.request(0x21, UVCRequest.setCur.rawValue, value: 0x0E00,
                                     index: UInt16(ct) << 8 | UInt16(self.topology.controlInterface), buffer: &b)
                    usleep(duration)
                    var stop: [UInt8] = [0, 0, 0, 0]
                    try self.request(0x21, UVCRequest.setCur.rawValue, value: 0x0E00,
                                     index: UInt16(ct) << 8 | UInt16(self.topology.controlInterface), buffer: &stop)
                    return
                }
                // Logitech motor extension unit 9: 16-bit pan then 16-bit tilt pulses.
                switch step {
                case .left: try self.setExtensionUnit(9, selector: 1, bytes: leEncode(0x0080, size: 4))
                case .right: try self.setExtensionUnit(9, selector: 1, bytes: leEncode(0xFF80, size: 4))
                case .up: try self.setExtensionUnit(9, selector: 1, bytes: leEncode(0xFF80_0000, size: 4))
                case .down: try self.setExtensionUnit(9, selector: 1, bytes: leEncode(0x0080_0000, size: 4))
                case .reset: try self.setExtensionUnit(9, selector: 2, bytes: [3])
                }
            } catch {
                NSLog("Pan/tilt step failed: \(error)")
            }
        }
    }
}
