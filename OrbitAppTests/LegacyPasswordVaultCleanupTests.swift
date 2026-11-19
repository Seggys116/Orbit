//  Removing the old built-in password vault on the first launch without it: only Orbit's own keychain service for the running scope, the
//  three preferences it kept, and only once the keychain confirms the delete. The keychain call is replaced by a recorder.

import Foundation
import Security
import XCTest
@testable import Orbit

@MainActor
final class LegacyPasswordVaultCleanupTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var deletedServices: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "orbit.legacy-vault-cleanup.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        deletedServices = []
        for key in LegacyPasswordVaultCleanup.legacyDefaultsKeys { defaults.set(true, forKey: key) }
        defaults.set("kept", forKey: "OrbitSomethingElse")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func run(scope: OrbitRuntimeScope, status: OSStatus = errSecSuccess) {
        LegacyPasswordVaultCleanup.runIfNeeded(defaults: defaults, scope: scope) { service in
            self.deletedServices.append(service)
            return status
        }
    }

    func testTheProductionVaultAndItsPreferencesAreRemovedOnce() {
        run(scope: .production)
        XCTAssertEqual(deletedServices, ["com.zak-noble-clarke.Orbit.saved-logins"])
        for key in LegacyPasswordVaultCleanup.legacyDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(defaults.string(forKey: "OrbitSomethingElse"), "kept", "nothing but the vault's own preferences is touched")
        XCTAssertTrue(defaults.bool(forKey: LegacyPasswordVaultCleanup.completedKey))

        run(scope: .production)
        XCTAssertEqual(deletedServices.count, 1, "the cleanup runs once")
    }

    func testADevelopmentBuildRemovesOnlyItsOwnService() {
        run(scope: .development)
        XCTAssertEqual(deletedServices, ["com.zak-noble-clarke.Orbit.saved-logins.development"])
    }

    func testATestRunNeverReachesTheKeychain() {
        run(scope: .test)
        XCTAssertTrue(deletedServices.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: LegacyPasswordVaultCleanup.completedKey))
    }

    func testAnEmptyKeychainCountsAsDone() {
        run(scope: .production, status: errSecItemNotFound)
        XCTAssertTrue(defaults.bool(forKey: LegacyPasswordVaultCleanup.completedKey))
    }

    func testAFailedDeleteIsTriedAgainNextLaunch() {
        run(scope: .production, status: errSecInteractionNotAllowed)
        XCTAssertFalse(defaults.bool(forKey: LegacyPasswordVaultCleanup.completedKey))
        run(scope: .production)
        XCTAssertEqual(deletedServices.count, 2)
        XCTAssertTrue(defaults.bool(forKey: LegacyPasswordVaultCleanup.completedKey))
    }
}
