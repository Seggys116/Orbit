//  Every store here is backed by a fresh StateStore pointed at a scratch
//  temp directory, never the real ~/Library/Application Support/Orbit/State/.

import XCTest

@MainActor
final class StoreTests: XCTestCase {

    // MARK: - Fixture

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-StateStore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> BrowserStore {
        BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
    }

    // MARK: - Open / close / pin / unpin / archive / restore

    func test_openTab_addsToTodayAndActivates() {
        let store = makeStore()
        let space = store.activeSpace!

        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)

        XCTAssertEqual(store.tab(tabID)?.section, .today)
        XCTAssertTrue(store.todayTabs(in: space.id).map(\.id).contains(tabID))
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), tabID)
    }

    func test_pin_movesTabFromTodayToPinnedTree() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)

        store.pin(tabID)

        XCTAssertEqual(store.tab(tabID)?.section, .pinned)
        XCTAssertFalse(store.todayTabs(in: space.id).map(\.id).contains(tabID))
        XCTAssertTrue(store.pinnedNodes(in: space.id).flatMap(\.allTabIDs).contains(tabID))
    }

    func test_unpin_movesTabBackToToday() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)
        store.pin(tabID)

        store.unpin(tabID)

        XCTAssertEqual(store.tab(tabID)?.section, .today)
        XCTAssertTrue(store.todayTabs(in: space.id).map(\.id).contains(tabID))
        XCTAssertFalse(store.pinnedNodes(in: space.id).flatMap(\.allTabIDs).contains(tabID))
    }

    func test_togglePin_flipsBothWays() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)

        store.togglePin(tabID)
        XCTAssertEqual(store.tab(tabID)?.section, .pinned)

        store.togglePin(tabID)
        XCTAssertEqual(store.tab(tabID)?.section, .today)
    }

    func test_archiveTab_movesToArchivedAndClearsFromToday() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)

        store.archiveTab(tabID)

        XCTAssertEqual(store.tab(tabID)?.section, .archived)
        XCTAssertNotNil(store.tab(tabID)?.archivedAt)
        XCTAssertTrue(store.tab(tabID)?.isUnloaded ?? false)
        XCTAssertFalse(store.todayTabs(in: space.id).map(\.id).contains(tabID))
        XCTAssertTrue(store.archivedTabs(in: space.id).map(\.id).contains(tabID))
    }

    func test_archiveTab_reassignsActiveTabWhenArchivingTheActiveTab() {
        let store = makeStore()
        let space = store.activeSpace!
        for seeded in store.space(space.id)?.today ?? [] { store.closeTab(seeded) }
        XCTAssertEqual(store.space(space.id)?.today.count, 0, "precondition: this test starts from an empty Today list")
        let firstTabID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondTabID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)
        store.selectTab(firstTabID)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), firstTabID)

        store.archiveTab(firstTabID)

        XCTAssertNotEqual(store.activeTabBySpaceForTesting(space.id), firstTabID)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), secondTabID)
    }

    func test_restoreFromArchive_returnsTabToToday() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)
        store.archiveTab(tabID)

        store.restoreFromArchive(tabID)

        XCTAssertEqual(store.tab(tabID)?.section, .today)
        XCTAssertNil(store.tab(tabID)?.archivedAt)
        XCTAssertTrue(store.todayTabs(in: space.id).map(\.id).contains(tabID))
    }

    func test_closeTab_archivesATodayTabAndUnpinsAPinnedTab() {
        let store = makeStore()
        let space = store.activeSpace!
        let todayTabID = store.openTab(url: URL(string: "https://today.example.com")!, in: space.id)
        let pinnedTabID = store.openTab(url: URL(string: "https://pinned.example.com")!, in: space.id, section: .pinned)

        store.closeTab(todayTabID)
        store.closeTab(pinnedTabID)

        XCTAssertEqual(store.tab(todayTabID)?.section, .archived, "closeTab on a Today tab archives it (BrowserStore+Tabs.swift file header).")
        XCTAssertEqual(store.tab(pinnedTabID)?.section, .today, "closeTab on a Pinned tab unpins it down to Today, it does not archive or delete it.")
    }

    // MARK: - Active-tab successor on close

    func test_closeTab_returnsToThePreviouslyActiveTab_notTheFirstTabInSpace() {
        let store = makeStore()
        let space = store.activeSpace!
        for seeded in store.space(space.id)?.today ?? [] { store.closeTab(seeded) }
        let tabA = store.openTab(url: URL(string: "https://a.example.com")!, in: space.id)
        _ = store.openTab(url: URL(string: "https://b.example.com")!, in: space.id)
        _ = store.openTab(url: URL(string: "https://c.example.com")!, in: space.id)
        let tabD = store.openTab(url: URL(string: "https://d.example.com")!, in: space.id)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), tabD, "precondition: opening a tab activates it")

        store.selectTab(tabA)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), tabA, "precondition: the user switched back to tabA")

        store.closeTab(tabA)

        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), tabD,
            "closing the active tab must return to the tab the user came from (tabD), not the first remaining tab in the sidebar (tabB) and not merely tabA's list neighbour."
        )
    }

    func test_closeTab_withNoActivationHistory_fallsBackToTheAdjacentTab() {
        let store = makeStore()
        let space = store.activeSpace!
        for seeded in store.space(space.id)?.today ?? [] { store.closeTab(seeded) }
        let tabA = store.openTab(url: URL(string: "https://a.example.com")!, in: space.id, activate: false)
        let tabB = store.openTab(url: URL(string: "https://b.example.com")!, in: space.id, activate: false)
        let tabC = store.openTab(url: URL(string: "https://c.example.com")!, in: space.id, activate: false)
        var seededState = store.state
        seededState.activeTabBySpace[space.id] = tabB
        store.state = seededState
        _ = tabA

        store.closeTab(tabB)

        XCTAssertEqual(
            store.activeTabBySpaceForTesting(space.id), tabC,
            "with no recorded activation transition to consult, the successor must be the adjacent tab (preferring the one after), not the first tab in the space."
        )
    }

    func test_closeTab_closingTheLastTabInASpace_leavesNoActiveTab() {
        let store = makeStore()
        let space = store.activeSpace!
        for seeded in store.space(space.id)?.today ?? [] { store.closeTab(seeded) }
        let onlyTabID = store.openTab(url: URL(string: "https://only.example.com")!, in: space.id)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), onlyTabID)

        store.closeTab(onlyTabID)

        XCTAssertNil(
            store.activeTabBySpaceForTesting(space.id),
            "closing the only open tab in a Space must leave no active tab, not silently keep pointing at the archived one."
        )
    }

    func test_closeTabKeepingPin_deactivatesRatherThanPickingASuccessor() {
        let store = makeStore()
        let space = store.activeSpace!
        for seeded in store.space(space.id)?.today ?? [] { store.closeTab(seeded) }
        let tabB = store.openTab(url: URL(string: "https://b.example.com")!, in: space.id)
        let tabA = store.openTab(url: URL(string: "https://a.example.com")!, in: space.id)
        let pinnedTabID = store.openTab(url: URL(string: "https://pinned.example.com")!, in: space.id, section: .pinned)
        store.selectTab(tabA)
        store.selectTab(pinnedTabID)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), pinnedTabID, "precondition: the pinned tab is active")

        store.closeTabKeepingPin(pinnedTabID)

        XCTAssertNil(
            store.activeTabBySpaceForTesting(space.id),
            "closeTabKeepingPin ('-') must leave no active tab — unlike closeTab, it must not fall back to tabA (the history-based successor) or tabB."
        )
    }

    func test_closeTab_leavesExactlyOneActiveTabAndItIsTheSuccessor() throws {
        let store = makeStore()
        let space = store.activeSpace!
        for seeded in store.space(space.id)?.today ?? [] { store.closeTab(seeded) }
        let tabA = store.openTab(url: URL(string: "https://a.example.com")!, in: space.id)
        let tabB = store.openTab(url: URL(string: "https://b.example.com")!, in: space.id)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), tabB)

        store.closeTab(tabB)

        let successor = try XCTUnwrap(store.activeTabBySpaceForTesting(space.id), "a successor must be active while another tab remains open")
        XCTAssertEqual(successor, tabA, "the previously-active tab must take over")
        XCTAssertEqual(store.state.activeTabBySpace[space.id], successor, "exactly one active tab must be recorded for the space")
        XCTAssertTrue(store.todayTabs(in: space.id).map(\.id).contains(successor), "the active tab must actually still be open, not the just-closed one")
    }

    func test_reopenLastClosedTab_reversesWhicheverCloseTabDid() {
        let store = makeStore()
        let space = store.activeSpace!
        let pinnedTabID = store.openTab(url: URL(string: "https://pinned.example.com")!, in: space.id, section: .pinned)
        store.closeTab(pinnedTabID)
        XCTAssertEqual(store.tab(pinnedTabID)?.section, .today)

        store.reopenLastClosedTab()

        XCTAssertEqual(store.tab(pinnedTabID)?.section, .pinned, "Reopening after closing a Pinned tab must re-pin it, not merely reactivate it as a Today tab.")
    }

    // MARK: - Bookmarked (pinned) rows that are also open tabs

    func test_closeTabKeepingPin_marksTheTabUnloadedAndLeavesItPinned() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://pinned.example.com")!, in: space.id, section: .pinned)

        store.closeTabKeepingPin(tabID)

        XCTAssertEqual(store.tab(tabID)?.isUnloaded, true, "The minus closes the running tab, so the tab must record that it is no longer open.")
        XCTAssertEqual(store.tab(tabID)?.section, .pinned, "The bookmark must survive: the row does not move out of Pinned.")
        XCTAssertTrue(
            store.pinnedNodes(in: space.id).flatMap(\.allTabIDs).contains(tabID),
            "The row must still be in the Pinned tree, not merely still flagged .pinned."
        )
    }

    func test_closeTabKeepingPin_vacatesTheActiveSlotRatherThanHandingItToAnotherTab() {
        let store = makeStore()
        let space = store.activeSpace!
        store.openTab(url: URL(string: "https://today.example.com")!, in: space.id)
        let pinnedTabID = store.openTab(url: URL(string: "https://pinned.example.com")!, in: space.id, section: .pinned)
        store.selectTab(pinnedTabID)
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), pinnedTabID)

        store.closeTabKeepingPin(pinnedTabID)

        XCTAssertNil(
            store.activeTabBySpaceForTesting(space.id),
            "The Space must not still be showing the tab that was just closed, and must not have handed the slot to any other open tab either — the empty/new-tab state is the honest outcome."
        )
    }

    func test_removeBookmark_takesTheRowOutOfPinnedAndArchivesIt() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://pinned.example.com")!, in: space.id, section: .pinned)

        store.removeBookmark(tabID)

        XCTAssertEqual(store.tab(tabID)?.section, .archived)
        XCTAssertFalse(
            store.pinnedNodes(in: space.id).flatMap(\.allTabIDs).contains(tabID),
            "Removing the bookmark must take the row out of the Pinned tree — that is the whole visible effect."
        )
        XCTAssertNotNil(store.tab(tabID), "Removing a bookmark archives; it does not delete. Only clearArchive deletes.")
    }

    func test_removeBookmark_isUndoneByReopenLastClosedTab_backIntoPinned() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://pinned.example.com")!, in: space.id, section: .pinned)
        let originalPinnedURL = store.tab(tabID)?.pinnedURL
        XCTAssertNotNil(originalPinnedURL)

        store.removeBookmark(tabID)
        store.reopenLastClosedTab()

        XCTAssertEqual(store.tab(tabID)?.section, .pinned)
        XCTAssertEqual(store.tab(tabID)?.pinnedURL, originalPinnedURL, "The pinned origin must survive a remove/undo round trip.")
    }

    func test_bookmarkVerbs_noOpOnATabThatIsNotPinned() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://today.example.com")!, in: space.id)

        store.closeTabKeepingPin(tabID)
        store.removeBookmark(tabID)

        XCTAssertEqual(store.tab(tabID)?.section, .today)
        XCTAssertEqual(store.tab(tabID)?.isUnloaded, false)
    }

    func test_clearArchive_permanentlyRemovesTabsFromState() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)
        store.archiveTab(tabID)

        store.clearArchive(in: space.id)

        XCTAssertNil(store.tab(tabID), "clearArchive is the only operation that actually deletes a Tab from state.tabs.")
    }

    // MARK: - Folder tree: insert / remove / move at depth

    func test_createFolder_addsEmptyFolderToPinnedRoot() {
        let store = makeStore()
        let space = store.activeSpace!

        let folderID = store.createFolder(name: "Work", in: space.id)

        let folder = store.folder(folderID, in: space.id)
        XCTAssertEqual(folder?.name, "Work")
        XCTAssertEqual(folder?.children.count, 0)
        XCTAssertTrue(store.pinnedNodes(in: space.id).contains { $0.id == folderID })
    }

    func test_moveNode_reparentsATabIntoANestedFolder() {
        let store = makeStore()
        let space = store.activeSpace!
        let outerID = store.createFolder(name: "Outer", in: space.id)
        let innerID = store.createFolder(name: "Inner", in: space.id, parent: outerID)
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id, section: .pinned)

        store.moveNode(tabID, toParent: innerID, atIndex: 0, in: space.id)

        let inner = store.folder(innerID, in: space.id)
        XCTAssertEqual(inner?.children.map(\.id), [tabID], "Tab must be reachable as a direct child of the deeply nested folder after the move.")
        let path = store.path(to: tabID, in: space.id)
        XCTAssertEqual(path?.count, 3, "A tab nested two folders deep (Outer > Inner > tab) should resolve to a 3-element path.")
    }

    func test_deleteFolder_hoistsChildrenRatherThanDestroyingThem() {
        let store = makeStore()
        let space = store.activeSpace!
        let folderID = store.createFolder(name: "Work", in: space.id)
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id, section: .pinned)
        store.moveNode(tabID, toParent: folderID, atIndex: 0, in: space.id)

        store.deleteFolder(folderID, in: space.id)

        XCTAssertNil(store.folder(folderID, in: space.id), "The folder itself must be gone.")
        XCTAssertTrue(store.pinnedNodes(in: space.id).contains { $0.id == tabID }, "Its child tab must survive, hoisted to where the folder was — deleteFolder must never destroy contents along with the folder.")
    }

    func test_removeFromAllContainers_removesNodeFromPinnedTreeAtAnyDepth() {
        let store = makeStore()
        let space = store.activeSpace!
        let folderID = store.createFolder(name: "Work", in: space.id)
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id, section: .pinned)
        store.moveNode(tabID, toParent: folderID, atIndex: 0, in: space.id)
        XCTAssertNotNil(store.path(to: tabID, in: space.id))

        store.archiveTab(tabID)

        XCTAssertNil(store.path(to: tabID, in: space.id), "A tab archived out of a nested folder must no longer resolve to any path in the Pinned tree.")
        XCTAssertTrue(store.folder(folderID, in: space.id)?.children.isEmpty ?? false)
    }

    // MARK: - Split view

    func test_createSplit_groupsTwoTabsWithEvenFractions() {
        let store = makeStore()
        let space = store.activeSpace!
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)

        let groupID = store.createSplit(with: [firstID, secondID])

        XCTAssertNotNil(groupID)
        let group = store.splitGroup(for: firstID)
        XCTAssertEqual(group?.tabIDs, [firstID, secondID])
        XCTAssertEqual(group?.fractions, [0.5, 0.5])
        XCTAssertEqual(store.tab(firstID)?.splitGroupID, groupID)
        XCTAssertEqual(store.tab(secondID)?.splitGroupID, groupID)
    }

    func test_createSplit_returnsNilWithFewerThanTwoValidTabs() {
        let store = makeStore()
        let space = store.activeSpace!
        let onlyID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)

        XCTAssertNil(store.createSplit(with: [onlyID]))
    }

    func test_createSplit_persistsAxis() {
        let store = makeStore()
        let space = store.activeSpace!
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)

        _ = store.createSplit(with: [firstID, secondID], axis: .vertical)

        XCTAssertEqual(store.splitGroup(for: firstID)?.axis, .vertical)
    }

    // MARK: - Flipping an existing split's orientation

    func test_setSplitAxis_flipsAnExistingGroup() {
        let store = makeStore()
        let space = store.activeSpace!
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)
        let groupID = store.createSplit(with: [firstID, secondID], axis: .horizontal)!

        let changed = store.setSplitAxis(.vertical, forGroup: groupID)

        XCTAssertTrue(changed, "flipping a horizontal split to vertical is a real change and must report as one")
        XCTAssertEqual(store.splitGroup(for: firstID)?.axis, .vertical)
    }

    func test_setSplitAxis_keepsEveryPaneAndEveryFraction() {
        let store = makeStore()
        let space = store.activeSpace!
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)
        let thirdID = store.openTab(url: URL(string: "https://three.example.com")!, in: space.id)
        let groupID = store.createSplit(with: [firstID, secondID, thirdID], axis: .horizontal)!
        store.setSplitFractions([0.5, 0.3, 0.2], forGroup: groupID)
        let fractionsBefore = store.splitGroup(for: firstID)?.fractions

        store.setSplitAxis(.vertical, forGroup: groupID)

        let group = store.splitGroup(for: firstID)
        XCTAssertEqual(group?.tabIDs, [firstID, secondID, thirdID], "a flip must not reorder or drop panes")
        XCTAssertEqual(group?.fractions, fractionsBefore, "a flip must not discard the pane sizes the user dragged")
        XCTAssertEqual(group?.axis, .vertical)
    }

    func test_setSplitAxis_isANoOpForTheAxisItAlreadyHas() {
        let store = makeStore()
        let space = store.activeSpace!
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)
        let groupID = store.createSplit(with: [firstID, secondID], axis: .horizontal)!

        XCTAssertFalse(
            store.setSplitAxis(.horizontal, forGroup: groupID),
            "setting the axis a group already has changes nothing, and must say so rather than dirtying the document"
        )
        XCTAssertFalse(store.setSplitAxis(.vertical, forGroup: UUID()), "an unknown group is not a flip")
    }

    func test_setSplitAxis_survivesASaveAndReload() throws {
        let store = makeStore()
        let space = store.activeSpace!
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)
        let groupID = store.createSplit(with: [firstID, secondID], axis: .horizontal)!

        store.setSplitAxis(.vertical, forGroup: groupID)
        try store.saveNow()

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        XCTAssertEqual(reloaded.splitGroups[groupID]?.axis, .vertical)
    }

    func test_addToSplit_appendsAndRenormalisesFractions() {
        let store = makeStore()
        let space = store.activeSpace!
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)
        let thirdID = store.openTab(url: URL(string: "https://three.example.com")!, in: space.id)
        let groupID = store.createSplit(with: [firstID, secondID])!

        let added = store.addToSplit(thirdID, groupID: groupID)

        XCTAssertTrue(added)
        let group = store.splitGroup(for: firstID)
        XCTAssertEqual(group?.tabIDs.count, 3)
        XCTAssertEqual(group?.fractions.count, 3)
        XCTAssertEqual(group?.fractions.reduce(0, +) ?? 0, 1.0, accuracy: 0.0001)
    }

    func test_splitGroup_capsAtFourPanes() {
        let store = makeStore()
        let space = store.activeSpace!
        let ids = (0..<5).map { store.openTab(url: URL(string: "https://\($0).example.com")!, in: space.id) }
        let groupID = store.createSplit(with: ids)!

        XCTAssertEqual(store.splitGroup(for: ids[0])?.tabIDs.count, 4, "SplitGroup.maximumPanes is 4 — createSplit must clamp, not silently accept a 5th pane.")

        let extraID = store.openTab(url: URL(string: "https://extra.example.com")!, in: space.id)
        let added = store.addToSplit(extraID, groupID: groupID)
        XCTAssertFalse(added, "addToSplit must refuse to grow an already-full (4-pane) group.")
        XCTAssertEqual(store.splitGroup(for: ids[0])?.tabIDs.count, 4)
    }

    func test_removeFromSplit_dissolvesGroupBelowTwoMembers() {
        let store = makeStore()
        let space = store.activeSpace!
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id)
        let groupID = store.createSplit(with: [firstID, secondID])!

        store.removeFromSplit(firstID)

        XCTAssertNil(store.tab(firstID)?.splitGroupID)
        XCTAssertNil(store.tab(secondID)?.splitGroupID, "Dropping to a single remaining member must dissolve the group entirely, not leave a 1-pane split.")
        XCTAssertNil(store.splitGroup(for: secondID))
        _ = groupID
    }

    func test_dissolveSplit_separatesEveryTab() {
        let store = makeStore()
        let space = store.activeSpace!
        let ids = (0..<3).map { store.openTab(url: URL(string: "https://\($0).example.com")!, in: space.id) }
        let groupID = store.createSplit(with: ids)!

        store.dissolveSplit(groupID)

        for id in ids {
            XCTAssertNil(store.tab(id)?.splitGroupID)
        }
        XCTAssertNil(store.splitGroup(for: ids[0]))
    }

    // MARK: - Favourites: cap at 12, cross-space mirroring

    func test_favorites_capAtTwelve() {
        let store = makeStore()
        let space = store.activeSpace!
        for existing in store.favorites(for: space.id) {
            store.removeFavorite(existing.id, from: space.id)
        }
        XCTAssertEqual(store.favorites(for: space.id).count, 0, "test precondition: bootstrap favourites cleared")

        for index in 0..<OrbitMetrics.favoritesMaximumCount {
            let outcome = store.addFavorite(url: URL(string: "https://\(index).example.com")!, title: "Site \(index)", in: space.id)
            guard case .added = outcome else {
                XCTFail("Adding favourite #\(index) should succeed (.added) — under the cap of \(OrbitMetrics.favoritesMaximumCount).")
                continue
            }
        }
        XCTAssertEqual(store.favorites(for: space.id).count, OrbitMetrics.favoritesMaximumCount)

        let overflow = store.addFavorite(url: URL(string: "https://overflow.example.com")!, title: "Overflow", in: space.id)
        XCTAssertEqual(
            overflow, .atCapacity,
            "The 13th favourite must be refused — OrbitMetrics.favoritesMaximumCount is 12 (refs/ARC_INTERACTION.md §3)."
        )
        XCTAssertEqual(store.favorites(for: space.id).count, OrbitMetrics.favoritesMaximumCount)
    }

    // MARK: - Favourites: duplicate detection (2026-08-06 fix)

    func test_addFavorite_exactDuplicate_returnsAlreadyExistsWithoutAddingASecondTile() {
        let store = makeStore()
        let space = store.activeSpace!
        for existing in store.favorites(for: space.id) {
            store.removeFavorite(existing.id, from: space.id)
        }

        guard case .added(let firstID) = store.addFavorite(url: URL(string: "https://example.com/page")!, title: "Page", in: space.id) else {
            XCTFail("Expected the first add to create a new favourite.")
            return
        }
        let secondOutcome = store.addFavorite(url: URL(string: "https://example.com/page")!, title: "Page Again", in: space.id)

        XCTAssertEqual(
            secondOutcome, .alreadyExists(firstID),
            "Re-adding the exact same URL must report the EXISTING favourite's id, not create a second tile."
        )
        XCTAssertEqual(store.favorites(for: space.id).count, 1, "A duplicate add must not grow the grid.")
    }

    func test_addFavorite_deduplicatesATrailingSlashOnlyDifference() {
        let store = makeStore()
        let space = store.activeSpace!
        for existing in store.favorites(for: space.id) {
            store.removeFavorite(existing.id, from: space.id)
        }

        guard case .added(let firstID) = store.addFavorite(url: URL(string: "https://example.com")!, title: "Home", in: space.id) else {
            XCTFail("Expected the first add to create a new favourite.")
            return
        }
        let outcome = store.addFavorite(url: URL(string: "https://example.com/")!, title: "Home Again", in: space.id)

        XCTAssertEqual(
            outcome, .alreadyExists(firstID),
            "`https://example.com` and `https://example.com/` are the same resource and must dedupe."
        )
        XCTAssertEqual(store.favorites(for: space.id).count, 1)
    }

    func test_addFavorite_deduplicatesSchemeCaseHostCaseAndDefaultPort() {
        let store = makeStore()
        let space = store.activeSpace!
        for existing in store.favorites(for: space.id) {
            store.removeFavorite(existing.id, from: space.id)
        }

        guard case .added(let firstID) = store.addFavorite(url: URL(string: "https://Example.com/Page")!, title: "Page", in: space.id) else {
            XCTFail("Expected the first add to create a new favourite.")
            return
        }
        let outcome = store.addFavorite(url: URL(string: "HTTPS://example.com:443/Page")!, title: "Page Again", in: space.id)

        XCTAssertEqual(
            outcome, .alreadyExists(firstID),
            "Scheme case, host case, and a scheme's own default port carry no distinguishing information."
        )
        XCTAssertEqual(store.favorites(for: space.id).count, 1)
    }

    func test_addFavorite_foldsATrailingSlashOnANonRootPathToo() {
        let store = makeStore()
        let space = store.activeSpace!
        for existing in store.favorites(for: space.id) {
            store.removeFavorite(existing.id, from: space.id)
        }

        guard case .added(let firstID) = store.addFavorite(url: URL(string: "https://example.com/docs")!, title: "Docs", in: space.id) else {
            XCTFail("Expected the first add to create a new favourite.")
            return
        }
        let outcome = store.addFavorite(url: URL(string: "https://example.com/docs/")!, title: "Docs Slash", in: space.id)

        XCTAssertEqual(outcome, .alreadyExists(firstID))
        XCTAssertEqual(store.favorites(for: space.id).count, 1)
    }

    func test_addFavorite_doesNotFoldAQueryOrAFragmentDifference() {
        let store = makeStore()
        let space = store.activeSpace!
        for existing in store.favorites(for: space.id) {
            store.removeFavorite(existing.id, from: space.id)
        }

        store.addFavorite(url: URL(string: "https://example.com/docs")!, title: "Docs", in: space.id)
        let queryDifference = store.addFavorite(url: URL(string: "https://example.com/docs?tab=2")!, title: "Docs Tab 2", in: space.id)
        let fragmentDifference = store.addFavorite(url: URL(string: "https://example.com/docs#section")!, title: "Docs Section", in: space.id)

        for outcome in [queryDifference, fragmentDifference] {
            guard case .added = outcome else {
                XCTFail("A genuinely different query/fragment must not be folded into an existing favourite.")
                continue
            }
        }
        XCTAssertEqual(store.favorites(for: space.id).count, 3, "The base URL, the query variant, and the fragment variant are three distinct resources.")
    }

    func test_promoteTabToFavorite_alreadyFavourited_bindsRatherThanDuplicating() {
        let store = makeStore()
        let space = store.activeSpace!
        for existing in store.favorites(for: space.id) {
            store.removeFavorite(existing.id, from: space.id)
        }
        guard case .added(let favoriteID) = store.addFavorite(url: URL(string: "https://example.com/")!, title: "Home", in: space.id) else {
            XCTFail("Expected the first add to create a new favourite.")
            return
        }
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id, activate: false)

        let outcome = store.promoteTabToFavorite(tabID)

        XCTAssertEqual(
            outcome, .alreadyExists(favoriteID),
            "Dragging a tab whose URL is already favourited (even with a bare trailing-slash difference) must not create a second tile."
        )
        XCTAssertEqual(store.favorites(for: space.id).count, 1)
        XCTAssertEqual(
            store.favorite(favoriteID, in: space.id)?.liveTabID, tabID,
            "The existing favourite must be bound to the dragged tab, the same way a genuinely new one would be."
        )
    }

    func test_promoteTabToFavorite_atCapacity_reportsCapacityWithoutMutating() {
        let store = makeStore()
        let space = store.activeSpace!
        for existing in store.favorites(for: space.id) {
            store.removeFavorite(existing.id, from: space.id)
        }
        for index in 0..<OrbitMetrics.favoritesMaximumCount {
            store.addFavorite(url: URL(string: "https://\(index).example.com")!, title: "Site \(index)", in: space.id)
        }
        XCTAssertEqual(store.favorites(for: space.id).count, OrbitMetrics.favoritesMaximumCount, "test precondition: at the cap")
        let tabID = store.openTab(url: URL(string: "https://overflow.example.com")!, in: space.id, activate: false)

        let outcome = store.promoteTabToFavorite(tabID)

        XCTAssertEqual(
            outcome, .atCapacity,
            "A Space already at OrbitMetrics.favoritesMaximumCount must refuse a new favourite rather than silently doing nothing unreported."
        )
        XCTAssertEqual(store.favorites(for: space.id).count, OrbitMetrics.favoritesMaximumCount)
    }

    func test_favorites_mirrorAcrossSpacesOnTheSameProfile() {
        let store = makeStore()
        let firstSpace = store.activeSpace!
        let secondSpaceID = store.createSpace(name: "Second", profileID: firstSpace.profileID, activate: false)

        store.addFavorite(url: URL(string: "https://shared.example.com")!, title: "Shared", in: firstSpace.id)

        XCTAssertTrue(
            store.favorites(for: secondSpaceID).contains { $0.url == URL(string: "https://shared.example.com")! },
            "A favourite added on one Space must be mirrored onto every sibling Space sharing the same Profile (BrowserStore+Spaces.swift's mutateSpace/mirrorFavoriteChange)."
        )
    }

    func test_favorites_removalAlsoMirrorsAcrossSpaces() {
        let store = makeStore()
        let firstSpace = store.activeSpace!
        let secondSpaceID = store.createSpace(name: "Second", profileID: firstSpace.profileID, activate: false)
        guard case .added(let favoriteID) = store.addFavorite(url: URL(string: "https://shared.example.com")!, title: "Shared", in: firstSpace.id) else {
            XCTFail("Expected a fresh favourite to be added.")
            return
        }

        store.removeFavorite(favoriteID, from: firstSpace.id)

        XCTAssertFalse(
            store.favorites(for: secondSpaceID).contains { $0.url == URL(string: "https://shared.example.com")! },
            "Removing a shared favourite on one Space must remove it from every sibling Space on the same Profile too."
        )
    }

    func test_favorites_doNotMirrorAcrossDifferentProfiles() {
        let store = makeStore()
        let firstSpace = store.activeSpace!
        let otherProfileID = store.createProfile(name: "Work")
        let otherSpaceID = store.createSpace(name: "Other Profile Space", profileID: otherProfileID, activate: false)

        store.addFavorite(url: URL(string: "https://shared.example.com")!, title: "Shared", in: firstSpace.id)

        XCTAssertFalse(
            store.favorites(for: otherSpaceID).contains { $0.url == URL(string: "https://shared.example.com")! },
            "Favourites must only mirror within the same Profile — a Space on a different Profile must not receive it."
        )
    }

    // MARK: - Auto-archive sweep

    func test_runArchiveSweep_archivesATodayTabPastItsPolicyInterval() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let tabID = store.openTab(url: URL(string: "https://stale.example.com")!, in: space.id, activate: false)
        store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)

        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(tabID)?.section, .archived, "A Today tab whose lastAccessedAt is older than its Profile's ArchivePolicy interval must be swept into Archive.")
    }

    func test_runArchiveSweep_neverArchivesTheActiveTab() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let tabID = store.openTab(url: URL(string: "https://active.example.com")!, in: space.id, activate: true)
        store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)

        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(tabID)?.section, .today, "The active tab must never be auto-archived out from under the user, however stale lastAccessedAt is.")
    }

    func test_runArchiveSweep_honoursNeverPolicy() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.never, forProfile: space.profileID)
        let tabID = store.openTab(url: URL(string: "https://stale.example.com")!, in: space.id, activate: false)
        store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-365 * 24 * 3600)

        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(tabID)?.section, .today, "ArchivePolicy.never must mean never, regardless of staleness.")
    }

    func test_runArchiveSweep_doesNotArchiveATabInAnActiveSplit() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let firstID = store.openTab(url: URL(string: "https://one.example.com")!, in: space.id, activate: false)
        let secondID = store.openTab(url: URL(string: "https://two.example.com")!, in: space.id, activate: false)
        store.createSplit(with: [firstID, secondID])
        store.state.tabs[firstID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)
        store.state.tabs[secondID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)

        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(firstID)?.section, .today, "A tab in an active split group is a deliberate arrangement — the sweep must not archive it out from under the split.")
        XCTAssertEqual(store.tab(secondID)?.section, .today)
    }

    func test_runArchiveSweep_doesNotArchiveATabPlayingMedia() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let playingID = store.openTab(url: URL(string: "https://video.example.com")!, in: space.id, activate: false)
        let silentID = store.openTab(url: URL(string: "https://silent.example.com")!, in: space.id, activate: false)
        store.state.tabs[playingID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)
        store.state.tabs[silentID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)

        store.setMediaState(MediaState(hasVideo: true, isPlaying: true), forTab: playingID)

        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(playingID)?.section, .today,
                       "A tab playing media must not be archived out from under playback.")
        XCTAssertEqual(store.tab(silentID)?.section, .archived,
                       "…and an equally stale tab that is not playing anything still must be, or the exemption is just a broken sweep.")
    }

    func test_runArchiveSweep_exemptsAMutedButPlayingTab() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let tabID = store.openTab(url: URL(string: "https://muted.example.com")!, in: space.id, activate: false)
        store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)

        store.setMediaState(MediaState(isMuted: true, hasVideo: true, isPlaying: true), forTab: tabID)
        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(tabID)?.section, .today)
    }

    func test_runArchiveSweep_archivesOnceMediaStops() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let tabID = store.openTab(url: URL(string: "https://video.example.com")!, in: space.id, activate: false)
        store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)

        store.setMediaState(MediaState(hasVideo: true, isPlaying: true), forTab: tabID)
        store.runArchiveSweep(now: Date())
        XCTAssertEqual(store.tab(tabID)?.section, .today, "precondition: the exemption is in force")

        store.setMediaState(MediaState(hasVideo: true, isPlaying: false), forTab: tabID)
        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(tabID)?.section, .archived,
                       "once the page stops playing, the tab is an ordinary stale Today tab again")
    }

    func test_clearMediaState_endsTheExemption() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let tabID = store.openTab(url: URL(string: "https://video.example.com")!, in: space.id, activate: false)
        store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)

        store.setMediaState(MediaState(isAudible: true, isPlaying: true), forTab: tabID)
        store.clearMediaState(forTab: tabID)
        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(tabID)?.section, .archived)
    }

    func test_runArchiveSweep_leavesFreshTabsAlone() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let tabID = store.openTab(url: URL(string: "https://fresh.example.com")!, in: space.id, activate: false)

        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(tabID)?.section, .today, "A just-opened tab is nowhere near its ArchivePolicy interval and must not be swept.")
    }
}

// MARK: - Test-only access helpers

extension BrowserStore {
    func activeTabBySpaceForTesting(_ spaceID: SpaceID) -> TabID? {
        state.activeTabBySpace[spaceID]
    }
}
