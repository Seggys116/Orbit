import Foundation
import WebKit

extension WKWebExtensionContext {
    // WebKit keeps the background page's web view private; a selector missing on a future OS reports none rather than crashing.
    var orbitBackgroundWebView: WKWebView? {
        let name = "_backgroundWebView"
        guard responds(to: NSSelectorFromString(name)) else { return nil }
        return value(forKey: name) as? WKWebView
    }
}
