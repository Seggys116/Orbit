//  Without "webNavigation" the namespace is entirely undefined (stronger
//  than per-event scrubbing). Proven against a real navigation, not a synthetic event.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionWebNavigationPermissionLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func writeWebNavigationExtension(named name: String, includeWebNavigationPermission: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WebNavigationExtension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        // "storage" in both arms: the count below must survive the worker
        // being torn down and woken again (ordinary MV3), which a worker global does not.
        let permissions = includeWebNavigationPermission ? "[\"webNavigation\", \"storage\"]" : "[\"storage\"]"
        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": \(permissions),
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // chrome.webNavigation only exists in the privileged background
        // context, so onCompleted is registered here; content script only relays count/definedness into the DOM.
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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeWebNavigationExtension(named: "Orbit WebNavigation Positive Test", includeWebNavigationPermission: true)
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let server = try self.makeServer()
            defer { server.stop() }

            let observerContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { observerContents.close() }
            observerContents.load(server.baseURL.appendingPathComponent("observer"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)

            try await Self.pollUntil {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-webnav-poll-result')"
                )
                return self.parsePollSnapshot(raw)?.defined == true
            }
            let baselineRaw = try await observerContents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-webnav-poll-result')")
            let baseline = try XCTUnwrap(self.parsePollSnapshot(baselineRaw))
            XCTAssertTrue(baseline.defined, "chrome.webNavigation must exist for an extension holding the \"webNavigation\" permission")

            // The baseline is taken, not asserted on: nothing orders the
            // worker's first run against the first navigation. `defined` above proves the listener already existed.
            observerContents.load(server.baseURL.appendingPathComponent("observer"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)
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
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)
            observerContents.load(server.baseURL.appendingPathComponent("observer"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)

            try await Self.pollUntil {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-webnav-poll-result')"
                )
                guard let snapshot = self.parsePollSnapshot(raw) else { return false }
                return snapshot.count > afterFirst.count
            }
        }
    }

    // MARK: - Negative: no permission -> chrome.webNavigation does not exist at all -> no events, ever

    func testAnExtensionWithoutTheWebNavigationPermissionNeverSeesChromeWebNavigationAtAll() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeWebNavigationExtension(named: "Orbit WebNavigation Negative Test", includeWebNavigationPermission: false)
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let server = try self.makeServer()
            defer { server.stop() }

            let observerContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { observerContents.close() }
            observerContents.load(server.baseURL.appendingPathComponent("observer"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)

            try await Self.pollUntil {
                try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-webnav-poll-result')"
                ) != nil
            }
            let snapshotRaw = try await observerContents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-webnav-poll-result')")
            let snapshot = try XCTUnwrap(self.parsePollSnapshot(snapshotRaw))
            XCTAssertFalse(snapshot.defined, "an extension with no \"webNavigation\" permission must not even see chrome.webNavigation as defined")
            XCTAssertEqual(snapshot.count, 0, "with chrome.webNavigation undefined, no onCompleted listener could ever have been registered, so the count must stay zero")

            // A further real navigation still must not somehow make an event arrive.
            observerContents.load(server.baseURL.appendingPathComponent("subject"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)
            observerContents.load(server.baseURL.appendingPathComponent("observer"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)
            try await Task.sleep(for: .milliseconds(500))

            let afterRaw = try await observerContents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-webnav-poll-result')")
            let after = try XCTUnwrap(self.parsePollSnapshot(afterRaw))
            XCTAssertFalse(after.defined)
            XCTAssertEqual(after.count, 0)
        }
    }
}
