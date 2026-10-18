import Foundation
import OSLog
import WebKit

@MainActor
final class WebKitSession: EngineSession {
    let identifier: String
    let isPersistent: Bool
    let storageURL: URL?
    private(set) var dataStore: WKWebsiteDataStore
    /// An explicit override; nil means each web view sends its own default identity.
    private(set) var userAgent: String?
    private let attachedViews = NSHashTable<WKWebView>.weakObjects()

    // nil for a non-persistent session: its decisions live and die in memory.
    let contentSettingsFileURL: URL?

    private var settings: [String: ContentSetting]

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "WebKitSession")

    // The production engine passes a nil storageURL, so decisions land in the process data root.
    init(identifier: String, persistent: Bool, storageURL: URL?, settingsDirectory: URL? = nil) {
        self.identifier = identifier
        self.isPersistent = persistent
        self.storageURL = storageURL
        if persistent {
            self.dataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier(for: identifier))
            let directory = settingsDirectory
                ?? storageURL?.appendingPathComponent("ContentSettings", isDirectory: true)
                ?? OrbitDataRoot.processDefault.contentSettings
            let file = directory.appendingPathComponent(Self.settingsFileName(for: identifier), isDirectory: false)
            self.contentSettingsFileURL = file
            self.settings = Self.loadSettings(from: file)
        } else {
            self.dataStore = .nonPersistent()
            self.contentSettingsFileURL = nil
            self.settings = [:]
        }
    }

    // An empty string clears the override.
    func setUserAgent(_ userAgent: String) {
        self.userAgent = userAgent.isEmpty ? nil : userAgent
        for view in attachedViews.allObjects { view.customUserAgent = self.userAgent }
    }

    // Web views join here so a later override reaches them too.
    func attach(_ view: WKWebView) {
        attachedViews.add(view)
        view.customUserAgent = userAgent
        WebKitNotificationPresenter.shared.install(on: dataStore) { [weak self] origin in
            self?.activateTab(showing: origin)
        }
    }

    // A clicked notification brings forward a tab on the origin that posted it.
    private func activateTab(showing origin: String) {
        let target = URL(string: origin)
        let match = attachedViews.allObjects.compactMap { $0 as? OrbitWebView }.first { view in
            guard let url = view.url, let target else { return false }
            return url.scheme == target.scheme && url.host() == target.host() && url.port == target.port
        }
        guard let contents = match?.menuOwner else { return }
        contents.delegate?.webContentsDidRequestActivation(contents)
    }

    /// document.cookie changes the store without going through chrome.cookies.set.
    var onCookieChanged: (@MainActor (HTTPCookie, Bool) -> Void)?
    private var knownCookies: [String: HTTPCookie] = [:]
    private var cookieObserver: CookieStoreObserver?
    private var cookieWatchStarted = false

    func startWatchingCookies() {
        guard !cookieWatchStarted else { return }
        cookieWatchStarted = true
        let store = dataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self else { return }
                self.knownCookies = Dictionary(uniqueKeysWithValues: cookies.map { (Self.cookieKey($0), $0) })
                let observer = CookieStoreObserver(session: self)
                self.cookieObserver = observer
                store.add(observer)
            }
        }
    }

    fileprivate func noteCookies(_ cookies: [HTTPCookie]) {
        var next: [String: HTTPCookie] = [:]
        for cookie in cookies {
            let key = Self.cookieKey(cookie)
            next[key] = cookie
            if knownCookies[key] == nil {
                onCookieChanged?(cookie, false)
            }
        }
        for (key, cookie) in knownCookies where next[key] == nil {
            onCookieChanged?(cookie, true)
        }
        knownCookies = next
    }

    private static func cookieKey(_ cookie: HTTPCookie) -> String {
        "\(cookie.name)|\(cookie.domain)|\(cookie.path)"
    }

    func cookies(for url: URL) async -> [HTTPCookie] {
        let all = await dataStore.httpCookieStore.allCookies()
        return all.filter { Self.cookie($0, matches: url) }
    }

    func deleteCookies(for url: URL) async {
        let matching = await cookies(for: url)
        for cookie in matching {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }

    func setCookies(_ cookies: [EngineCookie]) async -> Int {
        var accepted = 0
        for cookie in cookies {
            guard let http = Self.httpCookie(from: cookie) else { continue }
            await dataStore.httpCookieStore.setCookie(http)
            accepted += 1
        }
        return accepted
    }

    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting {
        guard let origin = ContentSettingOrigin.normalize(url) else { return .unsupported }
        return settings[Self.key(kind, origin)] ?? .ask
    }

    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL) {
        guard let origin = ContentSettingOrigin.normalize(url) else { return }
        let key = Self.key(kind, origin)
        if setting == .ask {
            settings.removeValue(forKey: key)
        } else {
            settings[key] = setting
        }
        _ = persistSettings()
    }

    /// False when the stored decisions could not be removed from disk.
    @discardableResult
    func clearContentSettings() -> Bool {
        settings.removeAll()
        return persistSettings()
    }

    // `.cookies` is the whole cookies-and-site-data scope, not cookies alone.
    static func dataTypes(for scope: BrowsingDataScope) -> Set<String> {
        var types = Set<String>()
        if scope.contains(.cookies) {
            types.formUnion([
                WKWebsiteDataTypeCookies,
                WKWebsiteDataTypeLocalStorage,
                WKWebsiteDataTypeSessionStorage,
                WKWebsiteDataTypeIndexedDBDatabases,
                WKWebsiteDataTypeServiceWorkerRegistrations,
                WKWebsiteDataTypeWebSQLDatabases,
                WKWebsiteDataTypeFileSystem,
                WKWebsiteDataTypeHashSalt,
                WKWebsiteDataTypeMediaKeys,
                WKWebsiteDataTypeSearchFieldRecentSearches,
            ])
        }
        if scope.contains(.cache) {
            types.formUnion([
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache,
            ])
        }
        return types
    }

    func clear(_ scope: BrowsingDataScope, since: Date?) async {
        await removeData(ofTypes: Self.dataTypes(for: scope), since: since)
    }

    // Every type this OS knows, including ones no scope names.
    func clearAllWebsiteData() async {
        await removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), since: nil)
    }

    // WebKit refuses while a web view still uses the store, so callers release tabs first.
    // The store is released and recreated under the same identifier so later web views get a fresh one.
    // It is not recreated until removal ends: a live instance makes WebKit report "in use" forever.
    func removePersistentDataStore() async -> Bool {
        guard isPersistent else { return true }
        let uuid = Self.dataStoreIdentifier(for: identifier)
        dataStore = .nonPersistent()
        var removed = false
        // The web process drops a closed view's store asynchronously, so "in use" may clear shortly.
        for attempt in 0..<Self.removeAttempts {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: uuid)
                removed = true
                break
            } catch {
                let inUse = Self.isDataStoreInUse(error)
                if inUse, attempt + 1 < Self.removeAttempts {
                    try? await Task.sleep(for: Self.removeRetryDelay)
                    continue
                }
                Self.logger.error("could not remove data store for \(self.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
                break
            }
        }
        dataStore = WKWebsiteDataStore(forIdentifier: uuid)
        return removed
    }

    private static let removeAttempts = 21
    private static let removeRetryDelay = Duration.milliseconds(100)

    private static func isDataStoreInUse(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "WKWebSiteDataStore" && nsError.code == 1
    }

    private func removeData(ofTypes types: Set<String>, since: Date?) async {
        guard !types.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.removeData(ofTypes: types, modifiedSince: since ?? .distantPast) {
                continuation.resume()
            }
        }
    }

    // MARK: - Content settings persistence

    private struct StoredSettings: Codable {
        var version = 1
        var settings: [String: ContentSetting]
    }

    static func settingsFileName(for identifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? UUID().uuidString
        return "\(encoded).json"
    }

    private static func loadSettings(from file: URL) -> [String: ContentSetting] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        guard let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
            logger.error("ignoring unreadable content settings at \(file.path, privacy: .public)")
            return [:]
        }
        return stored.settings.filter { $0.value != .ask && $0.value != .unsupported }
    }

    // An empty set removes the file rather than leaving an empty document behind.
    private func persistSettings() -> Bool {
        guard let file = contentSettingsFileURL else { return true }
        let manager = FileManager.default
        if settings.isEmpty {
            guard manager.fileExists(atPath: file.path) else { return true }
            do {
                try manager.removeItem(at: file)
                return true
            } catch {
                Self.logger.error("could not remove content settings: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        do {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(StoredSettings(settings: settings)).write(to: file, options: .atomic)
            return true
        } catch {
            Self.logger.error("could not write content settings: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func key(_ kind: PermissionKind, _ origin: URL) -> String {
        "\(kind.rawValue) \(origin.absoluteString)"
    }

    static func dataStoreIdentifier(for identifier: String) -> UUID {
        WebKitDataStoreIdentifiers.shared.identifier(for: identifier)
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }

    private static func httpCookie(from cookie: EngineCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path.isEmpty ? "/" : cookie.path,
        ]
        if cookie.isSecure { properties[.secure] = "TRUE" }
        if let expiresAt = cookie.expiresAt { properties[.expires] = expiresAt }
        switch cookie.sameSite {
        case .none: properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: "none")
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }
}

private final class CookieStoreObserver: NSObject, WKHTTPCookieStoreObserver {
    weak var session: WebKitSession?

    init(session: WebKitSession) {
        self.session = session
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                self?.session?.noteCookies(cookies)
            }
        }
    }
}
