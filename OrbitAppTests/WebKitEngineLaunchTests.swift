import MachO
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
        assertNoChromiumLinked()
        engine.shutdown()
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

    func testContentRulesKeepSubdomainsAndCosmeticDomains() throws {
        let network = try XCTUnwrap(SafariContentRuleCompiler.compiledRule(from: "||example.com^"))
        let filter = try XCTUnwrap((network["trigger"] as? [String: Any])?["url-filter"] as? String)
        XCTAssertFalse(filter.contains("\\\\."))
        let regex = try NSRegularExpression(pattern: filter)
        func matches(_ url: String) -> Bool {
            regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        XCTAssertTrue(matches("https://example.com/"))
        XCTAssertTrue(matches("https://ads.example.com/"))
        XCTAssertFalse(matches("https://ads.example.org/"))

        let cosmetic = try XCTUnwrap(SafariContentRuleCompiler.compiledRule(from: "example.com##.ad"))
        let trigger = try XCTUnwrap(cosmetic["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["if-domain"] as? [String], ["*example.com"])
        XCTAssertEqual((cosmetic["action"] as? [String: Any])?["selector"] as? String, ".ad")
        let global = try XCTUnwrap(SafariContentRuleCompiler.compiledRule(from: "##.banner"))
        XCTAssertNil((global["trigger"] as? [String: Any])?["if-domain"])
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
            text.contains("Chrome/") && text.contains("AppleWebKit")
        }
        XCTAssertTrue(agent.contains("Chrome/"))
        XCTAssertTrue(agent.contains("AppleWebKit"))
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
        XCTAssertTrue(contents.webView.isInspectable)
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

    private func assertNoChromiumLinked() {
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let path = String(cString: raw)
            XCTAssertFalse(path.contains("Orbit Framework.framework"), path)
            XCTAssertFalse(path.contains("Chromium Framework"), path)
        }
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
