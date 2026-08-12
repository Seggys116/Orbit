//  Regression coverage for two controls reported dead: Split View and the Space switcher.
//  Runs against the real BrowserStore, the layer AppEnvironment's addSplitToActiveTab()/selectSpace(_:) wrap.

import XCTest

@MainActor
final class R3SpacesAndSplitViewStoreTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-R3-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Split View

    func test_addSplitFlow_bothTabsEndUpInOneRenderableSplitGroup() {
        let store = makeStore()
        let space = store.activeSpace!
        let existingTabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)
        let blankTabID = store.openTab(url: URL(string: "orbit://new-tab")!, in: space.id, section: .today, activate: false)

        XCTAssertNil(store.splitGroup(for: existingTabID), "test precondition: not already split")

        let groupID = store.createSplit(with: [existingTabID, blankTabID], axis: .horizontal)

        XCTAssertNotNil(groupID, "createSplit returned nil — the split was never created.")
        let existingGroup = store.splitGroup(for: existingTabID)
        let blankGroup = store.splitGroup(for: blankTabID)
        XCTAssertEqual(existingGroup?.id, groupID, "The originally active tab isn't in the new split group.")
        XCTAssertEqual(blankGroup?.id, groupID, "The new blank pane isn't in the new split group.")
        XCTAssertEqual(existingGroup?.tabIDs, [existingTabID, blankTabID], "Panes are not in left-to-right creation order.")
        XCTAssertEqual(existingGroup?.fractions, [0.5, 0.5], "A fresh two-pane split must start with even fractions.")
    }

    func test_addSplitFlow_secondInvocation_extendsTheExistingGroupUpToFour() {
        let store = makeStore()
        let space = store.activeSpace!
        let firstTabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)
        let secondTabID = store.openTab(url: URL(string: "orbit://new-tab")!, in: space.id, section: .today, activate: false)
        let groupID = store.createSplit(with: [firstTabID, secondTabID], axis: .horizontal)!

        let thirdTabID = store.openTab(url: URL(string: "orbit://new-tab")!, in: space.id, section: .today, activate: false)
        let addedGroupID = store.splitGroup(for: firstTabID)?.id
        XCTAssertEqual(addedGroupID, groupID)
        XCTAssertTrue(store.addToSplit(thirdTabID, groupID: groupID))

        let group = store.splitGroup(for: firstTabID)
        XCTAssertEqual(group?.tabIDs.count, 3, "The 3rd pane didn't join the existing group.")
        XCTAssertTrue(group?.tabIDs.contains(thirdTabID) ?? false)
    }

    // MARK: - Spaces

    func test_switchToSpace_withMultipleSpaces_actuallyMovesActiveSpaceID() {
        let store = makeStore()
        let firstSpace = store.activeSpace!
        let secondSpaceID = store.createSpace(name: "Work", profileID: firstSpace.profileID)

        XCTAssertEqual(store.activeSpace?.id, secondSpaceID, "test precondition: createSpace(activate: true) should have switched already")

        store.switchToSpace(firstSpace.id)
        XCTAssertEqual(store.activeSpace?.id, firstSpace.id, "switchToSpace(_:) back to the first Space had no effect.")

        store.switchToSpace(secondSpaceID)
        XCTAssertEqual(store.activeSpace?.id, secondSpaceID, "switchToSpace(_:) to the second Space had no effect.")
    }

    func test_nextAndPreviousSpace_cycleThroughAllSpacesAndWrap() {
        let store = makeStore()
        let firstSpace = store.activeSpace!
        let secondSpaceID = store.createSpace(name: "Work", profileID: firstSpace.profileID, activate: false)
        let thirdSpaceID = store.createSpace(name: "Play", profileID: firstSpace.profileID, activate: false)
        store.switchToSpace(firstSpace.id)

        store.nextSpace()
        XCTAssertEqual(store.activeSpace?.id, secondSpaceID)
        store.nextSpace()
        XCTAssertEqual(store.activeSpace?.id, thirdSpaceID)
        store.nextSpace()
        XCTAssertEqual(store.activeSpace?.id, firstSpace.id, "nextSpace() from the last Space must wrap to the first.")

        store.previousSpace()
        XCTAssertEqual(store.activeSpace?.id, thirdSpaceID, "previousSpace() from the first Space must wrap to the last.")
    }

    func test_switchToSpace_toTheAlreadyActiveSpace_isHarmless() {
        let store = makeStore()
        let space = store.activeSpace!
        store.switchToSpace(space.id)
        XCTAssertEqual(store.activeSpace?.id, space.id)
    }
}
