//  If web_request_event.js is missing from orbit_resources.pak the renderer
//  aborts on first touch (reported as "registration status 3") -- what a real Honey install hit.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionWebRequestBindingsLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private static let eventNames = [
        "onBeforeRequest",
        "onBeforeSendHeaders",
        "onSendHeaders",
        "onHeadersReceived",
        "onResponseStarted",
        "onCompleted",
        "onErrorOccurred",
    ]

    private struct Fixture {
        let directory: URL
        let reportAttribute = "data-orbit-live-test-webrequest-report"
        let contentScriptRanAttribute = "data-orbit-live-test-webrequest-content-script-ran"
    }

    private struct WorkerReport: Decodable {
        let events: [String]
        let listenerAdded: Bool
        let error: String?
    }

    private func writeFixture(named name: String, matchHost: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WebRequestBindings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["webRequest"],
          "host_permissions": ["http://\(matchHost)/*"],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://\(matchHost)/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // onMessage registered BEFORE touching chrome.webRequest, so a
        // renderer abort (no reply) stays distinguishable from an ordinary JS throw (still replies).
        let eventList = Self.eventNames.map { "'\($0)'" }.joined(separator: ", ")
        let background = """
        var report = { events: [], listenerAdded: false, error: null };
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message === 'orbit-live-test-webrequest-report') {
            sendResponse(JSON.stringify(report));
          }
          return true;
        });
        try {
          var names = [\(eventList)];
          for (var i = 0; i < names.length; i++) {
            var event = chrome.webRequest[names[i]];
            var usable = !!event && typeof event.addListener === 'function'
              && typeof event.removeListener === 'function'
              && typeof event.hasListener === 'function';
            report.events.push(names[i] + '=' + usable);
          }
          chrome.webRequest.onBeforeRequest.addListener(function() {}, { urls: ['http://\(matchHost)/*'] });
          report.listenerAdded = chrome.webRequest.onBeforeRequest.hasListeners();
        } catch (error) {
          report.error = String(error);
        }
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        document.documentElement.setAttribute('data-orbit-live-test-webrequest-content-script-ran', 'true');
        chrome.runtime.sendMessage('orbit-live-test-webrequest-report', function(response) {
          document.documentElement.setAttribute('data-orbit-live-test-webrequest-report', String(response));
        });
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return Fixture(directory: directory)
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-webrequest-bindings-test</body></html>"),
        ])
    }

    // A renderer abort takes the message port down with it, so the
    // page-side callback never runs and the only symptom is this wait expiring.
    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(15),
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
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static let reportWait = "the background service worker to answer after reading chrome.webRequest.on* — no answer means its renderer process died, which is what ModuleSystem::Require(\"webRequestEvent\") does when web_request_event.js is not in orbit_resources.pak"

    func testRealMV3ServiceWorkerReadsEveryChromeWebRequestEventObjectWithoutAbortingItsRendererProcess() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (contentScriptRan, rawReport) = try LiveChromiumEngineHost.runLive { () -> (Bool, String?) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.writeFixture(named: "Orbit WebRequest Bindings Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.pollUntil(Self.reportWait) {
                try await contents.evaluateJavaScript("document.documentElement.getAttribute('\(fixture.reportAttribute)')") != nil
            }

            let contentScriptRan = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.contentScriptRanAttribute)')"
            ) as? String == "true"
            let rawReport = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.reportAttribute)')"
            ) as? String

            return (contentScriptRan, rawReport)
        }

        XCTAssertTrue(contentScriptRan, "the extension's content script never injected into the real navigated page")
        let payload = try XCTUnwrap(
            rawReport,
            "the background service worker never answered — reading chrome.webRequest.onBeforeRequest hit ModuleSystem::Require(\"webRequestEvent\") with no such resource in orbit_resources.pak, which aborts the renderer outright and leaves the browser reporting only \"Service worker registration failed. Status code: 3\""
        )
        guard payload != "undefined" else {
            return XCTFail(
                "chrome.runtime.sendMessage completed with no response: the background service worker's message port closed, which is what a renderer abort inside ModuleSystem::Require(\"webRequestEvent\") looks like from the page side"
            )
        }

        let report = try JSONDecoder().decode(WorkerReport.self, from: Data(payload.utf8))
        XCTAssertNil(report.error, "touching chrome.webRequest threw inside the real MV3 service worker")
        XCTAssertEqual(
            report.events,
            Self.eventNames.map { "\($0)=true" },
            "at least one chrome.webRequest event object was not a usable extensions Event — web_request_event.js is what supplies addListener/removeListener/hasListener for all of them"
        )
        XCTAssertTrue(report.listenerAdded, "chrome.webRequest.onBeforeRequest.addListener did not register a listener inside the real service worker")
    }

    func testEngineAndExtensionRegistrySurviveAServiceWorkerThatTouchesChromeWebRequest() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (stillLoaded, bodyAfterwards) = try LiveChromiumEngineHost.runLive { () -> (Bool, String?) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.writeFixture(named: "Orbit WebRequest Survival Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.pollUntil(Self.reportWait) {
                try await contents.evaluateJavaScript("document.documentElement.getAttribute('\(fixture.reportAttribute)')") != nil
            }

            let stillLoaded = engine.loadedExtensions(session: engine.defaultSession)
                .contains { $0.id == loaded.id }

            let after = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { after.close() }
            after.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(after)
            let bodyAfterwards = try await after.evaluateJavaScript("document.body.textContent") as? String

            return (stillLoaded, bodyAfterwards)
        }

        XCTAssertTrue(stillLoaded, "the extension left the registry after its service worker touched chrome.webRequest")
        XCTAssertEqual(
            bodyAfterwards, "orbit-webrequest-bindings-test",
            "the engine could not complete an ordinary navigation after a service worker touched chrome.webRequest"
        )
    }
}
