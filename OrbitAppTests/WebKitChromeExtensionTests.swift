import WebKit
import XCTest
@testable import Orbit

@MainActor
final class WebKitChromeExtensionTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var roots: [URL] = []
    private var servers: [Process] = []

    override func tearDown() {
        // Closing the window after the engine is gone trips WebKit's UI persistence.
        windows.forEach {
            $0.contentView = nil
            $0.orderOut(nil)
        }
        windows.removeAll()
        servers.forEach { $0.terminate() }
        servers.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    func testUnpackedAndCRXExtensionsRunOnWebKit() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        XCTAssertEqual(type(of: engine).kind, .webkit)

        let unpackedStore = store()
        let unpacked = try makeExtension(name: "Unpacked Fixture")
        let unpackedInstalled = try unpackedStore.install(unpackedAt: unpacked, publicKey: nil)
        let runtime = ExtensionRuntime(store: unpackedStore)
        runtime.bind(to: engine)
        let appeared = await waitLoaded(unpackedInstalled.id, on: engine)
        XCTAssertTrue(appeared, engine.loadedExtensions(session: engine.defaultSession).map(\.id).joined(separator: ","))
        let unpackedLoaded = try XCTUnwrap(engine.loadedExtensions(session: engine.defaultSession).first { $0.id == unpackedInstalled.id })
        XCTAssertEqual(unpackedInstalled.id, unpackedLoaded.id)
        try await assertExtensionWorks(unpackedLoaded, on: engine, marker: "unpacked-marker")
        try unpackedStore.setEnabled(false, id: unpackedInstalled.id)
        XCTAssertFalse(engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == unpackedInstalled.id })
        runtime.unbind()

        let crxSource = try makeExtension(name: "CRX Fixture")
        let zip = try zipDirectory(crxSource)
        let built = try CRX3AppTestFixture.build(zipPayload: zip)
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: built.publicKeyBase64))
        OrbitExtensionDownloadStub.bytes = built.bytes
        let installer = ExtensionInstaller(store: store(), client: ChromeWebStoreClient(session: OrbitExtensionDownloadStub.makeSession(), prodVersion: "120.0.0.0")) { _ in true }
        let result = try await installer.install(id)
        guard case .installed(let installed, _, _) = result else {
            return XCTFail("CRX install did not install")
        }
        let crxLoaded = try await engine.loadExtension(at: installed.directory, session: engine.defaultSession)
        XCTAssertEqual(installed.id, crxLoaded.id)
        try await assertExtensionWorks(crxLoaded, on: engine, marker: "crx-marker")
        engine.shutdown()
    }

    func testExtensionPopupURLLoadsOnWebKit() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let root = try makePopupExtension()
        let installed = try store().install(unpackedAt: root, publicKey: nil)
        let loaded = try await engine.loadExtension(at: installed.directory, session: engine.defaultSession)
        let popup = URL(string: "chrome-extension://\(loaded.id)/popup.html")!
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        host(contents)
        contents.load(popup)
        let text = try await waitFor(
            contents,
            script: "document.getElementById('popup') ? document.getElementById('popup').textContent : ''",
            equals: "popup-loaded"
        )
        XCTAssertEqual(text, "popup-loaded")
        engine.shutdown()
    }

    func testModuleBackgroundRepliesOnWebKit() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let source = try makeExtension(name: "Module Fixture", module: true)
        let installed = try store().install(unpackedAt: source, publicKey: nil)
        let loaded = try await engine.loadExtension(at: installed.directory, session: engine.defaultSession)
        let entry = try String(contentsOf: installed.directory.appendingPathComponent("orbit-background-entry.js"), encoding: .utf8)
        XCTAssertTrue(entry.contains("import "))
        XCTAssertFalse(entry.contains("importScripts"))
        let manifest = try String(contentsOf: installed.directory.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("module"))
        try await assertExtensionWorks(loaded, on: engine, marker: "module-marker")
        engine.shutdown()
    }

    func testUndeclaredHistoryDeleteAllIsRejected() async throws {
        let engine = try XCTUnwrap(EngineFactory.makeEngine(storage: .ephemeral) as? WebKitEngine)
        let bare = try makeBareExtension(permissions: [])
        let loaded = try await engine.loadExtension(at: bare, session: engine.defaultSession)
        let denied = await engine.performChromeAPI(extensionID: loaded.id, namespace: "history", method: "deleteAll", args: [])
        guard case .failure(let error) = denied else {
            return XCTFail("history.deleteAll ran without the history permission")
        }
        XCTAssertTrue(String(describing: error).contains("history"))

        let declared = try makeBareExtension(permissions: ["history"])
        let allowed = try await engine.loadExtension(at: declared, session: engine.defaultSession)
        let accepted = await engine.performChromeAPI(
            extensionID: allowed.id, namespace: "history", method: "search", args: [["text": ""]]
        )
        if case .failure(let error) = accepted {
            XCTAssertFalse(String(describing: error).contains("Missing history permission"), String(describing: error))
        }
        engine.shutdown()
    }

    func testUndeclaredSearchQueryIsRejected() async throws {
        let engine = try XCTUnwrap(EngineFactory.makeEngine(storage: .ephemeral) as? WebKitEngine)
        let bare = try makeBareExtension(permissions: [])
        let loaded = try await engine.loadExtension(at: bare, session: engine.defaultSession)
        let denied = await engine.performChromeAPI(
            extensionID: loaded.id, namespace: "search", method: "query", args: [["text": "orbit"]]
        )
        guard case .failure(let error) = denied else {
            return XCTFail("search.query ran without the search permission")
        }
        XCTAssertTrue(String(describing: error).contains("search"))

        let declared = try makeBareExtension(permissions: ["search"])
        let allowed = try await engine.loadExtension(at: declared, session: engine.defaultSession)
        let accepted = await engine.performChromeAPI(
            extensionID: allowed.id, namespace: "search", method: "query", args: [["text": "orbit"]]
        )
        if case .failure(let error) = accepted {
            XCTAssertFalse(String(describing: error).contains("Missing search permission"), String(describing: error))
        }
        engine.shutdown()
    }

    func testHostPermissionBypassFollowsGrantedPatterns() async throws {
        let engine = try XCTUnwrap(EngineFactory.makeEngine(storage: .ephemeral) as? WebKitEngine)
        let page = URL(string: "https://example.com/page")!
        let other = URL(string: "https://other.test/page")!
        let contents = try XCTUnwrap(try engine.makeWebContents(session: engine.defaultSession, initialURL: nil) as? WebKitWebContents)
        contents.load(page)

        let bare = try await engine.loadExtension(at: try makeBareExtension(permissions: []), session: engine.defaultSession)
        let bareContext = try context(bare.id, on: engine)
        XCTAssertFalse(contents.shouldBypassPermissions(for: bareContext))

        let granted = try await engine.loadExtension(
            at: try makeBareExtension(permissions: [], hosts: ["https://example.com/*"]),
            session: engine.defaultSession
        )
        let grantedContext = try context(granted.id, on: engine)
        XCTAssertTrue(contents.shouldBypassPermissions(for: grantedContext))
        contents.load(other)
        XCTAssertFalse(contents.shouldBypassPermissions(for: grantedContext))
        engine.shutdown()
    }

    private func context(_ id: String, on engine: WebKitEngine) throws -> WKWebExtensionContext {
        try XCTUnwrap(engine.extensionController.extensionContexts.first { $0.uniqueIdentifier == id })
    }

    private func assertExtensionWorks(_ loaded: LoadedExtension, on engine: any BrowserEngine, marker: String) async throws {
        let page = try servedPage(marker: marker)
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        host(contents)
        let webView = try XCTUnwrap(contents.view as? WKWebView)
        XCTAssertNotNil(webView.configuration.webExtensionController)
        contents.load(page)
        let mutated = try await waitFor(
            contents,
            script: "document.getElementById('marker') ? document.getElementById('marker').textContent : ''",
            equals: "content-script-ran"
        )
        let diagnostics = (engine as? WebKitEngine)?.extensionDiagnostics(id: loaded.id) ?? ""
        XCTAssertEqual(mutated, "content-script-ran", diagnostics)
        print("extension-proof marker=\(mutated)")
        let reply = try await waitFor(
            contents,
            script: "document.getElementById('reply') ? document.getElementById('reply').textContent : ''",
            equals: "pong-from-background"
        )
        XCTAssertEqual(reply, "pong-from-background")
        print("extension-proof reply=\(reply)")
        let deadline = Date().addingTimeInterval(10)
        var badge = ""
        while Date() < deadline {
            badge = engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeText
            if badge == "OK" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(badge, "OK")
        print("extension-proof badge=\(badge)")
    }

    private func store() -> ExtensionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-webkit-ext-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return ExtensionStore(root: root)
    }

    private func waitLoaded(_ id: String, on engine: any BrowserEngine) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if engine.loadedExtensions(session: engine.defaultSession).contains(where: { $0.id == id }) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func makeExtension(name: String, module: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-src-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let background = module
            ? "\"background\":{\"service_worker\":\"background.js\",\"type\":\"module\"}"
            : "\"background\":{\"service_worker\":\"background.js\"}"
        let manifest = """
        {"manifest_version":3,"name":"\(name)","version":"1.0.0","description":"\(name) fixture","action":{"default_title":"\(name)"},"permissions":["nativeMessaging"],"host_permissions":["<all_urls>"],\(background),"content_scripts":[{"matches":["<all_urls>"],"js":["content.js"],"run_at":"document_idle"}]}
        """
        try manifest.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message && message.kind === "ping") { sendResponse({reply: "pong-from-background"}); }
          return true;
        });
        chrome.action.setBadgeText({text: "OK"});
        """.write(to: root.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try """
        function orbitFixtureRun() {
          var marker = document.getElementById("marker");
          if (marker) { marker.textContent = "content-script-ran"; }
          chrome.runtime.sendMessage({kind: "ping"}, function(response) {
            var node = document.getElementById("reply") || document.createElement("p");
            node.id = "reply";
            node.textContent = response && response.reply ? response.reply : "";
            (document.body || document.documentElement).appendChild(node);
          });
        }
        if (document.readyState === "loading") {
          document.addEventListener("DOMContentLoaded", orbitFixtureRun);
        } else {
          orbitFixtureRun();
        }
        """.write(to: root.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        return root
    }

    private func makePopupExtension() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-popup-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"Popup","version":"1.0.0","description":"popup fixture","action":{"default_popup":"popup.html"},"background":{"service_worker":"background.js"}}
        """
        try manifest.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "void 0;\n".write(to: root.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body><p id=\"popup\">popup-loaded</p></body></html>".write(
            to: root.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8
        )
        return root
    }

    private func makeBareExtension(permissions: [String], hosts: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-bare-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let listed = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        let hostList = hosts.map { "\"\($0)\"" }.joined(separator: ",")
        let manifest = """
        {"manifest_version":3,"name":"Bare","version":"1.0.0","description":"bare fixture","permissions":[\(listed)],"host_permissions":[\(hostList)],"background":{"service_worker":"background.js"}}
        """
        try manifest.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "void 0;\n".write(to: root.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        return root
    }

    private func servedPage(marker: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let html = "<!doctype html><html><body><p id=\"marker\">\(marker)</p></body></html>"
        try html.write(to: root.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        let port = 8765 + servers.count
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        servers.append(process)
        Thread.sleep(forTimeInterval: 0.4)
        return URL(string: "http://127.0.0.1:\(port)/page.html")!
    }

    private func zipDirectory(_ directory: URL) throws -> Data {
        let destination = directory.deletingLastPathComponent().appendingPathComponent("\(directory.lastPathComponent).zip")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-r", "-X", destination.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: destination)
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

    private func waitFor(_ contents: WebContents, script: String, equals expected: String) async throws -> String {
        let deadline = Date().addingTimeInterval(25)
        var latest = ""
        while Date() < deadline {
            if let value = try? await contents.evaluateJavaScript(script), let text = value as? String {
                latest = text
                if text == expected { return text }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        return latest
    }
}

final class OrbitExtensionDownloadStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytes = Data()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrbitExtensionDownloadStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://clients2.google.com/service/update2/crx")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-chrome-extension"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
