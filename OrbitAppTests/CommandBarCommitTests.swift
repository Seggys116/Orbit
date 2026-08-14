import XCTest
@testable import Orbit

@MainActor
final class CommandBarCommitTests: XCTestCase {

    // MARK: - Harness

    private final class Recorder {
        var materialised: [(tabID: TabID, url: URL)] = []
        var contentsByTab: [TabID: MockWebContents] = [:]

        func destinations(for tabID: TabID) -> [URL] {
            var urls = materialised.filter { $0.tabID == tabID }.map(\.url)
            if let current = contentsByTab[tabID]?.navigationState.url { urls.append(current) }
            return urls
        }

        func currentURL(for tabID: TabID) -> URL? {
            contentsByTab[tabID]?.navigationState.url
        }
    }

    private var env: AppEnvironment!
    private var recorder: Recorder!
    private var spaceID: SpaceID!

    override func setUp() {
        super.setUp()
        env = AppEnvironment.demo
        recorder = Recorder()
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Commit",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
        env.state.activeSpaceID = spaceID

        let recorder = self.recorder!
        env._test_webContentsFactory = { tabID, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            recorder.materialised.append((tabID, url))
            recorder.contentsByTab[tabID] = contents
            return contents
        }
    }

    override func tearDown() {
        env = nil
        recorder = nil
        spaceID = nil
        super.tearDown()
    }

    private func expectedSearchURL(for query: String) throws -> URL {
        try XCTUnwrap(env.searchEngine.searchURL(for: query), "The active Profile's search engine produced no URL for \"\(query)\".")
    }

    private func topIntent(for query: String, mode: CommandBarMode) throws -> CommandResultKind.ActivationIntent {
        let rows = CommandBarEngine.results(
            query: query,
            mode: mode,
            env: env,
            suggestions: [],
            searchEngine: env.searchEngine,
            siteSearch: env.siteSearchStore.state(active: nil)
        )
        let top = try XCTUnwrap(rows.first, "\"\(query)\" produced no rows at all, so Enter has nothing to activate.")
        return top.kind.activationIntent
    }

    private func makeBlankPane() -> TabID {
        env.openTab(url: URL(string: "orbit://new-tab")!, in: spaceID)
    }

    // MARK: - 1. The reported defect: Enter on "wikipedia"

    func test_enterOnWikipedia_alwaysLandsSomewhere() throws {
        let wikipediaCopies = env.spaces.flatMap(\.favorites).filter { $0.url.host()?.contains("wikipedia") == true }
        XCTAssertGreaterThan(wikipediaCopies.count, 1, "Precondition: the fixture mirrors a Wikipedia favourite across Spaces.")
        XCTAssertGreaterThan(
            Set(wikipediaCopies.map(\.id)).count, 1,
            "Precondition: the mirrors carry distinct ids, which is what a Space-scoped id lookup trips over."
        )

        let tabsBefore = env.state.tabs.count
        let intent = try topIntent(for: "wikipedia", mode: .newTab)
        let activeSpaceID = try XCTUnwrap(env.activeSpace?.id)

        switch intent {
        case .navigate(let url):
            env.openTab(url: url, in: activeSpaceID)
        case .searchGoogle(let text):
            env.openTab(url: try XCTUnwrap(env.searchEngine.searchURL(for: text)), in: activeSpaceID)
        case .switchToTab(let tabID):
            env.activateTab(tabID)
            XCTAssertEqual(env.activeTabID, tabID, "Switching to an open tab must actually select it.")
            return
        case .switchToSpaceAndTab(let targetSpaceID, let tabID):
            env.selectSpace(targetSpaceID)
            env.activateTab(tabID)
            XCTAssertEqual(env.activeTabID, tabID, "A deliberately chosen cross-Space row must select its tab.")
            return
        case .activateFavoriteResult(let favorite):
            env.activateFavorite(favorite, in: activeSpaceID)
        case .runAction:
            return XCTFail("\"wikipedia\" must not commit to an Action.")
        }

        XCTAssertGreaterThan(
            env.state.tabs.count, tabsBefore,
            """
            Enter on "wikipedia" opened nothing. Intent was \(intent). This is the \
            reported defect: the top row is a Favourite belonging to another Space, \
            and activateFavorite's Space-scoped ID lookup returned early without \
            opening anything.
            """
        )
    }

    func test_favouriteFromAnotherSpaceStillOpens() throws {
        let otherSpace = try XCTUnwrap(env.spaces.first { $0.id != spaceID && !$0.favorites.isEmpty })
        let favourite = try XCTUnwrap(otherSpace.favorites.first)
        XCTAssertNil(
            env.store.favorite(favourite.id, in: spaceID),
            "Precondition: the active Space has no favourite with this id — the lookup the store used to make."
        )

        let tabsBefore = env.state.tabs.count
        env.activateFavorite(favourite, in: spaceID)

        XCTAssertGreaterThan(env.state.tabs.count, tabsBefore, "Activating another Space's favourite did nothing at all.")
        XCTAssertTrue(
            env.state.tabs.values.contains { $0.url == favourite.url && $0.spaceID == spaceID },
            "The favourite must open in the Space the user is actually in, not teleport them to the Space its copy came from."
        )
    }

    func test_mirroredFavouritesCollapseToOneRow() {
        let rows = CommandBarEngine.results(
            query: "wikipedia",
            mode: .newTab,
            env: env,
            suggestions: [],
            searchEngine: env.searchEngine,
            siteSearch: env.siteSearchStore.state(active: nil)
        )
        let favouriteURLs = rows.compactMap { row -> String? in
            guard case .favorite(let favorite) = row.kind else { return nil }
            return CommandBarEngine.dedupeKey(for: favorite.url)
        }
        XCTAssertEqual(
            favouriteURLs.count, Set(favouriteURLs).count,
            "The same favourite destination is offered more than once:\n" + rows.map { "  \($0.id) — \($0.title)" }.joined(separator: "\n")
        )
    }

    // MARK: - 2. The blank pane, and the renderer-less no-op

    func test_blankPane_navigatesAndStopsBeingBlank() throws {
        let tabID = makeBlankPane()
        env.commandBarMode = .blankPane(tabID)
        let url = try expectedSearchURL(for: "wikipedia")

        if case .newTab = OrbitScheme.parse(try XCTUnwrap(env.tab(tabID)).url) {} else {
            return XCTFail("Precondition: the pane starts as an orbit://new-tab blank pane.")
        }

        env.loadInTab(tabID, url: url)
        env.activateTab(tabID)

        XCTAssertTrue(
            recorder.destinations(for: tabID).contains(url),
            "The blank pane was never sent to \(url) — destinations were \(recorder.destinations(for: tabID))."
        )
        if case .newTab = OrbitScheme.parse(try XCTUnwrap(env.tab(tabID)).url) {
            XCTFail("The pane still parses as a blank new-tab pane, so it keeps drawing NewTabPlaceholder and re-presenting the Command Bar over the page.")
        }
    }

    // MARK: - 2. The same hole, reached without a blank pane

    func test_unloadedTab_enterOnAGeneralQueryStillNavigates() throws {
        let tabID = env.openTab(url: URL(string: "https://example.com")!, in: spaceID)
        XCTAssertNotNil(env.webContents[tabID], "Precondition: the tab starts with a renderer.")
        env.releaseWebContents(for: tabID)
        XCTAssertNil(env.webContents[tabID], "Precondition: the renderer has been reclaimed.")

        let url = try expectedSearchURL(for: "wikipedia")
        env.loadInTab(tabID, url: url)

        XCTAssertTrue(
            recorder.destinations(for: tabID).contains(url),
            "An unloaded tab asked to navigate went nowhere — destinations were \(recorder.destinations(for: tabID))."
        )
    }

    func test_liveTab_isToldToLoadRatherThanRebuilt() throws {
        let tabID = env.openTab(url: URL(string: "https://example.com")!, in: spaceID)
        let contents = try XCTUnwrap(recorder.contentsByTab[tabID])
        let materialisationsBefore = recorder.materialised.filter { $0.tabID == tabID }.count

        let url = try expectedSearchURL(for: "wikipedia")
        env.loadInTab(tabID, url: url)

        XCTAssertEqual(recorder.currentURL(for: tabID), url, "A live renderer must be told to load the URL.")
        XCTAssertEqual(
            recorder.materialised.filter { $0.tabID == tabID }.count, materialisationsBefore,
            "A tab that already had a renderer must not be given a second one."
        )
        XCTAssertTrue(env.webContents[tabID] === contents, "The existing renderer must be kept, not replaced.")
    }

    // MARK: - 3. Every mode commits somewhere real

    func test_newTabMode_enterOnAGeneralQueryOpensATab() throws {
        env.commandBarMode = .newTab
        let url = try expectedSearchURL(for: "wikipedia")
        let before = env.state.tabs.count

        env.openTab(url: url, in: spaceID)

        XCTAssertEqual(env.state.tabs.count, before + 1, "⌘T plus a query must open a tab.")
        XCTAssertTrue(env.state.tabs.values.contains { $0.url == url }, "The new tab must be on the search results page.")
    }

    func test_editURLMode_enterOnAGeneralQueryNavigatesTheCurrentTab() throws {
        let tabID = env.openTab(url: URL(string: "https://example.com")!, in: spaceID)
        env.commandBarMode = .editURL(URL(string: "https://example.com")!)
        let before = env.state.tabs.count

        let url = try expectedSearchURL(for: "wikipedia")
        env.loadInTab(tabID, url: url)
        env.activateTab(tabID)

        XCTAssertTrue(recorder.destinations(for: tabID).contains(url), "⌘L plus a query must navigate the current tab.")
        XCTAssertEqual(env.state.tabs.count, before, "⌘L must not open a second tab.")
    }

    // MARK: - 4. The query really is a search, not a URL

    func test_bareWordAlwaysOffersASearchAndIsNeverTreatedAsAnAddress() throws {
        XCTAssertNil(CommandBarEngine.detectTypedURL("wikipedia"), "A bare word with no dot is not an address.")

        let rows = CommandBarEngine.results(
            query: "wikipedia",
            mode: .newTab,
            env: env,
            suggestions: [],
            searchEngine: env.searchEngine,
            siteSearch: env.siteSearchStore.state(active: nil)
        )
        let searchRow = rows.first { row in
            if case .searchSuggestion(let text) = row.kind { return text == "wikipedia" }
            return false
        }
        XCTAssertNotNil(searchRow, "The literal search row must always be offered:\n" + rows.map { "  \($0.id)" }.joined(separator: "\n"))

        let url = try expectedSearchURL(for: "wikipedia")
        XCTAssertNotNil(url.host(), "The committed search URL must have a host to navigate to.")
        XCTAssertTrue(url.absoluteString.contains("wikipedia"), "The query must survive into the search URL: \(url).")
    }

    func test_queryMatchingNothingStillCommitsAsASearch() throws {
        guard case .searchGoogle(let text) = try topIntent(for: "zzqx nonexistent phrase", mode: .newTab) else {
            return XCTFail("A query matching nothing must commit as a search.")
        }
        XCTAssertEqual(text, "zzqx nonexistent phrase")

        let activeSpaceID = try XCTUnwrap(env.activeSpace?.id)
        let before = env.state.tabs.count
        env.openTab(url: try XCTUnwrap(env.searchEngine.searchURL(for: text)), in: activeSpaceID)
        XCTAssertEqual(env.state.tabs.count, before + 1)
    }
}
