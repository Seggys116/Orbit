//  Chromium v10 scheme only (v11/v20 refused): PBKDF2-HMAC-SHA1 key (salt "saltysalt", 1003 rounds,
//  16 bytes), AES-128-CBC, IV = 16x 0x20, PKCS#7. Since schema 24 (~M130) plaintext is SHA256(host_key) || value, stripped only when present (jars can be mid-migration).
//  encrypted_value has a 3-byte ASCII version prefix ("v10" etc.) before the ciphertext.

import Foundation
import CommonCrypto
import CryptoKit
import Security
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - What comes out

/// cookies.samesite: -1 unspecified, 0 none, 1 lax, 2 strict.
public enum ArcCookieSameSite: Sendable, Hashable {
    case unspecified
    case none
    case lax
    case strict

    public init(chromiumValue: Int) {
        switch chromiumValue {
        case 0: self = .none
        case 1: self = .lax
        case 2: self = .strict
        default: self = .unspecified
        }
    }
}

public struct ArcCookie: Sendable, Hashable {
    /// A leading dot means "and every subdomain" (e.g. .github.com); kept verbatim since it's also the SHA-256 integrity-prefix input.
    public var hostKey: String
    public var name: String
    public var value: String
    public var path: String
    /// nil when has_expires is 0 — a session cookie, not an expiry of "now".
    public var expiresAt: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSitePolicy: ArcCookieSameSite
    public var sourcePort: Int
    public var createdAt: Date
    public var lastAccessedAt: Date

    public init(
        hostKey: String,
        name: String,
        value: String,
        path: String,
        expiresAt: Date?,
        isSecure: Bool,
        isHTTPOnly: Bool,
        sameSitePolicy: ArcCookieSameSite,
        sourcePort: Int,
        createdAt: Date,
        lastAccessedAt: Date
    ) {
        self.hostKey = hostKey
        self.name = name
        self.value = value
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSitePolicy = sameSitePolicy
        self.sourcePort = sourcePort
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

/// rowsRead/rowsFailedToDecrypt exist because a wrong key doesn't throw — it fails PKCS#7 unpadding or UTF-8 decoding row by row, and only these counts distinguish a broken key from an empty jar.
public struct ArcCookieJar: Sendable, Hashable {
    public var cookies: [ArcCookie]
    public var schemaVersion: Int?
    public var rowsRead: Int
    public var rowsFailedToDecrypt: Int

    public init(cookies: [ArcCookie], schemaVersion: Int?, rowsRead: Int, rowsFailedToDecrypt: Int) {
        self.cookies = cookies
        self.schemaVersion = schemaVersion
        self.rowsRead = rowsRead
        self.rowsFailedToDecrypt = rowsFailedToDecrypt
    }
}

// MARK: - Errors

public enum ArcCookieError: Error, LocalizedError, Sendable {
    case keychainAccessRefused
    case safeStorageItemMissing
    case keychainInteractionNotAllowed
    case keychainAuthenticationFailed
    case keychainUnavailable(status: OSStatus)
    case emptySafeStoragePassword
    case keyDerivationFailed(status: Int32)
    case unsupportedEncryptionScheme(prefix: String)
    case decryptionFailed(status: Int32)
    case plaintextNotUTF8

    /// True for "the user or system declined to hand over the key", as opposed to "something is broken".
    public var isKeychainRefusal: Bool {
        switch self {
        case .keychainAccessRefused, .keychainInteractionNotAllowed, .keychainAuthenticationFailed:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .keychainAccessRefused:
            return "Orbit wasn't given access to Arc's keychain item, so your Arc logins weren't brought across. "
                + "Everything else was imported."
        case .safeStorageItemMissing:
            return "Arc has no saved encryption key on this Mac, so there are no cookies to import."
        case .keychainInteractionNotAllowed:
            return "macOS wouldn't unlock your keychain, so your Arc logins weren't brought across."
        case .keychainAuthenticationFailed:
            return "Your keychain couldn't be unlocked, so your Arc logins weren't brought across."
        case .keychainUnavailable(let status):
            return "Orbit couldn't read Arc's encryption key from your keychain (error \(status))."
        case .emptySafeStoragePassword:
            return "Arc's keychain item is empty, so its cookies can't be decrypted."
        case .keyDerivationFailed(let status):
            return "Orbit couldn't derive Arc's cookie key (error \(status))."
        case .unsupportedEncryptionScheme(let prefix):
            return "Arc encrypted these cookies with a scheme Orbit doesn't support (\(prefix))."
        case .decryptionFailed(let status):
            return "Orbit couldn't decrypt an Arc cookie (error \(status))."
        case .plaintextNotUTF8:
            return "An Arc cookie decrypted to something that isn't text."
        }
    }
}

// MARK: - Decryptor

enum ArcCookieDecryptor {

    // MARK: Chromium's constants

    static let safeStorageService = "Arc Safe Storage"
    static let safeStorageAccount = "Arc"
    static let pbkdf2Salt = "saltysalt"
    static let pbkdf2Rounds = 1003
    static let derivedKeyLength = 16
    static let versionPrefix = "v10"
    static let initializationVectorByte: UInt8 = 0x20

    // MARK: Keychain

    static func mapKeychainStatus(_ status: OSStatus) -> ArcCookieError {
        switch status {
        case errSecUserCanceled:
            return .keychainAccessRefused
        case errSecItemNotFound:
            return .safeStorageItemMissing
        case errSecInteractionNotAllowed:
            return .keychainInteractionNotAllowed
        case errSecAuthFailed:
            return .keychainAuthenticationFailed
        default:
            return .keychainUnavailable(status: status)
        }
    }

    /// Prompts the user — the item's ACL names Arc, not Orbit. Never call this from a test.
    static func keychainSafeStoragePassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: safeStorageService,
            kSecAttrAccount as String: safeStorageAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw mapKeychainStatus(status) }
        guard let password = item as? Data, !password.isEmpty else {
            throw ArcCookieError.emptySafeStoragePassword
        }
        return password
    }

    // MARK: Key derivation

    static func safeStorageKey(
        passwordProvider: () throws -> Data = keychainSafeStoragePassword
    ) throws -> Data {
        try derivedKey(fromPassword: passwordProvider())
    }

    static func derivedKey(fromPassword password: Data) throws -> Data {
        guard !password.isEmpty else { throw ArcCookieError.emptySafeStoragePassword }

        let salt = Array(pbkdf2Salt.utf8)
        let keyLength = derivedKeyLength
        var derived = [UInt8](repeating: 0, count: keyLength)

        let status = password.withUnsafeBytes { passwordBuffer -> Int32 in
            salt.withUnsafeBufferPointer { saltBuffer -> Int32 in
                derived.withUnsafeMutableBufferPointer { derivedBuffer -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordBuffer.count,
                        saltBuffer.baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(pbkdf2Rounds),
                        derivedBuffer.baseAddress,
                        keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw ArcCookieError.keyDerivationFailed(status: status) }
        return Data(derived)
    }

    // MARK: Decryption

    static func decrypt(_ encrypted: Data, key: Data, hostKey: String) throws -> String {
        let prefixBytes = Array(versionPrefix.utf8)
        guard encrypted.count > prefixBytes.count else {
            throw ArcCookieError.unsupportedEncryptionScheme(prefix: "empty")
        }

        let prefix = encrypted.prefix(prefixBytes.count)
        guard Array(prefix) == prefixBytes else {
            let described = String(decoding: prefix, as: UTF8.self)
            throw ArcCookieError.unsupportedEncryptionScheme(
                prefix: described.allSatisfy(\.isASCII) ? described : prefix.map { String(format: "%02x", $0) }.joined()
            )
        }

        let ciphertext = encrypted.dropFirst(prefixBytes.count)
        let plaintext = try aesCBCDecrypt(Data(ciphertext), key: key)
        return try decodeValue(from: plaintext, hostKey: hostKey)
    }

    static func decodeValue(from plaintext: Data, hostKey: String) throws -> String {
        var body = plaintext
        let digest = Data(SHA256.hash(data: Data(hostKey.utf8)))
        if body.count >= digest.count, body.prefix(digest.count) == digest {
            body = body.dropFirst(digest.count)
        }
        guard let value = String(data: Data(body), encoding: .utf8) else {
            throw ArcCookieError.plaintextNotUTF8
        }
        return value
    }

    /// Falls back to manual unpadding when CommonCrypto rejects the final block outright, rather than losing the cookie.
    static func aesCBCDecrypt(_ ciphertext: Data, key: Data) throws -> Data {
        if let padded = try? crypt(ciphertext, key: key, options: CCOptions(kCCOptionPKCS7Padding)) {
            return padded
        }

        let blockSize = kCCBlockSizeAES128
        let alignedLength = (ciphertext.count / blockSize) * blockSize
        guard alignedLength > 0 else {
            return try crypt(ciphertext, key: key, options: CCOptions(kCCOptionPKCS7Padding))
        }
        let raw = try crypt(ciphertext.prefix(alignedLength), key: key, options: CCOptions(0))
        return strippingPKCS7Padding(raw)
    }

    /// Every byte of the trailing pad must equal the pad length, or nothing is stripped — a value that merely ends in 0x01 must not be corrupted.
    static func strippingPKCS7Padding(_ data: Data) -> Data {
        guard let padLength = data.last.map({ Int($0) }),
              padLength > 0,
              padLength <= kCCBlockSizeAES128,
              padLength <= data.count,
              data.suffix(padLength).allSatisfy({ $0 == UInt8(padLength) })
        else { return data }
        return data.dropLast(padLength)
    }

    private static func crypt(_ ciphertext: Data, key: Data, options: CCOptions) throws -> Data {
        let iv = [UInt8](repeating: initializationVectorByte, count: kCCBlockSizeAES128)
        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: outputCapacity)
        var bytesDecrypted = 0

        let status = key.withUnsafeBytes { keyBuffer -> Int32 in
            ciphertext.withUnsafeBytes { cipherBuffer -> Int32 in
                iv.withUnsafeBufferPointer { ivBuffer -> Int32 in
                    output.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            options,
                            keyBuffer.baseAddress,
                            keyBuffer.count,
                            ivBuffer.baseAddress,
                            cipherBuffer.baseAddress,
                            cipherBuffer.count,
                            outputBuffer.baseAddress,
                            outputCapacity,
                            &bytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == Int32(kCCSuccess) else { throw ArcCookieError.decryptionFailed(status: status) }
        return Data(output.prefix(bytesDecrypted))
    }

    // MARK: Reading the jar

    static func readJar(
        cookiesDatabase: URL,
        browser: ImportableBrowser,
        key: Data,
        limit: Int? = nil
    ) throws -> ArcCookieJar {
        try ImportSQLiteSnapshot.withReadOnlyCopy(of: cookiesDatabase, browser: browser) { handle in
            let schemaVersion = readSchemaVersion(handle, browser: browser)

            var rowsRead = 0
            var rowsFailedToDecrypt = 0

            let cookies = try ImportSQLiteSnapshot.query(
                handle,
                sql: """
                SELECT host_key, name, value, encrypted_value, path, expires_utc,
                       is_secure, is_httponly, samesite, source_port,
                       creation_utc, last_access_utc, has_expires
                FROM cookies
                ORDER BY last_access_utc DESC
                LIMIT ?;
                """,
                browser: browser,
                bindInt64: [limit.map { Int64(max($0, 0)) } ?? -1]
            ) { statement -> ArcCookie? in
                rowsRead += 1

                let hostKey = ImportSQLiteSnapshot.columnText(statement, 0) ?? ""
                let name = ImportSQLiteSnapshot.columnText(statement, 1) ?? ""
                let plainValue = ImportSQLiteSnapshot.columnText(statement, 2) ?? ""
                let encrypted = columnBlob(statement, 3)

                let value: String
                if encrypted.isEmpty {
                    value = plainValue
                } else {
                    do {
                        value = try decrypt(encrypted, key: key, hostKey: hostKey)
                    } catch {
                        rowsFailedToDecrypt += 1
                        return nil
                    }
                }

                let hasExpires = sqlite3_column_int64(statement, 12) != 0
                let expiresRaw = sqlite3_column_int64(statement, 5)

                return ArcCookie(
                    hostKey: hostKey,
                    name: name,
                    value: value,
                    path: ImportSQLiteSnapshot.columnText(statement, 4) ?? "/",
                    expiresAt: hasExpires ? ImportSQLiteSnapshot.dateFromChromiumTime(expiresRaw) : nil,
                    isSecure: sqlite3_column_int64(statement, 6) != 0,
                    isHTTPOnly: sqlite3_column_int64(statement, 7) != 0,
                    sameSitePolicy: ArcCookieSameSite(chromiumValue: Int(sqlite3_column_int64(statement, 8))),
                    sourcePort: Int(sqlite3_column_int64(statement, 9)),
                    createdAt: ImportSQLiteSnapshot.dateFromChromiumTime(sqlite3_column_int64(statement, 10)),
                    lastAccessedAt: ImportSQLiteSnapshot.dateFromChromiumTime(sqlite3_column_int64(statement, 11))
                )
            }

            return ArcCookieJar(
                cookies: cookies,
                schemaVersion: schemaVersion,
                rowsRead: rowsRead,
                rowsFailedToDecrypt: rowsFailedToDecrypt
            )
        }
    }

    static func readCookies(
        cookiesDatabase: URL,
        browser: ImportableBrowser,
        key: Data,
        limit: Int? = nil
    ) throws -> [ArcCookie] {
        try readJar(cookiesDatabase: cookiesDatabase, browser: browser, key: key, limit: limit).cookies
    }

    private static func readSchemaVersion(_ handle: OpaquePointer, browser: ImportableBrowser) -> Int? {
        let rows = try? ImportSQLiteSnapshot.query(
            handle,
            sql: "SELECT value FROM meta WHERE key = 'version' LIMIT 1;",
            browser: browser
        ) { statement -> Int? in
            ImportSQLiteSnapshot.columnText(statement, 0).flatMap { Int($0) }
        }
        return rows?.first
    }

    private static func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: length)
    }
}
