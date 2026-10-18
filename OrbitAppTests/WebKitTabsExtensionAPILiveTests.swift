//  chrome.tabs/windows coverage: tab mutations, popup exclusion, permission
//  scrubbing, and window.open() adoption, read through a real background worker, never a mock.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitTabsExtensionAPILiveTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture: an extension whose background answers chrome.tabs.query

    private func writeTabsQueryExtension(named name: String, includeTabsPermission: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-TabsQueryExtension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let permissions = includeTabsPermission ? "[\"tabs\"]" : "[]"
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

        // hasUrl/hasTitle are typeof checks, not truthiness: scrubbing must
        // remove the property entirely (undefined), not leave it empty.
        let background = """
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message === 'orbit-tabs-query') {
            chrome.tabs.query({}, function(tabs) {
              sendResponse(JSON.stringify(tabs.map(function(t) {
                return {
                  id: t.id,
                  hasUrl: typeof t.url !== 'undefined',
                  hasTitle: typeof t.title !== 'undefined',
                  url: t.url || null,
                  active: !!t.active,
                  pinned: !!t.pinned
                };
              })));
            });
            return true;
          }
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        // Only /observer polls; the subject/popup pages this content script
        // also injects into must not perturb what's being observed.
        let content = """
        if (location.pathname === '/observer') {
          function orbitPollTabsQuery() {
            chrome.runtime.sendMessage('orbit-tabs-query', function(response) {
              document.documentElement.setAttribute('data-orbit-tabs-query-result', response || '[]');
            });
          }
          orbitPollTabsQuery();
          setInterval(orbitPollTabsQuery, 150);
        }
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/observer": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>observer</body></html>"),
            "/subject": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>subject</body></html>"),
            "/popup": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>popup</body></html>"),
        ])
    }

    // MARK: - Decoding the observer's own report

    private struct TabSnapshot {
        let id: Int
        let hasUrl: Bool
        let hasTitle: Bool
        let url: String?
        let active: Bool
        let pinned: Bool
    }

    private func parseTabsQueryResult(_ raw: Any?) -> [TabSnapshot]? {
        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return array.map { dict in
            TabSnapshot(
                id: dict["id"] as? Int ?? -1,
                hasUrl: dict["hasUrl"] as? Bool ?? false,
                hasTitle: dict["hasTitle"] as? Bool ?? false,
                url: dict["url"] as? String,
                active: dict["active"] as? Bool ?? false,
                pinned: dict["pinned"] as? Bool ?? false
            )
        }
    }

    private func snapshot(withURLSuffix suffix: String, in snapshots: [TabSnapshot]) -> TabSnapshot? {
        snapshots.first { $0.url?.hasSuffix(suffix) == true }
    }

    private static func pollUntil(
        timeout: Duration = .seconds(10),
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

    // MARK: - A. Full lifecycle: created, activated, pinned, removed -- plus
    // the negative control (an extension popup never appears).

    func testTabLifecycleEventsReachChromeTabsQueryAndAnExtensionPopupNeverAppearsThere() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixtureDirectory = try self.writeTabsQueryExtension(
                named: "Orbit Tabs Query Lifecycle Test", includeTabsPermission: true
            )
            let loaded = try await engine.loadExtension(at: fixtureDirectory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let server = try self.makeServer()
            defer { server.stop() }

            // 1. The observer itself is the first (and, so far, only) tab.
            let observerTabID = env.openTab(url: server.baseURL.appendingPathComponent("observer"), in: spaceID)
            defer { env.closeTab(observerTabID) }
            let observerContents = try XCTUnwrap(env.webContents[observerTabID] as? WebKitWebContents)
            // openTab defers navigation until content blocking compiles, so
            // there's no main frame to evaluate script in until this settles.
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(observerContents)

            try await Self.pollUntil(timeout: .seconds(15)) {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
                )
                return self.parseTabsQueryResult(raw)?.count == 1
            }
            var snapshots = self.parseTabsQueryResult(
                try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
                )
            )
            let observerSnapshot = try XCTUnwrap(self.snapshot(withURLSuffix: "/observer", in: try XCTUnwrap(snapshots)))
            XCTAssertTrue(observerSnapshot.hasUrl && observerSnapshot.hasTitle, "an extension holding \"tabs\" must see url/title")
            XCTAssertTrue(observerSnapshot.active, "the only open tab must be active")

            // 2. Opening a second (subject) tab must fire tabs.onCreated --
            // observed here as the query's count going from 1 to 2.
            let subjectTabID = env.openTab(url: server.baseURL.appendingPathComponent("subject"), in: spaceID)
            // Step 6 closes it; this keeps a failure before then from leaving
            // a registered tab behind for later suites to count.
            defer { if env.state.tabs[subjectTabID] != nil { env.closeTab(subjectTabID) } }
            try await Self.pollUntil(timeout: .seconds(15)) {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
                )
                return self.parseTabsQueryResult(raw)?.count == 2
            }

            // 3. Negative control: a popup WebContents (via
            // ExtensionActionPopupModel) must not move the count -- absent from the same real registry.
            let popupModel = ExtensionActionPopupModel(
                engine: engine, session: engine.defaultSession, url: server.baseURL.appendingPathComponent("popup")
            )
            popupModel.start()
            defer { popupModel.teardown() }
            try await Task.sleep(for: .milliseconds(500))
            snapshots = self.parseTabsQueryResult(
                try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
                )
            )
            XCTAssertEqual(snapshots?.count, 2, "an extension popup's own WebContents must never be reported by chrome.tabs.query")

            // 4. Activating the subject must fire tabs.onActivated.
            env.activateTab(subjectTabID)
            try await Self.pollUntil(timeout: .seconds(15)) {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
                )
                guard let found = self.parseTabsQueryResult(raw) else { return false }
                return self.snapshot(withURLSuffix: "/subject", in: found)?.active == true
                    && self.snapshot(withURLSuffix: "/observer", in: found)?.active == false
            }

            // 5. Pinning the subject must fire tabs.onUpdated({pinned: true}).
            env.pinTab(subjectTabID)
            try await Self.pollUntil(timeout: .seconds(15)) {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
                )
                guard let found = self.parseTabsQueryResult(raw) else { return false }
                return self.snapshot(withURLSuffix: "/subject", in: found)?.pinned == true
            }

            // 6. Closing the subject must fire tabs.onRemoved -- back to just the observer.
            env.closeTabKeepingBookmark(subjectTabID)
            try await Self.pollUntil(timeout: .seconds(15)) {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
                )
                guard let found = self.parseTabsQueryResult(raw) else { return false }
                // Not a count: closing the active bookmark leaves no active tab
                // at all (it does not fall over onto observer); observer stays
                // present here only because its own WebContents was already open.
                return self.snapshot(withURLSuffix: "/subject", in: found) == nil
                    && self.snapshot(withURLSuffix: "/observer", in: found) != nil
            }
        }
    }

    // MARK: - B. Permission scrubbing

    func testAnExtensionWithoutTheTabsPermissionGetsScrubbedResults() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixtureDirectory = try self.writeTabsQueryExtension(
                named: "Orbit Tabs Query No Permission Test", includeTabsPermission: false
            )
            let loaded = try await engine.loadExtension(at: fixtureDirectory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let server = try self.makeServer()
            defer { server.stop() }

            let observerTabID = env.openTab(url: server.baseURL.appendingPathComponent("observer"), in: spaceID)
            defer { env.closeTab(observerTabID) }
            let observerContents = try XCTUnwrap(env.webContents[observerTabID] as? WebKitWebContents)
            // openTab defers navigation until content blocking compiles, so
            // there's no main frame to evaluate script in until this settles.
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(observerContents)

            try await Self.pollUntil(timeout: .seconds(15)) {
                let raw = try await observerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
                )
                return self.parseTabsQueryResult(raw)?.count == 1
            }
            let rawSnapshots = try await observerContents.evaluateJavaScript(
                "document.documentElement.getAttribute('data-orbit-tabs-query-result')"
            )
            let snapshots = try XCTUnwrap(self.parseTabsQueryResult(rawSnapshots))
            let observerSnapshot = try XCTUnwrap(snapshots.first)
            XCTAssertFalse(observerSnapshot.hasUrl, "an extension with no \"tabs\"/host permission must not see url")
            XCTAssertFalse(observerSnapshot.hasTitle, "an extension with no \"tabs\"/host permission must not see title")
        }
    }

    // MARK: - C. Tear-off: still registered, under a fresh id, owned by the new window

    func testATornOffTabIsStillRegisteredUnderANewWindowIdentity() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let sourceEnv = self.env
            sourceEnv._test_engineOverride = engine
            let spaceID = try XCTUnwrap(sourceEnv.activeSpace?.id)

            let server = try self.makeServer()
            defer { server.stop() }

            let tabID = sourceEnv.openTab(url: server.baseURL.appendingPathComponent("subject"), in: spaceID)
            let originalID = try XCTUnwrap(engine.numericID(for: tabID), "opening a tab must register it")
            XCTAssertNotNil(sourceEnv.webContents[tabID], "the tab must be owned by the window that opened it")

            let tornOffSpaceID = sourceEnv.store.createSpace(
                name: "Torn Off", icon: "square.on.square", iconIsEmoji: false,
                theme: WindowSession.incognitoTheme, profileID: sourceEnv.state.profiles[0].id, activate: false
            )
            let destinationEnv = AppEnvironment.makeWindowScoped(
                sharing: sourceEnv, activeSpaceID: tornOffSpaceID, isTornOff: true
            )
            sourceEnv.store.moveTab(tabID, toSpace: tornOffSpaceID, section: .today)
            destinationEnv.adoptWebContents(for: tabID, from: sourceEnv)
            defer { destinationEnv.closeTab(tabID) }

            let newID = try XCTUnwrap(
                engine.numericID(for: tabID), "a tab torn off into a new window must still be registered"
            )
            XCTAssertEqual(newID, originalID, "a tab moved between windows keeps its id")
            XCTAssertNotNil(destinationEnv.webContents[tabID], "the tab must now be owned by the destination window")
            XCTAssertNil(sourceEnv.webContents[tabID], "the source window must have released the tab")
            XCTAssertEqual(engine.storeTabID(forNumericID: originalID), tabID, "the id must still name the moved tab")
        }
    }

    // MARK: - D. An adopted WebContents (window.open()/openOptionsPage() from
    // an extension page) becomes a real Orbit tab.
    // Adopts the WebContents the engine already built, rather than JS: a worker
    // never constructs the host, so a JS-driven trigger risks testing nothing.

    func testAdoptExtensionTabWrapsARealHandleAsAGenuineOrbitTab() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let env = self.env
            env._test_engineOverride = engine
            let previousProcessRoot = AppEnvironment.processRoot
            AppEnvironment.processRoot = env
            defer { AppEnvironment.processRoot = previousProcessRoot }

            let server = try self.makeServer()
            defer { server.stop() }
            let targetURL = server.baseURL.appendingPathComponent("subject")

            let rawContents = try engine.makeWebContents(session: engine.defaultSession, initialURL: targetURL)
            let handle = try XCTUnwrap((rawContents as? WebKitWebContents)?.extensionTabHandle)

            let tabCountBefore = env.state.tabs.count
            let adoptedID = env.adoptExtensionTab(handle: handle, url: targetURL, active: true)

            XCTAssertNotNil(adoptedID, "adopting must accept a real handle when an active Space exists to host it")
            XCTAssertEqual(
                env.state.tabs.count, tabCountBefore + 1,
                "adopting must create exactly one new Orbit tab"
            )
            let adoptedTab = try XCTUnwrap(env.state.tabs.values.first { $0.url.absoluteString == targetURL.absoluteString })
            defer { env.closeTab(adoptedTab.id) }
            XCTAssertTrue(
                env.webContents[adoptedTab.id] === rawContents,
                "the adopted tab must carry the WebContents that was already built, not a second one"
            )
            XCTAssertNotNil(
                engine.numericID(for: adoptedTab.id),
                "the adopted tab must be registered with the WebKit engine, same as any other tab"
            )
            XCTAssertEqual(
                env.activeTabID, adoptedTab.id,
                "an active adoption must adopt the tab as active"
            )
        }
    }

    // MARK: - E. Ids Orbit's wrapper reports (sessions, commands) are accepted by WebKit's
    // own tabs.get/action.setBadgeText, and the badge lands on the intended Orbit tab.

    private func writeTabIdentityExtension() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-TabIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Orbit Tab Identity",
          "version": "1.0",
          "permissions": ["tabs", "sessions"],
          "host_permissions": ["<all_urls>"],
          "action": { "default_title": "Orbit Tab Identity" },
          "commands": {
            "orbit-identity": {
              "suggested_key": { "default": "Ctrl+Shift+Y", "mac": "Command+Shift+Y" },
              "description": "Report the active tab"
            }
          },
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var orbitCommandTabIDs = [];
        chrome.commands.onCommand.addListener(function (command, tab) {
          orbitCommandTabIDs.push(tab && typeof tab.id === 'number' ? tab.id : null);
        });
        function orbitLastError() {
          return chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
        }
        function orbitCheck(tabId, label, done) {
          var found = null;
          chrome.tabs.get(tabId).then(function (tab) {
            found = tab;
            return chrome.action.setBadgeText({ tabId: tabId, text: label });
          }).then(function () {
            return chrome.action.getBadgeText({ tabId: tabId });
          }).then(function (text) {
            done({ tabId: tabId, url: (found && found.url) || null, badge: text, error: null });
          }, function (error) {
            done({ tabId: tabId, error: String((error && error.message) || error) });
          });
        }
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          function answer(payload) { sendResponse(JSON.stringify(payload)); }
          if (!message) { return; }
          if (message.command === 'restore') {
            chrome.sessions.restore(message.sessionId, function (restored) {
              var restoreError = orbitLastError();
              var id = restored && restored.tab ? restored.tab.id : null;
              if (typeof id !== 'number' || id < 0) {
                answer({ tabId: id, error: restoreError || 'sessions.restore reported no tab id' });
                return;
              }
              orbitCheck(id, message.label, answer);
            });
            return true;
          }
          if (message.command === 'check') { orbitCheck(message.tabId, message.label, answer); return true; }
          if (message.command === 'commandTabs') { answer({ ids: orbitCommandTabIDs }); return true; }
          if (message.command === 'idForURL') {
            chrome.tabs.query({}, function (tabs) {
              var hits = (tabs || []).filter(function (t) { return t.url === message.url; });
              answer({ ids: hits.map(function (t) { return t.id; }) });
            });
            return true;
          }
          if (message.command === 'reload') {
            chrome.tabs.reload(message.tabId, { bypassCache: true }, function () { answer({ error: orbitLastError() }); });
            return true;
          }
          if (message.command === 'windows') {
            chrome.windows.getAll({ populate: true }).then(function (windows) {
              answer({ windows: (windows || []).map(function (w) {
                return { id: w.id, tabIds: (w.tabs || []).map(function (t) { return t.id; }) };
              }) });
            }, function (error) { answer({ error: String(error), windows: [] }); });
            return true;
          }
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>Orbit tab identity probe</title></head>
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

    private func askWorker(_ probe: WebKitWebContents, _ messageJS: String) async throws -> [String: Any] {
        _ = try await probe.evaluateJavaScript("window.orbitSend(\(messageJS)); 'sent'")
        try await Self.pollUntil(timeout: .seconds(20)) {
            try await probe.evaluateJavaScript("window.__orbitReply !== null") as? Bool == true
        }
        let raw = try await probe.evaluateJavaScript("window.__orbitReply") as? String ?? ""
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("the worker's reply to \(messageJS) was not JSON: \(raw)")
            return [:]
        }
        return parsed
    }

    private func openLoadedTab(_ url: URL, in environment: AppEnvironment, space: SpaceID) async throws -> TabID {
        let tabID = environment.openTab(url: url, in: space)
        let contents = try XCTUnwrap(environment.webContents[tabID] as? WebKitWebContents)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        return tabID
    }

    /// The badge Orbit recorded for this Orbit tab, which only a call naming that tab can set.
    private func orbitBadge(_ engine: WebKitEngine, extensionID: String, tab: TabID) -> String? {
        guard let number = engine.numericID(for: tab) else { return nil }
        return engine.extensionActionStates.state(extensionID: extensionID, tabID: number).badgeText
    }

    private func assertAccepted(
        _ reply: [String: Any], label: String, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Int {
        XCTAssertNil(reply["error"] as? String, "\(what): WebKit refused the id. Reply: \(reply)", file: file, line: line)
        XCTAssertEqual(reply["badge"] as? String, label, "\(what): the badge did not stick to that id", file: file, line: line)
        return try XCTUnwrap(reply["tabId"] as? Int, "\(what): no id at all. Reply: \(reply)", file: file, line: line)
    }

    func testTabIDsOrbitsWrapperReportsAreWebKitsOwnAcrossOpenMoveCloseAndTwoWindows() throws {
        try WebKitLiveEngineHost.runLive(timeout: 240) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let env = self.env
            env._test_engineOverride = engine
            let previousRoot = AppEnvironment.processRoot
            AppEnvironment.processRoot = env
            defer { AppEnvironment.processRoot = previousRoot }
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixtureDirectory = try self.writeTabIdentityExtension()
            let loaded = try await engine.loadExtension(at: fixtureDirectory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            func page(_ name: String) -> LiveHTTPTestServer.Route {
                LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: "<!doctype html><html><head><title>identity \(name)</title></head><body>\(name)</body></html>"
                )
            }
            let server = try LiveHTTPTestServer(routes: ["/a": page("a"), "/b": page("b"), "/c": page("c"), "/d": page("d")])
            defer { server.stop() }
            func url(_ name: String) -> URL { server.baseURL.appendingPathComponent(name) }
            func requests(_ name: String) -> Int { server.requestLog.all.filter { $0.path == "/\(name)" }.count }

            let probe = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { probe.close() }
            probe.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(probe)
            try await Self.pollUntil(timeout: .seconds(20)) {
                try await probe.evaluateJavaScript("typeof window.orbitSend === 'function'") as? Bool == true
            }

            // Open: three tabs in this window.
            let tabA = try await self.openLoadedTab(url("a"), in: env, space: spaceID)
            defer { if env.state.tabs[tabA] != nil { env.closeTab(tabA) } }
            let tabB = try await self.openLoadedTab(url("b"), in: env, space: spaceID)
            let tabC = try await self.openLoadedTab(url("c"), in: env, space: spaceID)
            defer { env.closeTab(tabC) }

            // A second Orbit window owning tab D, and a second extension window.
            let otherSpaceID = env.store.createSpace(
                name: "Identity Other Window", icon: "square.on.square", iconIsEmoji: false,
                theme: WindowSession.incognitoTheme, profileID: env.state.profiles[0].id, activate: false
            )
            let otherEnv = AppEnvironment.makeWindowScoped(sharing: env, activeSpaceID: otherSpaceID, isTornOff: true)
            let tabD = try await self.openLoadedTab(url("d"), in: env, space: spaceID)
            env.store.moveTab(tabD, toSpace: otherSpaceID, section: .today)
            otherEnv.adoptWebContents(for: tabD, from: env)
            defer { otherEnv.closeTab(tabD) }
            XCTAssertNotNil(otherEnv.webContents[tabD], "tab D must belong to the second Orbit window")
            let extraWindow = engine.openAdditionalExtensionWindow()
            defer { engine.closeExtensionWindow(extraWindow) }

            // Move, then close: every index after them shifts.
            env.moveTodayTab(tabC, toIndex: 0, in: spaceID)
            env.closeTab(tabB)

            // 1. sessions.restore (Orbit) reports an id; tabs.get and action.setBadgeText (WebKit) accept it.
            let restored = try await self.askWorker(
                probe, "{command: 'restore', sessionId: '\(tabB.uuidString)', label: 'R'}"
            )
            let restoredID = try self.assertAccepted(restored, label: "R", "sessions.restore")
            defer { if env.state.tabs[tabB] != nil { env.closeTab(tabB) } }
            try await Self.pollUntil(timeout: .seconds(10)) {
                self.orbitBadge(engine, extensionID: loaded.id, tab: tabB) == "R"
            }
            let restoredContents = try XCTUnwrap(env.webContents[tabB] as? WebKitWebContents)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(restoredContents)
            let restoredLookup = try await self.askWorker(probe, "{command: 'check', tabId: \(restoredID), label: 'R2'}")
            _ = try self.assertAccepted(restoredLookup, label: "R2", "the restored tab after it loaded")
            XCTAssertEqual(restoredLookup["url"] as? String, url("b").absoluteString, "the restored id must name tab B")

            // 2. commands.onCommand (Orbit) for the tab in the second Orbit window.
            otherEnv.activateTab(tabD)
            XCTAssertNil(
                GlobalKeyEventMonitor.handle(ExtensionCommandKeyEvents.commandShiftY(), in: otherEnv),
                "⇧⌘Y is the fixture's own command, so the monitor had to consume it"
            )
            var commandIDs: [Any] = []
            try await Self.pollUntil(timeout: .seconds(10)) {
                commandIDs = try await self.askWorker(probe, "{command: 'commandTabs'}")["ids"] as? [Any] ?? []
                return !commandIDs.isEmpty
            }
            let commandTabID = try XCTUnwrap(commandIDs.last as? Int, "onCommand carried no tab id: \(commandIDs)")
            let commandCheck = try await self.askWorker(probe, "{command: 'check', tabId: \(commandTabID), label: 'D'}")
            _ = try self.assertAccepted(commandCheck, label: "D", "commands.onCommand")
            XCTAssertEqual(commandCheck["url"] as? String, url("d").absoluteString, "onCommand's id must name tab D")
            try await Self.pollUntil(timeout: .seconds(10)) {
                self.orbitBadge(engine, extensionID: loaded.id, tab: tabD) == "D"
            }

            // 3. Close another tab, then hand Orbit a WebKit id it has never translated: tabs.reload
            // with bypassCache is Orbit's, so the id has to come back to exactly tab C.
            env.closeTab(tabA)
            let idsForC = try await self.askWorker(probe, "{command: 'idForURL', url: '\(url("c").absoluteString)'}")["ids"] as? [Int] ?? []
            let idForC = try XCTUnwrap(idsForC.first, "WebKit lists no tab for C")
            XCTAssertEqual(idsForC.count, 1, "tab C must be listed once, not once per window")
            let before = (b: requests("b"), c: requests("c"), d: requests("d"))
            let reload = try await self.askWorker(probe, "{command: 'reload', tabId: \(idForC)}")
            XCTAssertNil(reload["error"] as? String, "tabs.reload rejected WebKit's own id for C: \(reload)")
            try await Self.pollUntil(timeout: .seconds(10)) { requests("c") > before.c }
            XCTAssertEqual(requests("b"), before.b, "reloading C must not reload B")
            XCTAssertEqual(requests("d"), before.d, "reloading C must not reload D")

            // The ids already handed out still hold after that close.
            let afterClose = try await self.askWorker(probe, "{command: 'check', tabId: \(restoredID), label: 'S'}")
            _ = try self.assertAccepted(afterClose, label: "S", "the restored id after another tab closed")
            try await Self.pollUntil(timeout: .seconds(10)) {
                self.orbitBadge(engine, extensionID: loaded.id, tab: tabB) == "S"
            }

            // 4. Two extension windows: each tab is listed exactly once, all in the window that holds tabs.
            let windows = try await self.askWorker(probe, "{command: 'windows'}")["windows"] as? [[String: Any]] ?? []
            XCTAssertGreaterThanOrEqual(windows.count, 2, "the additional extension window must be reported")
            let listed = windows.flatMap { $0["tabIds"] as? [Int] ?? [] }
            XCTAssertEqual(listed.count, Set(listed).count, "a tab listed in two windows has no single windowId. Windows: \(windows)")
            for id in [restoredID, commandTabID, idForC] {
                XCTAssertTrue(listed.contains(id), "tab \(id) is missing from chrome.windows.getAll. Windows: \(windows)")
            }
        }
    }
}
