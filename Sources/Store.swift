import Foundation

/// Read/write interval choices. Values are in 0.5 s ticks; 0 is disabled.
enum UpdateInterval: Int, CaseIterable, Identifiable, Codable {
    case disabled = 0, halfSecond = 1, oneSecond = 2, twoSeconds = 4, threeSeconds = 6
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .halfSecond: return "Every 0.5 seconds"
        case .oneSecond: return "Every 1 second"
        case .twoSeconds: return "Every 2 seconds"
        case .threeSeconds: return "Every 3 seconds"
        }
    }
}

struct Schedule: Codable, Identifiable, Hashable {
    var id = UUID()
    var modelID: String
    var cameraName: String
    var profile: String
    var hour: Int
    var minute: Int
    var enabled = true

    var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

typealias SettingValues = [String: Int]

/// All persisted state, kept in UserDefaults.
final class Store {
    static let shared = Store()
    static let cameraDefaultProfile = "Camera Default"

    private let defaults = UserDefaults.standard
    private enum Key {
        static let profiles = "Profiles"              // [modelID: [name: SettingValues]]
        static let startupProfile = "StartupProfile"  // [modelID: name]
        static let lastSettings = "LastSettings"      // [modelID: SettingValues]
        static let schedules = "Schedules"
        static let readInterval = "UpdateSlider"
        static let writeInterval = "ReconfigureWebcam"
        static let blackAndWhiteIcon = "BlackandWhiteMenuIcon"
        static let hideMenuBarIcon = "HideMenuBarIcon"
        static let showValues = "DisplayValue"
        static let welcomeShown = "WelcomeShown"
    }

    private init() {
        defaults.register(defaults: [
            Key.readInterval: UpdateInterval.disabled.rawValue,
            Key.writeInterval: UpdateInterval.disabled.rawValue,
            Key.blackAndWhiteIcon: true,
            Key.hideMenuBarIcon: false,
            Key.showValues: true,
        ])
    }

    // MARK: Preferences

    var readInterval: UpdateInterval {
        get { UpdateInterval(rawValue: defaults.integer(forKey: Key.readInterval)) ?? .disabled }
        set { defaults.set(newValue.rawValue, forKey: Key.readInterval) }
    }

    var writeInterval: UpdateInterval {
        get { UpdateInterval(rawValue: defaults.integer(forKey: Key.writeInterval)) ?? .disabled }
        set { defaults.set(newValue.rawValue, forKey: Key.writeInterval) }
    }

    var blackAndWhiteIcon: Bool {
        get { defaults.bool(forKey: Key.blackAndWhiteIcon) }
        set { defaults.set(newValue, forKey: Key.blackAndWhiteIcon) }
    }

    var hideMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.hideMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.hideMenuBarIcon) }
    }

    var showValues: Bool {
        get { defaults.bool(forKey: Key.showValues) }
        set { defaults.set(newValue, forKey: Key.showValues) }
    }

    var welcomeShown: Bool {
        get { defaults.bool(forKey: Key.welcomeShown) }
        set { defaults.set(newValue, forKey: Key.welcomeShown) }
    }

    // MARK: Profiles

    private var allProfiles: [String: [String: SettingValues]] {
        get { defaults.dictionary(forKey: Key.profiles) as? [String: [String: SettingValues]] ?? [:] }
        set { defaults.set(newValue, forKey: Key.profiles) }
    }

    func profileNames(for modelID: String) -> [String] {
        (allProfiles[modelID] ?? [:]).keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func profile(_ name: String, for modelID: String) -> SettingValues? {
        allProfiles[modelID]?[name]
    }

    func saveProfile(_ name: String, values: SettingValues, for modelID: String) {
        var all = allProfiles
        all[modelID, default: [:]][name] = values
        allProfiles = all
    }

    func deleteProfile(_ name: String, for modelID: String) {
        var all = allProfiles
        all[modelID]?[name] = nil
        allProfiles = all
        if startupProfile(for: modelID) == name { setStartupProfile(nil, for: modelID) }
        schedules = schedules.filter { !($0.modelID == modelID && $0.profile == name) }
    }

    // MARK: Startup ("Load at Start")

    func startupProfile(for modelID: String) -> String? {
        (defaults.dictionary(forKey: Key.startupProfile) as? [String: String])?[modelID]
    }

    func setStartupProfile(_ name: String?, for modelID: String) {
        var all = defaults.dictionary(forKey: Key.startupProfile) as? [String: String] ?? [:]
        all[modelID] = name
        defaults.set(all, forKey: Key.startupProfile)
    }

    // MARK: Last applied settings (rewritten by the write timer)

    func lastSettings(for modelID: String) -> SettingValues? {
        (defaults.dictionary(forKey: Key.lastSettings) as? [String: SettingValues])?[modelID]
    }

    func setLastSettings(_ values: SettingValues, for modelID: String) {
        var all = defaults.dictionary(forKey: Key.lastSettings) as? [String: SettingValues] ?? [:]
        all[modelID] = values
        defaults.set(all, forKey: Key.lastSettings)
    }

    // MARK: Schedules

    var schedules: [Schedule] {
        get {
            guard let data = defaults.data(forKey: Key.schedules) else { return [] }
            return (try? JSONDecoder().decode([Schedule].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.schedules)
            NotificationCenter.default.post(name: .schedulesChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let schedulesChanged = Notification.Name("SchedulesChanged")
    static let camerasChanged = Notification.Name("CamerasChanged")
}
