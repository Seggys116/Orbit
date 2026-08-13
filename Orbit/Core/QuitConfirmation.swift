import Foundation

enum QuitConfirmation {

    // Must match GeneralSettingsPane's @AppStorage key — renaming resets the preference for existing installs.
    static let enabledKey = "OrbitConfirmBeforeQuit"

    static let minimumTabsToWarn = 2

    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    static var isEnabled: Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func shouldConfirm(openTabCount: Int, isEnabled: Bool = QuitConfirmation.isEnabled) -> Bool {
        isEnabled && openTabCount >= minimumTabsToWarn
    }

    static func message(openTabCount: Int) -> String {
        "Quit Orbit with \(openTabCount) tabs open?"
    }

    static let informativeText =
        "Your tabs are saved and will be restored the next time you open Orbit."
}
