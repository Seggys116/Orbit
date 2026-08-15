//  chrome.sessions end to end against Orbit's own recently-closed list: a real MV3 worker
//  reads back tabs this test really closed, restores one by id, and sees onChanged fire.
//
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_getRecentlyClosed_reportsOrbitsOwnClosedTabsMostRecentFirst
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_getRecentlyClosed_honoursMaxResults
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_restore_reopensTheNamedTabRatherThanTheMostRecent
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_restore_withNoSessionId_reopensTheMostRecentlyClosedTab
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anUnknownSessionId_isAnErrorNotASilentNoOp
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_onChanged_firesWhenTheClosedListActuallyChanges

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionSessionsLiveTests: LiveEnvironmentTestCase {

    private var temporaryDirectories: [URL] = []
    private var previousProcessRoot: AppEnvironment?

    override func tearDown() {
        if let previousProcessRoot {
            AppEnvironment.processRoot = previousProcessRoot
        }
        previousProcessRoot = nil
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-Sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Orbit Sessions",
          "version": "1.0",
          "permissions": ["sessions", "tabs"],
          "host_permissions": ["<all_urls>"],
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var orbitChanges = 0;
        chrome.sessions.onChanged.addListener(function () { orbitChanges += 1; });
        function reply(sendResponse, payload) {
          payload.lastError = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
          sendResponse(JSON.stringify(payload));
        }
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message && message.command === 'changes') {
            sendResponse(JSON.stringify({ changes: orbitChanges, max: chrome.sessions.MAX_SESSION_RESULTS }));
            return true;
          }
          if (message && message.command === 'getRecentlyClosed') {
            chrome.sessions.getRecentlyClosed(message.filter, function (sessions) {
              reply(sendResponse, { sessions: sessions === undefined ? null : sessions });
            });
            return true;
          }
          if (message && message.command === 'restore') {
            chrome.sessions.restore(message.sessionId, function (restored) {
              reply(sendResponse, { restored: restored === undefined ? null : restored });
            });
            return true;
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>Orbit sessions probe</title></head>
        <body><div id="ready">ready</div><script src="probe.js"></script></body></html>
        """
        try probeHTML.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let probeJS = """
        window.__orbitReply = null;
        window.orbitSend = function (message) {
          window.__orbitReply = null;
          chrome.runtime.sendMessage(message, function (response) {
            window.__orbitReply = String(response);
          });
        };
        """
        try probeJS.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
    }

    // MARK: - Harness

    private struct Harness {
        var engine: ChromiumEngine
        var server: LiveHTTPTestServer
        var extensionID: String
        var probe: ChromiumWebContents
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        func page(_ name: String) -> LiveHTTPTestServer.Route {
            LiveHTTPTestServer.Route(
                contentType: "text/html; charset=utf-8",
                body: """
                <!doctype html><html><head><meta charset="utf-8"><title>orbit sessions \(name)</title></head>
                <body>orbit-sessions-\(name)</body></html>
                """
            )
        }
        return try LiveHTTPTestServer(routes: ["/a": page("a"), "/b": page("b"), "/c": page("c")])
    }

    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(20),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out waiting for \(waitingFor)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// AppEnvironment.frontmost finds no key OrbitWindowController in the test host,
    /// so this environment has to be the process root for the bridge to reach it.
    private func makeHarness() async throws -> Harness {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        env._test_engineOverride = engine
        let bridge = OrbitChromiumTabsBridge.shared
        if !bridge.isWindowRegistered(env) {
            bridge.windowCreated(owner: env, focused: false)
        }
        bridge.windowFocusChanged(owner: env)
        if previousProcessRoot == nil {
            previousProcessRoot = AppEnvironment.processRoot
        }
        AppEnvironment.processRoot = env

        let server = try makeServer()
        let directory = try writeFixture()
        let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)

        let probe = try await LiveChromiumEngineHost.makeContents(engine: engine)
        probe.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(probe)
        try await Self.pollUntil("the probe page for \(loaded.id)") {
            try await probe.evaluateJavaScript("typeof window.orbitSend === 'function'") as? Bool == true
        }

        return Harness(engine: engine, server: server, extensionID: loaded.id, probe: probe)
    }

    private func teardown(_ harness: Harness) {
        harness.probe.close()
        harness.engine.unloadExtension(id: harness.extensionID, session: harness.engine.defaultSession)
        harness.server.stop()
    }

    // MARK: - Worker conversation

    private func send(_ harness: Harness, _ messageJS: String) async throws -> [String: Any] {
        _ = try await harness.probe.evaluateJavaScript("window.orbitSend(\(messageJS)); 'sent'")
        try await Self.pollUntil("the worker's reply to \(messageJS)") {
            try await harness.probe.evaluateJavaScript("window.__orbitReply !== null") as? Bool == true
        }
        let raw = try await harness.probe.evaluateJavaScript("window.__orbitReply") as? String ?? ""
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("the worker's reply to \(messageJS) was not JSON: \(raw)")
            return [:]
        }
        return parsed
    }

    private func recentlyClosed(_ harness: Harness, maxResults: Int? = nil) async throws -> [[String: Any]] {
        let filter = maxResults.map { "{maxResults: \($0)}" } ?? "undefined"
        let reply = try await send(harness, "{command: 'getRecentlyClosed', filter: \(filter)}")
        XCTAssertNil(reply["lastError"] as? String, "getRecentlyClosed reported runtime.lastError")
        return reply["sessions"] as? [[String: Any]] ?? []
    }

    private func closeTab(at path: String, _ harness: Harness) throws -> TabID {
        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let tabID = env.openTab(url: harness.server.baseURL.appendingPathComponent(path), in: spaceID)
        env.closeTab(tabID)
        return tabID
    }

    private func tabValue(_ session: [String: Any]) -> [String: Any] {
        session["tab"] as? [String: Any] ?? [:]
    }

    // MARK: - getRecentlyClosed

    func test_getRecentlyClosed_reportsOrbitsOwnClosedTabsMostRecentFirst() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runOrderingChecks() }
    }

    private func runOrderingChecks() async throws {
        let harness = try await makeHarness()
        defer { teardown(harness) }

        let before = Date().timeIntervalSince1970
        let first = try closeTab(at: "a", harness)
        let second = try closeTab(at: "b", harness)
        let after = Date().timeIntervalSince1970

        let sessions = try await recentlyClosed(harness)
        XCTAssertEqual(
            sessions.count, 2,
            "getRecentlyClosed must report the tabs Orbit actually closed, not an empty list"
        )

        let ids = sessions.map { tabValue($0)["sessionId"] as? String }
        XCTAssertEqual(
            ids, [second.uuidString, first.uuidString],
            "index 0 is the most recently closed tab, so the store's append-ordered list has to be reversed"
        )

        let urls = sessions.map { tabValue($0)["url"] as? String ?? "" }
        XCTAssertTrue(urls[0].hasSuffix("/b"), "the newest entry must carry its own url, not another tab's. Got \(urls)")
        XCTAssertTrue(urls[1].hasSuffix("/a"), "Got \(urls)")

        for session in sessions {
            let lastModified = try XCTUnwrap(
                session["lastModified"] as? Double ?? (session["lastModified"] as? Int).map(Double.init),
                "Session.lastModified is required by the schema"
            )
            XCTAssertTrue(
                lastModified >= before.rounded(.down) && lastModified <= after + 1,
                """
                lastModified must be the real second the tab closed (seconds since 1970), \
                not a fabricated or zero time. Got \(lastModified), window \(before)...\(after)
                """
            )
            let tab = tabValue(session)
            XCTAssertEqual(
                tab["id"] as? Int, -1,
                "a closed tab has no live tab id, so chrome reports TAB_ID_NONE for it"
            )
            XCTAssertFalse(
                (tab["title"] as? String ?? "").isEmpty,
                "the closed tab's title has to survive into the session entry"
            )
            XCTAssertEqual(tab["active"] as? Bool, false)
            XCTAssertNil(
                session["window"],
                "Orbit tracks no closed windows, so no entry may claim to describe one"
            )
        }
    }

    func test_getRecentlyClosed_honoursMaxResults() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runMaxResultsChecks() }
    }

    private func runMaxResultsChecks() async throws {
        let harness = try await makeHarness()
        defer { teardown(harness) }

        _ = try closeTab(at: "a", harness)
        let second = try closeTab(at: "b", harness)
        let third = try closeTab(at: "c", harness)

        let limited = try await recentlyClosed(harness, maxResults: 2)
        XCTAssertEqual(limited.count, 2, "Filter.maxResults must actually truncate the list")
        XCTAssertEqual(
            limited.map { tabValue($0)["sessionId"] as? String },
            [third.uuidString, second.uuidString],
            "truncation must keep the most recent entries, not the oldest"
        )

        let none = try await recentlyClosed(harness, maxResults: 0)
        XCTAssertEqual(none.count, 0, "maxResults 0 is a real request for nothing, not a request for the default")

        let all = try await recentlyClosed(harness)
        XCTAssertEqual(all.count, 3, "an omitted filter must fetch up to MAX_SESSION_RESULTS entries")

        let reply = try await send(harness, "{command: 'changes'}")
        XCTAssertEqual(
            reply["max"] as? Int, env.store.recentlyClosedCapacity,
            "sessions.MAX_SESSION_RESULTS and Orbit's own recently-closed capacity have to be the same number"
        )
    }

    // MARK: - restore

    func test_restore_reopensTheNamedTabRatherThanTheMostRecent() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runRestoreByIDChecks() }
    }

    private func runRestoreByIDChecks() async throws {
        let harness = try await makeHarness()
        defer { teardown(harness) }

        let first = try closeTab(at: "a", harness)
        let second = try closeTab(at: "b", harness)

        let reply = try await send(harness, "{command: 'restore', sessionId: '\(first.uuidString)'}")
        XCTAssertNil(reply["lastError"] as? String, "restoring a real session id must not error")

        XCTAssertEqual(
            env.tab(first)?.section, .today,
            "restore must put the named tab back in the sidebar, not merely report success"
        )
        XCTAssertEqual(
            env.activeTabID, first,
            "the restored tab has to become the active one, as upstream's restore does"
        )
        XCTAssertNotNil(
            env.webContents[first],
            "a restored tab with no live WebContents is a blank pane, not a reopened tab"
        )

        let remaining = try await recentlyClosed(harness)
        XCTAssertEqual(
            remaining.map { tabValue($0)["sessionId"] as? String }, [second.uuidString],
            "the restored entry must leave the list and the untouched newer one must stay"
        )

        let restored = reply["restored"] as? [String: Any] ?? [:]
        XCTAssertNotNil(restored["lastModified"], "restore resolves with the restored Session")
        let restoredTab = restored["tab"] as? [String: Any] ?? [:]
        XCTAssertEqual(
            restoredTab["id"] as? Int,
            OrbitChromiumTabsBridge.shared.existingTabID(for: first).map(Int.init),
            "the restored tab is live again, so it must report its real chrome.tabs id"
        )
        XCTAssertEqual(restoredTab["active"] as? Bool, true)
    }

    func test_restore_withNoSessionId_reopensTheMostRecentlyClosedTab() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runRestoreNewestChecks() }
    }

    private func runRestoreNewestChecks() async throws {
        let harness = try await makeHarness()
        defer { teardown(harness) }

        let first = try closeTab(at: "a", harness)
        let second = try closeTab(at: "b", harness)

        let reply = try await send(harness, "{command: 'restore', sessionId: undefined}")
        XCTAssertNil(reply["lastError"] as? String)
        XCTAssertEqual(
            env.tab(second)?.section, .today,
            "restore() with no argument restores the most recently closed tab"
        )
        XCTAssertEqual(
            env.tab(first)?.section, .archived,
            "it must restore exactly one entry, not drain the list"
        )
    }

    func test_anUnknownSessionId_isAnErrorNotASilentNoOp() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runUnknownSessionChecks() }
    }

    private func runUnknownSessionChecks() async throws {
        let harness = try await makeHarness()
        defer { teardown(harness) }

        let closed = try closeTab(at: "a", harness)

        let reply = try await send(harness, "{command: 'restore', sessionId: 'orbit-not-a-session'}")
        let error = reply["lastError"] as? String
        XCTAssertNotNil(
            error,
            "an id naming no entry must reach runtime.lastError; answering successfully would hide the failure"
        )
        XCTAssertTrue(
            error?.contains("orbit-not-a-session") == true,
            "the error has to name the id that was rejected. Got \(error ?? "nil")"
        )
        XCTAssertEqual(
            env.tab(closed)?.section, .archived,
            "a rejected restore must not quietly reopen some other tab instead"
        )
    }

    // MARK: - onChanged

    func test_onChanged_firesWhenTheClosedListActuallyChanges() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runOnChangedChecks() }
    }

    private func runOnChangedChecks() async throws {
        let harness = try await makeHarness()
        defer { teardown(harness) }

        let baseline = try await send(harness, "{command: 'changes'}")["changes"] as? Int ?? 0

        let closed = try closeTab(at: "a", harness)
        try await Task.sleep(for: .seconds(1))
        let afterClose = try await send(harness, "{command: 'changes'}")["changes"] as? Int ?? 0
        XCTAssertGreaterThan(
            afterClose, baseline,
            "closing a tab changes the recently closed list, so sessions.onChanged has to fire"
        )

        _ = try await send(harness, "{command: 'restore', sessionId: '\(closed.uuidString)'}")
        try await Task.sleep(for: .seconds(1))
        let afterRestore = try await send(harness, "{command: 'changes'}")["changes"] as? Int ?? 0
        XCTAssertGreaterThan(
            afterRestore, afterClose,
            "a restore removes the entry from the list, which is just as much a change as adding one"
        )
    }
}
