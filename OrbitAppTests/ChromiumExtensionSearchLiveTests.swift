//  chrome.search against the Profile's real search engine and the real surface each disposition names; asserted on the URL Orbit resolved, never on a provider's response.
//
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_newTabDisposition_opensARealForegroundTabOnTheResolvedURL
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theURLComesFromTheProfilesOwnConfiguredSearchEngine
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_currentTabDisposition_navigatesTheActiveTabAndOpensNothing
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_explicitTabId_navigatesThatTabAndLeavesTheActiveOneAlone
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_unknownTabId_isAnErrorRatherThanASilentFallback
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_newWindowDisposition_opensARealOrbitWindowOnTheResolvedURL

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionSearchLiveTests: LiveEnvironmentTestCase {

    private static let queryText = "orbit live search probe"

    private var previousProcessRoot: AppEnvironment?

    override func tearDown() {
        if let previousProcessRoot {
            AppEnvironment.processRoot = previousProcessRoot
        }
        previousProcessRoot = nil
        OrbitChromiumSearchBridge.shared._test_forgetLastResolution()
        super.tearDown()
    }

    // MARK: - Harness

    /// AppEnvironment.frontmost finds no key OrbitWindowController in the test
    /// host, so this environment has to be the process root to be found at all.
    private func prepare(_ engine: ChromiumEngine) {
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
        OrbitChromiumSearchBridge.shared._test_forgetLastResolution()
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html; charset=utf-8",
                body: "<!doctype html><html><head><meta charset=\"utf-8\"><title>orbit search</title></head><body>orbit-search</body></html>"
            ),
            "/second": LiveHTTPTestServer.Route(
                contentType: "text/html; charset=utf-8",
                body: "<!doctype html><html><head><meta charset=\"utf-8\"><title>orbit search two</title></head><body>orbit-search-two</body></html>"
            ),
        ])
    }

    /// The index `searchEngine(forSpace:)` reads for the active Space; writing
    /// anywhere else leaves the read answering with a different engine.
    private func activeProfileIndex() throws -> Int {
        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let profileID = try XCTUnwrap(env.space(spaceID)?.profileID)
        return try XCTUnwrap(env.state.profiles.firstIndex { $0.id == profileID })
    }

    private func resolution() throws -> OrbitChromiumSearchBridge.Resolution {
        try XCTUnwrap(
            OrbitChromiumSearchBridge.shared._test_lastResolution,
            "the query reported success but resolved to no surface at all"
        )
    }

    // MARK: - NEW_TAB

    func test_newTabDisposition_opensARealForegroundTabOnTheResolvedURL() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) { try await self.runNewTabChecks() }
    }

    private func runNewTabChecks() async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        prepare(engine)

        let profileIndex = try activeProfileIndex()
        env.state.profiles[profileIndex].searchEngine = .duckDuckGo
        let expected = try XCTUnwrap(SearchEngine.duckDuckGo.searchURL(for: Self.queryText))

        let tabsBefore = env.state.tabs.count
        let error = OrbitChromiumSearchBridge.shared.perform(text: Self.queryText, target: .newTab)
        XCTAssertEqual(error, "", "a NEW_TAB query in a window with an active Space must succeed")

        let resolved = try resolution()
        defer { env.closeTab(resolved.tabID) }

        XCTAssertEqual(resolved.target, .newTab)
        XCTAssertEqual(
            env.state.tabs.count, tabsBefore + 1,
            "NEW_TAB must open exactly one real Orbit tab"
        )
        XCTAssertEqual(
            env.tab(resolved.tabID)?.url, expected,
            "the new tab must carry the search URL Orbit built from the Profile's own engine"
        )
        XCTAssertEqual(
            env.activeTabID, resolved.tabID,
            "NEW_TAB is a foreground tab upstream (NEW_FOREGROUND_TAB); a background one is a different API"
        )
        XCTAssertNotNil(
            OrbitChromiumTabsBridge.shared.existingTabID(for: resolved.tabID),
            "the tab must be a genuine registered Orbit tab, addressable by chrome.tabs afterwards"
        )
        XCTAssertTrue(
            env.webContents[resolved.tabID] is ChromiumWebContents,
            "a store entry with no live WebContents is not a tab the search results can ever appear in"
        )
    }

    // MARK: - The search engine itself

    func test_theURLComesFromTheProfilesOwnConfiguredSearchEngine() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) { try await self.runSearchEngineChecks() }
    }

    private func runSearchEngineChecks() async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        prepare(engine)

        let profileIndex = try activeProfileIndex()
        var resolvedURLs: [SearchEngine: URL] = [:]

        for choice in [SearchEngine.bing, .ecosia] {
            env.state.profiles[profileIndex].searchEngine = choice
            let expected = try XCTUnwrap(choice.searchURL(for: Self.queryText))

            OrbitChromiumSearchBridge.shared._test_forgetLastResolution()
            let error = OrbitChromiumSearchBridge.shared.perform(text: Self.queryText, target: .newTab)
            XCTAssertEqual(error, "")

            let resolved = try resolution()
            defer { env.closeTab(resolved.tabID) }
            XCTAssertEqual(
                resolved.url, expected,
                """
                chrome.search must query the engine the Profile is actually configured with \
                (\(choice.displayName)), not a hardcoded provider.
                """
            )
            resolvedURLs[choice] = resolved.url
        }

        XCTAssertNotEqual(
            resolvedURLs[.bing], resolvedURLs[.ecosia],
            "changing the Profile's search engine must change the URL; identical URLs mean the setting was never read"
        )
        XCTAssertTrue(
            resolvedURLs[.ecosia]?.absoluteString.contains("ecosia.org") == true,
            "the resolved URL must belong to the configured provider. Got: \(String(describing: resolvedURLs[.ecosia]))"
        )
    }

    // MARK: - CURRENT_TAB

    func test_currentTabDisposition_navigatesTheActiveTabAndOpensNothing() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) { try await self.runCurrentTabChecks() }
    }

    private func runCurrentTabChecks() async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        prepare(engine)

        let server = try makeServer()
        defer { server.stop() }

        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let tabID = env.openTab(url: server.baseURL, in: spaceID)
        defer { env.closeTab(tabID) }
        let page = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(page)
        XCTAssertEqual(env.activeTabID, tabID)

        let expected = try XCTUnwrap(env.searchEngine.searchURL(for: Self.queryText))
        let tabsBefore = env.state.tabs.count
        let generationBefore = env.navigationGeneration[tabID, default: 0]

        let error = OrbitChromiumSearchBridge.shared.perform(text: Self.queryText, target: .currentTab)
        XCTAssertEqual(error, "")

        let resolved = try resolution()
        XCTAssertEqual(resolved.target, .currentTab)
        XCTAssertEqual(resolved.url, expected)
        XCTAssertEqual(
            resolved.tabID, tabID,
            "CURRENT_TAB must target the frontmost window's active tab"
        )
        XCTAssertEqual(
            env.state.tabs.count, tabsBefore,
            "CURRENT_TAB must reuse the active tab; opening one instead is NEW_TAB's behaviour"
        )
        XCTAssertEqual(
            env.navigationGeneration[tabID, default: 0], generationBefore + 1,
            "the active tab must actually have been told to navigate, not merely picked"
        )
    }

    // MARK: - An explicit tabId

    func test_explicitTabId_navigatesThatTabAndLeavesTheActiveOneAlone() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) { try await self.runExplicitTabChecks() }
    }

    private func runExplicitTabChecks() async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        prepare(engine)

        let server = try makeServer()
        defer { server.stop() }

        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let activeTabID = env.openTab(url: server.baseURL, in: spaceID)
        defer { env.closeTab(activeTabID) }
        let namedTabID = env.openTab(
            url: server.baseURL.appendingPathComponent("second"), in: spaceID, activate: false
        )
        defer { env.closeTab(namedTabID) }
        for tab in [activeTabID, namedTabID] {
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(
                try XCTUnwrap(env.webContents[tab] as? ChromiumWebContents)
            )
        }
        XCTAssertEqual(env.activeTabID, activeTabID, "the tab opened with activate: false must not have taken focus")

        let registryTabID = try XCTUnwrap(
            OrbitChromiumTabsBridge.shared.existingTabID(for: namedTabID),
            "the tab an extension names has to be one OrbitTabRegistry knows"
        )
        let expected = try XCTUnwrap(env.searchEngine.searchURL(for: Self.queryText))
        let tabsBefore = env.state.tabs.count
        let namedGenerationBefore = env.navigationGeneration[namedTabID, default: 0]
        let activeGenerationBefore = env.navigationGeneration[activeTabID, default: 0]

        let error = OrbitChromiumSearchBridge.shared.perform(
            text: Self.queryText, target: .tab(registryTabID)
        )
        XCTAssertEqual(error, "")

        let resolved = try resolution()
        XCTAssertEqual(resolved.target, .tab(registryTabID))
        XCTAssertEqual(resolved.url, expected)
        XCTAssertEqual(
            resolved.tabID, namedTabID,
            "an explicit tabId must resolve to that tab, not to whichever one happens to be active"
        )
        XCTAssertEqual(env.state.tabs.count, tabsBefore, "a tabId query must not open a tab")
        XCTAssertEqual(
            env.navigationGeneration[namedTabID, default: 0], namedGenerationBefore + 1,
            "the named tab must have been told to navigate"
        )
        XCTAssertEqual(
            env.navigationGeneration[activeTabID, default: 0], activeGenerationBefore,
            "the active tab must be left exactly as it was; navigating it too is a cross-tab write"
        )
        XCTAssertEqual(env.activeTabID, activeTabID, "a tabId query must not change which tab is active")
    }

    // MARK: - Refusals

    func test_unknownTabId_isAnErrorRatherThanASilentFallback() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) { try await self.runUnknownTabChecks() }
    }

    private func runUnknownTabChecks() async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        prepare(engine)

        // Allocated but never registered: it cannot collide with a live tab, and is exactly what a stale extension would pass.
        let unknownTabID = OrbitChromiumTabsBridge.shared._test_tabID(for: UUID())
        let tabsBefore = env.state.tabs.count

        let error = OrbitChromiumSearchBridge.shared.perform(
            text: Self.queryText, target: .tab(unknownTabID)
        )

        XCTAssertEqual(
            error, "No tab with id: \(unknownTabID).",
            "an unknown tabId must come back as chrome.search's own error message"
        )
        XCTAssertEqual(
            env.state.tabs.count, tabsBefore,
            "an unknown tabId must not quietly fall back to opening a tab somewhere else"
        )
        XCTAssertNil(
            OrbitChromiumSearchBridge.shared._test_lastResolution,
            "a refused query must reach no surface at all"
        )
    }

    // MARK: - NEW_WINDOW

    func test_newWindowDisposition_opensARealOrbitWindowOnTheResolvedURL() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) { try await self.runNewWindowChecks() }
    }

    private func runNewWindowChecks() async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        prepare(engine)

        // Opening a real window makes AppEnvironment start the engine it thinks it owns, and that engine claims the bridge's relay slots; this process's engine came from LiveChromiumEngineHost instead, so they have to be handed back or later suites read badges and commands out of an engine nothing drives.
        let previousActionHandler = OrbitChromiumBridge.shared.extensionActionHandler
        let previousCommandsHandler = OrbitChromiumBridge.shared.extensionCommandsHandler
        let previousReadyHandler = OrbitChromiumBridge.shared.browserReadyHandler
        let previousSuggestHandler = OrbitChromiumBridge.shared.searchSuggestEnabledHandler
        let previousDispatch = ExtensionCommandRegistry.shared.dispatch
        let previousPublishReserved = ExtensionCommandRegistry.shared.publishReserved
        defer {
            OrbitChromiumBridge.shared.extensionActionHandler = previousActionHandler
            OrbitChromiumBridge.shared.extensionCommandsHandler = previousCommandsHandler
            OrbitChromiumBridge.shared.browserReadyHandler = previousReadyHandler
            OrbitChromiumBridge.shared.searchSuggestEnabledHandler = previousSuggestHandler
            ExtensionCommandRegistry.shared.dispatch = previousDispatch
            ExtensionCommandRegistry.shared.publishReserved = previousPublishReserved
        }

        let expected = try XCTUnwrap(env.searchEngine.searchURL(for: Self.queryText))
        let windowsBefore = OrbitWindowController.openEnvironments.count

        let error = OrbitChromiumSearchBridge.shared.perform(text: Self.queryText, target: .newWindow)
        XCTAssertEqual(error, "")

        let resolved = try resolution()
        let controller = try XCTUnwrap(
            OrbitWindowController.controller(for: resolved.environment),
            "NEW_WINDOW must open a real Orbit window, not just another tab in the current one"
        )
        defer {
            resolved.environment.closeTab(resolved.tabID)
            controller.close()
        }

        XCTAssertEqual(resolved.target, .newWindow)
        XCTAssertEqual(resolved.url, expected)
        XCTAssertEqual(
            OrbitWindowController.openEnvironments.count, windowsBefore + 1,
            "exactly one window must have opened"
        )
        XCTAssertTrue(
            controller.window?.isVisible == true,
            "the window must actually be on screen; a window nobody can see is not where search results go"
        )
        XCTAssertEqual(
            resolved.environment.tab(resolved.tabID)?.url, expected,
            "the new window must be showing the search URL"
        )
        XCTAssertEqual(
            resolved.environment.activeTabID, resolved.tabID,
            "the search result must be the new window's active tab"
        )
        XCTAssertTrue(
            resolved.environment === env,
            "a standard window session shares the host's document, so the tab belongs to the same environment"
        )
    }
}
