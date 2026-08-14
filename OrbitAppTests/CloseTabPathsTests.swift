//  Every user-facing way of closing a bookmarked tab must leave a real page on
//  screen. Runs on a scratch demo environment with mock renderers — no engine.

import XCTest
@testable import Orbit

@MainActor
final class CloseTabPathsTests: XCTestCase {

    private var env: AppEnvironment!
    private var spaceID: SpaceID!

    private let bookmarkURL = URL(string: "https://bookmark.example.com")!
    private let todayURL = URL(string: "https://today.example.com")!

    override func setUp() {
        super.setUp()
        env = AppEnvironment.demo
        env._test_webContentsFactory = { _, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Close Paths Scratch", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID
        )
        env.selectSpace(spaceID)
    }

    override func tearDown() {
        env = nil
        spaceID = nil
        super.tearDown()
    }

    private func makeBookmarkedTabWithATodayTabBehindIt() -> (bookmark: TabID, today: TabID) {
        let todayTabID = env.openTab(url: todayURL, in: spaceID)
        let bookmarkTabID = env.openTab(url: bookmarkURL, in: spaceID, section: .pinned)
        env.activateTab(bookmarkTabID)
        return (bookmarkTabID, todayTabID)
    }

    private func assertPaneIsNotBlank(_ file: StaticString = #filePath, line: UInt = #line) {
        let activeTabID = env.activeTabID
        XCTAssertNotNil(activeTabID, "no active tab means the empty new-page pane", file: file, line: line)
        guard let activeTabID else { return }
        XCTAssertNotNil(
            env.webContents[activeTabID],
            "the active tab has no renderer, which draws as a blank pane", file: file, line: line
        )
    }

    func testTheCloseTabCommandOnABookmarkedTabKeepsTheBookmarkAndShowsTheNextTab() {
        let (bookmarkTabID, todayTabID) = makeBookmarkedTabWithATodayTabBehindIt()
        XCTAssertEqual(env.activeTabID, bookmarkTabID, "precondition: the bookmarked tab is on screen")

        env.perform(.closeTabOrWindow)

        XCTAssertEqual(env.activeTabID, todayTabID, "Cmd-W on a bookmarked tab must move to the next tab, not blank the pane.")
        XCTAssertEqual(env.tab(bookmarkTabID)?.section, .pinned, "and must keep the bookmark, exactly as the minus beside the row does")
        assertPaneIsNotBlank()
    }

    func testTheRowsMinusButtonAndTheKeyboardAgree() {
        let (bookmarkTabID, todayTabID) = makeBookmarkedTabWithATodayTabBehindIt()

        env.closeTabKeepingBookmark(bookmarkTabID)

        XCTAssertEqual(env.activeTabID, todayTabID)
        XCTAssertEqual(env.tab(bookmarkTabID)?.section, .pinned)
        assertPaneIsNotBlank()
    }

    func testClosingABookmarkedTabThroughTheRawCloseVerbStillLeavesAPageOnScreen() {
        let (bookmarkTabID, todayTabID) = makeBookmarkedTabWithATodayTabBehindIt()

        env.closeTab(bookmarkTabID)

        XCTAssertEqual(
            env.activeTabID, todayTabID,
            "closeTab releases the renderer first, so leaving the closed tab active is a blank pane — every caller of it must move on."
        )
        assertPaneIsNotBlank()
    }

    func testClosingTheOnlyBookmarkedTabThroughTheRawCloseVerbDoesNotBlankThePane() {
        let onlyTabID = env.openTab(url: bookmarkURL, in: spaceID, section: .pinned)
        env.activateTab(onlyTabID)

        env.closeTab(onlyTabID)

        XCTAssertEqual(env.tab(onlyTabID)?.section, .today, "closeTab on a pinned tab unpins it; the tab survives")
        assertPaneIsNotBlank()
    }

    func testClosingTheOnlyBookmarkedTabWithTheMinusLeavesTheEmptyState() {
        let onlyTabID = env.openTab(url: bookmarkURL, in: spaceID, section: .pinned)
        env.activateTab(onlyTabID)

        env.closeTabKeepingBookmark(onlyTabID)

        XCTAssertNil(env.activeTabID, "with nothing else open in the Space the empty state is the honest outcome")
        XCTAssertEqual(env.tab(onlyTabID)?.section, .pinned, "the bookmark itself stays in the sidebar")
    }
}
