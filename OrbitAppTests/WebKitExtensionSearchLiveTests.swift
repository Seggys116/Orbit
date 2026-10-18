//  chrome.search against the Profile's real search engine and the real surface each disposition names; asserted on the URL Orbit resolved, never on a provider's response.
//
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_newTabDisposition_opensARealForegroundTabOnTheResolvedURL
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theURLComesFromTheProfilesOwnConfiguredSearchEngine
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_currentTabDisposition_navigatesTheActiveTabAndOpensNothing
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anOmittedDisposition_behavesAsCurrentTab
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_explicitTabId_navigatesThatTabAndLeavesTheActiveOneAlone
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_unknownTabId_isAnErrorRatherThanASilentFallback
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_newWindowDisposition_opensARealOrbitWindowOnTheResolvedURL

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitExtensionSearchLiveTests: LiveEnvironmentTestCase {

    private static let queryText = "orbit live search probe"

    private var previousProcessRoot: AppEnvironment?

    override func tearDown() {
        if let previousProcessRoot {
            AppEnvironment.processRoot = previousProcessRoot
        }
        previousProcessRoot = nil
        super.tearDown()
    }

    // MARK: - Harness

    /// AppEnvironment.frontmost finds no key OrbitWindowController in the test
    /// host, so this environment has to be the process root to be found at all.
    private func prepare(_ engine: WebKitEngine) {
        env._test_engineOverride = engine
        if previousProcessRoot == nil {
            previousProcessRoot = AppEnvironment.processRoot
        }
        AppEnvironment.processRoot = env
    }

    private func performSearch(disposition: String?, tabID: Int? = nil) throws {
        var query: [String: Any] = ["text": Self.queryText]
        if let disposition { query["disposition"] = disposition }
        if let tabID { query["tabId"] = tabID }
        try ChromeExtensionAPI.performSearchQuery(query)
    }

    /// A query that must be accepted: a refusal here is the failure, not a later assertion about what opened.
    private func performAcceptedSearch(_ message: String, disposition: String?, tabID: Int? = nil) throws {
        do {
            try performSearch(disposition: disposition, tabID: tabID)
        } catch {
            XCTFail("\(message): \((error as? ChromeExtensionAPIError)?.message ?? String(describing: error))")
            throw error
        }
    }

    private func tabOpened(since keys: Set<TabID>) throws -> TabID {
        let created = Set(env.state.tabs.keys).subtracting(keys)
        XCTAssertEqual(created.count, 1, "the query must open exactly one Orbit tab")
        return try XCTUnwrap(created.first)
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

    // MARK: - NEW_TAB

    func test_newTabDisposition_opensARealForegroundTabOnTheResolvedURL() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) { try await self.runNewTabChecks() }
    }

    private func runNewTabChecks() async throws {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        prepare(engine)

        let profileIndex = try activeProfileIndex()
        env.state.profiles[profileIndex].searchEngine = .duckDuckGo
        let expected = try XCTUnwrap(SearchEngine.duckDuckGo.searchURL(for: Self.queryText))

        let keysBefore = Set(env.state.tabs.keys)
        let tabsBefore = env.state.tabs.count
        try performAcceptedSearch("a NEW_TAB query in a window with an active Space must succeed", disposition: "NEW_TAB")

        let tabID = try tabOpened(since: keysBefore)
        defer { env.closeTab(tabID) }

        XCTAssertEqual(
            env.state.tabs.count, tabsBefore + 1,
            "NEW_TAB must open exactly one real Orbit tab"
        )
        XCTAssertEqual(
            env.tab(tabID)?.url, expected,
            "the new tab must carry the search URL Orbit built from the Profile's own engine"
        )
        XCTAssertEqual(
            env.activeTabID, tabID,
            "NEW_TAB is a foreground tab upstream (NEW_FOREGROUND_TAB); a background one is a different API"
        )
        XCTAssertNotNil(
            engine.numericID(for: tabID),
            "the tab must be a genuine registered Orbit tab, addressable by chrome.tabs afterwards"
        )
        XCTAssertTrue(
            env.webContents[tabID] is WebKitWebContents,
            "a store entry with no live WebContents is not a tab the search results can ever appear in"
        )
    }

    // MARK: - The search engine itself

    func test_theURLComesFromTheProfilesOwnConfiguredSearchEngine() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) { try await self.runSearchEngineChecks() }
    }

    private func runSearchEngineChecks() async throws {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        prepare(engine)

        let profileIndex = try activeProfileIndex()
        var resolvedURLs: [SearchEngine: URL] = [:]

        for choice in [SearchEngine.bing, .ecosia] {
            env.state.profiles[profileIndex].searchEngine = choice
            let expected = try XCTUnwrap(choice.searchURL(for: Self.queryText))

            let keysBefore = Set(env.state.tabs.keys)
            try performAcceptedSearch("a NEW_TAB query against \(choice.displayName) must succeed", disposition: "NEW_TAB")
            let tabID = try tabOpened(since: keysBefore)
            defer { env.closeTab(tabID) }
            let resolvedURL = env.tab(tabID)?.url
            XCTAssertEqual(
                resolvedURL, expected,
                """
                chrome.search must query the engine the Profile is actually configured with \
                (\(choice.displayName)), not a hardcoded provider.
                """
            )
            resolvedURLs[choice] = resolvedURL
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
        try WebKitLiveEngineHost.runLive(timeout: 120) { try await self.runCurrentTabChecks() }
    }

    private func runCurrentTabChecks() async throws {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        prepare(engine)

        let server = try makeServer()
        defer { server.stop() }

        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let tabID = env.openTab(url: server.baseURL, in: spaceID)
        defer { env.closeTab(tabID) }
        let page = try XCTUnwrap(env.webContents[tabID] as? WebKitWebContents)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(page)
        XCTAssertEqual(env.activeTabID, tabID)

        let expected = try XCTUnwrap(env.searchEngine.searchURL(for: Self.queryText))
        let tabsBefore = env.state.tabs.count
        let generationBefore = env.navigationGeneration[tabID, default: 0]

        try performAcceptedSearch("a CURRENT_TAB query with an active tab must succeed", disposition: "CURRENT_TAB")

        XCTAssertEqual(
            env.tab(tabID)?.url, expected,
            "CURRENT_TAB must target the frontmost window's active tab"
        )
        XCTAssertEqual(env.activeTabID, tabID, "CURRENT_TAB must leave the same tab active")
        XCTAssertEqual(
            env.state.tabs.count, tabsBefore,
            "CURRENT_TAB must reuse the active tab; opening one instead is NEW_TAB's behaviour"
        )
        XCTAssertEqual(
            env.navigationGeneration[tabID, default: 0], generationBefore + 1,
            "the active tab must actually have been told to navigate, not merely picked"
        )
    }

    // MARK: - No disposition

    func test_anOmittedDisposition_behavesAsCurrentTab() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) { try await self.runOmittedDispositionChecks() }
    }

    private func runOmittedDispositionChecks() async throws {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        prepare(engine)

        let server = try makeServer()
        defer { server.stop() }

        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let tabID = env.openTab(url: server.baseURL, in: spaceID)
        defer { env.closeTab(tabID) }
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(try XCTUnwrap(env.webContents[tabID] as? WebKitWebContents))

        let expected = try XCTUnwrap(env.searchEngine.searchURL(for: Self.queryText))
        let tabsBefore = env.state.tabs.count
        try performAcceptedSearch("a query with no disposition must succeed", disposition: nil)

        XCTAssertEqual(
            env.tab(tabID)?.url, expected,
            "upstream's default disposition is CURRENT_TAB; a query without one must navigate the active tab"
        )
        XCTAssertEqual(env.state.tabs.count, tabsBefore, "a query without a disposition must not open a tab")
    }

    // MARK: - An explicit tabId

    func test_explicitTabId_navigatesThatTabAndLeavesTheActiveOneAlone() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) { try await self.runExplicitTabChecks() }
    }

    private func runExplicitTabChecks() async throws {
        let engine = await WebKitLiveEngineHost.sharedEngine()
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
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(
                try XCTUnwrap(env.webContents[tab] as? WebKitWebContents)
            )
        }
        XCTAssertEqual(env.activeTabID, activeTabID, "the tab opened with activate: false must not have taken focus")

        let registryTabID = try XCTUnwrap(
            engine.numericID(for: namedTabID),
            "the tab an extension names has to be one the WebKit engine knows"
        )
        let expected = try XCTUnwrap(env.searchEngine.searchURL(for: Self.queryText))
        let tabsBefore = env.state.tabs.count
        let namedGenerationBefore = env.navigationGeneration[namedTabID, default: 0]
        let activeGenerationBefore = env.navigationGeneration[activeTabID, default: 0]

        try performAcceptedSearch(
            "a query naming a tab the engine knows must succeed", disposition: "CURRENT_TAB", tabID: Int(registryTabID)
        )

        XCTAssertEqual(
            env.tab(namedTabID)?.url, expected,
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
        try WebKitLiveEngineHost.runLive(timeout: 120) { try await self.runUnknownTabChecks() }
    }

    private func runUnknownTabChecks() async throws {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        prepare(engine)

        // Never assigned by the engine: it cannot collide with a live tab, and is exactly what a stale extension would pass.
        let unknownTabID = Int(Int32.max)
        let tabsBefore = env.state.tabs.count
        let keysBefore = Set(env.state.tabs.keys)
        let generationsBefore = env.navigationGeneration
        let windowsBefore = OrbitWindowController.openEnvironments.count

        XCTAssertThrowsError(try performSearch(disposition: "CURRENT_TAB", tabID: unknownTabID)) { error in
            XCTAssertEqual(
                (error as? ChromeExtensionAPIError)?.message, "No tab with id: \(unknownTabID).",
                "an unknown tabId must come back as chrome.search's own error message"
            )
        }
        XCTAssertEqual(
            env.state.tabs.count, tabsBefore,
            "an unknown tabId must not quietly fall back to opening a tab somewhere else"
        )
        XCTAssertEqual(Set(env.state.tabs.keys), keysBefore, "a refused query must not have opened or closed anything")
        XCTAssertEqual(
            env.navigationGeneration, generationsBefore,
            "a refused query must reach no surface at all: no tab may have been told to navigate"
        )
        XCTAssertEqual(
            OrbitWindowController.openEnvironments.count, windowsBefore,
            "a refused query must not open a window"
        )
    }

    // MARK: - NEW_WINDOW

    func test_newWindowDisposition_opensARealOrbitWindowOnTheResolvedURL() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) { try await self.runNewWindowChecks() }
    }

    private func runNewWindowChecks() async throws {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        prepare(engine)

        // Opening a real window starts the engine that window owns. Hand the command registry back
        // so later suites keep dispatching through the engine this process already started.
        let previousDispatch = ExtensionCommandRegistry.shared.dispatch
        defer { ExtensionCommandRegistry.shared.dispatch = previousDispatch }

        let expected = try XCTUnwrap(env.searchEngine.searchURL(for: Self.queryText))
        let windowsBefore = OrbitWindowController.openEnvironments.count
        let keysBefore = Set(env.state.tabs.keys)

        try performAcceptedSearch("a NEW_WINDOW query must succeed", disposition: "NEW_WINDOW")

        let tabID = try tabOpened(since: keysBefore)
        let controller = try XCTUnwrap(
            OrbitWindowController.controller(for: env),
            "NEW_WINDOW must open a real Orbit window, not just another tab in the current one"
        )
        defer {
            env.closeTab(tabID)
            controller.close()
        }

        XCTAssertEqual(env.tab(tabID)?.url, expected, "the new window must be showing the search URL")
        XCTAssertTrue(
            controller.session.environment === env,
            "a standard window session shares the host's document, so the tab belongs to the same environment"
        )
        XCTAssertEqual(
            OrbitWindowController.openEnvironments.count, windowsBefore + 1,
            "exactly one window must have opened"
        )
        XCTAssertTrue(
            controller.window?.isVisible == true,
            "the window must actually be on screen; a window nobody can see is not where search results go"
        )
        XCTAssertEqual(
            env.activeTabID, tabID,
            "the search result must be the new window's active tab"
        )
    }
}
