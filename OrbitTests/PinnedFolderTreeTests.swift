import XCTest

@MainActor
final class PinnedFolderTreeTests: XCTestCase {

    // MARK: - Fixture (mirrors StoreTests.swift's own pattern)

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-PinnedFolderTree-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - "+" menu / discoverable creation

    func test_plusMenuNewFolder_isImmediatelyVisibleInPinnedRoot() {
        let store = makeStore()
        let space = store.activeSpace!
        XCTAssertTrue(store.pinnedNodes(in: space.id).isEmpty, "test precondition: Pinned starts empty")

        let folderID = store.createFolder(name: "New Folder", in: space.id)

        let rootNodes = store.pinnedNodes(in: space.id)
        XCTAssertEqual(rootNodes.map(\.id), [folderID], "The new folder must be the only, directly-visible root node PinnedSectionView's ForEach(nodes) would render.")
        guard case .folder(let folder) = rootNodes.first else {
            return XCTFail("Expected the root's sole node to be a folder.")
        }
        XCTAssertEqual(folder.name, "New Folder")
        XCTAssertTrue(folder.children.isEmpty)
    }

    func test_newFolderInside_nestsUnderParentAtDepthTwo() {
        let store = makeStore()
        let space = store.activeSpace!
        let parentID = store.createFolder(name: "Reading", in: space.id)

        let nestedID = store.createFolder(name: "New Folder", in: space.id, parent: parentID)

        let parent = store.folder(parentID, in: space.id)
        XCTAssertEqual(parent?.children.map(\.id), [nestedID], "The nested folder must be a direct child of the folder it was created inside.")
        let path = store.path(to: nestedID, in: space.id)
        XCTAssertEqual(path?.count, 2, "Reading > New Folder is two nesting levels deep: a 2-element path, matching the depth SidebarNodeRow's recursion would pass its row (depth 1).")
    }

    // MARK: - Drag a tab onto a tab creates a folder (Arc's grouping gesture)

    func test_dragTabOntoTab_createsNewFolderContainingBothInOrder() throws {
        let store = makeStore()
        let space = store.activeSpace!
        let targetTabID = store.openTab(url: URL(string: "https://example.com/target")!, in: space.id, section: .pinned)
        let draggedTabID = store.openTab(url: URL(string: "https://example.com/dragged")!, in: space.id, section: .pinned)

        let nodesBefore = store.pinnedNodes(in: space.id)
        XCTAssertEqual(nodesBefore.map(\.id), [targetTabID, draggedTabID], "test precondition: two pinned tabs, siblings at the root")

        guard let location = PinnedTreeLocation.locate(targetTabID, in: nodesBefore) else {
            return XCTFail("The drop target must be locatable in the Pinned forest before grouping can proceed.")
        }
        let newFolderID = store.createFolder(name: "New Folder", in: space.id, parent: location.parent, at: location.index)
        store.moveNode(targetTabID, toParent: newFolderID, atIndex: 0, in: space.id)
        store.moveNode(draggedTabID, toParent: newFolderID, atIndex: 1, in: space.id)

        let nodesAfter = store.pinnedNodes(in: space.id)
        XCTAssertEqual(nodesAfter.count, 1, "Both tabs must now live inside one folder at the root, not remain two sibling tabs.")
        guard case .folder(let folder) = nodesAfter.first else {
            return XCTFail("Expected the sole remaining root node to be the newly created folder.")
        }
        XCTAssertEqual(folder.id, newFolderID)
        XCTAssertEqual(folder.children.map(\.id), [targetTabID, draggedTabID], "The folder must contain exactly the two grouped tabs, target first then dragged.")
        XCTAssertEqual(store.path(to: targetTabID, in: space.id)?.count, 2, "The target tab must now resolve one level deep (new-folder > target), not as a root-level node.")
    }

    func test_dragUnpinnedTodayTabOntoAPinnedTab_pinsItIntoTheNewFolder() throws {
        let store = makeStore()
        let space = store.activeSpace!
        let pinnedTabID = store.openTab(url: URL(string: "https://example.com/pinned")!, in: space.id, section: .pinned)
        let todayTabID = store.openTab(url: URL(string: "https://example.com/today")!, in: space.id, section: .today)
        XCTAssertEqual(store.tab(todayTabID)?.section, .today, "test precondition")

        store.pin(todayTabID)

        let nodesBefore = store.pinnedNodes(in: space.id)
        guard let location = PinnedTreeLocation.locate(pinnedTabID, in: nodesBefore) else {
            return XCTFail("The pinned target must be locatable.")
        }
        let newFolderID = store.createFolder(name: "New Folder", in: space.id, parent: location.parent, at: location.index)
        store.moveNode(pinnedTabID, toParent: newFolderID, atIndex: 0, in: space.id)
        store.moveNode(todayTabID, toParent: newFolderID, atIndex: 1, in: space.id)

        XCTAssertEqual(store.tab(todayTabID)?.section, .pinned, "The formerly-Today tab must now be pinned.")
        let folder = store.folder(newFolderID, in: space.id)
        XCTAssertEqual(folder?.children.map(\.id), [pinnedTabID, todayTabID])
    }

    func test_dragFolderOntoItsOwnDescendant_wouldOnlyBePartiallyAppliedWithoutTheGuard() throws {
        let store = makeStore()
        let space = store.activeSpace!
        let childTabID = store.openTab(url: URL(string: "https://example.com/child")!, in: space.id, section: .pinned)
        let folderID = store.createFolder(name: "Parent", in: space.id)
        store.moveNode(childTabID, toParent: folderID, atIndex: 0, in: space.id)

        let nodes = store.pinnedNodes(in: space.id)
        XCTAssertTrue(
            PinnedNodeTree.isDescendant(childTabID, ofOrEqualTo: folderID, in: nodes),
            "This is exactly the condition PinnedSectionView.groupIntoNewFolder checks up front to refuse the whole operation."
        )

        guard let location = PinnedTreeLocation.locate(childTabID, in: nodes) else {
            return XCTFail("child should be locatable")
        }
        let newFolderID = store.createFolder(name: "New Folder", in: space.id, parent: location.parent, at: location.index)
        store.moveNode(childTabID, toParent: newFolderID, atIndex: 0, in: space.id)
        let beforeSecondMove = store.pinnedNodes(in: space.id)

        store.moveNode(folderID, toParent: newFolderID, atIndex: 1, in: space.id)
        let afterSecondMove = store.pinnedNodes(in: space.id)

        XCTAssertEqual(afterSecondMove, beforeSecondMove, "PinnedNodeTree.moveNode correctly refuses to nest a folder inside its own descendant, but only stops the second of the two moves — proving why groupIntoNewFolder's own up-front isDescendant guard, which prevents the sequence from starting at all, is necessary rather than redundant.")
    }
}
