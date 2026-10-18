import AppKit
import WebKit

// Location and notification requests. Both go through the same stored per-site decision and prompt as camera and microphone.
extension WebKitWebContents {

    // MARK: - Geolocation

    // macOS 27 made this public; earlier systems only answer the private selector below.
    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        answerPermission([.geolocation], origin: origin, decisionHandler: decisionHandler)
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webViewPrivateRequestsGeolocation(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        answerPermission([.geolocation], origin: origin, decisionHandler: decisionHandler)
    }

    // MARK: - Notifications

    // Notification permission has no public WKUIDelegate hook.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func webViewRequestsNotificationPermission(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        decisionHandler: @escaping (Bool) -> Void
    ) {
        answerPermission([.notifications], origin: origin) { decision in
            decisionHandler(decision == .grant)
        }
    }

    /// One in-flight lookup per page, origin, and kind set. A burst (the public and private
    /// geolocation hooks, or repeated `watchPosition` calls) shares that answer, and every
    /// WebKit handler still runs once. The entry is dropped when the lookup finishes, so the
    /// next request reads stored settings again and is never granted from this cache.
    private func answerPermission(
        _ kinds: Set<PermissionKind>,
        origin: WKSecurityOrigin,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let originURL = WebKitPermissionPolicy.url(for: origin)
        let key = InFlightPermissionPrompts.key(contents: self, kinds: kinds, origin: originURL)
        if var pending = InFlightPermissionPrompts.waiters[key] {
            pending.append(decisionHandler)
            InFlightPermissionPrompts.waiters[key] = pending
            return
        }
        InFlightPermissionPrompts.waiters[key] = [decisionHandler]
        resolvePermission(kinds, origin: originURL) { decision in
            let pending = InFlightPermissionPrompts.waiters.removeValue(forKey: key) ?? []
            for waiter in pending {
                waiter(decision)
            }
        }
    }
}

@MainActor
private enum InFlightPermissionPrompts {
    static var waiters: [String: [(WKPermissionDecision) -> Void]] = [:]

    static func key(contents: WebKitWebContents, kinds: Set<PermissionKind>, origin: URL) -> String {
        let kindList = kinds.map(\.rawValue).sorted().joined(separator: ",")
        return "\(ObjectIdentifier(contents))|\(origin.absoluteString)|\(kindList)"
    }
}
