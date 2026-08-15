//  chrome.history end to end, cross-checked against the real HistoryStore rows.
//
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_addUrlWritesARowSearchAndTheStoreBothSee
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_searchRespectsItsTimeWindow
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_getVisitsReportsEveryRealVisitWithItsOwnIdAndTransition
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_onVisitedFiresForOrbitsOwnRecordedVisit
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_deleteUrlRemovesTheRowAndReportsIt
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_deleteRangeSparesAUrlWithAVisitOutsideTheRange
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_deleteAllEmptiesTheStoreAndReportsAllHistory

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionHistoryLiveTests: LiveEnvironmentTestCase {

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

    private func writeFixture(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-History-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["history"],
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var orbitVisited = [];
        var orbitRemoved = [];
        chrome.history.onVisited.addListener(function (item) { orbitVisited.push(item); });
        chrome.history.onVisitRemoved.addListener(function (removed) { orbitRemoved.push(removed); });

        function reply(sendResponse, result) {
          sendResponse(JSON.stringify({
            result: result === undefined ? null : result,
            error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
          }));
        }

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (!message || !message.command) { return false; }
          switch (message.command) {
            case 'events':
              sendResponse(JSON.stringify({ result: { visited: orbitVisited, removed: orbitRemoved }, error: null }));
              return true;
            case 'reset-events':
              orbitVisited = [];
              orbitRemoved = [];
              sendResponse(JSON.stringify({ result: 'done', error: null }));
              return true;
            case 'search':
              chrome.history.search(message.query, function (results) { reply(sendResponse, results); });
              return true;
            case 'getVisits':
              chrome.history.getVisits({ url: message.url }, function (results) { reply(sendResponse, results); });
              return true;
            case 'addUrl':
              chrome.history.addUrl({ url: message.url }, function () { reply(sendResponse, 'done'); });
              return true;
            case 'deleteUrl':
              chrome.history.deleteUrl({ url: message.url }, function () { reply(sendResponse, 'done'); });
              return true;
            case 'deleteRange':
              chrome.history.deleteRange(
                { startTime: message.startTime, endTime: message.endTime },
                function () { reply(sendResponse, 'done'); }
              );
              return true;
            case 'deleteAll':
              chrome.history.deleteAll(function () { reply(sendResponse, 'done'); });
              return true;
          }
          return false;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Orbit History Probe</title></head>
        <body><div id="orbit-history-probe">ready</div><script src="probe.js"></script></body></html>
        """
        try probeHTML.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let probeJS = """
        window.__orbitOut = null;
        window.orbitAsk = function (message) {
          window.__orbitOut = null;
          chrome.runtime.sendMessage(message, function (response) {
            window.__orbitOut = String(response);
          });
        };
        """
        try probeJS.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
    }

    // MARK: - Harness

    private struct Harness {
        var engine: ChromiumEngine
        var extensionID: String
        var probe: ChromiumWebContents
        var store: HistoryStore
        var space: Space
    }

    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(20),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "timed out waiting for \(waitingFor)"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func withLoadedFixture(_ body: (Harness) async throws -> Void) async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        let env = self.env
        env._test_engineOverride = engine

        // The bridge resolves processRoot per call; without this it would read the real user's history.
        previousProcessRoot = AppEnvironment.processRoot
        AppEnvironment.processRoot = env
        OrbitChromiumHistoryBridge.shared.install()

        let bridge = OrbitChromiumTabsBridge.shared
        if !bridge.isWindowRegistered(env) {
            bridge.windowCreated(owner: env, focused: false)
        }
        bridge.windowFocusChanged(owner: env)

        let store = try XCTUnwrap(
            env.chromiumHistoryStore,
            "the demo environment opened no HistoryStore, so nothing below could be verified against a real one"
        )
        let space = try XCTUnwrap(env.activeSpace)

        let directory = try writeFixture(named: "Orbit History")
        let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
        defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

        let probe = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { probe.close() }
        probe.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(probe)
        try await Self.pollUntil("the probe page to load") {
            try await probe.evaluateJavaScript("typeof window.orbitAsk === 'function'") as? Bool == true
        }

        try await body(
            Harness(engine: engine, extensionID: loaded.id, probe: probe, store: store, space: space)
        )
    }

    // MARK: - Messaging

    /// The worker's `result`, having failed the test if chrome.runtime.lastError was set.
    @discardableResult
    private func ask(_ harness: Harness, _ messageJS: String, file: StaticString = #filePath, line: UInt = #line) async throws -> Any? {
        _ = try await harness.probe.evaluateJavaScript("window.orbitAsk(\(messageJS)); 'sent'")
        try await Self.pollUntil("the worker's reply to \(messageJS)") {
            try await harness.probe.evaluateJavaScript("window.__orbitOut !== null") as? Bool == true
        }
        let raw = try await harness.probe.evaluateJavaScript("window.__orbitOut") as? String ?? ""
        let data = try XCTUnwrap(raw.data(using: .utf8), "worker answered \(messageJS) with \(raw)", file: file, line: line)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "worker answered \(messageJS) with \(raw)", file: file, line: line
        )
        XCTAssertNil(
            envelope["error"] as? String,
            "chrome.history call \(messageJS) set runtime.lastError",
            file: file, line: line
        )
        return envelope["result"]
    }

    private func searchResults(_ harness: Harness, text: String, startTime: Double? = nil, endTime: Double? = nil) async throws -> [[String: Any]] {
        var query = "text: '\(text)'"
        if let startTime { query += ", startTime: \(startTime)" }
        if let endTime { query += ", endTime: \(endTime)" }
        let result = try await ask(harness, "{ command: 'search', query: { \(query) } }")
        return result as? [[String: Any]] ?? []
    }

    private func visits(_ harness: Harness, url: String) async throws -> [[String: Any]] {
        let result = try await ask(harness, "{ command: 'getVisits', url: '\(url)' }")
        return result as? [[String: Any]] ?? []
    }

    private func recordedEvents(_ harness: Harness) async throws -> (visited: [[String: Any]], removed: [[String: Any]]) {
        let result = try await ask(harness, "{ command: 'events' }") as? [String: Any] ?? [:]
        return (
            result["visited"] as? [[String: Any]] ?? [],
            result["removed"] as? [[String: Any]] ?? []
        )
    }

    private func uniqueURL(_ suffix: String = "a") -> String {
        "https://orbit-history-\(UUID().uuidString.lowercased()).example/\(suffix)"
    }

    private func token(of urlString: String) -> String {
        // The UUID inside the host, which no other row in the store can carry.
        String(urlString.dropFirst("https://orbit-history-".count).prefix(36))
    }

    // MARK: - addUrl / search

    func test_addUrlWritesARowSearchAndTheStoreBothSee() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runAddUrlChecks() }
    }

    private func runAddUrlChecks() async throws {
        try await withLoadedFixture { harness in
            let urlString = self.uniqueURL()
            try await self.ask(harness, "{ command: 'addUrl', url: '\(urlString)' }")

            let stored = try await harness.store.urlRow(forURL: try XCTUnwrap(URL(string: urlString)))
            let row = try XCTUnwrap(
                stored,
                "chrome.history.addUrl resolved but wrote no row into Orbit's own HistoryStore; the API answered without doing anything"
            )
            XCTAssertEqual(row.visitCount, 1)
            XCTAssertEqual(row.typedCount, 0, "addUrl is a \"link\" transition, never a typed one")

            let results = try await self.searchResults(harness, text: self.token(of: urlString))
            XCTAssertEqual(
                results.count, 1,
                "search must find the URL addUrl just added. Got \(results)"
            )
            let item = try XCTUnwrap(results.first)
            XCTAssertEqual(item["url"] as? String, urlString)
            XCTAssertEqual(item["visitCount"] as? Int, 1)
            XCTAssertEqual(item["typedCount"] as? Int, 0)
            XCTAssertEqual(
                item["id"] as? String, String(row.id),
                "HistoryItem.id must be the row's real urls.id, so getVisits and search agree on identity"
            )
            let lastVisitTime = try XCTUnwrap(item["lastVisitTime"] as? Double)
            XCTAssertEqual(
                lastVisitTime, row.lastVisit.timeIntervalSince1970 * 1000, accuracy: 1000,
                "lastVisitTime is milliseconds since 1970; seconds here would put the visit in 1970"
            )
        }
    }

    func test_searchRespectsItsTimeWindow() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runSearchWindowChecks() }
    }

    private func runSearchWindowChecks() async throws {
        try await withLoadedFixture { harness in
            let urlString = self.uniqueURL()
            let url = try XCTUnwrap(URL(string: urlString))
            let visitedAt = Date().addingTimeInterval(-6 * 3600)
            _ = try await harness.store.record(visit: HistoryVisit(
                url: url, title: "Orbit six hours ago", profileID: harness.space.profileID,
                spaceID: harness.space.id, visitedAt: visitedAt
            ))

            let token = self.token(of: urlString)
            let inWindow = try await self.searchResults(
                harness, text: token,
                startTime: Date().addingTimeInterval(-12 * 3600).timeIntervalSince1970 * 1000
            )
            XCTAssertEqual(inWindow.count, 1, "a six-hour-old visit is inside a twelve-hour window")

            let outOfWindow = try await self.searchResults(
                harness, text: token,
                startTime: Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000
            )
            XCTAssertEqual(
                outOfWindow.count, 0,
                "startTime must actually bound the query; a search that ignores it is not filtering at all. Got \(outOfWindow)"
            )
        }
    }

    // MARK: - getVisits

    func test_getVisitsReportsEveryRealVisitWithItsOwnIdAndTransition() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runGetVisitsChecks() }
    }

    private func runGetVisitsChecks() async throws {
        try await withLoadedFixture { harness in
            let urlString = self.uniqueURL()
            let url = try XCTUnwrap(URL(string: urlString))

            _ = try await harness.store.record(visit: HistoryVisit(
                url: url, title: "Orbit typed", profileID: harness.space.profileID,
                spaceID: harness.space.id, wasTyped: true,
                visitedAt: Date().addingTimeInterval(-600)
            ))
            try await self.ask(harness, "{ command: 'addUrl', url: '\(urlString)' }")

            let reported = try await self.visits(harness, url: urlString)
            XCTAssertEqual(
                reported.count, 2,
                "both visits to the same URL must be reported; collapsing them loses the per-visit history the API exists for. Got \(reported)"
            )

            let stored = try await harness.store.visitRows(forURL: url)
            XCTAssertEqual(
                reported.compactMap { $0["visitId"] as? String }, stored.map { String($0.id) },
                "visitId must be the real visits.id in the store, in the store's own order"
            )
            XCTAssertEqual(
                Set(reported.compactMap { $0["id"] as? String }).count, 1,
                "both visits belong to one URL, so both must carry the same HistoryItem id"
            )
            XCTAssertEqual(
                reported.compactMap { $0["transition"] as? String }, ["typed", "link"],
                "the Command Bar visit is \"typed\" and addUrl's is \"link\"; a constant transition would erase the distinction"
            )
            for visit in reported {
                XCTAssertEqual(visit["referringVisitId"] as? String, "0")
                XCTAssertEqual(visit["isLocal"] as? Bool, true)
                let visitTime = try XCTUnwrap(visit["visitTime"] as? Double)
                XCTAssertGreaterThan(
                    visitTime, Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000,
                    "visitTime is milliseconds since 1970"
                )
            }

            let unvisited = try await self.visits(harness, url: self.uniqueURL())
            XCTAssertEqual(unvisited.count, 0, "a URL that was never visited has no visits")
        }
    }

    // MARK: - onVisited

    func test_onVisitedFiresForOrbitsOwnRecordedVisit() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runOnVisitedChecks() }
    }

    private func runOnVisitedChecks() async throws {
        try await withLoadedFixture { harness in
            try await self.ask(harness, "{ command: 'reset-events' }")

            let urlString = self.uniqueURL()
            let url = try XCTUnwrap(URL(string: urlString))
            // Orbit's own funnel, not addUrl: an addUrl-only onVisited tells an extension nothing.
            self.env.recordVisit(
                url: url, title: "Orbit Recorded Visit",
                profileID: harness.space.profileID, spaceID: harness.space.id, wasTyped: true
            )

            var visited: [[String: Any]] = []
            try await Self.pollUntil("history.onVisited for \(urlString)") {
                visited = try await self.recordedEvents(harness).visited
                return visited.contains { $0["url"] as? String == urlString }
            }

            let item = try XCTUnwrap(visited.first { $0["url"] as? String == urlString })
            XCTAssertEqual(item["title"] as? String, "Orbit Recorded Visit")
            XCTAssertEqual(item["visitCount"] as? Int, 1)
            XCTAssertEqual(item["typedCount"] as? Int, 1, "the visit was typed, so the item must say so")
            XCTAssertNotNil(item["lastVisitTime"] as? Double)
            let stored = try await harness.store.urlRow(forURL: url)
            let row = try XCTUnwrap(stored)
            XCTAssertEqual(
                item["id"] as? String, String(row.id),
                "the event carries the same identity search would report for this URL"
            )
        }
    }

    // MARK: - deleteUrl

    func test_deleteUrlRemovesTheRowAndReportsIt() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runDeleteUrlChecks() }
    }

    private func runDeleteUrlChecks() async throws {
        try await withLoadedFixture { harness in
            let doomed = self.uniqueURL()
            let survivor = self.uniqueURL()
            try await self.ask(harness, "{ command: 'addUrl', url: '\(doomed)' }")
            try await self.ask(harness, "{ command: 'addUrl', url: '\(survivor)' }")
            try await self.ask(harness, "{ command: 'reset-events' }")

            try await self.ask(harness, "{ command: 'deleteUrl', url: '\(doomed)' }")

            let doomedURL = try XCTUnwrap(URL(string: doomed))
            let doomedRow = try await harness.store.urlRow(forURL: doomedURL)
            let doomedVisits = try await harness.store.visitRows(forURL: doomedURL)
            let survivorRow = try await harness.store.urlRow(forURL: try XCTUnwrap(URL(string: survivor)))
            XCTAssertNil(doomedRow, "deleteUrl resolved but the row is still in Orbit's HistoryStore")
            XCTAssertEqual(
                doomedVisits.count, 0,
                "deleting a URL must take its visits with it, not orphan them"
            )
            XCTAssertNotNil(survivorRow, "deleteUrl removed a URL it was not asked about")

            var removed: [[String: Any]] = []
            try await Self.pollUntil("history.onVisitRemoved for \(doomed)") {
                removed = try await self.recordedEvents(harness).removed
                return !removed.isEmpty
            }
            let event = try XCTUnwrap(removed.first)
            XCTAssertEqual(event["allHistory"] as? Bool, false)
            XCTAssertEqual(
                event["urls"] as? [String], [doomed],
                "onVisitRemoved must name the URL that actually went. Got \(removed)"
            )
        }
    }

    // MARK: - deleteRange

    func test_deleteRangeSparesAUrlWithAVisitOutsideTheRange() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runDeleteRangeChecks() }
    }

    private func runDeleteRangeChecks() async throws {
        try await withLoadedFixture { harness in
            let inside = try XCTUnwrap(URL(string: self.uniqueURL("inside")))
            let straddling = try XCTUnwrap(URL(string: self.uniqueURL("straddling")))
            let now = Date()

            _ = try await harness.store.record(visit: HistoryVisit(
                url: inside, title: "Only inside", profileID: harness.space.profileID,
                spaceID: harness.space.id, visitedAt: now.addingTimeInterval(-2 * 3600)
            ))
            _ = try await harness.store.record(visit: HistoryVisit(
                url: straddling, title: "Straddling", profileID: harness.space.profileID,
                spaceID: harness.space.id, visitedAt: now.addingTimeInterval(-2 * 3600)
            ))
            _ = try await harness.store.record(visit: HistoryVisit(
                url: straddling, title: "Straddling", profileID: harness.space.profileID,
                spaceID: harness.space.id, visitedAt: now.addingTimeInterval(-10 * 3600)
            ))
            try await self.ask(harness, "{ command: 'reset-events' }")

            let start = now.addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000
            let end = now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000
            try await self.ask(harness, "{ command: 'deleteRange', startTime: \(start), endTime: \(end) }")

            let insideRow = try await harness.store.urlRow(forURL: inside)
            let straddlingRow = try await harness.store.urlRow(forURL: straddling)
            XCTAssertNil(
                insideRow,
                "every visit to this URL was inside the range, so the URL itself must be gone"
            )
            let survivor = try XCTUnwrap(
                straddlingRow,
                "a URL with a visit outside the range must survive; deleteRange is not clear(since:)"
            )
            XCTAssertEqual(
                survivor.visitCount, 1,
                "the in-range visit must be gone and the out-of-range one kept, so the count drops from 2 to 1"
            )
            let remaining = try await harness.store.visitRows(forURL: straddling)
            XCTAssertEqual(remaining.count, 1)
            XCTAssertLessThan(
                try XCTUnwrap(remaining.first).visitTime, now.addingTimeInterval(-3 * 3600),
                "the surviving visit has to be the one that was outside the range"
            )

            var removed: [[String: Any]] = []
            try await Self.pollUntil("history.onVisitRemoved for the deleted range") {
                removed = try await self.recordedEvents(harness).removed
                return !removed.isEmpty
            }
            let event = try XCTUnwrap(removed.first)
            XCTAssertEqual(event["allHistory"] as? Bool, false)
            XCTAssertEqual(
                event["urls"] as? [String], [inside.absoluteString],
                "only the URL actually purged may be reported removed. Got \(removed)"
            )
        }
    }

    // MARK: - deleteAll

    func test_deleteAllEmptiesTheStoreAndReportsAllHistory() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runDeleteAllChecks() }
    }

    private func runDeleteAllChecks() async throws {
        try await withLoadedFixture { harness in
            let first = self.uniqueURL("one")
            let second = self.uniqueURL("two")
            try await self.ask(harness, "{ command: 'addUrl', url: '\(first)' }")
            try await self.ask(harness, "{ command: 'addUrl', url: '\(second)' }")
            try await self.ask(harness, "{ command: 'reset-events' }")

            try await self.ask(harness, "{ command: 'deleteAll' }")

            for urlString in [first, second] {
                let row = try await harness.store.urlRow(forURL: try XCTUnwrap(URL(string: urlString)))
                XCTAssertNil(row, "deleteAll left \(urlString) in Orbit's HistoryStore")
            }
            let everything = try await harness.store.urlRows(matchingText: "", start: nil, end: nil, limit: 10)
            XCTAssertEqual(
                everything.count, 0,
                "deleteAll must empty the store, not just the two rows this test added"
            )

            var removed: [[String: Any]] = []
            try await Self.pollUntil("history.onVisitRemoved with allHistory") {
                removed = try await self.recordedEvents(harness).removed
                return !removed.isEmpty
            }
            let event = try XCTUnwrap(removed.first)
            XCTAssertEqual(
                event["allHistory"] as? Bool, true,
                "deleteAll must report allHistory:true; a list of URLs would make an extension think the rest survived"
            )
        }
    }
}
