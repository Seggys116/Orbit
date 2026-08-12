import XCTest
@testable import Orbit

@MainActor
final class PinnedTabResetTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var scratchSpaceID: SpaceID!
    private var originalActiveSpaceID: SpaceID?
    private var pinnedTabID: TabID!

    private let pinnedURL = URL(string: "https://www.nytimes.com/2024/02/22/some-article")!
    private let wanderedURL = URL(string: "https://www.nytimes.com/section/world")!

    override func setUp() {
        super.setUp()
        originalActiveSpaceID = env.activeSpace?.id
        let profileID = env.createDefaultProfileIfNeeded()
        scratchSpaceID = env.createSpace(
            name: "Pinned Reset Scratch",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: profileID
        )
        env.selectSpace(scratchSpaceID)

        pinnedTabID = env.openTab(url: pinnedURL, in: scratchSpaceID, section: .pinned, activate: false)
        env.state.tabs[pinnedTabID]?.title = "The Article I Pinned"
        env.state.tabs[pinnedTabID]?.pinnedTitle = "The Article I Pinned"
    }

    override func tearDown() {
        if let pinnedTabID { env._test_detachWebContents(for: pinnedTabID) }
        if let scratchSpaceID { env.deleteSpace(scratchSpaceID) }
        if let originalActiveSpaceID, env.space(originalActiveSpaceID) != nil {
            env.selectSpace(originalActiveSpaceID)
        }
        pinnedTabID = nil
        scratchSpaceID = nil
        originalActiveSpaceID = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func attachContentsAndWanderOff() -> MockWebContents {
        let contents = MockWebContents()
        contents.navigationState.url = pinnedURL
        env._test_attachWebContents(contents, for: pinnedTabID)

        contents.load(wanderedURL)
        env.state.tabs[pinnedTabID]?.url = wanderedURL
        env.state.tabs[pinnedTabID]?.title = "World News"
        return contents
    }

    private var scratchTodayTabs: [Tab] { env.todayTabs(in: scratchSpaceID) }

    // MARK: - Plain click: revert in place

    func testPlainResetRevertsInPlaceAndCreatesNoSecondTab() {
        let contents = attachContentsAndWanderOff()
        XCTAssertEqual(env.tab(pinnedTabID)?.url, wanderedURL, "Fixture check: the tab really did wander off.")
        XCTAssertTrue(env.tab(pinnedTabID)!.hasNavigatedAwayFromPinnedURL)
        XCTAssertTrue(scratchTodayTabs.isEmpty, "Fixture check: the scratch Space starts with no Today tabs.")

        env.resetPinnedTab(pinnedTabID)

        XCTAssertEqual(env.tab(pinnedTabID)?.url, pinnedURL, "The document must be back on the pinned page.")
        XCTAssertEqual(
            contents.navigationState.url, pinnedURL,
            "The live WebContents must actually have been told to load it — otherwise the sidebar says one thing and the page shows another."
        )
        XCTAssertFalse(env.tab(pinnedTabID)!.hasNavigatedAwayFromPinnedURL, "So the `/` marker goes away.")
        XCTAssertTrue(
            scratchTodayTabs.isEmpty,
            "A plain favicon click reverts in place. Only the Command-click variant opens the prior URL in a new tab (RN2024 v1.31.0)."
        )
    }

    // MARK: - Command-click: revert and keep the prior page

    func testCommandResetRevertsAndOpensThePriorURLInANewTab() throws {
        let contents = attachContentsAndWanderOff()

        env.resetPinnedTab(pinnedTabID, openingPriorURLInNewTab: true)

        XCTAssertEqual(env.tab(pinnedTabID)?.url, pinnedURL, "The pinned tab still goes back — that is the first half of the sentence.")
        XCTAssertEqual(contents.navigationState.url, pinnedURL)

        XCTAssertEqual(scratchTodayTabs.count, 1, "Exactly one new tab, carrying the page the user had wandered to.")
        let opened = try XCTUnwrap(scratchTodayTabs.first)
        XCTAssertEqual(opened.url, wanderedURL, "\"...and open your prior URL in a new tab\" — the prior URL, not the pinned one.")
        XCTAssertEqual(opened.spaceID, scratchSpaceID, "The new tab belongs in the Space the pinned tab lives in.")
        XCTAssertEqual(opened.section, .today, "It is an ordinary Today tab, not a second pinned one.")
        XCTAssertNil(opened.pinnedURL, "And it is not itself pinned to anything.")
    }

    func testCommandResetLeavesFocusOnThePinnedTab() {
        attachContentsAndWanderOff()
        env.activateTab(pinnedTabID)
        XCTAssertEqual(env.activeTabID, pinnedTabID, "Fixture check.")

        env.resetPinnedTab(pinnedTabID, openingPriorURLInNewTab: true)

        XCTAssertEqual(
            env.activeTabID, pinnedTabID,
            "The new tab must not steal focus — it is context being preserved, not the thing the user asked to look at."
        )
    }

    // MARK: - Refusals

    func testResettingATabAlreadyOnItsOriginDoesNothingAtAll() {
        let contents = MockWebContents()
        contents.navigationState.url = pinnedURL
        env._test_attachWebContents(contents, for: pinnedTabID)

        env.resetPinnedTab(pinnedTabID, openingPriorURLInNewTab: true)

        XCTAssertEqual(env.tab(pinnedTabID)?.url, pinnedURL)
        XCTAssertTrue(scratchTodayTabs.isEmpty, "No origin to return from means no prior URL worth keeping.")
    }

    func testResettingAnUnpinnedTabDoesNothing() {
        attachContentsAndWanderOff()
        env.unpinTab(pinnedTabID)

        env.resetPinnedTab(pinnedTabID, openingPriorURLInNewTab: true)

        XCTAssertEqual(env.tab(pinnedTabID)?.url, wanderedURL, "A Today tab is left exactly where it is.")
        XCTAssertEqual(scratchTodayTabs.count, 1, "Only the unpinned tab itself is in Today — nothing new was opened.")
    }

    // MARK: - Edit Pinned Page

    func testReplacePinnedURLWithCurrentThroughAppEnvironment() {
        attachContentsAndWanderOff()

        env.replacePinnedURLWithCurrent(pinnedTabID)

        XCTAssertEqual(env.tab(pinnedTabID)?.pinnedURL, wanderedURL)
        XCTAssertEqual(env.tab(pinnedTabID)?.pinnedTitle, "World News")
        XCTAssertFalse(env.tab(pinnedTabID)!.hasNavigatedAwayFromPinnedURL)
    }

    func testSetPinnedURLThroughAppEnvironmentEditsWithoutNavigating() {
        let contents = attachContentsAndWanderOff()
        let typed = URL(string: "https://www.nytimes.com/2020/01/01/a-different-article")!

        env.setPinnedURL(pinnedTabID, to: typed)

        XCTAssertEqual(env.tab(pinnedTabID)?.pinnedURL, typed)
        XCTAssertEqual(env.tab(pinnedTabID)?.url, wanderedURL, "The user is still reading whatever they were reading.")
        XCTAssertEqual(contents.navigationState.url, wanderedURL, "And the live page did not move either.")

        env.resetPinnedTab(pinnedTabID)
        XCTAssertEqual(contents.navigationState.url, typed, "The edited URL is genuinely where the favicon click now goes.")
    }

    // MARK: - No automatic reversion

    func testActivatingAPinnedTabNeverResetsIt() {
        let contents = attachContentsAndWanderOff()
        let otherTabID = env.openTab(url: URL(string: "https://example.com/other")!, in: scratchSpaceID)

        env.activateTab(otherTabID)
        env.activateTab(pinnedTabID)

        XCTAssertEqual(
            env.tab(pinnedTabID)?.url, wanderedURL,
            "Switching away from and back to a Pinned Tab must not Reset it — see AppEnvironment+PinnedTabs.swift's header."
        )
        XCTAssertEqual(contents.navigationState.url, wanderedURL, "And the live page must not have been reloaded to the origin either.")
        XCTAssertTrue(env.tab(pinnedTabID)!.hasNavigatedAwayFromPinnedURL, "The `/` marker is still there, waiting to be clicked.")
    }
}
