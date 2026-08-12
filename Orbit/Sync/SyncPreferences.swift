import Foundation

/// Device-local sync toggle in `UserDefaults`, not `OrbitState`: a synced off-switch would propagate itself to every other Mac the instant it's flipped on one.
public enum SyncPreferences {

    public static let enabledKey = "OrbitICloudSyncEnabled"

    #if DEBUG
    public static var defaults: UserDefaults = .standard
    #else
    public static let defaults: UserDefaults = .standard
    #endif

    /// Default `true`; reads via `object(forKey:)` so "unset" isn't read as "disabled".
    public static var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    public static func resetToDefault() {
        defaults.removeObject(forKey: enabledKey)
    }
}
