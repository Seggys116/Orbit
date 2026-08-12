import XCTest
import CommonCrypto
import CryptoKit
#if canImport(SQLite3)
import SQLite3
#endif

final class ArcCookieDecryptorTests: XCTestCase {

    private static let password = "orbit-test-password"
    private static let expectedKeyHex = "688d53ec6dd69237f3c54139d62c8acf"

    private var scratch: URL!
    private var key: Data!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ArcCookies-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        key = Self.pbkdf2(password: Self.password, salt: "saltysalt", rounds: 1003, length: 16)
    }

    override func tearDown() {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        key = nil
        super.tearDown()
    }

    // MARK: - 1. Round trip through a real encrypted fixture

    func testRealEncryptedCookiesRoundTripThroughTheWholeCryptoPath() throws {
        let database = try writeCookiesDatabase(rows: [
            CookieRow(
                hostKey: ".github.com",
                name: "user_session",
                plaintext: "aBcD-1234_session-token",
                path: "/",
                lastAccessUTC: 13_364_569_800_000_000
            ),
            CookieRow(
                hostKey: ".example.com",
                name: "sixteen",
                plaintext: "0123456789abcdef",
                path: "/app",
                lastAccessUTC: 13_364_569_700_000_000
            ),
            CookieRow(
                hostKey: "orbit.test",
                name: "greeting",
                plaintext: "héllo — wörld ✅",
                path: "/",
                lastAccessUTC: 13_364_569_600_000_000
            ),
        ])

        let blob = try firstEncryptedValue(in: database)
        XCTAssertEqual(Array(blob.prefix(3)), Array("v10".utf8), "Fixture blob is not v10-prefixed.")
        XCTAssertFalse(
            String(decoding: blob, as: UTF8.self).contains("aBcD-1234_session-token"),
            "Fixture stored the plaintext, so this test would pass against a decryptor that does nothing."
        )

        let cookies = try ArcCookieDecryptor.readCookies(
            cookiesDatabase: database,
            browser: .chrome,
            key: key
        )

        guard cookies.count == 3 else {
            return XCTFail("Every fixture row must decrypt; got \(cookies.count) of 3.")
        }
        XCTAssertEqual(cookies.map(\.name), ["user_session", "sixteen", "greeting"], "Rows come back newest-accessed first.")
        XCTAssertEqual(cookies[0].value, "aBcD-1234_session-token")
        XCTAssertEqual(cookies[1].value, "0123456789abcdef")
        XCTAssertEqual(cookies[2].value, "héllo — wörld ✅")

        XCTAssertEqual(cookies[0].hostKey, ".github.com")
        XCTAssertEqual(cookies[1].path, "/app")
        XCTAssertTrue(cookies[0].isSecure)
        XCTAssertEqual(cookies[0].sourcePort, 443)
    }

    func testJarReportsTheSchemaVersionAndDecryptionCounts() throws {
        let database = try writeCookiesDatabase(rows: [
            CookieRow(hostKey: ".github.com", name: "a", plaintext: "one", path: "/", lastAccessUTC: 13_364_569_800_000_000),
            CookieRow(hostKey: ".github.com", name: "b", plaintext: "two", path: "/b", lastAccessUTC: 13_364_569_700_000_000),
        ])

        let jar = try ArcCookieDecryptor.readJar(cookiesDatabase: database, browser: .chrome, key: key)
        XCTAssertEqual(jar.schemaVersion, 24, "meta.version must be read and reported, not assumed.")
        XCTAssertEqual(jar.rowsRead, 2)
        XCTAssertEqual(jar.rowsFailedToDecrypt, 0)

        let wrongKey = Self.pbkdf2(password: "not-the-password", salt: "saltysalt", rounds: 1003, length: 16)
        let failed = try ArcCookieDecryptor.readJar(cookiesDatabase: database, browser: .chrome, key: wrongKey)
        XCTAssertEqual(failed.rowsRead, 2)
        XCTAssertEqual(failed.rowsFailedToDecrypt, 2, "Every row must fail under a wrong key, and be counted.")
        XCTAssertTrue(failed.cookies.isEmpty)
    }

    func testLimitClampsTheNumberOfCookiesRead() throws {
        let database = try writeCookiesDatabase(rows: [
            CookieRow(hostKey: ".github.com", name: "newest", plaintext: "one", path: "/", lastAccessUTC: 13_364_569_800_000_000),
            CookieRow(hostKey: ".github.com", name: "oldest", plaintext: "two", path: "/b", lastAccessUTC: 13_264_569_800_000_000),
        ])
        let cookies = try ArcCookieDecryptor.readCookies(cookiesDatabase: database, browser: .chrome, key: key, limit: 1)
        XCTAssertEqual(cookies.map(\.name), ["newest"], "The limit must keep the most recently accessed cookie.")
    }

    // MARK: - 2. The PBKDF2 parameters themselves

    func testPBKDF2MatchesTheChromiumParameters() throws {
        let derived = try ArcCookieDecryptor.derivedKey(fromPassword: Data(Self.password.utf8))

        XCTAssertEqual(derived.count, 16, "Chromium's macOS key is AES-128, i.e. 16 bytes.")
        XCTAssertEqual(
            Self.hex(derived),
            Self.expectedKeyHex,
            "Derived key doesn't match PBKDF2-HMAC-SHA1(\"\(Self.password)\", \"saltysalt\", 1003, 16). "
                + "A wrong round count or salt derives a valid-looking key that decrypts every cookie to noise."
        )
        XCTAssertNotEqual(
            Self.hex(derived),
            "905522fc3e49a87ba5daddadcc1cac79",
            "That is the 1000-round key. The macOS iteration count is 1003."
        )

        XCTAssertEqual(ArcCookieDecryptor.pbkdf2Rounds, 1003)
        XCTAssertEqual(ArcCookieDecryptor.pbkdf2Salt, "saltysalt")
        XCTAssertEqual(ArcCookieDecryptor.derivedKeyLength, 16)
        XCTAssertEqual(ArcCookieDecryptor.initializationVectorByte, 0x20)
        XCTAssertEqual(ArcCookieDecryptor.versionPrefix, "v10")
        XCTAssertEqual(ArcCookieDecryptor.safeStorageService, "Arc Safe Storage")
        XCTAssertEqual(ArcCookieDecryptor.safeStorageAccount, "Arc")

        let injected = try ArcCookieDecryptor.safeStorageKey { Data(Self.password.utf8) }
        XCTAssertEqual(Self.hex(injected), Self.expectedKeyHex)
    }

    // MARK: - 3. The schema-24 SHA-256 domain prefix

    func testSHA256DomainPrefixIsStrippedWhenPresentAndLeftAloneWhenAbsent() throws {
        let hostKey = ".github.com"
        let database = try writeCookiesDatabase(rows: [
            CookieRow(
                hostKey: hostKey,
                name: "with_prefix",
                plaintext: "session-value-A",
                path: "/",
                lastAccessUTC: 13_364_569_800_000_000,
                includeDomainHashPrefix: true
            ),
            CookieRow(
                hostKey: hostKey,
                name: "without_prefix",
                plaintext: "session-value-B-longer-than-thirty-two-bytes",
                path: "/legacy",
                lastAccessUTC: 13_364_569_700_000_000,
                includeDomainHashPrefix: false
            ),
        ])

        let cookies = try ArcCookieDecryptor.readCookies(cookiesDatabase: database, browser: .chrome, key: key)
        guard cookies.count == 2 else {
            return XCTFail("Both rows must decrypt; got \(cookies.count) of 2.")
        }
        XCTAssertEqual(
            cookies[0].value,
            "session-value-A",
            "The 32-byte SHA256(host_key) integrity prefix must be stripped when it is there."
        )
        XCTAssertEqual(
            cookies[1].value,
            "session-value-B-longer-than-thirty-two-bytes",
            "A plaintext with no integrity prefix must be used verbatim — never blindly chopped by 32 bytes."
        )

        let digest = Data(SHA256.hash(data: Data(hostKey.utf8)))
        XCTAssertEqual(digest.count, 32)
        XCTAssertEqual(
            try ArcCookieDecryptor.decodeValue(from: digest + Data("payload".utf8), hostKey: hostKey),
            "payload"
        )
        XCTAssertEqual(
            try ArcCookieDecryptor.decodeValue(from: Data("payload".utf8), hostKey: hostKey),
            "payload"
        )
        let otherDigest = Data(SHA256.hash(data: Data(".example.com".utf8)))
        XCTAssertThrowsError(
            try ArcCookieDecryptor.decodeValue(from: otherDigest + Data("payload".utf8), hostKey: hostKey),
            "Only this host's own hash may be stripped."
        ) { error in
            guard case ArcCookieError.plaintextNotUTF8 = error else {
                return XCTFail("Expected .plaintextNotUTF8, got \(error).")
            }
        }
        XCTAssertEqual(
            try ArcCookieDecryptor.decodeValue(from: otherDigest + Data("payload".utf8), hostKey: ".example.com"),
            "payload"
        )
    }

    // MARK: - 4. The 1601 epoch

    func testChromiumMicrosecondEpochConvertsToTheCorrectDates() throws {
        let database = try writeCookiesDatabase(rows: [
            CookieRow(
                hostKey: ".github.com",
                name: "dated",
                plaintext: "value",
                path: "/",
                expiresUTC: 13_411_699_200_000_000,
                hasExpires: true,
                creationUTC: 13_268_217_600_000_000,
                lastAccessUTC: 13_364_569_800_000_000
            ),
        ])

        let cookie = try XCTUnwrap(
            try ArcCookieDecryptor.readCookies(cookiesDatabase: database, browser: .chrome, key: key).first
        )

        let expiry = try XCTUnwrap(cookie.expiresAt)
        XCTAssertEqual(expiry.timeIntervalSince1970, 1_767_225_600, accuracy: 0.001)
        XCTAssertEqual(Self.iso8601(expiry), "2026-01-01T00:00:00Z", "expires_utc is microseconds since 1601, not 1970.")
        XCTAssertEqual(Self.iso8601(cookie.createdAt), "2021-06-15T08:00:00Z")
        XCTAssertEqual(Self.iso8601(cookie.lastAccessedAt), "2024-07-04T12:30:00Z")
    }

    // MARK: - 5. samesite

    func testSameSiteColumnMapsChromiumsFourValues() throws {
        let database = try writeCookiesDatabase(rows: [
            CookieRow(hostKey: "a.test", name: "unspecified", plaintext: "v", path: "/", sameSite: -1, lastAccessUTC: 13_364_569_804_000_000),
            CookieRow(hostKey: "b.test", name: "none", plaintext: "v", path: "/", sameSite: 0, lastAccessUTC: 13_364_569_803_000_000),
            CookieRow(hostKey: "c.test", name: "lax", plaintext: "v", path: "/", sameSite: 1, lastAccessUTC: 13_364_569_802_000_000),
            CookieRow(hostKey: "d.test", name: "strict", plaintext: "v", path: "/", sameSite: 2, lastAccessUTC: 13_364_569_801_000_000),
        ])

        let cookies = try ArcCookieDecryptor.readCookies(cookiesDatabase: database, browser: .chrome, key: key)
        XCTAssertEqual(
            cookies.map(\.sameSitePolicy),
            [.unspecified, .none, .lax, .strict],
            "Chromium's samesite column is -1 unspecified / 0 none / 1 lax / 2 strict."
        )
        XCTAssertEqual(ArcCookieSameSite(chromiumValue: 99), .unspecified, "Unknown values fall back to unspecified.")
    }

    // MARK: - 6. Session cookies

    func testHasExpiresZeroYieldsNoExpiryDate() throws {
        let database = try writeCookiesDatabase(rows: [
            CookieRow(
                hostKey: ".github.com",
                name: "session",
                plaintext: "v",
                path: "/",
                expiresUTC: 13_411_699_200_000_000,
                hasExpires: false,
                lastAccessUTC: 13_364_569_800_000_000
            ),
            CookieRow(
                hostKey: ".github.com",
                name: "persistent",
                plaintext: "v",
                path: "/p",
                expiresUTC: 13_411_699_200_000_000,
                hasExpires: true,
                lastAccessUTC: 13_364_569_700_000_000
            ),
        ])

        let cookies = try ArcCookieDecryptor.readCookies(cookiesDatabase: database, browser: .chrome, key: key)
        guard cookies.count == 2 else {
            return XCTFail("Both rows must decrypt; got \(cookies.count) of 2.")
        }
        XCTAssertNil(cookies[0].expiresAt, "has_expires = 0 is a session cookie: no expiry at all.")
        XCTAssertNotNil(cookies[1].expiresAt, "has_expires = 1 must still produce a date.")
    }

    // MARK: - 7. Keychain refusal is its own, distinguishable outcome

    func testKeychainStatusesMapToDistinctErrorCases() {
        guard case .keychainAccessRefused = ArcCookieDecryptor.mapKeychainStatus(errSecUserCanceled) else {
            return XCTFail("errSecUserCanceled (-128) must map to .keychainAccessRefused.")
        }
        guard case .safeStorageItemMissing = ArcCookieDecryptor.mapKeychainStatus(errSecItemNotFound) else {
            return XCTFail("errSecItemNotFound (-25300) must map to .safeStorageItemMissing.")
        }
        guard case .keychainInteractionNotAllowed = ArcCookieDecryptor.mapKeychainStatus(errSecInteractionNotAllowed) else {
            return XCTFail("errSecInteractionNotAllowed must map to .keychainInteractionNotAllowed.")
        }
        guard case .keychainAuthenticationFailed = ArcCookieDecryptor.mapKeychainStatus(errSecAuthFailed) else {
            return XCTFail("errSecAuthFailed must map to .keychainAuthenticationFailed.")
        }
        guard case .keychainUnavailable(let status) = ArcCookieDecryptor.mapKeychainStatus(errSecDecode) else {
            return XCTFail("An unrecognised status must map to .keychainUnavailable, carrying the status.")
        }
        XCTAssertEqual(status, errSecDecode)

        XCTAssertEqual(errSecUserCanceled, -128)
        XCTAssertEqual(errSecItemNotFound, -25300)

        XCTAssertTrue(ArcCookieDecryptor.mapKeychainStatus(errSecUserCanceled).isKeychainRefusal)
        XCTAssertTrue(ArcCookieDecryptor.mapKeychainStatus(errSecInteractionNotAllowed).isKeychainRefusal)
        XCTAssertTrue(ArcCookieDecryptor.mapKeychainStatus(errSecAuthFailed).isKeychainRefusal)
        XCTAssertFalse(ArcCookieDecryptor.mapKeychainStatus(errSecItemNotFound).isKeychainRefusal)
        XCTAssertFalse(ArcCookieDecryptor.mapKeychainStatus(errSecDecode).isKeychainRefusal)

        XCTAssertNotNil(ArcCookieDecryptor.mapKeychainStatus(errSecUserCanceled).errorDescription)
    }

    // MARK: - Schemes other than v10

    func testNonV10BlobsAreRefusedRatherThanDecryptedWithTheV10Key() {
        for prefix in ["v11", "v20"] {
            let blob = Data(prefix.utf8) + Data(repeating: 0x41, count: 32)
            do {
                _ = try ArcCookieDecryptor.decrypt(blob, key: key, hostKey: ".github.com")
                XCTFail("A \(prefix) blob must not be decrypted with the v10 key.")
            } catch let error as ArcCookieError {
                guard case .unsupportedEncryptionScheme(let reported) = error else {
                    return XCTFail("Expected .unsupportedEncryptionScheme for \(prefix), got \(error).")
                }
                XCTAssertEqual(reported, prefix)
            } catch {
                XCTFail("Unexpected error \(error).")
            }
        }
    }

    // MARK: - Fixtures

    private struct CookieRow {
        var hostKey: String
        var name: String
        var plaintext: String
        var path: String
        var expiresUTC: Int64 = 0
        var hasExpires: Bool = false
        var isSecure: Bool = true
        var isHTTPOnly: Bool = false
        var sameSite: Int = -1
        var sourcePort: Int = 443
        var creationUTC: Int64 = 13_268_217_600_000_000
        var lastAccessUTC: Int64
        var includeDomainHashPrefix: Bool = true
    }

    private func writeCookiesDatabase(rows: [CookieRow]) throws -> URL {
        let url = scratch.appendingPathComponent("Cookies", isDirectory: false)
        let handle = try openDatabase(at: url)
        defer { sqlite3_close(handle) }

        try exec(handle, """
        CREATE TABLE meta (
            key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY,
            value LONGVARCHAR
        );
        CREATE TABLE cookies (
            creation_utc INTEGER NOT NULL,
            host_key TEXT NOT NULL,
            top_frame_site_key TEXT NOT NULL,
            name TEXT NOT NULL,
            value TEXT NOT NULL,
            encrypted_value BLOB NOT NULL,
            path TEXT NOT NULL,
            expires_utc INTEGER NOT NULL,
            is_secure INTEGER NOT NULL,
            is_httponly INTEGER NOT NULL,
            last_access_utc INTEGER NOT NULL,
            has_expires INTEGER NOT NULL DEFAULT 1,
            is_persistent INTEGER NOT NULL DEFAULT 1,
            priority INTEGER NOT NULL DEFAULT 1,
            samesite INTEGER NOT NULL DEFAULT -1,
            source_scheme INTEGER NOT NULL DEFAULT 0,
            source_port INTEGER NOT NULL DEFAULT -1,
            last_update_utc INTEGER NOT NULL DEFAULT 0,
            source_type INTEGER NOT NULL DEFAULT 0,
            has_cross_site_ancestor INTEGER NOT NULL DEFAULT 0,
            UNIQUE (host_key, top_frame_site_key, name, path, source_scheme, source_port)
        );
        """)
        try exec(handle, """
        INSERT INTO meta (key, value) VALUES ('version', '24');
        INSERT INTO meta (key, value) VALUES ('last_compatible_version', '24');
        """)

        for row in rows {
            var plaintext = Data(row.plaintext.utf8)
            if row.includeDomainHashPrefix {
                plaintext = Data(SHA256.hash(data: Data(row.hostKey.utf8))) + plaintext
            }
            let blob = Data("v10".utf8) + (try Self.aesCBCEncrypt(plaintext, key: key))

            try exec(handle, """
            INSERT INTO cookies (
                creation_utc, host_key, top_frame_site_key, name, value, encrypted_value,
                path, expires_utc, is_secure, is_httponly, last_access_utc, has_expires,
                is_persistent, priority, samesite, source_scheme, source_port,
                last_update_utc, source_type, has_cross_site_ancestor
            ) VALUES (
                \(row.creationUTC), \(Self.quoted(row.hostKey)), '', \(Self.quoted(row.name)), '',
                \(Self.blobLiteral(blob)),
                \(Self.quoted(row.path)), \(row.expiresUTC), \(row.isSecure ? 1 : 0), \(row.isHTTPOnly ? 1 : 0),
                \(row.lastAccessUTC), \(row.hasExpires ? 1 : 0), \(row.hasExpires ? 1 : 0), 1,
                \(row.sameSite), 2, \(row.sourcePort), \(row.lastAccessUTC), 0, 0
            );
            """)
        }

        return url
    }

    private func firstEncryptedValue(in database: URL) throws -> Data {
        let handle = try openDatabase(at: database)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT encrypted_value FROM cookies ORDER BY last_access_utc DESC LIMIT 1;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "ArcCookieDecryptorTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't read the fixture's encrypted_value back.",
            ])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return Data() }
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0, let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: length)
    }

    // MARK: - Crypto, implemented here rather than borrowed from production

    private static func pbkdf2(password: String, salt: String, rounds: Int, length: Int) -> Data {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: length)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer -> Int32 in
            saltBytes.withUnsafeBufferPointer { saltBuffer -> Int32 in
                derived.withUnsafeMutableBufferPointer { derivedBuffer -> Int32 in
                    passwordBuffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: passwordBuffer.count) { passwordChars in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passwordChars,
                            passwordBuffer.count,
                            saltBuffer.baseAddress,
                            saltBuffer.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                            UInt32(rounds),
                            derivedBuffer.baseAddress,
                            length
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess), "Test fixture PBKDF2 failed.")
        return Data(derived)
    }

    private static func aesCBCEncrypt(_ plaintext: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = plaintext.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: capacity)
        var moved = 0

        let status = key.withUnsafeBytes { keyBuffer -> Int32 in
            plaintext.withUnsafeBytes { plainBuffer -> Int32 in
                iv.withUnsafeBufferPointer { ivBuffer -> Int32 in
                    output.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            keyBuffer.count,
                            ivBuffer.baseAddress,
                            plainBuffer.baseAddress,
                            plainBuffer.count,
                            outputBuffer.baseAddress,
                            capacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw NSError(domain: "ArcCookieDecryptorTests", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Fixture encryption failed with CCCrypt status \(status).",
            ])
        }
        return Data(output.prefix(moved))
    }

    // MARK: - SQLite fixture plumbing (system libsqlite3, same as production)

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "ArcCookieDecryptorTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create the fixture database at \(url.path).",
            ])
        }
        return handle
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(domain: "ArcCookieDecryptorTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Fixture SQL failed: \(message)",
            ])
        }
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func blobLiteral(_ data: Data) -> String {
        data.isEmpty ? "X''" : "X'\(hex(data))'"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
