//  Targets "chrome is not defined": any reply only shows the listener ran,
//  not that chrome.runtime.id is readable. Makes the worker read and hand it back to prove the round trip.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionServiceWorkerBindingsLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let directory: URL
        let runtimeIDAttribute = "data-orbit-live-test-worker-runtime-id"
        let contentScriptRanAttribute = "data-orbit-live-test-worker-content-script-ran"
    }

    private func writeFixture(named name: String, matchHost: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WorkerBindings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://\(matchHost)/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // The whole point: read chrome.runtime.id INSIDE the worker and hand
        // it back. If `chrome` were undefined this throws synchronously and
        // sendResponse never fires, surfacing below as a poll timeout.
        let background = """
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message === 'orbit-live-test-get-runtime-id') {
            sendResponse(String(chrome.runtime.id));
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        document.documentElement.setAttribute('data-orbit-live-test-worker-content-script-ran', 'true');
        chrome.runtime.sendMessage('orbit-live-test-get-runtime-id', function(response) {
          document.documentElement.setAttribute('data-orbit-live-test-worker-runtime-id', String(response));
        });
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return Fixture(directory: directory)
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-worker-bindings-test</body></html>"),
        ])
    }

    private static func pollUntil(timeout: Duration = .seconds(15), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "pollUntil timed out after \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testChromeRuntimeIDIsReadableInsideTheRealMV3BackgroundServiceWorkerAndMatchesTheLoadedExtensionsIDWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (contentScriptRan, workerReportedID) = try LiveChromiumEngineHost.runLive { () -> (Bool, String?) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.writeFixture(named: "Orbit Worker Bindings Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.pollUntil {
                try await contents.evaluateJavaScript("document.documentElement.getAttribute('\(fixture.runtimeIDAttribute)')") != nil
            }

            let contentScriptRan = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.contentScriptRanAttribute)')"
            ) as? String == "true"
            let workerReportedID = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.runtimeIDAttribute)')"
            ) as? String

            return (contentScriptRan, workerReportedID)
        }

        XCTAssertTrue(contentScriptRan, "the extension's content script never injected into the real navigated page")
        let reportedID = try XCTUnwrap(
            workerReportedID,
            "the background service worker never answered — this is exactly the \"chrome is not defined inside the service worker\" failure mode: chrome.runtime.id would have thrown before sendResponse could ever be called"
        )
        XCTAssertNotEqual(reportedID, "undefined", "chrome.runtime.id read as JavaScript undefined inside the real MV3 service worker")
        XCTAssertFalse(reportedID.isEmpty)
    }

    func testChromeRuntimeIDReadInsideTheServiceWorkerExactlyMatchesTheEnginesOwnLoadedExtensionIDWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (loadedID, workerReportedID) = try LiveChromiumEngineHost.runLive { () -> (String, String?) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.writeFixture(named: "Orbit Worker Bindings Identity Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.pollUntil {
                try await contents.evaluateJavaScript("document.documentElement.getAttribute('\(fixture.runtimeIDAttribute)')") != nil
            }
            let workerReportedID = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.runtimeIDAttribute)')"
            ) as? String

            return (loaded.id, workerReportedID)
        }

        XCTAssertEqual(
            workerReportedID, loadedID,
            "chrome.runtime.id read inside the real background service worker did not match the id Chromium's own extension registry reports for this extension"
        )
    }
}
