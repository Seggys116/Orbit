//  chrome.tabs.query/windows values, read back through a real worker/content
//  script -- a silent no-match and a throw both look like "no tabs" to a test on Orbit's own store.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumTabsQueryConformanceLiveTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private func writeProbeExtension(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-TabsQueryConformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["tabs"],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // try/catch is the whole point: an unsupported query property throws
        // synchronously rather than returning empty, so tabs.length alone can't tell them apart.
        let background = """
        let lastFocusWindowId = 'never';

        chrome.windows.onFocusChanged.addListener(function(windowId) {
          lastFocusWindowId = windowId;
        });

        function describe(tabs) {
          return (tabs || []).map(function(t) {
            return {
              id: t.id,
              url: typeof t.url === 'undefined' ? null : t.url,
              pendingUrl: typeof t.pendingUrl === 'undefined' ? null : t.pendingUrl,
              hasUrl: typeof t.url !== 'undefined',
              index: t.index,
              windowId: t.windowId,
              groupId: t.groupId,
              active: !!t.active,
              pinned: !!t.pinned,
              highlighted: !!t.highlighted,
              audible: !!t.audible,
              discarded: !!t.discarded,
              autoDiscardable: !!t.autoDiscardable,
              frozen: !!t.frozen,
              muted: !!(t.mutedInfo && t.mutedInfo.muted)
            };
          });
        }

        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (!message || !message.kind) { return; }
          if (message.kind === 'query') {
            try {
              chrome.tabs.query(message.queryInfo, function(tabs) {
                sendResponse(JSON.stringify({
                  threw: null,
                  error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null,
                  tabs: describe(tabs)
                }));
              });
            } catch (e) {
              sendResponse(JSON.stringify({ threw: String((e && e.message) || e), error: null, tabs: [] }));
            }
            return true;
          }
          if (message.kind === 'windows') {
            try {
              chrome.windows.getAll({ populate: false }, function(windows) {
                sendResponse(JSON.stringify({
                  threw: null,
                  error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null,
                  windows: (windows || []).map(function(w) {
                    return { id: w.id, state: w.state, type: w.type, focused: !!w.focused };
                  })
                }));
              });
            } catch (e) {
              sendResponse(JSON.stringify({ threw: String((e && e.message) || e), error: null, windows: [] }));
            }
            return true;
          }
          if (message.kind === 'focus') {
            sendResponse(JSON.stringify({
              lastFocusWindowId: lastFocusWindowId,
              windowIdNone: chrome.windows.WINDOW_ID_NONE
            }));
            return true;
          }
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        // Request/response over two DOM attributes: the only thing shared
        // between evaluateJavaScript's main world and the content script's isolated world.
        let content = """
        if (location.pathname === '/observer') {
          let handled = null;
          setInterval(function() {
            const raw = document.documentElement.getAttribute('data-orbit-probe-request');
            if (!raw || raw === handled) { return; }
            handled = raw;
            const request = JSON.parse(raw);
            chrome.runtime.sendMessage(request.message, function(response) {
              document.documentElement.setAttribute('data-orbit-probe-response', JSON.stringify({
                id: request.id,
                response: response || null,
                error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
              }));
            });
          }, 50);
        }
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(
            routes: [
                "/observer": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>observer</title><body>observer</body></html>"),
                "/subject": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>subject</title><body>subject</body></html>"),
                "/second": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>second</title><body>second</body></html>"),
                "/third": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>third</title><body>third</body></html>"),
            ],
            stallingRoutes: ["/never-commits"]
        )
    }

    // MARK: - Probe plumbing

    private struct QueryResult {
        let threw: String?
        let error: String?
        let tabs: [TabSnapshot]
    }

    private struct TabSnapshot {
        let id: Int
        let url: String?
        let pendingUrl: String?
        let hasUrl: Bool
        let index: Int
        let windowId: Int
        let groupId: Int?
        let active: Bool
        let pinned: Bool
        let highlighted: Bool
        let audible: Bool
        let discarded: Bool
        let autoDiscardable: Bool
        let frozen: Bool
        let muted: Bool
    }

    private struct WindowSnapshot {
        let id: Int
        let state: String?
        let type: String?
        let focused: Bool
    }

    private static func pollUntil(
        timeout: Duration = .seconds(15),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "pollUntil timed out after \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// JSON-encodes `object` and hands it to the page as a genuine JS string
    /// literal (a one-element JSON array is one), so no filter value has to
    /// survive hand-rolled escaping.
    private func jsStringLiteral(for object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(decoding: data, as: UTF8.self)
        let wrapped = try JSONSerialization.data(withJSONObject: [text])
        return String(decoding: wrapped, as: UTF8.self) + "[0]"
    }

    private func probe(_ message: [String: Any], on contents: ChromiumWebContents) async throws -> [String: Any] {
        let id = UUID().uuidString
        let literal = try jsStringLiteral(for: ["id": id, "message": message])
        _ = try await contents.evaluateJavaScript(
            "document.documentElement.setAttribute('data-orbit-probe-request', \(literal)); true"
        )

        var payload: [String: Any]?
        try await Self.pollUntil {
            let raw = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('data-orbit-probe-response')"
            )
            guard let text = raw as? String, let data = text.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["id"] as? String == id
            else { return false }
            if let error = envelope["error"] as? String {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "probe failed: \(error)")
            }
            guard let inner = envelope["response"] as? String, let innerData = inner.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any]
            else { return false }
            payload = decoded
            return true
        }
        return try XCTUnwrap(payload)
    }

    private func query(_ queryInfo: [String: Any], on contents: ChromiumWebContents) async throws -> QueryResult {
        let payload = try await probe(["kind": "query", "queryInfo": queryInfo], on: contents)
        let tabs = (payload["tabs"] as? [[String: Any]] ?? []).map { dict in
            TabSnapshot(
                id: dict["id"] as? Int ?? -1,
                url: dict["url"] as? String,
                pendingUrl: dict["pendingUrl"] as? String,
                hasUrl: dict["hasUrl"] as? Bool ?? false,
                index: dict["index"] as? Int ?? -1,
                windowId: dict["windowId"] as? Int ?? -1,
                groupId: dict["groupId"] as? Int,
                active: dict["active"] as? Bool ?? false,
                pinned: dict["pinned"] as? Bool ?? false,
                highlighted: dict["highlighted"] as? Bool ?? false,
                audible: dict["audible"] as? Bool ?? false,
                discarded: dict["discarded"] as? Bool ?? false,
                autoDiscardable: dict["autoDiscardable"] as? Bool ?? false,
                frozen: dict["frozen"] as? Bool ?? false,
                muted: dict["muted"] as? Bool ?? false
            )
        }
        return QueryResult(threw: payload["threw"] as? String, error: payload["error"] as? String, tabs: tabs)
    }

    private func windows(on contents: ChromiumWebContents) async throws -> [WindowSnapshot] {
        let payload = try await probe(["kind": "windows"], on: contents)
        XCTAssertNil(payload["threw"] as? String, "chrome.windows.getAll must not throw")
        return (payload["windows"] as? [[String: Any]] ?? []).map { dict in
            WindowSnapshot(
                id: dict["id"] as? Int ?? -1,
                state: dict["state"] as? String,
                type: dict["type"] as? String,
                focused: dict["focused"] as? Bool ?? false
            )
        }
    }

    private func tab(withPath path: String, in result: QueryResult) -> TabSnapshot? {
        result.tabs.first { $0.url?.hasSuffix(path) == true }
    }

    // MARK: - Shared setup

    private struct Harness {
        let engine: ChromiumEngine
        let extensionID: String
        let server: LiveHTTPTestServer
        let observerContents: ChromiumWebContents
        let observerTabID: TabID
        let spaceID: SpaceID

        @MainActor
        func teardown() {
            server.stop()
            engine.unloadExtension(id: extensionID, session: engine.defaultSession)
        }
    }

    /// Also registers this environment as a real focused chrome.windows
    /// window, since nothing else in a test host does and currentWindow filters need one.
    private func makeHarness(named name: String) async throws -> Harness {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        env._test_engineOverride = engine
        let spaceID = try XCTUnwrap(env.activeSpace?.id)

        let fixtureDirectory = try writeProbeExtension(named: name)
        let loaded = try await engine.loadExtension(at: fixtureDirectory, session: engine.defaultSession)

        let server = try makeServer()
        let observerTabID = env.openTab(url: server.baseURL.appendingPathComponent("observer"), in: spaceID)
        let observerContents = try XCTUnwrap(env.webContents[observerTabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)

        if !OrbitChromiumTabsBridge.shared.isWindowRegistered(env) {
            OrbitChromiumTabsBridge.shared.windowCreated(owner: env, focused: true)
        }
        OrbitChromiumTabsBridge.shared.windowFocusChanged(owner: env)

        try await Self.pollUntil(timeout: .seconds(30)) {
            let result = try? await self.query([:], on: observerContents)
            return self.tab(withPath: "/observer", in: result ?? QueryResult(threw: nil, error: nil, tabs: [])) != nil
        }

        return Harness(
            engine: engine, extensionID: loaded.id, server: server,
            observerContents: observerContents, observerTabID: observerTabID, spaceID: spaceID
        )
    }

    // MARK: - A. url is a match pattern, and accepts an array

    func testQueryUrlMatchesAMatchPatternAndAcceptsAnArrayOfThem() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness(named: "Orbit Tabs Query Url Pattern Test")
            defer { harness.teardown() }
            let env = self.env

            let subjectTabID = env.openTab(url: harness.server.baseURL.appendingPathComponent("subject"), in: harness.spaceID)
            defer { if env.state.tabs[subjectTabID] != nil { env.closeTab(subjectTabID) } }
            try await Self.pollUntil {
                let all = try await self.query([:], on: harness.observerContents)
                return self.tab(withPath: "/subject", in: all) != nil
            }

            // The defect: this used to be `tab_url != *url`, so a pattern
            // matched nothing at all.
            let pattern = try await self.query(["url": "*://127.0.0.1/subject*"], on: harness.observerContents)
            XCTAssertNil(pattern.threw, "a match-pattern url filter must not throw")
            XCTAssertNil(pattern.error)
            XCTAssertNotNil(self.tab(withPath: "/subject", in: pattern), "a match pattern must select the tab it matches")
            XCTAssertNil(self.tab(withPath: "/observer", in: pattern), "and must not select the tabs it does not match")

            // The array form was a hard argument-validation error.
            let array = try await self.query(
                ["url": ["*://127.0.0.1/subject*", "*://127.0.0.1/observer*"]], on: harness.observerContents
            )
            XCTAssertNil(array.threw, "chrome.tabs.query({url: [...]}) must be accepted, not rejected by argument validation")
            XCTAssertNotNil(self.tab(withPath: "/subject", in: array))
            XCTAssertNotNil(self.tab(withPath: "/observer", in: array))

            // Negative control: a pattern that matches neither tab.
            let miss = try await self.query(["url": "*://example.invalid/*"], on: harness.observerContents)
            XCTAssertNil(miss.threw)
            XCTAssertNil(self.tab(withPath: "/subject", in: miss))
            XCTAssertNil(self.tab(withPath: "/observer", in: miss))

            // A full url is itself a valid pattern, so the old exact-string
            // callers keep working.
            let exact = harness.server.baseURL.appendingPathComponent("subject").absoluteString
            let exactResult = try await self.query(["url": exact], on: harness.observerContents)
            XCTAssertNil(exactResult.threw)
            XCTAssertNotNil(self.tab(withPath: "/subject", in: exactResult), "an exact url must still match its own tab")

            // title is a glob, gated on the same permission as url.
            let title = try await self.query(["title": "subj*"], on: harness.observerContents)
            XCTAssertNil(title.threw, "title is a Chrome query field and must not throw")
            XCTAssertNotNil(self.tab(withPath: "/subject", in: title))
            XCTAssertNil(self.tab(withPath: "/observer", in: title))
        }
    }

    // MARK: - B. currentWindow:false, and currentWindow alongside windowId

    func testCurrentWindowFalseExcludesAndWindowIdIsNotDroppedAlongsideCurrentWindow() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness(named: "Orbit Tabs Query Current Window Test")
            defer { harness.teardown() }

            let all = try await self.query([:], on: harness.observerContents)
            let observer = try XCTUnwrap(self.tab(withPath: "/observer", in: all))
            let windowID = observer.windowId

            let inCurrent = try await self.query(["currentWindow": true], on: harness.observerContents)
            XCTAssertNil(inCurrent.threw)
            XCTAssertNotNil(self.tab(withPath: "/observer", in: inCurrent), "currentWindow:true must find this window's tabs")

            // The defect: there was no else branch, so this used to be
            // silently ignored and answered with every tab.
            let notCurrent = try await self.query(["currentWindow": false], on: harness.observerContents)
            XCTAssertNil(notCurrent.threw)
            XCTAssertNil(
                self.tab(withPath: "/observer", in: notCurrent),
                "currentWindow:false must exclude the current window, not be ignored"
            )
            XCTAssertTrue(
                notCurrent.tabs.allSatisfy { $0.windowId != windowID },
                "no tab from the current window may survive currentWindow:false"
            )

            // The defect: windowId was only read in the else branch, so
            // passing both silently dropped it.
            let both = try await self.query(
                ["currentWindow": true, "windowId": windowID], on: harness.observerContents
            )
            XCTAssertNil(both.threw)
            XCTAssertNotNil(self.tab(withPath: "/observer", in: both))

            let mismatched = try await self.query(
                ["currentWindow": true, "windowId": windowID + 4096], on: harness.observerContents
            )
            XCTAssertNil(mismatched.threw)
            XCTAssertTrue(
                mismatched.tabs.isEmpty,
                "windowId must still be applied when currentWindow is present -- naming another window must match nothing"
            )

            let lastFocused = try await self.query(["lastFocusedWindow": true], on: harness.observerContents)
            XCTAssertNil(lastFocused.threw, "lastFocusedWindow is a Chrome query field and must not throw")
            XCTAssertNotNil(self.tab(withPath: "/observer", in: lastFocused))
        }
    }

    // MARK: - C. The Chrome query fields that used to throw

    func testEveryChromeQueryFieldIsAcceptedRatherThanThrowing() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness(named: "Orbit Tabs Query Fields Test")
            defer { harness.teardown() }

            // Each was an argument-validation exception because queryInfo
            // declared no additionalProperties.
            let fields: [[String: Any]] = [
                ["lastFocusedWindow": true],
                ["title": "*"],
                ["audible": false],
                ["muted": false],
                ["highlighted": false],
                ["discarded": false],
                ["autoDiscardable": true],
                ["frozen": false],
                ["groupId": -1],
                ["index": 0],
                ["windowType": "normal"],
            ]
            for field in fields {
                let result = try await self.query(field, on: harness.observerContents)
                XCTAssertNil(result.threw, "chrome.tabs.query(\(field)) must not throw")
                XCTAssertNil(result.error, "chrome.tabs.query(\(field)) must not error")
            }

            // The single most common real-world idiom.
            let idiom = try await self.query(
                ["active": true, "lastFocusedWindow": true], on: harness.observerContents
            )
            XCTAssertNil(idiom.threw, "query({active:true, lastFocusedWindow:true}) must not throw")
            XCTAssertFalse(idiom.tabs.isEmpty, "and must answer with the active tab, not nothing")

            // The Tab fields those filters read must exist too, or an
            // extension that filters on them cannot then read them back.
            let all = try await self.query([:], on: harness.observerContents)
            let observer = try XCTUnwrap(self.tab(withPath: "/observer", in: all))
            XCTAssertEqual(observer.groupId, -1, "tab.groupId must be TAB_GROUP_ID_NONE, not undefined")
            XCTAssertTrue(observer.autoDiscardable)
            XCTAssertFalse(observer.frozen)
            XCTAssertFalse(observer.discarded)

            // Negative controls: these must be filters, not no-ops.
            let audible = try await self.query(["audible": true], on: harness.observerContents)
            XCTAssertNil(self.tab(withPath: "/observer", in: audible), "a silent tab must not match audible:true")
            let grouped = try await self.query(["groupId": 7], on: harness.observerContents)
            XCTAssertTrue(grouped.tabs.isEmpty, "Orbit has no tab groups, so no tab may match a real group id")
            let devtoolsWindow = try await self.query(["windowType": "devtools"], on: harness.observerContents)
            XCTAssertTrue(devtoolsWindow.tabs.isEmpty, "every Orbit window is normal, so windowType:devtools matches nothing")
        }
    }

    // MARK: - D. Pinned tabs have real, distinct indices

    func testPinnedTabsHaveDistinctLeadingIndices() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness(named: "Orbit Tabs Query Index Test")
            defer { harness.teardown() }
            let env = self.env

            let subjectTabID = env.openTab(url: harness.server.baseURL.appendingPathComponent("subject"), in: harness.spaceID)
            defer { if env.state.tabs[subjectTabID] != nil { env.closeTab(subjectTabID) } }
            let secondTabID = env.openTab(url: harness.server.baseURL.appendingPathComponent("second"), in: harness.spaceID)
            defer { if env.state.tabs[secondTabID] != nil { env.closeTab(secondTabID) } }

            try await Self.pollUntil {
                let all = try await self.query([:], on: harness.observerContents)
                return self.tab(withPath: "/subject", in: all) != nil && self.tab(withPath: "/second", in: all) != nil
            }

            env.pinTab(subjectTabID)
            env.pinTab(secondTabID)
            try await Self.pollUntil {
                let all = try await self.query(["pinned": true], on: harness.observerContents)
                return self.tab(withPath: "/subject", in: all)?.pinned == true
                    && self.tab(withPath: "/second", in: all)?.pinned == true
            }

            let all = try await self.query([:], on: harness.observerContents)
            let observer = try XCTUnwrap(self.tab(withPath: "/observer", in: all))
            let windowTabs = all.tabs.filter { $0.windowId == observer.windowId }
            let indices = windowTabs.map(\.index)

            // The defect: every pinned tab reported 0, because pinned tabs
            // are absent from todayTabs and hit the `?? 0` fallback.
            XCTAssertEqual(
                Set(indices).count, indices.count,
                "every tab in a window must have its own index -- got \(indices)"
            )
            let pinnedIndices = windowTabs.filter(\.pinned).map(\.index)
            let unpinnedIndices = windowTabs.filter { !$0.pinned }.map(\.index)
            XCTAssertEqual(pinnedIndices.count, 2, "both tabs must still report as pinned")
            XCTAssertEqual(
                Set(pinnedIndices), Set(indices.sorted().prefix(pinnedIndices.count)),
                "pinned tabs occupy the leading positions of the strip -- got \(pinnedIndices) of \(indices.sorted())"
            )
            for pinned in pinnedIndices {
                for unpinned in unpinnedIndices {
                    XCTAssertLessThan(pinned, unpinned, "a pinned tab must precede every unpinned one")
                }
            }

            // The index filter must select by that same index.
            let atZero = try await self.query(["index": 0], on: harness.observerContents)
            XCTAssertEqual(atZero.tabs.filter { $0.windowId == observer.windowId }.count, 1,
                           "index:0 must select exactly one tab in this window")

            // Query results come back in strip order, not tab-id order.
            XCTAssertEqual(
                windowTabs.map(\.index), windowTabs.map(\.index).sorted(),
                "chrome.tabs.query must answer in window-then-index order"
            )
        }
    }

    // MARK: - E. Tab.url is the committed url, never one that never committed

    func testTabUrlReportsTheCommittedUrlDuringAnUncommittedNavigation() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness(named: "Orbit Tabs Committed Url Test")
            defer { harness.teardown() }
            let env = self.env

            let subjectTabID = env.openTab(url: harness.server.baseURL.appendingPathComponent("subject"), in: harness.spaceID)
            defer { if env.state.tabs[subjectTabID] != nil { env.closeTab(subjectTabID) } }
            let subjectContents = try XCTUnwrap(env.webContents[subjectTabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(subjectContents)

            try await Self.pollUntil {
                let all = try await self.query([:], on: harness.observerContents)
                return self.tab(withPath: "/subject", in: all) != nil
            }

            // /never-commits accepts the connection but never answers, so
            // this navigation stays pending forever while /subject stays committed.
            env.loadInTab(subjectTabID, url: harness.server.baseURL.appendingPathComponent("never-commits"))

            try await Self.pollUntil(timeout: .seconds(20)) {
                let all = try await self.query([:], on: harness.observerContents)
                return self.tab(withPath: "/subject", in: all)?.pendingUrl?.hasSuffix("/never-commits") == true
            }

            let all = try await self.query([:], on: harness.observerContents)
            let subject = try XCTUnwrap(self.tab(withPath: "/subject", in: all))
            XCTAssertTrue(
                subject.url?.hasSuffix("/subject") == true,
                "tab.url must be the last committed url, not a url this tab never committed -- got \(subject.url ?? "nil")"
            )
            XCTAssertTrue(
                subject.pendingUrl?.hasSuffix("/never-commits") == true,
                "the in-flight navigation belongs in pendingUrl"
            )

            // The url filter matches the committed url too, so origin gating
            // cannot be steered by a navigation that never landed.
            let byPending = try await self.query(["url": "*://127.0.0.1/never-commits*"], on: harness.observerContents)
            XCTAssertTrue(byPending.tabs.isEmpty, "an uncommitted url must not satisfy a url filter")
            let byCommitted = try await self.query(["url": "*://127.0.0.1/subject*"], on: harness.observerContents)
            XCTAssertNotNil(self.tab(withPath: "/subject", in: byCommitted), "the committed url must still satisfy it")
        }
    }

    // MARK: - F. Window.state is real, and WINDOW_ID_NONE is -1

    func testWindowStateIsRealAndFocusLostDeliversWindowIdNone() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness(named: "Orbit Windows State Test")
            defer { harness.teardown() }
            let env = self.env

            let all = try await self.query([:], on: harness.observerContents)
            let windowID = try XCTUnwrap(self.tab(withPath: "/observer", in: all)).windowId

            var reported = try await self.windows(on: harness.observerContents)
            var window = try XCTUnwrap(reported.first { $0.id == windowID })
            XCTAssertEqual(window.state, "normal", "an ordinary window reports normal")
            XCTAssertEqual(window.type, "normal", "every Orbit window is a normal browser window")

            // The defect: state was the literal "normal" for every window.
            // Pushed here the same way OrbitWindowController's NSWindow delegate hooks push it.
            OrbitChromiumTabsBridge.shared.windowStateChanged(owner: env, state: .fullscreen)
            try await Self.pollUntil {
                let current = try await self.windows(on: harness.observerContents)
                return current.first { $0.id == windowID }?.state == "fullscreen"
            }

            OrbitChromiumTabsBridge.shared.windowStateChanged(owner: env, state: .minimized)
            reported = try await self.windows(on: harness.observerContents)
            window = try XCTUnwrap(reported.first { $0.id == windowID })
            XCTAssertEqual(window.state, "minimized", "every WindowState value must survive the wire, not just one")

            OrbitChromiumTabsBridge.shared.windowStateChanged(owner: env, state: .normal)

            // The defect: Swift pushed 0 for "no window focused" verbatim, so
            // `windowId === chrome.windows.WINDOW_ID_NONE` never matched.
            OrbitChromiumTabsBridge.shared.windowFocusChanged(owner: nil)
            var focus: [String: Any] = [:]
            var observedFocusIDs: Set<Int> = []
            do {
                try await Self.pollUntil {
                    focus = try await self.probe(["kind": "focus"], on: harness.observerContents)
                    if let value = focus["lastFocusWindowId"] as? Int { observedFocusIDs.insert(value) }
                    return (focus["lastFocusWindowId"] as? Int) == -1
                }
            } catch {
                XCTFail(
                    "losing focus must deliver windows.WINDOW_ID_NONE (-1), not 0 -- saw \(observedFocusIDs.sorted())"
                )
            }
            XCTAssertEqual(focus["windowIdNone"] as? Int, -1)
            XCTAssertFalse(observedFocusIDs.contains(0), "0 is never a windowId chrome.windows may see")

            // And a real window id still arrives as itself.
            OrbitChromiumTabsBridge.shared.windowFocusChanged(owner: env)
            try await Self.pollUntil {
                let current = try await self.probe(["kind": "focus"], on: harness.observerContents)
                return (current["lastFocusWindowId"] as? Int) == windowID
            }
        }
    }
}
