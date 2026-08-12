//  ws://+WebTransport never reach WillCreateURLLoaderFactory, so the webRequest
//  proxy there is blind to both -- needs its own ContentBrowserClient overrides.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionWebSocketWebRequestLiveTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    private struct RecordedEvent: Decodable {
        let event: String
        let type: String
        let url: String
    }

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    func testWebRequestListenersSeeARealWebSocketHandshake() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let result = try LiveChromiumEngineHost.runLive(timeout: 180) { () -> (events: [RecordedEvent], socketURL: String, greeting: String?) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture()
            let server = try LiveHTTPTestServer(
                routes: [
                    "/": LiveHTTPTestServer.Route(
                        contentType: "text/html",
                        body: "<html><body><h1>orbit-websocket-webrequest</h1></body></html>"
                    )
                ],
                webSocketRoutes: ["/ws": .echo(greeting: "server-hello")]
            )
            defer { server.stop() }
            let socketURL = "ws://127.0.0.1:\(server.port)/ws"

            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let workerPage = try await self.makeReadyWorkerPage(engine: engine, extensionID: loaded.id)
            defer { workerPage.close() }

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            (function () {
              window.__orbitSocketGreeting = null;
              window.__orbitSocketError = null;
              var socket = new WebSocket('\(socketURL)');
              socket.onmessage = function (event) {
                if (window.__orbitSocketGreeting === null) {
                  window.__orbitSocketGreeting = String(event.data);
                }
              };
              socket.onerror = function () { window.__orbitSocketError = 'error'; };
              return 'opening';
            })()
            """)

            try await Self.pollUntil("the page's WebSocket to receive the server greeting") {
                try await contents.evaluateJavaScript(
                    "window.__orbitSocketGreeting !== null || window.__orbitSocketError !== null"
                ) as? Bool == true
            }
            let greeting = try await contents.evaluateJavaScript("window.__orbitSocketGreeting") as? String

            // The handshake completing is not the same instant as the last
            // webRequest event being dispatched to the worker.
            try await Task.sleep(for: .seconds(2))
            let events = try await self.readEvents(from: workerPage)
            return (events, socketURL, greeting)
        }

        XCTAssertEqual(result.greeting, "server-hello", "the page's WebSocket never completed a real handshake")

        let socketEvents = result.events.filter { $0.type == "websocket" }
        XCTAssertFalse(
            socketEvents.isEmpty,
            "chrome.webRequest saw no websocket request at all; saw \(result.events.map(\.event))"
        )
        for name in ["onBeforeRequest", "onResponseStarted", "onCompleted"] {
            XCTAssertTrue(
                socketEvents.contains { $0.event == name && $0.url == result.socketURL },
                "chrome.webRequest.\(name) never fired for \(result.socketURL); websocket events were \(socketEvents)"
            )
        }
    }

    func testWebRequestListenersSeeAWebTransportAttempt() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let result = try LiveChromiumEngineHost.runLive(timeout: 180) { () -> (events: [RecordedEvent], transportURL: String) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture()
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><h1>orbit-webtransport-webrequest</h1></body></html>"
                )
            ])
            defer { server.stop() }
            // Nothing speaks HTTP/3 on that UDP port, so the session fails --
            // after WillCreateWebTransport already handed the handshake to the webRequest proxy under test.
            let transportURL = "https://127.0.0.1:\(server.port)/orbit-webtransport"

            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let workerPage = try await self.makeReadyWorkerPage(engine: engine, extensionID: loaded.id)
            defer { workerPage.close() }

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            (function () {
              window.__orbitTransportSettled = false;
              if (typeof WebTransport !== 'function') {
                window.__orbitTransportSettled = 'unsupported';
                return 'unsupported';
              }
              var transport = new WebTransport('\(transportURL)');
              transport.ready.then(function () {
                window.__orbitTransportSettled = 'ready';
              }).catch(function () {
                window.__orbitTransportSettled = 'failed';
              });
              return 'connecting';
            })()
            """)

            try await Self.pollUntil("the WebTransport session to settle") {
                try await contents.evaluateJavaScript(
                    "window.__orbitTransportSettled !== false"
                ) as? Bool == true
            }

            try await Task.sleep(for: .seconds(2))
            return (try await self.readEvents(from: workerPage), transportURL)
        }

        let transportEvents = result.events.filter { $0.type == "webtransport" }
        XCTAssertFalse(
            transportEvents.isEmpty,
            "chrome.webRequest saw no webtransport request at all; saw \(result.events.map(\.event))"
        )
        XCTAssertTrue(
            transportEvents.contains { $0.event == "onBeforeRequest" && $0.url == result.transportURL },
            "chrome.webRequest.onBeforeRequest never fired for \(result.transportURL); webtransport events were \(transportEvents)"
        )
    }

    // MARK: - Fixture and worker channel

    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WSWebRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Orbit WebSocket webRequest Fixture",
          "version": "1.0",
          "permissions": ["webRequest"],
          "host_permissions": [
            "http://127.0.0.1/*",
            "https://127.0.0.1/*",
            "ws://127.0.0.1/*",
            "wss://127.0.0.1/*"
          ],
          "background": { "service_worker": "background.js" },
          "action": { "default_popup": "popup.html" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var recorded = [];
        function recorder(name) {
          return function (details) {
            recorded.push({ event: name, type: String(details.type), url: String(details.url) });
          };
        }
        var filter = { urls: ['<all_urls>'] };
        chrome.webRequest.onBeforeRequest.addListener(recorder('onBeforeRequest'), filter);
        chrome.webRequest.onBeforeSendHeaders.addListener(recorder('onBeforeSendHeaders'), filter);
        chrome.webRequest.onSendHeaders.addListener(recorder('onSendHeaders'), filter);
        chrome.webRequest.onHeadersReceived.addListener(recorder('onHeadersReceived'), filter);
        chrome.webRequest.onResponseStarted.addListener(recorder('onResponseStarted'), filter);
        chrome.webRequest.onCompleted.addListener(recorder('onCompleted'), filter);
        chrome.webRequest.onErrorOccurred.addListener(recorder('onErrorOccurred'), filter);

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message && message.func === 'getEvents') {
            sendResponse(JSON.stringify(recorded));
            return true;
          }
          sendResponse('pong');
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        try "<html><head><script src=\"popup.js\"></script></head><body>orbit</body></html>"
            .write(to: directory.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try "window.__orbitPopupReady = true;"
            .write(to: directory.appendingPathComponent("popup.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func readEvents(from workerPage: ChromiumWebContents) async throws -> [RecordedEvent] {
        _ = try await workerPage.evaluateJavaScript("""
        (function () {
          window.__orbitEvents = null;
          chrome.runtime.sendMessage({ func: 'getEvents' }, function (response) {
            window.__orbitEvents = chrome.runtime.lastError
              ? JSON.stringify([{ event: 'lastError', type: 'lastError', url: chrome.runtime.lastError.message }])
              : String(response);
          });
          return 'asked';
        })()
        """)
        try await Self.pollUntil("the background service worker to return its recorded events") {
            try await workerPage.evaluateJavaScript("window.__orbitEvents !== null") as? Bool == true
        }
        let rawValue = try await workerPage.evaluateJavaScript("window.__orbitEvents") as? String
        let raw = try XCTUnwrap(rawValue, "the background service worker never answered getEvents")
        return try JSONDecoder().decode([RecordedEvent].self, from: Data(raw.utf8))
    }

    /// The worker registers its webRequest listeners above its onMessage
    /// listener, so an answer here proves the listeners are installed.
    private func makeReadyWorkerPage(
        engine: ChromiumEngine, extensionID: String
    ) async throws -> ChromiumWebContents {
        let page = try await LiveChromiumEngineHost.makeContents(engine: engine)
        page.load(URL(string: "chrome-extension://\(extensionID)/popup.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(page)
        try await Self.pollUntil("the background service worker to finish starting up") {
            _ = try await page.evaluateJavaScript("""
            (function () {
              window.__orbitReady = null;
              chrome.runtime.sendMessage({ func: 'ping' }, function (response) {
                window.__orbitReady = chrome.runtime.lastError ? 'error' : 'ready';
              });
              return 'asked';
            })()
            """)
            try await Task.sleep(for: .milliseconds(250))
            return try await page.evaluateJavaScript("String(window.__orbitReady)") as? String == "ready"
        }
        return page
    }

    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(30),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "timed out after \(timeout) waiting for \(waitingFor)"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
