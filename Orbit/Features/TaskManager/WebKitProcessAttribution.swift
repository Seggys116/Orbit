import Foundation
import WebKit

// Which WebKit service processes belong to Orbit's web views. They are XPC services launched by
// launchd, so no parent/child walk finds them, and WebKit has no public API for their pids.
nonisolated struct WebKitProcessAttribution: Equatable, Sendable {

    var roles: [pid_t: OrbitProcessInfo.Role]
    var tabTitles: [pid_t: [String]]
    // Names of the extensions whose background pages, offscreen documents or pages a process hosts.
    var extensionNames: [pid_t: [String]] = [:]

    static let none = WebKitProcessAttribution(roles: [:], tabTitles: [:], extensionNames: [:])

    var processIdentifiers: [pid_t] { roles.keys.sorted() }

    @MainActor
    static func gather(
        from webViews: [WKWebView],
        extensionViews: [(name: String, webView: WKWebView)] = []
    ) -> WebKitProcessAttribution {
        var attribution = WebKitProcessAttribution.none
        // Hits only. A miss is not stored: a later call must still be allowed to succeed, and a
        // dictionary cannot remember a nil without deleting the key.
        var resolved: [ObjectIdentifier: [String: pid_t]] = [:]
        func pid(of webView: WKWebView, selector: String) -> pid_t? {
            let key = ObjectIdentifier(webView)
            if let cached = resolved[key]?[selector] { return cached }
            guard let found = Self.processIdentifier(webView, selector: selector) else { return nil }
            resolved[key, default: [:]][selector] = found
            return found
        }

        for webView in webViews {
            for (selector, role) in Self.reporters {
                guard let found = pid(of: webView, selector: selector) else { continue }
                if attribution.roles[found] == nil { attribution.roles[found] = role }
            }
            if let found = pid(of: webView, selector: "_webProcessIdentifier") {
                let title = webView.title ?? ""
                if !title.isEmpty, attribution.tabTitles[found]?.contains(title) != true {
                    attribution.tabTitles[found, default: []].append(title)
                }
            }
        }
        // After the tabs, so a process shared with a tab stays a web page process and keeps its tab titles.
        for (name, webView) in extensionViews {
            for (selector, role) in Self.extensionReporters {
                guard let found = pid(of: webView, selector: selector) else { continue }
                if attribution.roles[found] == nil { attribution.roles[found] = role }
            }
            if let found = pid(of: webView, selector: "_webProcessIdentifier"),
               !name.isEmpty, attribution.extensionNames[found]?.contains(name) != true {
                attribution.extensionNames[found, default: []].append(name)
            }
        }
        return attribution
    }

    private static let extensionReporters: [(String, OrbitProcessInfo.Role)] = [
        ("_webProcessIdentifier", .extensionProcess),
        ("_networkProcessIdentifier", .networking),
        ("_gpuProcessIdentifier", .gpu),
    ]

    private static let reporters: [(String, OrbitProcessInfo.Role)] = [
        ("_webProcessIdentifier", .webContent),
        ("_networkProcessIdentifier", .networking),
        ("_gpuProcessIdentifier", .gpu),
    ]

    // The one place that touches WKWebView SPI. A selector missing on a future OS reports no
    // process rather than crashing, and the Task Manager then shows only what it can prove.
    @MainActor
    private static func processIdentifier(_ webView: WKWebView, selector name: String) -> pid_t? {
        guard webView.responds(to: NSSelectorFromString(name)),
              let number = webView.value(forKey: name) as? NSNumber else { return nil }
        let pid = pid_t(truncatingIfNeeded: number.int32Value)
        return pid > 0 && pid != getpid() ? pid : nil
    }
}
