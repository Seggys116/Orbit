//  closeTab (Cmd-W / the raw close verb) hands a closed bookmarked tab's pane
//  to the next tab so the screen never blanks. closeTabKeepingBookmark (the
//  row's "-") is deliberately different: closing the ACTIVE bookmark with it
//  must leave no active tab at all — the new-tab-page state — never fall
//  back to some other tab, and never materialise any other bookmark in the
//  process. Runs on a scratch demo environment with mock renderers — no engine.

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

    func testTheCloseTabCommandOnABookmarkedTabKeepsTheBookmarkAndGoesToNoActiveTab() {
        let (bookmarkTabID, todayTabID) = makeBookmarkedTabWithATodayTabBehindIt()
        XCTAssertEqual(env.activeTabID, bookmarkTabID, "precondition: the bookmarked tab is on screen")

        env.perform(.closeTabOrWindow)

        // Cmd-W funnels a pinned tab through closeTabPreservingBookmark into
        // closeTabKeepingBookmark — "the same rule as the minus beside its
        // row" (see that function's own comment) — so it must agree with the
        // row's "-": no active tab, never a silent switch to the next tab.
        XCTAssertNil(env.activeTabID, "Cmd-W on the active bookmarked tab must go to the empty/new-tab state, not blank-switch to another tab.")
        XCTAssertNotEqual(env.activeTabID, todayTabID)
        XCTAssertEqual(env.tab(bookmarkTabID)?.section, .pinned, "and must keep the bookmark, exactly as the minus beside the row does")
    }

    func testTheMinusButtonOnTheActiveBookmarkedTabGoesToNoActiveTabNotTheNextTab() {
        let (bookmarkTabID, todayTabID) = makeBookmarkedTabWithATodayTabBehindIt()
        XCTAssertEqual(env.activeTabID, bookmarkTabID, "precondition: the bookmarked tab is on screen")

        env.closeTabKeepingBookmark(bookmarkTabID)

        XCTAssertNil(
            env.activeTabID,
            "Pressing '-' on the active bookmarked tab must land on the empty/new-tab state — as if there were no active tab at all — never hand the pane to some other tab."
        )
        XCTAssertNotEqual(env.activeTabID, todayTabID, "In particular it must not silently switch to the Today tab sitting behind it.")
        XCTAssertEqual(env.tab(bookmarkTabID)?.section, .pinned, "and must keep the bookmark, exactly as before.")
    }

    func testTheMinusButtonOnTheActiveBookmarkedTabInAFolderMaterializesNoSiblingTabs() {
        var materializedTabIDs: [TabID] = []
        env._test_webContentsFactory = { tabID, url in
            materializedTabIDs.append(tabID)
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }

        let folderID = env.createFolder(name: "Reading", in: spaceID)
        let closedSiblingA = env.openTab(url: URL(string: "https://sibling-a.example.com")!, in: spaceID, section: .pinned, activate: false)
        let closedSiblingB = env.openTab(url: URL(string: "https://sibling-b.example.com")!, in: spaceID, section: .pinned, activate: false)
        let activeBookmark = env.openTab(url: bookmarkURL, in: spaceID, section: .pinned, activate: false)
        env.pinTab(closedSiblingA, toParent: folderID, atIndex: 0, in: spaceID)
        env.pinTab(closedSiblingB, toParent: folderID, atIndex: 1, in: spaceID)
        env.pinTab(activeBookmark, toParent: folderID, atIndex: 2, in: spaceID)
        env._test_detachWebContents(for: closedSiblingA)
        env._test_detachWebContents(for: closedSiblingB)
        env.activateTab(activeBookmark)
        XCTAssertEqual(env.activeTabID, activeBookmark, "precondition: the bookmark inside the folder is active")

        materializedTabIDs = []

        env.closeTabKeepingBookmark(activeBookmark)

        XCTAssertNil(env.activeTabID, "Closing the active bookmark must leave the Space with no active tab.")
        XCTAssertTrue(
            materializedTabIDs.isEmpty,
            "No WebContents may be created for any other tab as a side effect of closing this one — got \(materializedTabIDs.count): \(materializedTabIDs)"
        )
        XCTAssertNil(env.webContents[closedSiblingA], "The sibling bookmark must stay closed, not get loaded — this is the reported 'loads all tabs in that bookmark' symptom.")
        XCTAssertNil(env.webContents[closedSiblingB], "Same for the other sibling — none of the folder's other tabs may materialise.")
        XCTAssertEqual(env.tab(activeBookmark)?.section, .pinned, "The bookmark itself must survive — this is a deactivation, not a removal.")
    }

    func testClosingANonActivePinnedTabInAFolderLeavesTheActiveTabAndSiblingsAlone() {
        var materializedTabIDs: [TabID] = []
        env._test_webContentsFactory = { tabID, url in
            materializedTabIDs.append(tabID)
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }

        let folderID = env.createFolder(name: "Reading", in: spaceID)
        let openNonActive = env.openTab(url: URL(string: "https://open-non-active.example.com")!, in: spaceID, section: .pinned, activate: false)
        let closedSibling = env.openTab(url: URL(string: "https://closed-sibling.example.com")!, in: spaceID, section: .pinned, activate: false)
        let activeBookmark = env.openTab(url: bookmarkURL, in: spaceID, section: .pinned, activate: false)
        env.pinTab(openNonActive, toParent: folderID, atIndex: 0, in: spaceID)
        env.pinTab(closedSibling, toParent: folderID, atIndex: 1, in: spaceID)
        env.pinTab(activeBookmark, toParent: folderID, atIndex: 2, in: spaceID)
        env._test_detachWebContents(for: closedSibling)
        env.activateTab(activeBookmark)

        materializedTabIDs = []

        env.closeTabKeepingBookmark(openNonActive)

        XCTAssertEqual(env.activeTabID, activeBookmark, "Closing a non-active pinned tab must not disturb what is on screen.")
        XCTAssertTrue(materializedTabIDs.isEmpty, "No sibling should be materialised just because an unrelated bookmark in the same folder closed.")
        XCTAssertNil(env.webContents[closedSibling], "The other closed sibling stays closed.")
        XCTAssertEqual(env.tab(openNonActive)?.section, .pinned, "The closed tab keeps its bookmark.")
        XCTAssertNil(env.webContents[openNonActive], "And it is genuinely closed — its own renderer released.")
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
