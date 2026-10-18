import XCTest
#if canImport(SQLite3)
import SQLite3
#endif

final class ChromiumProfileMigrationTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ChromiumMigration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    func testNothingToReadIsNotAMigration() {
        XCTAssertNil(ChromiumProfileMigration.discover(userDataDirectory: root))
    }

    func testAMarkerSuppressesASecondPass() throws {
        try writeFixture("cookies", to: "Default/Network/Cookies")
        let first = try XCTUnwrap(ChromiumProfileMigration.discover(userDataDirectory: root))
        XCTAssertEqual(first.cookiesDatabase?.lastPathComponent, "Cookies")

        try ChromiumProfileMigration.write(Self.record(), to: first.markerURL)
        XCTAssertNil(
            ChromiumProfileMigration.discover(userDataDirectory: root),
            "a second launch must not import the Chromium jar over cookies WebKit has stored since"
        )
    }

    func testTheModernCookieJarWinsOverTheLegacyFile() throws {
        try writeFixture("old", to: "Default/Cookies")
        try writeFixture("new", to: "Default/Network/Cookies")

        let discovery = try XCTUnwrap(ChromiumProfileMigration.discover(userDataDirectory: root))
        XCTAssertEqual(discovery.cookiesDatabase?.deletingLastPathComponent().lastPathComponent, "Network")
    }

    func testIndexedDBIsDetectedAndNotDescribedAsMigrated() throws {
        let database = root.appendingPathComponent("Default/IndexedDB/https_example.com_0.indexeddb.leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)

        let discovery = try XCTUnwrap(ChromiumProfileMigration.discover(userDataDirectory: root))
        XCTAssertNil(discovery.cookiesDatabase)
        XCTAssertNil(discovery.localStorageDirectory)
        XCTAssertEqual(ChromiumProfileMigration.indexedDBOriginCount(in: discovery.indexedDBDirectory), 1)
    }

    func testExpiredCookiesAreDroppedAndCookiesWebKitAlreadyHasAreKept() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = cookie(name: "sid", domain: ".example.com", path: "/", expiresAt: nil)
        let future = cookie(name: "stay", domain: "example.com", path: "/app", expiresAt: now.addingTimeInterval(60))
        let expired = cookie(name: "gone", domain: "example.com", path: "/", expiresAt: now.addingTimeInterval(-60))
        let blank = cookie(name: "", domain: "example.com", path: "/", expiresAt: nil)
        let duplicate = cookie(name: "sid", domain: ".Example.com", path: "/", expiresAt: nil)

        let installed = ChromiumProfileMigration.cookiesToInstall(
            [session, future, expired, blank, duplicate],
            alreadyPresent: [ChromiumProfileMigration.CookieIdentity(name: "stay", domain: "example.com", path: "/app")],
            now: now
        )

        XCTAssertEqual(installed.map(\.name), ["sid"])
    }

    func testPlaintextCookiesRoundTripAndExpiredRowsDoNot() throws {
        let database = try writeCookiesDatabase()
        let jar = try ChromiumProfileMigration.readJar(cookiesDatabase: database, key: Data())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let installed = ChromiumProfileMigration.importableCookies(jar.cookies, now: now)

        XCTAssertEqual(jar.rowsRead, 2)
        XCTAssertEqual(jar.rowsFailedToDecrypt, 0)
        XCTAssertEqual(installed.map(\.name), ["session"])
        XCTAssertEqual(installed.first?.value, "still-here")
        XCTAssertNil(installed.first?.expiresAt)
    }

    func testLocalStorageScriptKeepsPageOriginsAndDropsTheRest() throws {
        let leveldb = root.appendingPathComponent("leveldb", isDirectory: true)
        let writer = try LevelDBWriter(directory: leveldb)
        try writer.append([
            record("_https://excalidraw.com\u{0}\u{1}theme", value: "dark"),
            record("_https://excalidraw.com\u{0}\u{1}quote", value: "a\"b"),
            record("_https://embed.example/^0https://excalidraw.com\u{0}\u{1}k", value: "partitioned"),
            record("_chrome-extension://abcdefghijklmnop\u{0}\u{1}state", value: "1"),
        ])
        try writer.finish()

        let imported = try XCTUnwrap(ChromiumProfileMigration.localStorageImport(in: leveldb))
        XCTAssertEqual(imported.originCount, 1)
        XCTAssertTrue(imported.userScript.contains("https://excalidraw.com"))
        XCTAssertTrue(imported.userScript.contains("dark"))
        XCTAssertTrue(imported.userScript.contains("a\\\"b"))
        XCTAssertTrue(imported.userScript.contains("localStorage.getItem(key) === null"))
        XCTAssertFalse(imported.userScript.contains("partitioned"))
        XCTAssertFalse(imported.userScript.contains("chrome-extension"))
    }

    func testTheKeychainItemIsChromiumsStockSafeStorage() {
        XCTAssertEqual(ChromiumProfileMigration.safeStorageService, "Chrome Safe Storage")
        XCTAssertEqual(ChromiumProfileMigration.safeStorageAccount, "Chrome")
        XCTAssertTrue(ChromiumProfileMigration.KeychainError.cancelled.retriesOnNextLaunch)
        XCTAssertFalse(ChromiumProfileMigration.KeychainError.itemMissing.retriesOnNextLaunch)
    }

    // MARK: - Fixtures

    private static func record() -> ChromiumProfileMigration.Record {
        ChromiumProfileMigration.Record(
            version: ChromiumProfileMigration.Record.currentVersion,
            migratedAt: Date(timeIntervalSince1970: 0),
            cookiesAccepted: 1,
            cookiesSkipped: 0,
            cookiesFailedToDecrypt: 0,
            cookiesUnreadable: false,
            localStorageOrigins: 0,
            indexedDBOriginsLeftBehind: 0
        )
    }

    private func writeFixture(_ text: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func cookie(name: String, domain: String, path: String, expiresAt: Date?) -> ArcCookie {
        ArcCookie(
            hostKey: domain,
            name: name,
            value: "v",
            path: path,
            expiresAt: expiresAt,
            isSecure: true,
            isHTTPOnly: true,
            sameSitePolicy: .lax,
            sourcePort: 443,
            createdAt: Date(timeIntervalSince1970: 0),
            lastAccessedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func record(_ key: String, value: String) -> LevelDBRecord {
        LevelDBRecord(key: Data(key.utf8), value: Data([0x01]) + Data(value.utf8))
    }

    /// Two rows with an empty encrypted_value, so no keychain key is required.
    private func writeCookiesDatabase() throws -> URL {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Default/Network", isDirectory: true),
            withIntermediateDirectories: true
        )
        let url = root.appendingPathComponent("Default/Network/Cookies")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            XCTFail("could not create \(url.path)")
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(handle) }

        let sql = """
        CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        CREATE TABLE cookies (
            creation_utc INTEGER NOT NULL,
            host_key TEXT NOT NULL,
            name TEXT NOT NULL,
            value TEXT NOT NULL,
            encrypted_value BLOB NOT NULL,
            path TEXT NOT NULL,
            expires_utc INTEGER NOT NULL,
            is_secure INTEGER NOT NULL,
            is_httponly INTEGER NOT NULL,
            last_access_utc INTEGER NOT NULL,
            has_expires INTEGER NOT NULL,
            samesite INTEGER NOT NULL,
            source_port INTEGER NOT NULL
        );
        INSERT INTO meta (key, value) VALUES ('version', '24');
        INSERT INTO cookies VALUES (0, '.example.com', 'session', 'still-here', X'', '/', 0, 1, 1, 2, 0, 1, 443);
        INSERT INTO cookies VALUES (0, '.example.com', 'expired', 'old', X'', '/', 1, 1, 0, 1, 1, 1, 443);
        """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite"
            sqlite3_free(error)
            XCTFail(message)
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
