import Foundation
import WebKit

extension WebKitWebContents {
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool

    // Selectors are interned once. This callback runs for every content-rule hit.
    private static let blockedLoadSelector = NSSelectorFromString("blockedLoad")
    private static let redirectedSelector = NSSelectorFromString("redirected")

    // Reported by WebKit through its private navigation delegate callback for each blocked or redirected load.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func orbitContentRuleList(_ webView: WKWebView, identifier: String, action: AnyObject, url: URL) {
        guard identifier.hasPrefix(WebKitContentBlocking.identifierPrefix),
              let coordinator = WebKitContentBlocking.coordinator(for: webView.configuration.userContentController),
              let blocker = coordinator.blocker,
              let object = action as? NSObject
        else { return }
        guard Self.isSet(object, Self.blockedLoadSelector) || Self.isSet(object, Self.redirectedSelector) else { return }
        blocker.recordBlockedRequest(documentHost: webView.url?.host)
    }

    // Same result as KVC on these BOOL properties, without interning a selector or boxing an NSNumber per hit.
    private static func isSet(_ object: NSObject, _ selector: Selector) -> Bool {
        guard object.responds(to: selector) else { return false }
        let implementation = object.method(for: selector)
        return unsafeBitCast(implementation, to: BoolGetter.self)(object, selector)
    }
}
