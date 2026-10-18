import WebKit
import XCTest
@testable import Orbit

@MainActor
final class WebKitSessionContentSettingsTests: XCTestCase {

    private var directory: URL!
    private let origin = URL(string: "https://example.com/some/page?q=1")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WebKitSessionContentSettingsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeSession(_ identifier: String = "profile-a", persistent: Bool = true) -> WebKitSession {
        WebKitSession(identifier: identifier, persistent: persistent, storageURL: nil, settingsDirectory: directory)
    }

    // MARK: - Persistence

    func testDecisionsSurviveRecreatingTheSession() {
        let first = makeSession()
        first.setContentSetting(.allow, for: .camera, url: origin)
        first.setContentSetting(.block, for: .geolocation, url: origin)

        let second = makeSession()

        XCTAssertEqual(second.contentSetting(.camera, for: origin), .allow)
        XCTAssertEqual(second.contentSetting(.geolocation, for: origin), .block)
        XCTAssertEqual(second.contentSetting(.microphone, for: origin), .ask, "An unset kind must stay at ask.")
    }

    func testDecisionsApplyToTheWholeOriginAndNotAcrossOrigins() {
        makeSession().setContentSetting(.allow, for: .camera, url: origin)

        let reloaded = makeSession()

        XCTAssertEqual(reloaded.contentSetting(.camera, for: URL(string: "https://example.com/other")!), .allow)
        XCTAssertEqual(reloaded.contentSetting(.camera, for: URL(string: "https://sub.example.com/")!), .ask)
        XCTAssertEqual(reloaded.contentSetting(.camera, for: URL(string: "http://example.com/")!), .ask)
    }

    func testRevokingToAskPersistsTheRemoval() throws {
        let first = makeSession()
        first.setContentSetting(.allow, for: .camera, url: origin)
        first.setContentSetting(.allow, for: .microphone, url: origin)
        first.setContentSetting(.ask, for: .camera, url: origin)

        let second = makeSession()

        XCTAssertEqual(second.contentSetting(.camera, for: origin), .ask)
        XCTAssertEqual(second.contentSetting(.microphone, for: origin), .allow)
    }

    func testRevokingTheLastDecisionRemovesTheFile() throws {
        let session = makeSession()
        session.setContentSetting(.allow, for: .camera, url: origin)
        let file = try XCTUnwrap(session.contentSettingsFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        session.setContentSetting(.ask, for: .camera, url: origin)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "An empty document was left behind.")
    }

    func testSessionsKeepSeparateDecisions() {
        makeSession("profile-a").setContentSetting(.allow, for: .camera, url: origin)

        XCTAssertEqual(makeSession("profile-b").contentSetting(.camera, for: origin), .ask)
        XCTAssertEqual(makeSession("profile-a").contentSetting(.camera, for: origin), .allow)
    }

    func testAnIdentifierWithPathCharactersStaysInsideTheDirectory() throws {
        let session = makeSession("../escape/../x")
        session.setContentSetting(.allow, for: .camera, url: origin)

        let file = try XCTUnwrap(session.contentSettingsFileURL)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnUnreadableFileIsIgnoredAndOverwrittenByTheNextDecision() throws {
        let file = try XCTUnwrap(makeSession().contentSettingsFileURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)

        let session = makeSession()
        XCTAssertEqual(session.contentSetting(.camera, for: origin), .ask)
        session.setContentSetting(.allow, for: .camera, url: origin)

        XCTAssertEqual(makeSession().contentSetting(.camera, for: origin), .allow)
    }

    func testAnUnsupportedOriginStoresNothing() throws {
        let session = makeSession()
        let local = URL(string: "file:///tmp/page.html")!

        session.setContentSetting(.allow, for: .camera, url: local)

        XCTAssertEqual(session.contentSetting(.camera, for: local), .unsupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(session.contentSettingsFileURL).path))
    }

    // MARK: - Reset

    func testClearingRemovesEveryDecisionInMemoryAndOnDisk() throws {
        let session = makeSession()
        session.setContentSetting(.allow, for: .camera, url: origin)
        session.setContentSetting(.block, for: .notifications, url: origin)

        XCTAssertTrue(session.clearContentSettings())

        XCTAssertEqual(session.contentSetting(.camera, for: origin), .ask)
        XCTAssertEqual(session.contentSetting(.notifications, for: origin), .ask)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(session.contentSettingsFileURL).path))
        XCTAssertEqual(makeSession().contentSetting(.camera, for: origin), .ask, "A recreated session read the old decisions back.")
    }

    func testClearingWithNothingStoredSucceeds() {
        XCTAssertTrue(makeSession().clearContentSettings())
    }

    // MARK: - Ephemeral sessions

    func testAnEphemeralSessionNeverWritesAndForgetsOnRecreation() {
        let session = makeSession(persistent: false)
        XCTAssertNil(session.contentSettingsFileURL)

        session.setContentSetting(.allow, for: .camera, url: origin)

        XCTAssertEqual(session.contentSetting(.camera, for: origin), .allow, "In-memory decisions still apply within the session.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "An ephemeral session created its settings directory.")
        XCTAssertEqual(makeSession(persistent: false).contentSetting(.camera, for: origin), .ask)
        XCTAssertEqual(makeSession(persistent: true).contentSetting(.camera, for: origin), .ask, "An ephemeral decision leaked into a persistent session.")
        XCTAssertTrue(session.clearContentSettings())
    }

    func testPersistentSessionWithoutAStorageURLUsesTheProcessDataRoot() throws {
        let session = WebKitSession(identifier: "default", persistent: true, storageURL: nil)

        let file = try XCTUnwrap(session.contentSettingsFileURL)

        XCTAssertEqual(
            file.deletingLastPathComponent().standardizedFileURL,
            OrbitDataRoot.processDefault.contentSettings.standardizedFileURL
        )
        XCTAssertFalse(OrbitDataRoot.processDefault.isProduction, "Under XCTest the process root must be scratch.")
    }

    func testPersistentSessionWithAStorageURLKeepsSettingsInsideIt() throws {
        let storage = directory.appendingPathComponent("engine", isDirectory: true)
        let session = WebKitSession(identifier: "isolated", persistent: true, storageURL: storage)

        let file = try XCTUnwrap(session.contentSettingsFileURL)

        XCTAssertEqual(
            file.deletingLastPathComponent().standardizedFileURL,
            storage.appendingPathComponent("ContentSettings", isDirectory: true).standardizedFileURL
        )
    }

    // MARK: - Website data types

    func testCookiesScopeCoversEverySiteDataTypeAndNoCache() {
        let types = WebKitSession.dataTypes(for: .cookies)

        for type in [
            WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeServiceWorkerRegistrations,
            WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeFileSystem, WKWebsiteDataTypeHashSalt,
            WKWebsiteDataTypeMediaKeys,
        ] {
            XCTAssertTrue(types.contains(type), "\(type) is missing from the cookies-and-site-data scope.")
        }
        XCTAssertFalse(types.contains(WKWebsiteDataTypeDiskCache))
    }

    func testCacheScopeCoversEveryCacheTypeAndNoSiteData() {
        let types = WebKitSession.dataTypes(for: .cache)

        XCTAssertEqual(types, [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache])
    }

    func testAllScopeIsTheUnionAndEmptyScopeIsEmpty() {
        XCTAssertEqual(
            WebKitSession.dataTypes(for: .all),
            WebKitSession.dataTypes(for: .cookies).union(WebKitSession.dataTypes(for: .cache))
        )
        XCTAssertTrue(WebKitSession.dataTypes(for: []).isEmpty)
    }

    func testEveryNamedTypeIsOneWebKitKnowsAbout() {
        let known = WKWebsiteDataStore.allWebsiteDataTypes()
        let named = WebKitSession.dataTypes(for: .all)

        XCTAssertTrue(named.isSubset(of: known), "Not known to WebKit: \(named.subtracting(known).sorted())")
    }

    func testTheDataStoreIdentifierIsStablePerSessionIdentifier() {
        XCTAssertEqual(WebKitSession.dataStoreIdentifier(for: "a"), WebKitSession.dataStoreIdentifier(for: "a"))
        XCTAssertNotEqual(WebKitSession.dataStoreIdentifier(for: "a"), WebKitSession.dataStoreIdentifier(for: "b"))
    }
}
