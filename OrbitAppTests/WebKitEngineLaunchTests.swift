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
        XCTAssertFalse(canonical.isEmpty)
    }

    func testCosmeticAndStylesheetCSSStayData() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        var rules = ContentBlockerRuleSet()
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
        let css = try await waitForText(
            contents,
            script: "Array.from(document.querySelectorAll('style')).map(function(node){return node.textContent||'';}).join('\\n')",
            equals: "pending-style"
        ) { latest in
            latest.contains("__orbitPwned") && latest.contains("__orbitSheet")
        }
        XCTAssertFalse(css.isEmpty)
        let flags = try await waitForText(
            contents,
            script: "String(window.__orbitPwned||'') + String(window.__orbitSheet||'')",
            equals: ""
        )
        XCTAssertEqual(flags, "")
        XCTAssertTrue(css.contains("__orbitPwned") || css.contains("__orbitSheet"))
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
        let sources = contents.webView.configuration.userContentController.userScripts.map(\.source).joined(separator: "\n")
        XCTAssertTrue(sources.contains("__orbitWebStorePrivate"))
        XCTAssertTrue(sources.contains("__orbitOwnsAddToChromeButton"))
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

    func testPictureInPicturePresentsThePlayingVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-pip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("clip.mp4")
        let clip = Data(base64Encoded: Self.pictureInPictureClipBase64, options: .ignoreUnknownCharacters)
        try XCTUnwrap(clip).write(to: video)
        let html = "<!doctype html><html><body><video id=\"v\" src=\"clip.mp4\" autoplay muted playsinline loop></video></body></html>"
        try html.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let port = 18_981
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", root.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        host(contents)
        contents.load(URL(string: "http://127.0.0.1:\(port)/")!)
        let ready = try await waitForText(
            contents,
            script: "(function(){var v=document.getElementById('v'); if(!v) return 'missing'; return v.readyState >= 2 && v.webkitSupportsPresentationMode('picture-in-picture') ? 'ready' : 'wait';})()",
            equals: "ready"
        )
        XCTAssertEqual(ready, "ready")
        contents.togglePictureInPicture()
        let mode = try await waitForText(
            contents,
            script: "(function(){var v=document.getElementById('v'); return (document.pictureInPictureElement || (v && v.webkitPresentationMode === 'picture-in-picture')) ? 'floating' : 'inline';})()",
            equals: "floating"
        )
        XCTAssertEqual(mode, "floating")
        try await Task.sleep(nanoseconds: 800_000_000)
        contents.togglePictureInPicture()
        let left = try await waitForText(
            contents,
            script: "(function(){var v=document.getElementById('v'); return (document.pictureInPictureElement || (v && v.webkitPresentationMode === 'picture-in-picture')) ? 'floating' : 'inline';})()",
            equals: "inline"
        )
        XCTAssertEqual(left, "inline")
        engine.shutdown()
    }

    private static let pictureInPictureClipBase64 = """
    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
    """

    func testClearingCacheReloadsTheDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = root.appendingPathComponent("body.txt")
        try "cache-first".write(to: body, atomically: true, encoding: .utf8)
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
