import WebKit

// WKWebpagePreferences carries a per-navigation user agent only through SPI on macOS.
// The Chrome identity is applied only when the caller passes it (web-store hosts). nil clears
// the override so the navigation keeps WebKit's product user agent. Both strings repeat, so
// the bridged copies are reused instead of rebuilt on every main-frame policy decision.
enum WebKitNavigationUserAgent {
    private static let setter = NSSelectorFromString("_setCustomUserAgent:")
    private static let clearedAgent: NSString = ""
    private static var bridgedOverride: (source: String, agent: NSString)?

    static func set(_ userAgent: String?, on preferences: WKWebpagePreferences) {
        guard preferences.responds(to: setter) else { return }
        preferences.perform(setter, with: bridged(userAgent))
    }

    private static func bridged(_ userAgent: String?) -> NSString {
        guard let userAgent else { return clearedAgent }
        if let bridgedOverride, bridgedOverride.source == userAgent {
            return bridgedOverride.agent
        }
        let agent = userAgent as NSString
        bridgedOverride = (userAgent, agent)
        return agent
    }
}
