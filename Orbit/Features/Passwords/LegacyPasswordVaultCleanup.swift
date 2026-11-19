import Foundation
import OSLog
import Security

/// Orbit once kept its own password vault: one generic-password item per login in the login keychain, under a service of its own for each
/// runtime scope, and three preferences. All of it is removed on the first launch without the vault. Only items under Orbit's own
/// services are touched; the run is retried on later launches until the keychain confirms the delete.
@MainActor
enum LegacyPasswordVaultCleanup {

    static let completedKey = "OrbitLegacyPasswordVaultRemoved"
    static let productionService = "com.zak-noble-clarke.Orbit.saved-logins"
    static let legacyDefaultsKeys = [
        "OrbitPasswordNeverSaveSiteKeys",
        "OrbitPasswordsOfferToSave",
        "OrbitPasswordsOfferToAutofill",
    ]

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "LegacyPasswordVaultCleanup")

    /// Nil under test: a test run never had a vault in the real keychain and must not reach it.
    static func service(for scope: OrbitRuntimeScope) -> String? {
        switch scope {
        case .production: return productionService
        case .development: return productionService + ".development"
        case .test: return nil
        }
    }

    static func runIfNeeded(
        defaults: UserDefaults = OrbitDefaults.standard,
        scope: OrbitRuntimeScope = OrbitRuntimeScope.current,
        deleteItems: (String) -> OSStatus = deleteKeychainItems
    ) {
        guard let service = service(for: scope), !defaults.bool(forKey: completedKey) else { return }
        for key in legacyDefaultsKeys { defaults.removeObject(forKey: key) }
        let status = deleteItems(service)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("could not remove the old saved logins: status \(status, privacy: .public)")
            return
        }
        defaults.set(true, forKey: completedKey)
    }

    static func deleteKeychainItems(service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // The file-based keychain deletes only the first match unless told otherwise.
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
