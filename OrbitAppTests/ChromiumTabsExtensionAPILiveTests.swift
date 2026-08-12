//  chrome.tabs/windows coverage: tab mutations, popup exclusion, permission
//  scrubbing, and window.open() adoption, read through a real background worker, never a mock.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumTabsExtensionAPILiveTests: LiveEnvironmentTestCase {

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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
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
            let observerContents = try XCTUnwrap(env.webContents[observerTabID] as? ChromiumWebContents)
            // openTab defers navigation until content blocking compiles, so
            // there's no main frame to evaluate script in until this settles.
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)

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
                // Not a count: closing the active tab activates another tab,
                // which legitimately materialises a different tab's WebContents here.
                return self.snapshot(withURLSuffix: "/subject", in: found) == nil
                    && self.snapshot(withURLSuffix: "/observer", in: found) != nil
            }
        }
    }

    // MARK: - B. Permission scrubbing

    func testAnExtensionWithoutTheTabsPermissionGetsScrubbedResults() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
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
            let observerContents = try XCTUnwrap(env.webContents[observerTabID] as? ChromiumWebContents)
            // openTab defers navigation until content blocking compiles, so
            // there's no main frame to evaluate script in until this settles.
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(observerContents)

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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let sourceEnv = self.env
            sourceEnv._test_engineOverride = engine
            let spaceID = try XCTUnwrap(sourceEnv.activeSpace?.id)

            let server = try self.makeServer()
            defer { server.stop() }

            let tabID = sourceEnv.openTab(url: server.baseURL.appendingPathComponent("subject"), in: spaceID)
            let bridge = OrbitChromiumTabsBridge.shared
            let originalID = try XCTUnwrap(bridge.existingTabID(for: tabID), "opening a tab must register it")
            let originalOwner = try XCTUnwrap(bridge.tabWindowOwner(for: originalID) as? AppEnvironment)
            XCTAssertTrue(originalOwner === sourceEnv)

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
                bridge.existingTabID(for: tabID), "a tab torn off into a new window must still be registered"
            )
            XCTAssertNotEqual(
                newID, originalID,
                "OrbitTabRegistry has no cross-window move primitive (see AppEnvironment+TearOff.swift's own comment) -- a fresh id is the honest representation"
            )
            let newOwner = try XCTUnwrap(bridge.tabWindowOwner(for: newID) as? AppEnvironment)
            XCTAssertTrue(newOwner === destinationEnv, "the tab must now be owned by the destination window, not the source")
            XCTAssertNil(bridge.tabUUID(for: originalID), "the old (window, tab) pairing must be forgotten, not left dangling")
        }
    }

    // MARK: - D. An adopted WebContents (window.open()/openOptionsPage() from
    // an extension page) becomes a real Orbit tab.
    // Exercises chromiumAdoptExtensionTab directly with a real engine handle
    // rather than JS: MV3 workers never construct an ExtensionHost, so a
    // JS-driven trigger risks testing nothing.

    func testChromiumAdoptExtensionTabWrapsARealHandleAsAGenuineOrbitTab() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let previousProcessRoot = AppEnvironment.processRoot
            AppEnvironment.processRoot = env
            defer { AppEnvironment.processRoot = previousProcessRoot }

            let server = try self.makeServer()
            defer { server.stop() }
            let targetURL = server.baseURL.appendingPathComponent("subject")

            // Mirrors what content:: hands Swift on CreateTab: a WebContents
            // already mid-navigation. `rawContents` is never touched again; the adopting side owns it.
            let rawContents = try engine.makeWebContents(session: engine.defaultSession, initialURL: targetURL)
            let handle = try XCTUnwrap((rawContents as? ChromiumWebContents)?.chromiumHandle)

            let tabCountBefore = env.state.tabs.count
            let adopted = ChromiumTabsRouter.shared.chromiumAdoptExtensionTab(
                handle: handle, url: targetURL.absoluteString, extensionID: "orbit-live-test-extension-id",
                disposition: 3, userGesture: true
            )

            XCTAssertTrue(adopted, "chromiumAdoptExtensionTab must accept a real handle when an active Space exists to host it")
            XCTAssertEqual(
                env.state.tabs.count, tabCountBefore + 1,
                "adopting must create exactly one new Orbit tab"
            )
            let adoptedTab = try XCTUnwrap(env.state.tabs.values.first { $0.url.absoluteString == targetURL.absoluteString })
            defer { env.closeTab(adoptedTab.id) }
            XCTAssertTrue(
                env.webContents[adoptedTab.id] is ChromiumWebContents,
                "the adopted tab must carry a real, live WebContents -- not just a store entry"
            )
            XCTAssertNotNil(
                OrbitChromiumTabsBridge.shared.existingTabID(for: adoptedTab.id),
                "the adopted tab must be registered with OrbitTabRegistry, same as any other tab"
            )
            XCTAssertEqual(
                env.activeTabID, adoptedTab.id,
                "disposition 3 (newForegroundTab) must adopt the tab as active"
            )
        }
    }
}
