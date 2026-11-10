import Foundation

// Saved settings per camera (keyed by camera product name) and the
// "apply at startup" preference. Stored in UserDefaults.
enum Profiles {
    private static let defaults = UserDefaults.standard
    private static let loadKey = "applySavedProfilesAtStartup"

    private static func key(for camera: String) -> String {
        "profile.\(camera)"
    }

    static var loadAtStart: Bool {
        get { defaults.bool(forKey: loadKey) }
        set { defaults.set(newValue, forKey: loadKey) }
    }

    static func save(_ values: [String: Int], for camera: String) {
        defaults.set(values, forKey: key(for: camera))
    }

    static func saved(for camera: String) -> [String: Int]? {
        defaults.dictionary(forKey: key(for: camera)) as? [String: Int]
    }

    static func applyIfEnabled(to cameras: [UVCCamera]) {
        guard loadAtStart else { return }
        for camera in cameras {
            if let values = saved(for: camera.name) {
                camera.apply(values)
            }
        }
    }
}
