//  One launch, after an update from the Chromium build. That build kept site data in
//  Application Support/Orbit/Default. WebKit stores its own copy under a data-store
//  identifier and never opens those files. Cookies and Local Storage can be read and
//  handed to WebKit. IndexedDB, cache, and Login Data cannot: WebKit has no reader for
//  Chromium's files, and they are left on disk.

import Foundation
import OSLog
import Security

nonisolated enum ChromiumProfileMigration {

    static let markerFileName = "WebKitSiteDataMigration.json"
    /// Stock Chromium KeychainKeyProvider. Orbit's embedder did not override it.
    static let safeStorageService = "Chrome Safe Storage"
    static let safeStorageAccount = "Chrome"

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "ChromiumProfileMigration")

    struct Discovery: Equatable, Sendable {
        var profileDirectory: URL
        var cookiesDatabase: URL?
        var localStorageDirectory: URL?
        var indexedDBDirectory: URL?
        var markerURL: URL
    }

    struct CookieIdentity: Hashable, Sendable {
        var name: String
        var domain: String
        var path: String

        init(name: String, domain: String, path: String) {
            self.name = name
            self.domain = domain.lowercased()
            self.path = path.isEmpty ? "/" : path
        }
    }

    struct LocalStorageImport: Equatable, Sendable {
        var userScript: String
        var originCount: Int
    }

    struct Record: Codable, Equatable, Sendable {
        var version: Int
        var migratedAt: Date
        var cookiesAccepted: Int
        var cookiesSkipped: Int
        var cookiesFailedToDecrypt: Int
        var cookiesUnreadable: Bool
        var localStorageOrigins: Int
        var indexedDBOriginsLeftBehind: Int

        static let currentVersion = 1
    }

    enum KeychainError: Error {
        case cancelled
        case interactionNotAllowed
        case authenticationFailed
        case itemMissing
        case emptyPassword
        case unavailable(OSStatus)

        /// A later launch can still succeed. A missing item cannot.
        var retriesOnNextLaunch: Bool {
            switch self {
            case .cancelled, .interactionNotAllowed, .authenticationFailed:
                return true
            case .itemMissing, .emptyPassword, .unavailable:
                return false
            }
        }
    }

    /// Nil when this directory was already migrated, or it has no Chromium profile to read.
    static func discover(userDataDirectory: URL, fileManager: FileManager = .default) -> Discovery? {
        let markerURL = userDataDirectory.appendingPathComponent(markerFileName, isDirectory: false)
        guard !fileManager.fileExists(atPath: markerURL.path) else { return nil }

        let profile = userDataDirectory.appendingPathComponent("Default", isDirectory: true)
        let cookies = cookiesDatabase(in: profile, fileManager: fileManager)
        let localStorage = profile.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
        let indexedDB = profile.appendingPathComponent("IndexedDB", isDirectory: true)
        let hasLocalStorage = fileManager.fileExists(atPath: localStorage.path)
        let indexedDBOrigins = indexedDBOriginCount(in: indexedDB, fileManager: fileManager)
        guard cookies != nil || hasLocalStorage || indexedDBOrigins > 0 else { return nil }

        return Discovery(
            profileDirectory: profile,
            cookiesDatabase: cookies,
            localStorageDirectory: hasLocalStorage ? localStorage : nil,
            indexedDBDirectory: indexedDBOrigins > 0 ? indexedDB : nil,
            markerURL: markerURL
        )
    }

    /// `Network/Cookies` is where Chromium has kept the jar since M96. The older path is the fallback.
    static func cookiesDatabase(in profile: URL, fileManager: FileManager = .default) -> URL? {
        let modern = profile.appendingPathComponent("Network/Cookies", isDirectory: false)
        if fileManager.fileExists(atPath: modern.path) { return modern }
        let legacy = profile.appendingPathComponent("Cookies", isDirectory: false)
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return nil
    }

    static func indexedDBOriginCount(in directory: URL?, fileManager: FileManager = .default) -> Int {
        guard let directory else { return 0 }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".indexeddb.leveldb") }.count
    }

    static func keychainPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: safeStorageService,
            kSecAttrAccount as String: safeStorageAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let password = item as? Data, !password.isEmpty else { throw KeychainError.emptyPassword }
        return password
    }

    static func readJar(cookiesDatabase: URL, key: Data) throws -> ArcCookieJar {
        try ArcCookieDecryptor.readJar(cookiesDatabase: cookiesDatabase, browser: .chrome, key: key)
    }

    /// Session cookies stay. An expiry already in the past is not a session cookie and is dropped.
    static func importableCookies(_ cookies: [ArcCookie], now: Date = Date()) -> [ArcCookie] {
        cookies.filter { cookie in
            guard !cookie.name.isEmpty else { return false }
            guard let expiresAt = cookie.expiresAt else { return true }
            return expiresAt > now
        }
    }

    /// Skips a cookie WebKit already has, so a later WebKit login is not replaced by the older Chromium one.
    static func cookiesToInstall(
        _ cookies: [ArcCookie],
        alreadyPresent: Set<CookieIdentity>,
        now: Date = Date()
    ) -> [ArcCookie] {
        var seen = alreadyPresent
        var result: [ArcCookie] = []
        for cookie in importableCookies(cookies, now: now) {
            let identity = CookieIdentity(name: cookie.name, domain: cookie.hostKey, path: cookie.path)
            guard seen.insert(identity).inserted else { continue }
            result.append(cookie)
        }
        return result
    }

    /// Document-start script. Sets only keys the page does not already have. Partitioned and
    /// non-web origins are omitted: the script looks entries up by `location.origin`.
    static func localStorageImport(in leveldb: URL, fileManager: FileManager = .default) -> LocalStorageImport? {
        guard fileManager.fileExists(atPath: leveldb.path),
              let records = try? LevelDBReader.readAll(directory: leveldb)
        else { return nil }

        var byOrigin: [String: [String: String]] = [:]
        for record in records {
            guard let origin = LocalStorageKey.storageKey(of: record.key),
                  isPageOrigin(origin),
                  let item = LocalStorageKey.itemName(of: record.key),
                  let value = LocalStorageKey.stringValue(of: record.value)
            else { continue }
            byOrigin[origin, default: [:]][item] = value
        }
        guard !byOrigin.isEmpty else { return nil }

        let data = (try? JSONSerialization.data(withJSONObject: byOrigin, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        let source = """
        (function() {
          var imported = \(json);
          var items = imported[location.origin];
          if (!items) return;
          Object.keys(items).forEach(function(key) {
            try { if (localStorage.getItem(key) === null) localStorage.setItem(key, items[key]); } catch (e) {}
          });
        })();
        """
        return LocalStorageImport(userScript: source, originCount: byOrigin.count)
    }

    static func isPageOrigin(_ storageKey: String) -> Bool {
        LocalStorageKey.isWebOrigin(storageKey) && !storageKey.contains("^0")
    }

    static func write(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        logger.notice("""
        recorded chromium site-data migration at \(url.path, privacy: .public): \
        \(record.cookiesAccepted, privacy: .public) cookies, \
        \(record.localStorageOrigins, privacy: .public) local-storage origins, \
        \(record.indexedDBOriginsLeftBehind, privacy: .public) indexedDB origins left behind
        """)
    }

    private static func keychainError(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecUserCanceled: return .cancelled
        case errSecInteractionNotAllowed: return .interactionNotAllowed
        case errSecAuthFailed: return .authenticationFailed
        case errSecItemNotFound: return .itemMissing
        default: return .unavailable(status)
        }
    }
}
