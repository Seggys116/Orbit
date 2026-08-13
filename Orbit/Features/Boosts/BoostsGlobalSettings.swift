import Foundation

public enum BoostsGlobalSettings {
    #if DEBUG
    public static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    public static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    private static let key = "OrbitBoostsGloballyEnabled"

    public static let label = "Enable Boosts on websites you visit."

    // Absent-means-on: bool(forKey:) alone would default an upgrading user to Boosts off.
    public static var isEnabled: Bool {
        get {
            guard defaults.object(forKey: key) != nil else { return true }
            return defaults.bool(forKey: key)
        }
        set {
            defaults.set(newValue, forKey: key)
        }
    }

    public static func reset() {
        defaults.removeObject(forKey: key)
    }
}
