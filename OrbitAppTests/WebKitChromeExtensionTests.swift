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
        let installer = ExtensionInstaller(store: store(), client: ChromeWebStoreClient(session: OrbitExtensionDownloadStub.makeSession())) { _ in true }
        let result = try await installer.install(id)
        guard case .installed(let installed, _, _) = result else {
            return XCTFail("CRX install did not install")
        }
        let crxLoaded = try await engine.loadExtension(at: installed.directory, session: engine.defaultSession)
        XCTAssertEqual(installed.id, crxLoaded.id)
        try await assertExtensionWorks(crxLoaded, on: engine, marker: "crx-marker")
        engine.shutdown()
    }

    func testUndocumentedContextErrorCodeIsNotALoadFailure() {
        XCTAssertFalse(WebKitEngine.isBackgroundLoadFailure(NSError(domain: WKWebExtensionContext.errorDomain, code: 7)))
        XCTAssertTrue(WebKitEngine.isBackgroundLoadFailure(NSError(
            domain: WKWebExtensionContext.errorDomain,
            code: WKWebExtensionContext.Error.Code.backgroundContentFailedToLoad.rawValue
        )))
    }

    // Honey's worker rejects a promise on localStorage at startup; Chrome only logs that, so it must still load here.
    func testWorkerRejectionDuringStartupDoesNotFailTheLoad() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let source = try makeExtension(name: "Rejecting Worker Fixture")
        let background = source.appendingPathComponent("background.js")
        let original = try String(contentsOf: background, encoding: .utf8)
        try (original + "\nPromise.resolve().then(function () { localStorage.orbitProbe = \"1\"; });\n")
            .write(to: background, atomically: true, encoding: .utf8)
        let extensionStore = store()
        let installed = try extensionStore.install(unpackedAt: source, publicKey: nil)
        let runtime = ExtensionRuntime(store: extensionStore)
        runtime.bind(to: engine)
        let appeared = await waitLoaded(installed.id, on: engine)
        XCTAssertTrue(appeared, runtime.lastError ?? "not loaded")
        let settleDeadline = Date().addingTimeInterval(2)
        while extensionStore.hasPendingChanges, Date() < settleDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(runtime.lastError)
        XCTAssertFalse(extensionStore.hasPendingChanges)
        let loaded = try XCTUnwrap(engine.loadedExtensions(session: engine.defaultSession).first { $0.id == installed.id })
        try await assertExtensionWorks(loaded, on: engine, marker: "rejecting-worker-marker")
        runtime.unbind()
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

    private func makeExtension(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-src-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let background = "\"background\":{\"service_worker\":\"background.js\"}"
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
        // Offset by the running server count so several pages in one test never share a port.
        let port = 8765 + servers.count
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        servers.append(process)
        // A fixed sleep lost the race under load: the first load hit NSURLErrorDomain -1004 and never retried.
        let deadline = Date().addingTimeInterval(15)
        while !Self.acceptsConnections(port: port), Date() < deadline {
            guard process.isRunning else { throw CocoaError(.fileReadUnknown, userInfo: [NSDebugDescriptionErrorKey: "http.server on \(port) exited"]) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard Self.acceptsConnections(port: port) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSDebugDescriptionErrorKey: "http.server on \(port) never accepted a connection"])
        }
        return URL(string: "http://127.0.0.1:\(port)/page.html")!
    }

    private static func acceptsConnections(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
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

@MainActor
final class WebKitExtensionKeepAliveTests: XCTestCase {

    private final class Pings {
        var count = 0
    }

    private func makeServices() -> WebKitExtensionServices {
        WebKitExtensionServices(stateDirectory: nil)
    }

    func testTheKeepAliveTimerStopsWhenTheLastBackgroundPortDetaches() {
        let services = makeServices()
        let first = services._test_attachBackgroundPort(extensionID: "a", send: { _ in })
        let second = services._test_attachBackgroundPort(extensionID: "b", send: { _ in })
        XCTAssertTrue(services.isBackgroundKeepAliveRunning)

        services._test_detachPort(first)
        XCTAssertTrue(services.isBackgroundKeepAliveRunning, "One background port is still attached.")

        services._test_detachPort(second)
        XCTAssertFalse(services.isBackgroundKeepAliveRunning, "The timer kept waking the main run loop with no background port left.")
    }

    func testAPortIsPingedWhileItIsWithinTheGraceWindow() {
        let services = makeServices()
        let pings = Pings()
        _ = services._test_attachBackgroundPort(extensionID: "a", send: { _ in pings.count += 1 })

        services.keepAliveTick(now: Date().addingTimeInterval(WebKitExtensionServices.keepAliveGrace - 5))

        XCTAssertEqual(pings.count, 1)
        XCTAssertTrue(services.isBackgroundKeepAliveRunning)
    }

    func testAPortIsNotPingedPastTheGraceWindowAndTheTimerStops() {
        let services = makeServices()
        let pings = Pings()
        _ = services._test_attachBackgroundPort(extensionID: "a", send: { _ in pings.count += 1 })

        services.keepAliveTick(now: Date().addingTimeInterval(WebKitExtensionServices.keepAliveGrace + 5))

        XCTAssertEqual(pings.count, 0, "An idle worker was kept alive past Chrome's idle window.")
        XCTAssertFalse(services.isBackgroundKeepAliveRunning)
    }

    func testAMessageFromAnIdlePortRestartsThePings() {
        let services = makeServices()
        let pings = Pings()
        let key = services._test_attachBackgroundPort(
            extensionID: "a", send: { _ in pings.count += 1 },
            lastActivity: Date().addingTimeInterval(-(WebKitExtensionServices.keepAliveGrace + 10))
        )
        services.keepAliveTick(now: Date())
        XCTAssertFalse(services.isBackgroundKeepAliveRunning, "Precondition: the idle port stopped the timer.")

        services._test_receivePortMessage(["anything": true], key: key)
        services.keepAliveTick(now: Date())

        XCTAssertTrue(services.isBackgroundKeepAliveRunning)
        XCTAssertEqual(pings.count, 1)
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
        let url = request.url ?? ChromeWebStoreClient.updateServiceEndpoint
        // The client first POSTs an Omaha update check, then GETs the package it names.
        let isUpdateCheck = url.host == "update.googleapis.com"
        let body: Data
        let contentType: String
        if isUpdateCheck {
            contentType = "text/xml"
            body = Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <response protocol="3.0" server="prod"><app appid="fixture" status="ok"><updatecheck status="ok">\
                <urls><url codebase="https://clients2.googleusercontent.com/crx/blobs/"/></urls>\
                <manifest version="1.0"><packages><package name="fixture.crx" required="true"/></packages></manifest>\
                </updatecheck></app></response>
                """.utf8
            )
        } else {
            contentType = "application/x-chrome-extension"
            body = Self.bytes
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
