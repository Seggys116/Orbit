import XCTest
@testable import Orbit

@MainActor
final class WebKitDataStoreIdentifiersTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WebKitDataStoreIdentifiersTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var registryURL: URL { directory.appendingPathComponent("WebsiteDataStoreIdentifiers.json") }

    private func production(installed: Set<UUID>?) -> WebKitDataStoreIdentifiers {
        WebKitDataStoreIdentifiers(scope: .production, registryURL: registryURL, installedIdentifiers: { installed })
    }

    // Two profile ids the earlier XOR fold maps to one UUID: "a" and "0" at positions 0 and 16 against "A" and "P".
    private let collidingFirst = "a" + String(repeating: "x", count: 15) + "0"
    private let collidingSecond = "A" + String(repeating: "x", count: 15) + "P"

    // MARK: - Derivation

    func testTheDerivedIdentifierIsAVersion5Uuid() {
        let uuid = WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .production).uuid

        XCTAssertEqual(uuid.6 >> 4, 5, "the version nibble must say name-based SHA")
        XCTAssertEqual(uuid.8 >> 6, 0b10, "the variant bits must be RFC 4122")
    }

    func testTheDerivedIdentifiersAreFixedForAGivenProfileAndScope() {
        XCTAssertEqual(
            WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .production),
            UUID(uuidString: "1790FCB7-38CD-5E28-A35C-1829F3FFA5A1")
        )
        XCTAssertEqual(
            WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .development),
            UUID(uuidString: "5D6F620E-427F-55B8-8E9E-5138263806D2")
        )
        XCTAssertEqual(
            WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .test),
            UUID(uuidString: "E5AAABCF-3BFC-5B01-885E-2F8F88839224")
        )
    }

    func testProfilesTheOldFoldConfusedGetDistinctIdentifiers() {
        XCTAssertEqual(
            WebKitDataStoreIdentifiers.legacyIdentifier(for: collidingFirst),
            WebKitDataStoreIdentifiers.legacyIdentifier(for: collidingSecond),
            "test precondition: the earlier derivation collides on these two profiles"
        )

        XCTAssertNotEqual(
            WebKitDataStoreIdentifiers.derivedIdentifier(for: collidingFirst, scope: .production),
            WebKitDataStoreIdentifiers.derivedIdentifier(for: collidingSecond, scope: .production)
        )
    }

    func testManyProfilesNeverShareAnIdentifier() {
        let profiles = ["default", "isolated", "incognito"] + (0..<2_000).map { "space-\($0)" } + (0..<500).map { _ in "profile-\(UUID().uuidString)" }
        let identifiers = Set(profiles.map { WebKitDataStoreIdentifiers.derivedIdentifier(for: $0, scope: .production) })

        XCTAssertEqual(identifiers.count, profiles.count)
    }

    func testTheScopeIsPartOfTheName() {
        let scopes: [OrbitRuntimeScope] = [.production, .development, .test]
        let identifiers = Set(scopes.map { WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: $0) })

        XCTAssertEqual(identifiers.count, scopes.count, "the same profile must resolve to a different store in every scope")
    }

    // MARK: - Scoping

    func testANonProductionRunNeverResolvesToTheProductionStoreEvenWhenOneExists() {
        let productionStore = WebKitDataStoreIdentifiers.legacyIdentifier(for: "default")
        for scope in [OrbitRuntimeScope.development, .test] {
            let identifiers = WebKitDataStoreIdentifiers(scope: scope, registryURL: registryURL, installedIdentifiers: { [productionStore] })

            let resolved = identifiers.identifier(for: "default")

            XCTAssertNotEqual(resolved, productionStore, "\(scope) reached an earlier release's production store")
            XCTAssertNotEqual(resolved, WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .production))
            XCTAssertEqual(resolved, WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: scope))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL.path), "a non-production run must not write the production registry")
    }

    func testTheSessionsOfThisTestRunUseTheTestScope() {
        XCTAssertEqual(OrbitRuntimeScope.current, .test)
        XCTAssertEqual(
            WebKitSession.dataStoreIdentifier(for: "default"),
            WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .test)
        )
        XCTAssertNotEqual(
            WebKitSession.dataStoreIdentifier(for: "default"),
            WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .production)
        )
    }

    // MARK: - Production keeps what earlier releases created

    func testAProfileWithAnEarlierStoreKeepsUsingIt() {
        let legacy = WebKitDataStoreIdentifiers.legacyIdentifier(for: "default")

        XCTAssertEqual(production(installed: [legacy]).identifier(for: "default"), legacy)
    }

    func testTheEarlierStoreStaysWithTheProfileOnTheNextLaunch() {
        let legacy = WebKitDataStoreIdentifiers.legacyIdentifier(for: "default")
        XCTAssertEqual(production(installed: [legacy]).identifier(for: "default"), legacy)

        XCTAssertEqual(
            production(installed: []).identifier(for: "default"), legacy,
            "the decision is recorded, so it survives the store not being listed"
        )
    }

    func testAProfileWithNoEarlierStoreGetsTheDerivedIdentifier() {
        XCTAssertEqual(
            production(installed: []).identifier(for: "default"),
            WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .production)
        )
    }

    func testAnEarlierStoreIsGivenToOnlyOneOfTheProfilesThatSharedIt() {
        let shared = WebKitDataStoreIdentifiers.legacyIdentifier(for: collidingFirst)
        let identifiers = production(installed: [shared])

        XCTAssertEqual(identifiers.identifier(for: collidingFirst), shared)
        XCTAssertEqual(
            identifiers.identifier(for: collidingSecond),
            WebKitDataStoreIdentifiers.derivedIdentifier(for: collidingSecond, scope: .production),
            "a profile created later must not adopt a store another profile already owns"
        )
    }

    func testNothingIsRecordedWhileTheInstalledStoresAreUnknown() {
        let legacy = WebKitDataStoreIdentifiers.legacyIdentifier(for: "default")

        XCTAssertEqual(
            production(installed: nil).identifier(for: "default"),
            WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .production)
        )
        XCTAssertEqual(
            production(installed: [legacy]).identifier(for: "default"), legacy,
            "an unanswered lookup must not have fixed the profile to the new identifier"
        )
    }

    func testADerivedStoreIsPreferredWhenBothExist() {
        let derived = WebKitDataStoreIdentifiers.derivedIdentifier(for: "default", scope: .production)
        let legacy = WebKitDataStoreIdentifiers.legacyIdentifier(for: "default")

        XCTAssertEqual(production(installed: [legacy, derived]).identifier(for: "default"), derived)
    }
}
