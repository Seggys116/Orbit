import Foundation

/// The two switches on the Passwords settings pane. Both default to on; the vault itself is untouched by either.
enum PasswordSettings {

    // Namespaced so a `defaults read` of the app shows them together.
    static let offerToSaveKey = "OrbitPasswordsOfferToSave"
    static let offerToAutofillKey = "OrbitPasswordsOfferToAutofill"

    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    /// Whether a sign-in the user just made may lead to a "Save password" prompt.
    static var offersToSave: Bool {
        get { storedFlag(offerToSaveKey) }
        set { defaults.set(newValue, forKey: offerToSaveKey) }
    }

    /// Whether saved logins and strong passwords are offered on a field the user focuses.
    static var offersToAutofill: Bool {
        get { storedFlag(offerToAutofillKey) }
        set { defaults.set(newValue, forKey: offerToAutofillKey) }
    }

    private static func storedFlag(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
