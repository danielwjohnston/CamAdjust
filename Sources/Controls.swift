import Foundation

// Every control the app knows about. Values are stored per field, so a
// multi-field UVC control (pan/tilt, white balance U/V) appears as two rows.

enum UVCEntity {
    case cameraTerminal
    case processingUnit
}

enum ControlGroup: String, CaseIterable, Identifiable {
    case basic = "Basic"
    case advanced = "Advanced"
    case panTilt = "Pan / Tilt"
    var id: String { rawValue }
}

struct ControlChoice: Hashable {
    let value: Int
    let title: String
}

enum ControlKind {
    case slider
    case toggle
    case choice([ControlChoice])
    /// Relative control: −/+ buttons send -1/+1, then 0 to stop.
    case relative
}

struct ControlSpec {
    let key: String           // stable key used in profiles
    let title: String
    let group: ControlGroup
    let entity: UVCEntity
    let selector: UInt8
    let wireSize: Int         // full control length on the wire
    let offset: Int           // this field's byte offset in the control
    let size: Int             // this field's length
    let signed: Bool
    let kind: ControlKind
    /// When this returns true for the current value of `dependsOn`, the
    /// control is driven by the camera and its row is disabled.
    let dependsOn: String?
    let isAutomatic: ((Int) -> Bool)?

    init(_ key: String, _ title: String, _ group: ControlGroup, _ entity: UVCEntity, _ selector: UInt8,
         size: Int, wireSize: Int? = nil, offset: Int = 0, signed: Bool = false,
         kind: ControlKind = .slider, dependsOn: String? = nil, isAutomatic: ((Int) -> Bool)? = nil) {
        self.key = key
        self.title = title
        self.group = group
        self.entity = entity
        self.selector = selector
        self.wireSize = wireSize ?? size
        self.offset = offset
        self.size = size
        self.signed = signed
        self.kind = kind
        self.dependsOn = dependsOn
        self.isAutomatic = isAutomatic
    }
}

enum AEMode {
    static let manual = 1, auto = 2, shutterPriority = 4, aperturePriority = 8
}

let autoExposureChoices = [
    ControlChoice(value: AEMode.manual, title: "Manual"),
    ControlChoice(value: AEMode.auto, title: "Auto"),
    ControlChoice(value: AEMode.shutterPriority, title: "Shutter Priority"),
    ControlChoice(value: AEMode.aperturePriority, title: "Aperture Priority"),
]

let powerLineChoices = [
    ControlChoice(value: 0, title: "Disabled"),
    ControlChoice(value: 1, title: "50 Hz"),
    ControlChoice(value: 2, title: "60 Hz"),
    ControlChoice(value: 3, title: "Auto"),
]

private let isOn: (Int) -> Bool = { $0 != 0 }

/// Ordered so that mode and auto switches are written before the manual
/// values they gate. Profiles are applied in this order.
let controlSpecs: [ControlSpec] = [
    // Basic
    ControlSpec("brightness", "Brightness", .basic, .processingUnit, 0x02, size: 2, signed: true),
    ControlSpec("contrast", "Contrast", .basic, .processingUnit, 0x03, size: 2),
    ControlSpec("hueAuto", "Auto Hue", .basic, .processingUnit, 0x10, size: 1, kind: .toggle),
    ControlSpec("hue", "Hue", .basic, .processingUnit, 0x06, size: 2, signed: true,
                dependsOn: "hueAuto", isAutomatic: isOn),
    ControlSpec("saturation", "Saturation", .basic, .processingUnit, 0x07, size: 2),
    ControlSpec("sharpness", "Sharpness", .basic, .processingUnit, 0x08, size: 2),
    ControlSpec("gamma", "Gamma", .basic, .processingUnit, 0x09, size: 2),
    ControlSpec("whiteBalanceAuto", "Auto White Balance", .basic, .processingUnit, 0x0B, size: 1, kind: .toggle),
    ControlSpec("whiteBalance", "White Balance Temperature", .basic, .processingUnit, 0x0A, size: 2,
                dependsOn: "whiteBalanceAuto", isAutomatic: isOn),
    ControlSpec("whiteBalanceComponentAuto", "Auto White Balance U/V", .basic, .processingUnit, 0x0D, size: 1,
                kind: .toggle),
    ControlSpec("whiteBalanceU", "White Balance U", .basic, .processingUnit, 0x0C, size: 2, wireSize: 4, offset: 0,
                dependsOn: "whiteBalanceComponentAuto", isAutomatic: isOn),
    ControlSpec("whiteBalanceV", "White Balance V", .basic, .processingUnit, 0x0C, size: 2, wireSize: 4, offset: 2,
                dependsOn: "whiteBalanceComponentAuto", isAutomatic: isOn),
    ControlSpec("backlight", "Backlight Compensation", .basic, .processingUnit, 0x01, size: 2),
    ControlSpec("powerLine", "Power Line Frequency (anti-flicker)", .basic, .processingUnit, 0x05, size: 1,
                kind: .choice(powerLineChoices)),

    // Advanced
    ControlSpec("autoExposureMode", "Auto-Exposure Mode", .advanced, .cameraTerminal, 0x02, size: 1,
                kind: .choice(autoExposureChoices)),
    ControlSpec("exposure", "Exposure Time", .advanced, .cameraTerminal, 0x04, size: 4,
                dependsOn: "autoExposureMode",
                isAutomatic: { $0 == AEMode.auto || $0 == AEMode.aperturePriority }),
    ControlSpec("gain", "Gain", .advanced, .processingUnit, 0x04, size: 2),
    ControlSpec("iris", "Aperture", .advanced, .cameraTerminal, 0x09, size: 2,
                dependsOn: "autoExposureMode",
                isAutomatic: { $0 == AEMode.auto || $0 == AEMode.shutterPriority }),
    ControlSpec("irisRelative", "Aperture (step)", .advanced, .cameraTerminal, 0x0A, size: 1, signed: true,
                kind: .relative),
    ControlSpec("focusAuto", "Auto Focus", .advanced, .cameraTerminal, 0x08, size: 1, kind: .toggle),
    ControlSpec("focus", "Focus", .advanced, .cameraTerminal, 0x06, size: 2,
                dependsOn: "focusAuto", isAutomatic: isOn),
    ControlSpec("zoom", "Zoom", .advanced, .cameraTerminal, 0x0B, size: 2),

    // Pan / Tilt (absolute, arc-seconds)
    ControlSpec("pan", "Pan", .panTilt, .cameraTerminal, 0x0D, size: 4, wireSize: 8, offset: 0, signed: true),
    ControlSpec("tilt", "Tilt", .panTilt, .cameraTerminal, 0x0D, size: 4, wireSize: 8, offset: 4, signed: true),
]

/// Keys that the camera changes on its own while an auto mode is on; the
/// read timer refreshes these.
let autoUpdatedKeys: Set<String> = ["exposure", "gain", "iris", "whiteBalance", "whiteBalanceU", "whiteBalanceV",
                                    "focus", "hue"]

// MARK: Little-endian helpers

func leDecode(_ bytes: ArraySlice<UInt8>, signed: Bool) -> Int {
    var raw: UInt64 = 0
    for (i, b) in bytes.enumerated() {
        raw |= UInt64(b) << UInt64(8 * i)
    }
    if signed, !bytes.isEmpty {
        let shift = UInt64(64 - 8 * bytes.count)
        return Int(Int64(bitPattern: raw << shift) >> Int64(shift))
    }
    return Int(raw)
}

func leEncode(_ value: Int, size: Int) -> [UInt8] {
    let raw = UInt64(bitPattern: Int64(value))
    return (0..<size).map { UInt8(truncatingIfNeeded: raw >> UInt64(8 * $0)) }
}
