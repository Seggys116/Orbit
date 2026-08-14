//  Closing a bookmarked (pinned) tab must hand the pane to the next sensible
//  tab. Backed by a fresh StateStore in a scratch temp directory.

import XCTest

@MainActor
final class CloseTabSuccessorTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-CloseSuccessor-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> BrowserStore {
        let store = BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
        for seeded in store.space(store.activeSpace!.id)?.today ?? [] { store.archiveTab(seeded) }
        return store
    }

    private func url(_ name: String) -> URL { URL(string: "https://\(name).example.com")! }

    func test_closingTheOnlyOpenPinnedTab_landsOnATodayTab() {
        let store = makeStore()
        let space = store.activeSpace!
        let todayTabID = store.openTab(url: url("today"), in: space.id)
        let pinnedTabID = store.openTab(url: url("pinned"), in: space.id, section: .pinned)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), pinnedTabID, "precondition: the pinned tab is active")

        store.closeTabKeepingPin(pinnedTabID)

        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), todayTabID,
            "Closing the only open pinned tab must fall out of Pinned into Today, not leave the Space with no active tab (a blank pane)."
        )
    }

    func test_closingAMiddlePinnedTab_landsOnTheFollowingPinnedRow() {
        let store = makeStore()
        let space = store.activeSpace!
        _ = store.openTab(url: url("first"), in: space.id, section: .pinned, activate: false)
        let second = store.openTab(url: url("second"), in: space.id, section: .pinned, activate: false)
        let third = store.openTab(url: url("third"), in: space.id, section: .pinned, activate: false)
        var seeded = store.state
        seeded.activeTabBySpace[space.id] = second
        store.state = seeded

        store.closeTabKeepingPin(second)

        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), third,
            "Closing a pinned row with no activation history must land on the neighbour below it, in sidebar order."
        )
    }

    func test_closingTheLastPinnedTab_landsOnThePrecedingPinnedRow() {
        let store = makeStore()
        let space = store.activeSpace!
        _ = store.openTab(url: url("first"), in: space.id, section: .pinned, activate: false)
        let second = store.openTab(url: url("second"), in: space.id, section: .pinned, activate: false)
        let third = store.openTab(url: url("third"), in: space.id, section: .pinned, activate: false)
        var seeded = store.state
        seeded.activeTabBySpace[space.id] = third
        store.state = seeded

        store.closeTabKeepingPin(third)

        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), second,
            "With nothing below it, the row above must take over."
        )
    }

    func test_closingAPinnedTabInAFolder_staysWithinThePinnedSection() {
        let store = makeStore()
        let space = store.activeSpace!
        let folderID = store.createFolder(name: "Work", in: space.id)
        let inFolder = store.openTab(url: url("infolder"), in: space.id, section: .pinned, activate: false)
        store.pin(inFolder, toParent: folderID, atIndex: 0, in: space.id)
        let sibling = store.openTab(url: url("sibling"), in: space.id, section: .pinned, activate: false)
        var seeded = store.state
        seeded.activeTabBySpace[space.id] = inFolder
        store.state = seeded

        store.closeTabKeepingPin(inFolder)

        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), sibling,
            "A pinned tab nested in a folder must still find its neighbour in the flattened Pinned order."
        )
    }

    func test_closingTheOnlyTabInTheSpace_leavesTheEmptyState() {
        let store = makeStore()
        let space = store.activeSpace!
        let onlyTabID = store.openTab(url: url("only"), in: space.id, section: .pinned)

        store.closeTabKeepingPin(onlyTabID)

        XCTAssertNil(
            store.activeTabBySpaceForTesting(space.id),
            "With nothing else open in the Space, the empty state is the correct outcome."
        )
    }

    func test_closeTab_onAPinnedTab_handsThePaneToAnotherTab() {
        let store = makeStore()
        let space = store.activeSpace!
        let todayTabID = store.openTab(url: url("today"), in: space.id)
        let pinnedTabID = store.openTab(url: url("pinned"), in: space.id, section: .pinned)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), pinnedTabID, "precondition: the pinned tab is active")

        store.closeTab(pinnedTabID)

        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), todayTabID,
            "Cmd-W on a pinned tab releases its renderer, so leaving it active shows a blank pane — the successor must take over."
        )
    }

    func test_closeTab_onTheOnlyPinnedTab_keepsShowingTheTabItUnpinned() {
        let store = makeStore()
        let space = store.activeSpace!
        let onlyTabID = store.openTab(url: url("only"), in: space.id, section: .pinned)

        store.closeTab(onlyTabID)

        XCTAssertEqual(store.tab(onlyTabID)?.section, .today, "closeTab on a pinned tab unpins it; the tab itself survives.")
        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), onlyTabID,
            "The unpinned tab is the Space's only open tab, so it must stay on screen rather than be replaced by the empty state."
        )
    }
}
