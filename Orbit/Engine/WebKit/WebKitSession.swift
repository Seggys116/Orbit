import Foundation
import WebKit

@MainActor
final class WebKitSession: EngineSession {
    let identifier: String
    let isPersistent: Bool
    let storageURL: URL?
    let dataStore: WKWebsiteDataStore
    var userAgent: String?

    private var settings: [String: ContentSetting] = [:]

    init(identifier: String, persistent: Bool, storageURL: URL?) {
        self.identifier = identifier
        self.isPersistent = persistent
        self.storageURL = storageURL
        if persistent {
            let uuid = Self.stableUUID(for: identifier)
            self.dataStore = WKWebsiteDataStore(forIdentifier: uuid)
        } else {
            self.dataStore = .nonPersistent()
        }
    }

    func setUserAgent(_ userAgent: String) {
        self.userAgent = userAgent
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
    }

    func clear(_ scope: BrowsingDataScope, since: Date?) async {
        var types = Set<String>()
        if scope.contains(.cookies) { types.insert(WKWebsiteDataTypeCookies) }
        if scope.contains(.cache) { types.insert(WKWebsiteDataTypeDiskCache) }
        guard !types.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.removeData(ofTypes: types, modifiedSince: since ?? .distantPast) {
                continuation.resume()
            }
        }
    }

    private static func key(_ kind: PermissionKind, _ origin: URL) -> String {
        "\(kind.rawValue) \(origin.absoluteString)"
    }

    private static func stableUUID(for identifier: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let data = Array(identifier.utf8)
        for (index, byte) in data.enumerated() {
            bytes[index % 16] ^= byte &+ UInt8(index)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
