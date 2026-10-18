//  declarativeNetRequest regexFilter rules: RE2 syntax WebKit's content blockers lack is rewritten
//  into an equivalent rule that really blocks, an inexpressible one reaches runtime.lastError, and
//  the callback runs when WebKit has actually applied the update.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitExtensionDeclarativeNetRequestRegexLiveTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private static let supportedRegex = #"^http://127\.0\.0\.1:\d+/blocked(?:\?.*|#.*|$)"#
    private static let unsupportedRegex = #"^http://(alpha|beta)\.example/"#

    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-DNRRegex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        try """
        {
          "manifest_version": 3,
          "name": "Orbit DNR Regex",
          "version": "1.0",
          "permissions": ["declarativeNetRequest"],
          "host_permissions": ["http://127.0.0.1/*"],
          "background": { "service_worker": "background.js" }
        }
        """.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        var SUPPORTED = \(JavaScriptLiteral.string(Self.supportedRegex));
        var UNSUPPORTED = \(JavaScriptLiteral.string(Self.unsupportedRegex));
        function rule(id, regex) {
          return { id: id, priority: 1, action: { type: 'block' }, condition: { regexFilter: regex, resourceTypes: ['xmlhttprequest'] } };
        }
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'add-supported' || message === 'add-unsupported') {
            var added = message === 'add-supported' ? rule(1, SUPPORTED) : rule(2, UNSUPPORTED);
            chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [1, 2], addRules: [added] }, function () {
              sendResponse(JSON.stringify({ error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null }));
            });
            return true;
          }
          if (message === 'get') {
            chrome.declarativeNetRequest.getDynamicRules(function (rules) {
              sendResponse(JSON.stringify({ rules: rules || [] }));
            });
            return true;
          }
          return true;
        });
        """.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try """
        <!DOCTYPE html><html><head><title>probe</title></head><body><script src="probe.js"></script></body></html>
        """.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)
        try """
        var question = new URL(location.href).searchParams.get('ask');
        chrome.runtime.sendMessage(question, function (response) {
          document.documentElement.setAttribute('data-orbit-answer',
            chrome.runtime.lastError ? JSON.stringify({ error: chrome.runtime.lastError.message }) : String(response));
        });
        """.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)
        return directory
    }

    private static func pollUntil(timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "pollUntil timed out after \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func ask(_ question: String, extensionID: String, engine: WebKitEngine) async throws -> [String: Any] {
        let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
        defer { contents.close() }
        contents.load(URL(string: "chrome-extension://\(extensionID)/probe.html?ask=\(question)")!)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        try await Self.pollUntil {
            try await contents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-answer')") as? String != nil
        }
        let raw = try await contents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-answer')") as? String ?? ""
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], "answer was \(raw)")
    }

    private func fetchStatus(_ path: String, in contents: WebKitWebContents) async throws -> String {
        _ = try await contents.evaluateJavaScript("""
        (function () {
          window.__orbitFetch = null;
          fetch('\(path)').then(function (response) { window.__orbitFetch = 'status:' + response.status; },
                                function (error) { window.__orbitFetch = 'failed'; });
          return 'fetching';
        })()
        """)
        try await Self.pollUntil {
            try await contents.evaluateJavaScript("window.__orbitFetch !== null") as? Bool == true
        }
        return try await contents.evaluateJavaScript("window.__orbitFetch") as? String ?? ""
    }

    func testARewrittenRegexRuleBlocksAndAnInexpressibleOneReportsLastError() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-dnr</body></html>"),
                "/blocked": LiveHTTPTestServer.Route(contentType: "text/plain", body: "should-not-load"),
                "/allowed": LiveHTTPTestServer.Route(contentType: "text/plain", body: "loaded"),
            ])
            defer { server.stop() }
            let loaded = try await engine.loadExtension(at: try self.writeFixture(), session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let added = try await self.ask("add-supported", extensionID: loaded.id, engine: engine)
            XCTAssertTrue(added["error"] is NSNull, "a regex WebKit can express after rewriting must be accepted: \(added)")

            let rules = try await self.ask("get", extensionID: loaded.id, engine: engine)["rules"] as? [[String: Any]] ?? []
            let condition = rules.first { $0["id"] as? Int == 1 }?["condition"] as? [String: Any]
            XCTAssertEqual(condition?["regexFilter"] as? String, Self.supportedRegex,
                           "getDynamicRules must return the rule as the extension wrote it")

            let tab = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { tab.close() }
            tab.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(tab)
            let blocked = try await self.fetchStatus("/blocked", in: tab)
            let blockedWithQuery = try await self.fetchStatus("/blocked?x=1", in: tab)
            let allowed = try await self.fetchStatus("/allowed", in: tab)
            XCTAssertEqual(blocked, "failed", "the rewritten rule must really block the URL its regex names")
            XCTAssertEqual(blockedWithQuery, "failed", "the (?:\\?.*|#.*|$) tail must still match a query")
            XCTAssertEqual(allowed, "status:200", "the rule must not block what its regex does not name")

            let rejected = try await self.ask("add-unsupported", extensionID: loaded.id, engine: engine)
            let error = rejected["error"] as? String ?? ""
            XCTAssertTrue(error.contains("Rule with id 2") && error.contains("regexFilter"),
                          "an alternation WebKit cannot express must reach runtime.lastError, not vanish: \(rejected)")
        }
    }
}
