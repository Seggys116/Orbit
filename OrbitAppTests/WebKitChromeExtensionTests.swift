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

        let unpacked = try makeExtension(name: "Unpacked Fixture")
        let unpackedInstalled = try store().install(unpackedAt: unpacked, publicKey: nil)
        let unpackedLoaded = try await engine.loadExtension(at: unpackedInstalled.directory, session: engine.defaultSession)
        try await assertExtensionWorks(unpackedLoaded, on: engine, marker: "unpacked-marker")

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
        try await assertExtensionWorks(crxLoaded, on: engine, marker: "crx-marker")
        engine.shutdown()
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
        let reply = try await waitFor(
            contents,
            script: "document.getElementById('reply') ? document.getElementById('reply').textContent : ''",
            equals: "pong-from-background"
        )
        XCTAssertEqual(reply, "pong-from-background")
        let deadline = Date().addingTimeInterval(10)
        var badge = ""
        while Date() < deadline {
            badge = engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeText
            if badge == "OK" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(badge, "OK")
    }

    private func store() -> ExtensionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-webkit-ext-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return ExtensionStore(root: root)
    }

    private func makeExtension(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-src-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"\(name)","version":"1.0.0","description":"\(name) fixture","action":{"default_title":"\(name)"},"permissions":["nativeMessaging"],"host_permissions":["<all_urls>"],"background":{"service_worker":"background.js"},"content_scripts":[{"matches":["<all_urls>"],"js":["content.js"],"run_at":"document_idle"}]}
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
