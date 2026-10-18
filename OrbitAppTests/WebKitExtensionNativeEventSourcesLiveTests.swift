//  webRequest comes from WebKit itself and webNavigation's main frame from Orbit's document
//  observer, with WebKit's own main-frame events filtered out: one navigation must produce each
//  event exactly once, never a replayed or fabricated copy.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitExtensionNativeEventSourcesLiveTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-EventSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        try """
        {
          "manifest_version": 3,
          "name": "Orbit Event Sources",
          "version": "1.0",
          "permissions": ["webRequest", "webNavigation"],
          "host_permissions": ["http://127.0.0.1/*"],
          "background": { "service_worker": "background.js" }
        }
        """.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        var seen = [];
        function record(kind) {
          return function (details) {
            seen.push({
              kind: kind, url: String(details.url), frameId: details.frameId,
              requestId: typeof details.requestId, type: details.type || null,
              transitionType: details.transitionType || null
            });
          };
        }
        chrome.webRequest.onCompleted.addListener(record('webRequest.onCompleted'), { urls: ['<all_urls>'], types: ['main_frame'] });
        chrome.webNavigation.onCommitted.addListener(record('webNavigation.onCommitted'));
        chrome.webNavigation.onCompleted.addListener(record('webNavigation.onCompleted'));
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'seen') { sendResponse(JSON.stringify(seen)); }
          return true;
        });
        """.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try """
        <!DOCTYPE html><html><head><title>probe</title></head><body><script src="probe.js"></script></body></html>
        """.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)
        try """
        window.__orbitSeen = null;
        window.orbitAsk = function () {
          window.__orbitSeen = null;
          chrome.runtime.sendMessage('seen', function (response) { window.__orbitSeen = String(response); });
        };
        """.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)
        return directory
    }

    private static func pollUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out waiting for \(what)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private struct Seen: Decodable {
        let kind: String
        let url: String
        let frameId: Int?
        let requestId: String
        let type: String?
        let transitionType: String?
    }

    func testOneNavigationYieldsEachEventOnceFromItsRealSource() throws {
        let seen = try WebKitLiveEngineHost.runLive(timeout: 120) { () -> [Seen] in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let server = try LiveHTTPTestServer(routes: [
                "/page": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-event-sources</body></html>"),
            ])
            defer { server.stop() }
            let loaded = try await engine.loadExtension(at: try self.writeFixture(), session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let probe = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { probe.close() }
            probe.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(probe)

            let tab = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { tab.close() }
            let target = server.baseURL.appendingPathComponent("page").absoluteString
            tab.load(URL(string: target)!)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(tab)

            var decoded: [Seen] = []
            try await Self.pollUntil("all three events for \(target)") {
                _ = try await probe.evaluateJavaScript("window.orbitAsk(); 'asked'")
                try await Task.sleep(for: .milliseconds(200))
                let raw = try await probe.evaluateJavaScript("window.__orbitSeen") as? String ?? "[]"
                decoded = (try? JSONDecoder().decode([Seen].self, from: Data(raw.utf8))) ?? []
                let kinds = Set(decoded.filter { $0.url == target }.map(\.kind))
                return kinds.count == 3
            }
            // Long enough for any replay or duplicate to have landed.
            try await Task.sleep(for: .seconds(3))
            _ = try await probe.evaluateJavaScript("window.orbitAsk(); 'asked'")
            try await Task.sleep(for: .milliseconds(300))
            let raw = try await probe.evaluateJavaScript("window.__orbitSeen") as? String ?? "[]"
            return ((try? JSONDecoder().decode([Seen].self, from: Data(raw.utf8))) ?? decoded)
                .filter { $0.url == target }
        }

        let requests = seen.filter { $0.kind == "webRequest.onCompleted" }
        XCTAssertEqual(requests.count, 1, "one main-frame load is one webRequest.onCompleted: \(seen)")
        XCTAssertEqual(requests.first?.type, "main_frame")
        XCTAssertEqual(requests.first?.requestId, "string", "WebKit's own requestId must be present")

        let commits = seen.filter { $0.kind == "webNavigation.onCommitted" }
        XCTAssertEqual(commits.count, 1, "the main frame commits once; WebKit's copy must not double it: \(seen)")
        XCTAssertEqual(commits.first?.frameId, 0)
        XCTAssertNotNil(commits.first?.transitionType, "onCommitted must carry a transitionType")

        XCTAssertEqual(seen.filter { $0.kind == "webNavigation.onCompleted" }.count, 1,
                       "onCompleted must fire once per load, never replayed: \(seen)")
    }
}
