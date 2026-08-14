//  closeTabKeepingPin ("-" on a bookmarked tab) is a deactivation: closing the
//  ACTIVE pinned tab with it must always leave the Space with no active tab,
//  never hand the pane to a sibling — even one right next to it in the same
//  folder. closeTab (the raw close verb / Cmd-W) is the one that still hands
//  the pane to the next sensible tab. Backed by a fresh StateStore in a
//  scratch temp directory.

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

    func test_closingTheOnlyOpenPinnedTab_leavesNoActiveTab() {
        let store = makeStore()
        let space = store.activeSpace!
        let todayTabID = store.openTab(url: url("today"), in: space.id)
        let pinnedTabID = store.openTab(url: url("pinned"), in: space.id, section: .pinned)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), pinnedTabID, "precondition: the pinned tab is active")

        store.closeTabKeepingPin(pinnedTabID)

        XCTAssertNil(
            store.activeTabBySpaceForTesting(space.id),
            "The '-' on the active pinned tab is a deactivation, not a 'give me the next tab' gesture — it must never silently switch to the Today tab behind it."
        )
        XCTAssertNotEqual(store.activeTabBySpaceForTesting(space.id), todayTabID)
    }

    func test_closingAMiddlePinnedTab_leavesNoActiveTab() {
        let store = makeStore()
        let space = store.activeSpace!
        _ = store.openTab(url: url("first"), in: space.id, section: .pinned, activate: false)
        let second = store.openTab(url: url("second"), in: space.id, section: .pinned, activate: false)
        _ = store.openTab(url: url("third"), in: space.id, section: .pinned, activate: false)
        var seeded = store.state
        seeded.activeTabBySpace[space.id] = second
        store.state = seeded

        store.closeTabKeepingPin(second)

        XCTAssertNil(
            store.activeTabBySpaceForTesting(space.id),
            "Closing the active pinned row must never hand the pane to its neighbour, in sidebar order or otherwise."
        )
    }

    func test_closingTheLastPinnedTab_leavesNoActiveTab() {
        let store = makeStore()
        let space = store.activeSpace!
        _ = store.openTab(url: url("first"), in: space.id, section: .pinned, activate: false)
        _ = store.openTab(url: url("second"), in: space.id, section: .pinned, activate: false)
        let third = store.openTab(url: url("third"), in: space.id, section: .pinned, activate: false)
        var seeded = store.state
        seeded.activeTabBySpace[space.id] = third
        store.state = seeded

        store.closeTabKeepingPin(third)

        XCTAssertNil(
            store.activeTabBySpaceForTesting(space.id),
            "With nothing below it, the row above must NOT take over — the empty state is the correct outcome, not the preceding row."
        )
    }

    func test_closingAPinnedTabInAFolder_leavesNoActiveTabAndDoesNotActivateItsSibling() {
        let store = makeStore()
        let space = store.activeSpace!
        let folderID = store.createFolder(name: "Work", in: space.id)
        let inFolder = store.openTab(url: url("infolder"), in: space.id, section: .pinned, activate: false)
        store.pin(inFolder, toParent: folderID, atIndex: 0, in: space.id)
        let sibling = store.openTab(url: url("sibling"), in: space.id, section: .pinned, activate: false)
        store.pin(sibling, toParent: folderID, atIndex: 1, in: space.id)
        var seeded = store.state
        seeded.activeTabBySpace[space.id] = inFolder
        store.state = seeded

        store.closeTabKeepingPin(inFolder)

        XCTAssertNil(
            store.activeTabBySpaceForTesting(space.id),
            "A pinned tab nested in a folder must not fall over onto its sibling in the same folder — this is exactly the reported 'closing the active bookmark loads another tab in that folder' bug."
        )
        XCTAssertNotEqual(store.activeTabBySpaceForTesting(space.id), sibling)
    }

    func test_closingANonActivePinnedTab_leavesTheActiveTabUntouched() {
        let store = makeStore()
        let space = store.activeSpace!
        let first = store.openTab(url: url("first"), in: space.id, section: .pinned, activate: false)
        let second = store.openTab(url: url("second"), in: space.id, section: .pinned, activate: false)
        var seeded = store.state
        seeded.activeTabBySpace[space.id] = second
        store.state = seeded

        store.closeTabKeepingPin(first)

        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), second,
            "Closing a pinned tab that is not the active one must not move the active tab at all."
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
