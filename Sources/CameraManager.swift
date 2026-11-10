import AppKit
import AVFoundation
import Combine
import IOKit

/// UI-facing state for one camera.
final class CameraModel: ObservableObject, Identifiable {
    let camera: UVCCamera
    var id: String { camera.uniqueID }
    var name: String { camera.name }
    var modelID: String { camera.modelID }

    @Published private(set) var states: [ControlState] = []
    @Published var values: SettingValues = [:]
    @Published var ledMode: LEDMode = .auto
    @Published private(set) var formatText = ""

    init(camera: UVCCamera) {
        self.camera = camera
        refresh()
    }

    func refresh() {
        states = camera.readStates()
        values = Dictionary(uniqueKeysWithValues: states.map { ($0.spec.key, $0.cur) })
        formatText = Self.formatText(uniqueID: camera.uniqueID)
    }

    func state(_ key: String) -> ControlState? { states.first { $0.spec.key == key } }

    /// Current settings, excluding momentary relative controls.
    var settingValues: SettingValues {
        values.filter { key, _ in
            guard let spec = state(key)?.spec else { return false }
            if case .relative = spec.kind { return false }
            return true
        }
    }

    var defaultValues: SettingValues {
        Dictionary(uniqueKeysWithValues: states.compactMap { s -> (String, Int)? in
            if case .relative = s.spec.kind { return nil }
            return (s.spec.key, s.def)
        })
    }

    /// True when the camera's auto mode is driving this control.
    func isAutomatic(_ spec: ControlSpec) -> Bool {
        guard let dep = spec.dependsOn, let v = values[dep] else { return false }
        return spec.isAutomatic?(v) ?? false
    }

    private var pendingWrites: SettingValues = [:]

    /// Updates a value. Writes are coalesced so a dragged slider sends at
    /// most one request per control every 50 ms.
    func set(_ key: String, _ value: Int) {
        values[key] = value
        let flushNeeded = pendingWrites.isEmpty
        pendingWrites[key] = value
        if flushNeeded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                let batch = self.pendingWrites
                self.pendingWrites = [:]
                for (k, v) in batch { self.camera.write(k, v) }
                Store.shared.setLastSettings(self.settingValues, for: self.modelID)
            }
        }
        // Turning an auto mode off: show the value the camera settled on.
        if controlSpecs.contains(where: { $0.dependsOn == key }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshAutoValues(force: true) }
        }
    }

    func apply(_ settings: SettingValues) {
        camera.apply(settings, waitUntilDone: true)
        refresh()
        Store.shared.setLastSettings(settingValues, for: modelID)
    }

    func applyProfile(_ name: String) {
        if name == Store.cameraDefaultProfile {
            apply(defaultValues)
        } else if let saved = Store.shared.profile(name, for: modelID) {
            apply(saved)
        }
    }

    func resetToDefault() { apply(defaultValues) }

    func setLED(_ mode: LEDMode) {
        ledMode = mode
        camera.setLED(mode)
    }

    /// Re-reads values the camera changes on its own while auto modes are on.
    func refreshAutoValues(force: Bool = false) {
        let keys = Set(states.filter { force || isAutomatic($0.spec) || $0.spec.key == "gain" }
            .map(\.spec.key)).intersection(autoUpdatedKeys)
        guard !keys.isEmpty else { return }
        let camera = self.camera
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = camera.readCurrent(keys)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (k, v) in fresh where self.values[k] != v { self.values[k] = v }
            }
        }
    }

    /// Rewrites the last applied settings (for apps that reset the camera).
    func rewriteSettings() {
        guard let last = Store.shared.lastSettings(for: modelID) else { return }
        camera.apply(last)
    }

    private static func formatText(uniqueID: String) -> String {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.external]
        } else {
            types = [.externalUnknown]
        }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        guard let device = session.devices.first(where: { $0.uniqueID.lowercased() == uniqueID.lowercased() })
        else { return "" }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let duration = device.activeVideoMinFrameDuration
        let fps = duration.seconds > 0 ? 1 / duration.seconds : device.activeFormat.videoSupportedFrameRateRanges
            .map(\.maxFrameRate).max() ?? 0
        return String(format: "%d × %d  ·  %.0f fps", dims.width, dims.height, fps)
    }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case basic = "Basic", advanced = "Advanced", panTilt = "Pan / Tilt", profiles = "Profiles",
         preferences = "Preferences"
    var id: String { rawValue }
}

/// Owns the camera list, hot-plug notifications, timers and schedules.
final class CameraManager: ObservableObject {
    @Published private(set) var cameras: [CameraModel] = []
    @Published var selectedID: String?
    /// Starting tab; `open CamAdjust.app --args -PanelTab Profiles` picks another.
    @Published var tab: PanelTab = UserDefaults.standard.string(forKey: "PanelTab").flatMap(PanelTab.init) ?? .basic

    var selected: CameraModel? { cameras.first { $0.id == selectedID } ?? cameras.first }

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var rescanWork: DispatchWorkItem?
    private var tickTimer: Timer?
    private var readTicks = 0
    private var writeTicks = 0
    private var scheduleTimers: [Timer] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        rescan(applyStartupProfiles: true)
        registerHotPlug()
        registerSleepWake()
        installTicker()
        installSchedules()
        observers.append(NotificationCenter.default.addObserver(forName: .schedulesChanged, object: nil,
                                                                queue: .main) { [weak self] _ in
            self?.installSchedules()
        })
    }

    // MARK: Discovery

    /// Rebuilds the camera list with fresh USB handles (a re-plugged camera
    /// invalidates the old ones). Startup profiles go only to new arrivals.
    func rescan(applyStartupProfiles: Bool) {
        let previous = Set(cameras.map(\.id))
        let next = UVCCamera.discover().map(CameraModel.init)
        let newlyFound = next.filter { !previous.contains($0.id) }
        cameras = next
        if selectedID == nil || !cameras.contains(where: { $0.id == selectedID }) {
            selectedID = cameras.first?.id
        }
        if applyStartupProfiles {
            for model in newlyFound {
                if let name = Store.shared.startupProfile(for: model.modelID) {
                    model.applyProfile(name)
                }
            }
        }
        NotificationCenter.default.post(name: .camerasChanged, object: nil)
    }

    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan(applyStartupProfiles: true) }
        rescanWork = work
        // Give the camera a moment to finish enumerating.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func registerHotPlug() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let refcon else { return }
            Unmanaged<CameraManager>.fromOpaque(refcon).takeUnretainedValue().scheduleRescan()
        }
        for (type, iterator) in [(kIOFirstMatchNotification, \CameraManager.addedIterator),
                                 (kIOTerminatedNotification, \CameraManager.removedIterator)] {
            guard let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { continue }
            matching["bInterfaceClass"] = 14
            matching["bInterfaceSubClass"] = 1
            var it: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, matching, callback, context, &it) == KERN_SUCCESS {
                // Drain the iterator to arm the notification.
                while case let service = IOIteratorNext(it), service != 0 { IOObjectRelease(service) }
                self[keyPath: iterator] = it
            }
        }
    }

    // MARK: Timers

    private func installTicker() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let store = Store.shared
        if store.readInterval != .disabled {
            readTicks += 1
            if readTicks >= store.readInterval.rawValue {
                readTicks = 0
                cameras.forEach { $0.refreshAutoValues() }
            }
        }
        if store.writeInterval != .disabled {
            writeTicks += 1
            if writeTicks >= store.writeInterval.rawValue {
                writeTicks = 0
                cameras.forEach { $0.rewriteSettings() }
            }
        }
    }

    private func registerSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.tickTimer?.invalidate()
            self?.scheduleTimers.forEach { $0.invalidate() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                self.rescan(applyStartupProfiles: false)
                // Cameras often come back from sleep with factory values.
                self.cameras.forEach { $0.rewriteSettings() }
                self.installTicker()
                self.installSchedules()
            }
        })
    }

    // MARK: Schedules

    func installSchedules() {
        scheduleTimers.forEach { $0.invalidate() }
        scheduleTimers = Store.shared.schedules.filter(\.enabled).map { schedule in
            let timer = Timer(fireAt: Self.nextFireDate(for: schedule), interval: 0, target: self,
                              selector: #selector(scheduleFired(_:)), userInfo: schedule, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    }

    @objc private func scheduleFired(_ timer: Timer) {
        guard let schedule = timer.userInfo as? Schedule else { return }
        for model in cameras where model.modelID == schedule.modelID {
            model.applyProfile(schedule.profile)
        }
        installSchedules()
    }

    static func nextFireDate(for schedule: Schedule, from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = schedule.hour
        parts.minute = schedule.minute
        parts.second = 0
        let today = calendar.date(from: parts) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
}
