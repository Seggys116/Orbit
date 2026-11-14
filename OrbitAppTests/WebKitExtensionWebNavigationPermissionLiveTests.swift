//  With "webNavigation" the extension sees real onCompleted events, proven against a real navigation rather than a synthetic event.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitExtensionWebNavigationPermissionLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func writeWebNavigationExtension(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WebNavigationExtension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        // "storage" is declared so the count survives the worker being torn down and woken again, which a worker global does not.
        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["webNavigation", "storage"],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // chrome.webNavigation only exists in the privileged background context, so onCompleted is registered here and the content script only relays count/definedness.
        let background = """
        if (chrome.webNavigation) {
          chrome.webNavigation.onCompleted.addListener(function(details) {
            chrome.storage.local.get(['orbitNavCompletedCount'], function(stored) {
              chrome.storage.local.set({
                orbitNavCompletedCount: (stored.orbitNavCompletedCount || 0) + 1
              });
            });
          });
        }
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message === 'orbit-webnav-poll') {
            chrome.storage.local.get(['orbitNavCompletedCount'], function(stored) {
              sendResponse(JSON.stringify({
                defined: typeof chrome.webNavigation !== 'undefined',
                count: stored.orbitNavCompletedCount || 0
              }));
            });
            return true;
          }
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        if (location.pathname === '/observer') {
          function orbitPollWebNavigation() {
            chrome.runtime.sendMessage('orbit-webnav-poll', function(response) {
              document.documentElement.setAttribute('data-orbit-webnav-poll-result', response || '{}');
            });
          }
          orbitPollWebNavigation();
          setInterval(orbitPollWebNavigation, 150);
        }
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/observer": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>observer</body></html>"),
            "/subject": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>subject</body></html>"),
        ])
    }

    private struct PollSnapshot {
        let defined: Bool
        let count: Int
    }

    private func parsePollSnapshot(_ raw: Any?) -> PollSnapshot? {
        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let defined = dict["defined"] as? Bool, let count = dict["count"] as? Int else { return nil }
        return PollSnapshot(defined: defined, count: count)
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

    // MARK: - Positive: chrome.webNavigation exists and receives real navigation events

    func testAnExtensionWithTheWebNavigationPermissionSeesRealOnCompletedEventsForARealNavigation() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let directory = try self.writeWebNavigationExtension(named: "Orbit WebNavigation Positive Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let server = try self.makeServer()
            defer { server.stop() }

            let observerContents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { observerContents.close() }
            observerContents.load(server.baseURL.appendingPathComponent("observer"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(observerContents)

            try await Self.pollUntil {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-webnav-poll-result')"
                )
                return self.parsePollSnapshot(raw)?.defined == true
            }
            let baselineRaw = try await observerContents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-webnav-poll-result')")
            let baseline = try XCTUnwrap(self.parsePollSnapshot(baselineRaw))
            XCTAssertTrue(baseline.defined, "chrome.webNavigation must exist for an extension holding the \"webNavigation\" permission")

            // The baseline is taken, not asserted on: nothing orders the worker's first run against the first navigation.
            observerContents.load(server.baseURL.appendingPathComponent("observer"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(observerContents)
            try await Self.pollUntil {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-webnav-poll-result')"
                )
                guard let snapshot = self.parsePollSnapshot(raw) else { return false }
                return snapshot.count > baseline.count
            }

            // A second, distinct real navigation on the SAME contents must fire another event.
            let afterFirstRaw = try await observerContents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-webnav-poll-result')")
            let afterFirst = try XCTUnwrap(self.parsePollSnapshot(afterFirstRaw))

            observerContents.load(server.baseURL.appendingPathComponent("subject"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(observerContents)
            observerContents.load(server.baseURL.appendingPathComponent("observer"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(observerContents)

            try await Self.pollUntil {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-webnav-poll-result')"
                )
                guard let snapshot = self.parsePollSnapshot(raw) else { return false }
                return snapshot.count > afterFirst.count
            }
        }
    }
}
