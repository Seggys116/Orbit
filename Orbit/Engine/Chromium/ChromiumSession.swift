//  One content::BrowserContext backs every ChromiumSession; per-session isolation
//  is a later slice, so cookies/user agent/content settings are process-wide.

import Foundation
import OSLog

@MainActor
final class ChromiumSession: EngineSession {

    let identifier: String
    let isPersistent: Bool

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "ChromiumSession")

    init(identifier: String, persistent: Bool) {
        self.identifier = identifier
        self.isPersistent = persistent
    }

    var storageURL: URL? {
        OrbitChromiumBridge.shared.browserContextPathValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // Process-wide: content:: has no narrower, session-scoped notion of "the" user agent.
    func setUserAgent(_ userAgent: String) {
        OrbitChromiumBridge.shared.setUserAgent(userAgent)
    }

    func cookies(for url: URL) async -> [HTTPCookie] {
        let json = await OrbitChromiumBridge.shared.getCookiesJSON(url: url.absoluteString)
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap(ChromiumSession.httpCookie(from:))
    }

    func deleteCookies(for url: URL) async {
        await OrbitChromiumBridge.shared.deleteCookies(url: url.absoluteString)
    }

    func setCookies(_ cookies: [EngineCookie]) async -> Int {
        guard let json = ChromiumSession.cookiesJSON(cookies) else {
            Self.logger.error("failed to encode \(cookies.count, privacy: .public) EngineCookie(s) for setCookies")
            return 0
        }
        return await OrbitChromiumBridge.shared.setCookiesJSON(json)
    }

    // Backed by OrbitPermissionStore, not components/content_settings (a
    // chrome/-layer subsystem this embedder does not link) -- see
    // orbit_bridge_api.h's OrbitGetContentSetting.
    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting {
        let raw = OrbitChromiumBridge.shared.contentSetting(kind: kind.rawValue, url: url.absoluteString)
        return ContentSetting(rawValue: raw) ?? .unsupported
    }

    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL) {
        OrbitChromiumBridge.shared.setContentSetting(setting.rawValue, kind: kind.rawValue, url: url.absoluteString)
    }

    // MARK: - Cookie JSON mapping

    private static func httpCookie(from dict: [String: Any]) -> HTTPCookie? {
        guard let name = dict["name"] as? String,
              let value = dict["value"] as? String,
              let domain = dict["domain"] as? String,
              let path = dict["path"] as? String
        else { return nil }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if (dict["secure"] as? Bool) == true {
            properties[.secure] = "TRUE"
        }
        // No key for HttpOnly: Foundation only exposes it as a read-only getter,
        // so a cookie built here can never round-trip that bit.
        switch dict["sameSite"] as? String {
        case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        default: break
        }
        if let expiresAt = dict["expiresAt"] as? Double {
            properties[.expires] = Date(timeIntervalSince1970: expiresAt)
        }
        return HTTPCookie(properties: properties)
    }

    private static func cookiesJSON(_ cookies: [EngineCookie]) -> String? {
        let encoded: [[String: Any]] = cookies.map { cookie in
            var dict: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.isSecure,
                "httpOnly": cookie.isHTTPOnly,
                "sameSite": sameSiteString(cookie.sameSite),
            ]
            if let expiresAt = cookie.expiresAt {
                dict["expiresAt"] = expiresAt.timeIntervalSince1970
            }
            return dict
        }
        guard JSONSerialization.isValidJSONObject(encoded),
              let data = try? JSONSerialization.data(withJSONObject: encoded)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func sameSiteString(_ sameSite: EngineCookie.SameSite) -> String {
        switch sameSite {
        case .unspecified: return "unspecified"
        case .none: return "none"
        case .lax: return "lax"
        case .strict: return "strict"
        }
    }
}
