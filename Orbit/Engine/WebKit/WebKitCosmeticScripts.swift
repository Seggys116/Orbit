import CryptoKit
import WebKit

/// Cosmetic rules the Safari content rule lists cannot express (exceptions narrower than a rule's domain, domain
/// lists WebKit cannot take) are applied as a stylesheet. It is installed on the user content controller when the
/// navigation is decided, so it runs at document start rather than after the page has painted.
///
/// The first host for a given stylesheet publishes it once, as a function in an isolated world. Later hosts install
/// only a hostname check that calls that function, so the sheet is not copied into another user script and the page
/// cannot read it. The literal stays inside the function and is evaluated only when a frame's hostname matches.
@MainActor
enum WebKitCosmeticScripts {
    /// Aliases do not carry the stylesheet, but each host is still remembered. Past this many, every user script
    /// on the controller is rebuilt and only the host being installed is kept.
    static let hostLimit = 16

    private static let world = WKContentWorld.world(name: "orbit-cosmetic")
    private static let installed = NSMapTable<WKUserContentController, Registry>.weakToStrongObjects()

    private final class Registry: NSObject {
        var hosts = Set<String>()
        /// SHA-256 hex of each stylesheet already published into `world`.
        var published = Set<String>()
    }

    static func isInstalled(_ host: String, on controller: WKUserContentController) -> Bool {
        installed.object(forKey: controller)?.hosts.contains(host) == true
    }

    /// Script installed for the first host of `css`. Further hosts with the same sheet use an alias.
    static func source(css: String, host: String) -> String {
        publisherSource(css: css, host: host, key: stylesheetKey(for: css))
    }

    /// The controller's scripts were just rebuilt, so none of the host scripts remain.
    static func reset(_ controller: WKUserContentController) {
        installed.removeObject(forKey: controller)
    }

    /// `rebuild` must drop every user script and reinstall the base set, calling `reset` on the way.
    static func install(css: String, host: String, on controller: WKUserContentController, rebuild: () -> Void) {
        guard !css.isEmpty else { return }
        var slot = installed.object(forKey: controller)
        if slot?.hosts.contains(host) == true { return }
        if (slot?.hosts.count ?? 0) >= hostLimit {
            rebuild()
            slot = nil
        }
        let record: Registry
        if let slot {
            record = slot
        } else {
            record = Registry()
            installed.setObject(record, forKey: controller)
        }
        // Record the host before building the script so a re-entrant install of the same host does not add a second copy.
        record.hosts.insert(host)
        let key = stylesheetKey(for: css)
        if record.published.contains(key) {
            add(aliasSource(host: host, key: key), to: controller)
        } else {
            // The sheet is recorded only once its script is installed, so a later host's alias runs after it.
            add(publisherSource(css: css, host: host, key: key), to: controller)
            record.published.insert(key)
        }
    }

    private static func stylesheetKey(for css: String) -> String {
        SHA256.hash(data: Data(css.utf8)).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    private static func publisherSource(css: String, host: String, key: String) -> String {
        let keyLiteral = JavaScriptLiteral.string(key)
        let hostLiteral = JavaScriptLiteral.string(host)
        let cssLiteral = JavaScriptLiteral.string(css)
        return """
        (function () {
          var bucket = window.__orbitCosmetic || (window.__orbitCosmetic = {});
          var key = \(keyLiteral);
          if (!bucket[key]) {
            bucket[key] = function () { return \(cssLiteral); };
          }
          if (location.hostname !== \(hostLiteral)) { return; }
          var css = bucket[key]();
          var style = document.createElement('style');
          style.textContent = css;
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    private static func aliasSource(host: String, key: String) -> String {
        let hostLiteral = JavaScriptLiteral.string(host)
        let keyLiteral = JavaScriptLiteral.string(key)
        return """
        (function () {
          if (location.hostname !== \(hostLiteral)) { return; }
          var bucket = window.__orbitCosmetic;
          var read = bucket && bucket[\(keyLiteral)];
          if (!read) { return; }
          var css = read();
          var style = document.createElement('style');
          style.textContent = css;
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    private static func add(_ source: String, to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        ))
    }
}

extension WebKitWebContents {
    func installCosmeticStyleSheet(for url: URL) {
        guard !isExtensionPage, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return }
        let controller = webView.configuration.userContentController
        // The first non-empty sheet for a host wins; later navigations must not rebuild it.
        if WebKitCosmeticScripts.isInstalled(host, on: controller) { return }
        WebKitCosmeticScripts.install(
            css: engine.cosmeticStyleSheet(for: url.absoluteString),
            host: host,
            on: controller,
            rebuild: { reinstallScripts() }
        )
    }
}
