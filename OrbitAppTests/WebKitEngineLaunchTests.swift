import WebKit
import XCTest
@testable import Orbit

@MainActor
final class WebKitEngineLaunchTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach {
            $0.contentView = nil
            $0.orderOut(nil)
        }
        windows.removeAll()
        super.tearDown()
    }

    func testShippedEngineLoadsFixtureTextAsWebKit() async throws {
        let fixture = "orbit-webkit-fixture-text"
        let html = "<!doctype html><html><body><p id=\"fixture\">\(fixture)</p></body></html>"
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        XCTAssertEqual(type(of: engine).kind, .webkit)
        XCTAssertTrue(engine.versionDescription.contains("WebKit"))
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        host(contents)
        contents.loadHTML(html, baseURL: URL(string: "https://orbit.test/"))
        let text = try await waitForText(contents, script: "document.getElementById('fixture') ? document.getElementById('fixture').textContent : ''", equals: fixture)
        XCTAssertEqual(text, fixture)
        engine.shutdown()
    }

    /// Factory boot, private storage, then a background script's chrome.bookmarks.getTree.
    func testFactoryInstallsAChromeExtensionAndBookmarksAnswers() async throws {
        let previousRoot = AppEnvironment.processRoot
        let environment = LiveEnvironmentTestCase.makeEnvironmentWithNoOpenTabs()
        AppEnvironment.processRoot = environment
        defer { AppEnvironment.processRoot = previousRoot }

        let engine = EngineFactory.makeEngine(storage: .isolated)
        defer { engine.shutdown() }
        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertEqual(type(of: engine).kind, .webkit)
        print("ENGINE \(type(of: engine).kind.rawValue)")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-factory-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        {
          "manifest_version": 3,
          "name": "Orbit Factory Probe",
          "version": "1.0.0",
          "description": "Asks chrome.bookmarks for the real tree.",
          "permissions": ["bookmarks"],
          "background": { "service_worker": "background.js" }
        }
        """.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.bookmarks.getTree(function () {});
        """.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try """
        document.title = "script-started";
        try {
          chrome.bookmarks.getTree(function (tree) {
            var err = chrome.runtime && chrome.runtime.lastError;
            document.title = err ? ("lastError:" + err.message) : JSON.stringify(tree);
          });
        } catch (e) {
          document.title = "threw:" + String(e);
        }
        """.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)
        try """
        <!doctype html><html><head><title>pending</title></head>
        <body><script src="orbit-chrome-wrapper.js"></script><script src="probe.js"></script></body>
        </html>
        """.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let loaded = try await webKit.loadExtension(at: directory, session: engine.defaultSession)
        let contents = try XCTUnwrap(
            try webKit.makeWebContents(session: engine.defaultSession, initialURL: nil) as? WebKitWebContents
        )
        host(contents)
        contents.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
        let result = try await waitForText(contents, script: "document.title", equals: "") { title in
            title.contains("\"permanent\"")
        }
        let stable = result
            .replacing(/"id":"[^"]*"/, with: "\"id\":\"_\"")
            .replacing(/"dateAdded":[0-9]+/, with: "\"dateAdded\":0")
        let object = try JSONSerialization.jsonObject(with: Data(stable.utf8))
        let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let canonical = String(decoding: canonicalData, as: UTF8.self)
        print("CHROME_BOOKMARKS \(canonical)")
        XCTAssertTrue(result.contains("\"id\""), result)
        XCTAssertTrue(result.contains("\"permanent\""), result)
        XCTAssertTrue(result.contains("https://www.google.com"), result)
        XCTAssertFalse(result.contains("__orbitError"), result)

        // getTree answers a one-element array holding the root; the expectation is built from the environment's own spaces and favourites
        let actualTree = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]], result)
        XCTAssertEqual(
            actualTree as NSArray, [Self.expectedBookmarkRoot(for: environment.state)] as NSArray,
            "chrome.bookmarks.getTree must return the root, a node per space, and under each its Favourites and Pinned folders"
        )
    }

    /// Spaces by order, then creation date, then id; each holds a Favourites folder of its favourites and an empty Pinned folder.
    private static func expectedBookmarkRoot(for state: OrbitState) -> [String: Any] {
        func milliseconds(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }
        let spaces = state.spaces.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let spaceNodes: [[String: Any]] = spaces.enumerated().map { index, space in
            let id = space.id.uuidString.lowercased()
            let favourites: [[String: Any]] = space.favorites.enumerated().map { position, favourite in
                [
                    "id": "b:" + favourite.id.uuidString.lowercased(), "parentId": "f:" + id, "index": position,
                    "title": favourite.title, "syncing": false, "url": favourite.url.absoluteString,
                ]
            }
            let children: [[String: Any]] = [
                [
                    "id": "f:" + id, "parentId": "s:" + id, "index": 0, "title": "Favourites",
                    "syncing": false, "permanent": true, "children": favourites,
                ],
                [
                    "id": "p:" + id, "parentId": "s:" + id, "index": 1, "title": "Pinned",
                    "syncing": false, "permanent": true, "children": [] as [[String: Any]],
                ],
            ]
            return [
                "id": "s:" + id, "parentId": "0", "index": index, "title": space.name, "syncing": false,
                "permanent": true, "dateAdded": milliseconds(space.createdAt), "children": children,
            ]
        }
        return ["id": "0", "title": "", "permanent": true, "syncing": false, "children": spaceNodes]
    }

    func testCosmeticAndStylesheetCSSStayData() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        var rules = ContentBlockerRuleSet()
        // The `${...}` bodies are template-literal syntax; they must reach the page as CSS text and never be evaluated.
        rules.add(listText: "##${window.__orbitPwned=1}", listID: "cosmetic")
        let blocker = ContentBlocker()
        blocker.isEnabled = true
        blocker.setRuleSet(rules)
        await engine.applyContentBlocker(blocker, session: engine.defaultSession)
        engine.addUserScript(
            UserScript(kind: .stylesheet, source: "${window.__orbitSheet=1}", injectionTime: .documentStart),
            session: engine.defaultSession
        )
        let pageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-css-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pageRoot) }
        try "<!doctype html><html><body><p id=\"fixture\">orbit-webkit-fixture-text</p></body></html>"
            .write(to: pageRoot.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        let port = 18990
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", pageRoot.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        // Give the server time to bind before the first request.
        Thread.sleep(forTimeInterval: 0.3)
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        host(contents)
        contents.load(URL(string: "http://127.0.0.1:\(port)/page.html")!)
        let text = try await waitForText(
            contents,
            script: "document.getElementById('fixture') ? document.getElementById('fixture').textContent : ''",
            equals: "orbit-webkit-fixture-text"
        )
        XCTAssertEqual(text, "orbit-webkit-fixture-text")
        let stylesJSON = try await waitForText(
            contents,
            script: "JSON.stringify(Array.from(document.querySelectorAll('style')).map(function(node){return node.textContent||'';}))",
            equals: "pending-style"
        ) { latest in
            latest.contains("__orbitPwned") && latest.contains("__orbitSheet")
        }
        let styles = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stylesJSON.utf8)) as? [String],
            "the page's style elements did not come back as a JSON array: \(stylesJSON)"
        )
        // the user stylesheet is injected verbatim; the cosmetic rule is one hide rule built from its selector
        XCTAssertEqual(styles.filter { $0.contains("__orbitSheet") }, ["${window.__orbitSheet=1}"])
        XCTAssertEqual(styles.filter { $0.contains("__orbitPwned") }, ["${window.__orbitPwned=1} { display: none !important; }\n"])
        // typeof, so a script that never ran reads differently from one that ran and set nothing
        let flags = try await waitForText(
            contents,
            script: "'flags:' + typeof window.__orbitPwned + ',' + typeof window.__orbitSheet",
            equals: "flags:undefined,undefined"
        )
        XCTAssertEqual(flags, "flags:undefined,undefined", "the ${...} bodies must reach the page as CSS text and never be evaluated")
        engine.shutdown()
    }

    func testTargetBlankOpensTheDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-blank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<!doctype html><html><body><a id=\"open\" target=\"_blank\" href=\"opened.html\">open</a><p id=\"fixture\">ready</p></body></html>"
            .write(to: root.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body><p id=\"opened\">opened-document-text</p></body></html>"
            .write(to: root.appendingPathComponent("opened.html"), atomically: true, encoding: .utf8)
        let port = 8891
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.3)

        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        host(contents)
        let adopter = WebKitWindowOpenDelegate()
        adopter.host = { [weak self] opened in self?.host(opened) }
        contents.delegate = adopter
        contents.load(URL(string: "http://127.0.0.1:\(port)/page.html")!)
        let ready = try await waitForText(
            contents,
            script: "document.getElementById('fixture') ? document.getElementById('fixture').textContent : ''",
            equals: "ready"
        )
        XCTAssertEqual(ready, "ready")
        _ = try await contents.evaluateJavaScript("document.getElementById('open').click()")
        let deadline = Date().addingTimeInterval(15)
        var openedText = ""
        while Date() < deadline {
            if let opened = adopter.opened {
                openedText = (try? await opened.evaluateJavaScript("document.getElementById('opened') ? document.getElementById('opened').textContent : ''")) as? String ?? ""
                if openedText == "opened-document-text" { break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let openerView = try XCTUnwrap(contents.view as? WKWebView)
        let openedView = try XCTUnwrap(adopter.opened?.view as? WKWebView)
        XCTAssertTrue(openedView.configuration.webExtensionController === openerView.configuration.webExtensionController)
        XCTAssertEqual(openedText, "opened-document-text")
        engine.shutdown()
    }

    func testPageMenuAndInspectorAndWebStoreAreInstalled() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let contents = try XCTUnwrap(try engine.makeWebContents(session: engine.defaultSession, initialURL: nil) as? WebKitWebContents)
        host(contents)
        contents.loadHTML("<!doctype html><html><body><a id=\"link\" href=\"https://example.com/dest\">go</a></body></html>", baseURL: URL(string: "https://example.com/page"))
        let ready = try await waitForText(
            contents,
            script: "document.getElementById('link') ? document.getElementById('link').textContent : ''",
            equals: "go"
        )
        XCTAssertEqual(ready, "go")
        let agent = try await waitForText(contents, script: "navigator.userAgent", equals: "pending") { text in
            text.contains("Safari/") && text.contains("AppleWebKit")
        }
        XCTAssertEqual(agent, WebKitProduct.userAgent)
        XCTAssertFalse(agent.contains("Chrome/"))
        // The Web Store scripts are added only when a main-frame navigation targets the store, never to every page.
        let ordinarySources = contents.webView.configuration.userContentController.userScripts.map(\.source).joined(separator: "\n")
        XCTAssertFalse(ordinarySources.contains("__orbitWebStorePrivate"))
        XCTAssertFalse(ordinarySources.contains("__orbitOwnsAddToChromeButton"))
        let recorder = PageMenuRecorder()
        contents.delegate = recorder
        contents.openContextMenu(atCSS: CGPoint(x: 8, y: 8))
        let deadline = Date().addingTimeInterval(5)
        while recorder.context == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let context = try XCTUnwrap(recorder.context)
        XCTAssertEqual(context.linkURL?.absoluteString, "https://example.com/dest")
        contents.showDeveloperTools(inspectAt: CGPoint(x: 8, y: 8))
        let inspectorDeadline = Date().addingTimeInterval(3)
        var inspectorOpen = false
        while Date() < inspectorDeadline {
            if contents.developerToolsAreOpen() {
                inspectorOpen = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(inspectorOpen)
        XCTAssertTrue(NSApp.windows.contains { $0.isVisible && $0.title.hasPrefix("Web Inspector") })
        XCTAssertTrue(contents.webView.isInspectable)
        engine.shutdown()
    }

    func testWebStoreScriptsAreInstalledForAStoreNavigation() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let contents = try XCTUnwrap(try engine.makeWebContents(session: engine.defaultSession, initialURL: nil) as? WebKitWebContents)
        host(contents)
        contents.loadHTML(
            "<!doctype html><html><head><title>store</title></head><body><p>store</p></body></html>",
            baseURL: URL(string: "https://chromewebstore.google.com/detail/example/abcdefghijklmnopabcdefghijklmnop")
        )
        _ = try await waitForText(contents, script: "document.title", equals: "store")
        let sources = contents.webView.configuration.userContentController.userScripts.map(\.source).joined(separator: "\n")
        XCTAssertTrue(sources.contains("__orbitWebStorePrivate"))
        XCTAssertTrue(sources.contains("__orbitOwnsAddToChromeButton"))
        engine.shutdown()
    }

    func testDeveloperToolsWindowOpensOnRequest() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let contents = try XCTUnwrap(try engine.makeWebContents(session: engine.defaultSession, initialURL: nil) as? WebKitWebContents)
        host(contents)
        contents.loadHTML("<!doctype html><html><head><title>probe</title></head><body><p>page</p></body></html>", baseURL: URL(string: "https://example.com/probe"))
        _ = try await waitForText(contents, script: "document.title", equals: "probe")
        contents.showDeveloperTools(inspectAt: nil)
        let open = try await waitForText(contents, script: "document.title", equals: "probe") { _ in
            NSApp.windows.contains { $0.isVisible && $0.title.hasPrefix("Web Inspector") }
        }
        XCTAssertEqual(open, "probe")
        XCTAssertTrue(NSApp.windows.contains { $0.isVisible && $0.title.hasPrefix("Web Inspector") })
        engine.shutdown()
    }

    private func host(_ contents: WebContents) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isRestorable = false
        window.contentView = contents.view
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    private func waitForText(
        _ contents: WebContents,
        script: String,
        equals expected: String,
        accept: ((String) -> Bool)? = nil
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(20)
        var latest = ""
        while Date() < deadline {
            if let value = try? await contents.evaluateJavaScript(script), let text = value as? String {
                latest = text
                if let accept {
                    if accept(text) { return text }
                } else if text == expected {
                    return text
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return latest
    }

    func testClearingCacheReloadsTheDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = root.appendingPathComponent("body.txt")
        try "cache-first".write(to: body, atomically: true, encoding: .utf8)
        // The server sends max-age=600, so the second load can only differ if the cache was really cleared.
        let port = 18_980
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
import http.server
body = r'''\(body.path)'''
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = open(body, encoding='utf-8').read().encode()
        page = ('<!doctype html><html><body><p id="marker">' + data.decode() + '</p></body></html>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Cache-Control', 'max-age=600')
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)
    def log_message(self, *args):
        pass
http.server.HTTPServer(('127.0.0.1', \(port)), H).serve_forever()
"""]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        host(contents)
        contents.load(URL(string: "http://127.0.0.1:\(port)/")!)
        let first = try await waitForText(
            contents,
            script: "document.getElementById('marker') ? document.getElementById('marker').textContent : ''",
            equals: "cache-first"
        )
        XCTAssertEqual(first, "cache-first")
        try "cache-second".write(to: body, atomically: true, encoding: .utf8)
        await engine.clearBrowsingData(.cache, session: contents.session, since: nil)
        contents.reload(ignoringCache: true)
        let second = try await waitForText(
            contents,
            script: "document.getElementById('marker') ? document.getElementById('marker').textContent : ''",
            equals: "cache-second"
        )
        XCTAssertEqual(second, "cache-second")
        engine.shutdown()
    }

}

@MainActor
final class PageMenuRecorder: NSObject, WebContentsDelegate {
    var context: ContextMenuContext?

    func webContents(_ contents: WebContents, showContextMenu context: ContextMenuContext) -> Bool {
        self.context = context
        return true
    }
}

@MainActor
final class WebKitWindowOpenDelegate: NSObject, WebContentsDelegate {
    var host: ((WebContents) -> Void)?
    private(set) var opened: WebContents?

    func webContents(_ contents: WebContents, requestsAdoptionOf pending: PendingWebContents) -> Bool {
        guard let adopted = pending.adopt() else { return false }
        opened = adopted
        host?(adopted)
        return true
    }
}
