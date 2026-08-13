import Foundation

enum UpdaterPreferences {

    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    static let prereleaseChannelEnabledKey = "OrbitUpdaterPrereleaseChannelEnabled"

    // Other call sites should go through UpdaterController.isPrereleaseChannelEnabled instead,
    // which also calls SPUUpdater.resetUpdateCycle() on write.
    static var isPrereleaseChannelEnabled: Bool {
        get { defaults.bool(forKey: prereleaseChannelEnabledKey) }
        set { defaults.set(newValue, forKey: prereleaseChannelEnabledKey) }
    }
}
