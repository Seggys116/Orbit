//  Every store here is on a StateStore pointed at a scratch directory, never the real profile.

import XCTest

@MainActor
final class BookmarkMutationRouterTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: BrowserStore!
    private var spaceA: SpaceID!
    private var spaceB: SpaceID!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-Bookmarks-\(UUID().uuidString)", isDirectory: true)
        store = BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
        spaceA = store.activeSpace!.id
        // A second Profile, so a Favourite mutation in one Space is not mirrored into the other.
        let profileB = store.createProfile(name: "Work")
        spaceB = store.createSpace(name: "Work", profileID: profileB, activate: false)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        store = nil
        spaceA = nil
        spaceB = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func apply(
        _ method: String, _ args: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) throws -> BookmarkNodeID {
        try BookmarkMutationRouter.apply(method: method, args: args, store: store)
    }

    private func assertRefused(
        _ method: String, _ args: [String: Any], _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let id = try BookmarkMutationRouter.apply(method: method, args: args, store: store)
            XCTFail("\(method) succeeded with \(id.rawValue) instead of refusing", file: file, line: line)
        } catch let error as BookmarkMutationError {
            XCTAssertEqual(error.message, message, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func node(_ id: BookmarkNodeID) -> [String: Any]? {
        func find(_ node: [String: Any]) -> [String: Any]? {
            if node["id"] as? String == id.rawValue { return node }
            for child in node["children"] as? [[String: Any]] ?? [] {
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(BookmarkTreeProjection.treeObject(for: store.state))
    }

    private func childIDs(of id: BookmarkNodeID) -> [String] {
        (node(id)?["children"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private func createFolder(_ name: String, in spaceID: SpaceID, parent: BookmarkNodeID? = nil) throws -> FolderID {
        let node = try apply("create", ["parentId": (parent ?? .pinned(spaceID)).rawValue, "title": name])
        guard case .pinnedFolder(let folderID) = node else {
            throw BookmarkMutationError("expected a folder, got \(node.rawValue)")
        }
        return folderID
    }

    private func createBookmark(
        _ title: String, _ url: String, parent: BookmarkNodeID, index: Int? = nil
    ) throws -> TabID {
        var args: [String: Any] = ["parentId": parent.rawValue, "title": title, "url": url]
        if let index { args["index"] = index }
        let node = try apply("create", args)
        guard case .pinnedTab(let tabID) = node else {
            throw BookmarkMutationError("expected a bookmark, got \(node.rawValue)")
        }
        return tabID
    }

    // MARK: - create

    func testCreatingAPinnedBookmarkOpensAPinnedTabWithTheGivenTitle() throws {
        let tabID = try createBookmark("Orbit docs", "https://docs.example.com", parent: .pinned(spaceA))

        XCTAssertEqual(store.tab(tabID)?.section, .pinned)
        XCTAssertEqual(store.tab(tabID)?.spaceID, spaceA)
        XCTAssertTrue(store.pinnedNodes(in: spaceA).contains { $0.id == tabID })
        XCTAssertEqual(node(.pinnedTab(tabID))?["title"] as? String, "Orbit docs")
        XCTAssertEqual(node(.pinnedTab(tabID))?["url"] as? String, "https://docs.example.com")
        XCTAssertEqual(node(.pinnedTab(tabID))?["parentId"] as? String, BookmarkNodeID.pinned(spaceA).rawValue)
    }

    func testCreatingAPinnedFolderHonoursTheRequestedIndex() throws {
        let first = try createFolder("First", in: spaceA)
        let second = try apply("create", [
            "parentId": BookmarkNodeID.pinned(spaceA).rawValue, "title": "Second", "index": 0,
        ])

        XCTAssertEqual(childIDs(of: .pinned(spaceA)).first, second.rawValue)
        XCTAssertEqual(childIDs(of: .pinned(spaceA)).last, BookmarkNodeID.pinnedFolder(first).rawValue)
    }

    func testCreatingInsideAFolderNestsTheNewBookmark() throws {
        let folderID = try createFolder("Reading", in: spaceA)
        let tabID = try createBookmark("Article", "https://read.example.com", parent: .pinnedFolder(folderID))

        XCTAssertEqual(childIDs(of: .pinnedFolder(folderID)), [BookmarkNodeID.pinnedTab(tabID).rawValue])
    }

    func testCreatingAFavouriteAddsItToTheSpacesFavouritesAtTheRequestedIndex() throws {
        let first = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Alpha", "url": "https://alpha.example.com",
        ])
        let second = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Beta",
            "url": "https://beta.example.com", "index": 0,
        ])

        XCTAssertEqual(store.favorites(for: spaceB).count, 2)
        XCTAssertEqual(childIDs(of: .favorites(spaceB)), [second.rawValue, first.rawValue])
        XCTAssertEqual(node(second)?["title"] as? String, "Beta")
    }

    func testCreatingAFavouriteBeyondTheSpaceLimitIsRefused() throws {
        for index in 0..<OrbitMetrics.favoritesMaximumCount {
            store.addFavorite(url: URL(string: "https://filler-\(index).example.com")!, title: "Filler", in: spaceB)
        }
        XCTAssertEqual(store.favorites(for: spaceB).count, OrbitMetrics.favoritesMaximumCount)

        assertRefused(
            "create",
            ["parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "One too many", "url": "https://over.example.com"],
            BookmarkErrors.favoritesAtCapacity
        )
    }

    // MARK: - move

    func testMovingAPinnedTabWithinItsFolderReordersIt() throws {
        let folderID = try createFolder("Reading", in: spaceA)
        let first = try createBookmark("First", "https://one.example.com", parent: .pinnedFolder(folderID))
        let second = try createBookmark("Second", "https://two.example.com", parent: .pinnedFolder(folderID))

        try apply("move", ["id": BookmarkNodeID.pinnedTab(second).rawValue, "index": 0])

        XCTAssertEqual(childIDs(of: .pinnedFolder(folderID)), [
            BookmarkNodeID.pinnedTab(second).rawValue,
            BookmarkNodeID.pinnedTab(first).rawValue,
        ])
    }

    // Chrome reads the index against the list with the node still in it, so moving the first of
    // three to index 2 lands it in the middle. Removing first and inserting would overshoot.
    func testMovingDownWithinOneParentUsesChromesPreRemovalIndex() throws {
        let folderID = try createFolder("Reading", in: spaceA)
        let a = try createBookmark("A", "https://a.example.com", parent: .pinnedFolder(folderID))
        let b = try createBookmark("B", "https://b.example.com", parent: .pinnedFolder(folderID))
        let c = try createBookmark("C", "https://c.example.com", parent: .pinnedFolder(folderID))

        try apply("move", ["id": BookmarkNodeID.pinnedTab(a).rawValue, "index": 2])

        XCTAssertEqual(childIDs(of: .pinnedFolder(folderID)), [
            BookmarkNodeID.pinnedTab(b).rawValue,
            BookmarkNodeID.pinnedTab(a).rawValue,
            BookmarkNodeID.pinnedTab(c).rawValue,
        ])
    }

    func testMovingToItsOwnIndexOrTheOneAfterItLeavesTheOrderUntouched() throws {
        let folderID = try createFolder("Reading", in: spaceA)
        let a = try createBookmark("A", "https://a.example.com", parent: .pinnedFolder(folderID))
        let b = try createBookmark("B", "https://b.example.com", parent: .pinnedFolder(folderID))
        let c = try createBookmark("C", "https://c.example.com", parent: .pinnedFolder(folderID))
        let original = [a, b, c].map { BookmarkNodeID.pinnedTab($0).rawValue }

        try apply("move", ["id": BookmarkNodeID.pinnedTab(b).rawValue, "index": 1])
        XCTAssertEqual(childIDs(of: .pinnedFolder(folderID)), original)

        try apply("move", ["id": BookmarkNodeID.pinnedTab(b).rawValue, "index": 2])
        XCTAssertEqual(childIDs(of: .pinnedFolder(folderID)), original)
    }

    func testMovingUpWithinOneParentDoesNotDecrementTheIndex() throws {
        let folderID = try createFolder("Reading", in: spaceA)
        let a = try createBookmark("A", "https://a.example.com", parent: .pinnedFolder(folderID))
        let b = try createBookmark("B", "https://b.example.com", parent: .pinnedFolder(folderID))
        let c = try createBookmark("C", "https://c.example.com", parent: .pinnedFolder(folderID))

        try apply("move", ["id": BookmarkNodeID.pinnedTab(c).rawValue, "index": 0])

        XCTAssertEqual(childIDs(of: .pinnedFolder(folderID)), [
            BookmarkNodeID.pinnedTab(c).rawValue,
            BookmarkNodeID.pinnedTab(a).rawValue,
            BookmarkNodeID.pinnedTab(b).rawValue,
        ])
    }

    func testMovingIntoAnotherParentDoesNotDecrementTheIndex() throws {
        let source = try createFolder("Source", in: spaceA)
        let destination = try createFolder("Destination", in: spaceA)
        let a = try createBookmark("A", "https://a.example.com", parent: .pinnedFolder(source))
        let x = try createBookmark("X", "https://x.example.com", parent: .pinnedFolder(destination))
        let y = try createBookmark("Y", "https://y.example.com", parent: .pinnedFolder(destination))

        try apply("move", [
            "id": BookmarkNodeID.pinnedTab(a).rawValue,
            "parentId": BookmarkNodeID.pinnedFolder(destination).rawValue,
            "index": 1,
        ])

        XCTAssertEqual(childIDs(of: .pinnedFolder(destination)), [
            BookmarkNodeID.pinnedTab(x).rawValue,
            BookmarkNodeID.pinnedTab(a).rawValue,
            BookmarkNodeID.pinnedTab(y).rawValue,
        ])
    }

    func testMovingAFavouriteDownUsesTheSamePreRemovalIndex() throws {
        let alpha = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Alpha", "url": "https://alpha.example.com",
        ])
        let beta = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Beta", "url": "https://beta.example.com",
        ])
        let gamma = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Gamma", "url": "https://gamma.example.com",
        ])

        try apply("move", ["id": alpha.rawValue, "index": 2])
        XCTAssertEqual(childIDs(of: .favorites(spaceB)), [beta.rawValue, alpha.rawValue, gamma.rawValue])

        try apply("move", ["id": alpha.rawValue, "index": 1])
        XCTAssertEqual(
            childIDs(of: .favorites(spaceB)), [beta.rawValue, alpha.rawValue, gamma.rawValue],
            "a favourite moved to its own index must not shift"
        )

        try apply("move", ["id": alpha.rawValue, "index": 2])
        XCTAssertEqual(
            childIDs(of: .favorites(spaceB)), [beta.rawValue, alpha.rawValue, gamma.rawValue],
            "a favourite moved to the index just after itself must not shift"
        )
    }

    func testMovingAPinnedTabBetweenFoldersReparentsIt() throws {
        let source = try createFolder("Source", in: spaceA)
        let destination = try createFolder("Destination", in: spaceA)
        let tabID = try createBookmark("Article", "https://read.example.com", parent: .pinnedFolder(source))

        try apply("move", [
            "id": BookmarkNodeID.pinnedTab(tabID).rawValue,
            "parentId": BookmarkNodeID.pinnedFolder(destination).rawValue,
        ])

        XCTAssertEqual(childIDs(of: .pinnedFolder(source)), [])
        XCTAssertEqual(childIDs(of: .pinnedFolder(destination)), [BookmarkNodeID.pinnedTab(tabID).rawValue])
    }

    func testMovingAPinnedTabToAnotherSpaceReparentsTheTabItself() throws {
        let tabID = try createBookmark("Article", "https://read.example.com", parent: .pinned(spaceA))

        try apply("move", [
            "id": BookmarkNodeID.pinnedTab(tabID).rawValue,
            "parentId": BookmarkNodeID.pinned(spaceB).rawValue,
        ])

        XCTAssertEqual(store.tab(tabID)?.spaceID, spaceB)
        XCTAssertEqual(store.tab(tabID)?.section, .pinned)
        XCTAssertFalse(store.pinnedNodes(in: spaceA).contains { $0.id == tabID })
        XCTAssertEqual(childIDs(of: .pinned(spaceB)), [BookmarkNodeID.pinnedTab(tabID).rawValue])
    }

    func testMovingAFolderWithinItsSpaceReordersIt() throws {
        let first = try createFolder("First", in: spaceA)
        let second = try createFolder("Second", in: spaceA)

        try apply("move", ["id": BookmarkNodeID.pinnedFolder(second).rawValue, "index": 0])

        XCTAssertEqual(childIDs(of: .pinned(spaceA)), [
            BookmarkNodeID.pinnedFolder(second).rawValue,
            BookmarkNodeID.pinnedFolder(first).rawValue,
        ])
    }

    func testMovingAFavouriteWithinFavouritesReordersIt() throws {
        let first = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Alpha", "url": "https://alpha.example.com",
        ])
        let second = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Beta", "url": "https://beta.example.com",
        ])

        try apply("move", ["id": second.rawValue, "index": 0])

        XCTAssertEqual(childIDs(of: .favorites(spaceB)), [second.rawValue, first.rawValue])
    }

    // MARK: - update

    func testUpdatingAFavouriteRewritesItsTitleAndUrl() throws {
        let favorite = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Alpha", "url": "https://alpha.example.com",
        ])

        try apply("update", ["id": favorite.rawValue, "title": "Renamed", "url": "https://renamed.example.com"])

        XCTAssertEqual(node(favorite)?["title"] as? String, "Renamed")
        XCTAssertEqual(node(favorite)?["url"] as? String, "https://renamed.example.com")
    }

    func testUpdatingAPinnedBookmarkRewritesItsTitleAndUrl() throws {
        let tabID = try createBookmark("Article", "https://read.example.com", parent: .pinned(spaceA))

        try apply("update", [
            "id": BookmarkNodeID.pinnedTab(tabID).rawValue, "title": "Renamed", "url": "https://renamed.example.com",
        ])

        XCTAssertEqual(node(.pinnedTab(tabID))?["title"] as? String, "Renamed")
        XCTAssertEqual(node(.pinnedTab(tabID))?["url"] as? String, "https://renamed.example.com")
    }

    func testUpdatingTheTitleOfATabPinnedByOrbitItselfIsVisibleInTheTree() throws {
        let tabID = store.openTab(url: URL(string: "https://pinned.example.com")!, in: spaceA, activate: false)
        store.pin(tabID, capturedTitle: "Captured title")
        XCTAssertNotNil(store.tab(tabID)?.pinnedTitle, "a pin-time title must not shadow the rename")

        try apply("update", ["id": BookmarkNodeID.pinnedTab(tabID).rawValue, "title": "Renamed by an extension"])

        XCTAssertEqual(node(.pinnedTab(tabID))?["title"] as? String, "Renamed by an extension")
    }

    func testUpdatingAFolderRewritesItsName() throws {
        let folderID = try createFolder("Reading", in: spaceA)

        try apply("update", ["id": BookmarkNodeID.pinnedFolder(folderID).rawValue, "title": "Renamed"])

        XCTAssertEqual(store.folder(folderID, in: spaceA)?.name, "Renamed")
        XCTAssertEqual(node(.pinnedFolder(folderID))?["title"] as? String, "Renamed")
    }

    // MARK: - remove / removeTree

    func testRemovingAFavouriteDropsItFromTheSpace() throws {
        let favorite = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Alpha", "url": "https://alpha.example.com",
        ])

        try apply("remove", ["id": favorite.rawValue])

        XCTAssertEqual(store.favorites(for: spaceB).count, 0)
        XCTAssertNil(node(favorite))
    }

    func testRemovingAPinnedBookmarkArchivesItsTab() throws {
        let tabID = try createBookmark("Article", "https://read.example.com", parent: .pinned(spaceA))

        try apply("remove", ["id": BookmarkNodeID.pinnedTab(tabID).rawValue])

        XCTAssertEqual(store.tab(tabID)?.section, .archived)
        XCTAssertNil(node(.pinnedTab(tabID)))
    }

    func testRemovingAnEmptyFolderDeletesIt() throws {
        let folderID = try createFolder("Empty", in: spaceA)

        try apply("remove", ["id": BookmarkNodeID.pinnedFolder(folderID).rawValue])

        XCTAssertNil(store.folder(folderID, in: spaceA))
        XCTAssertNil(node(.pinnedFolder(folderID)))
    }

    func testRemoveTreeDeletesANestedFolderDepthFirst() throws {
        let outer = try createFolder("Outer", in: spaceA)
        let inner = try createFolder("Inner", in: spaceA, parent: .pinnedFolder(outer))
        let outerTab = try createBookmark("Outer tab", "https://outer.example.com", parent: .pinnedFolder(outer))
        let innerTab = try createBookmark("Inner tab", "https://inner.example.com", parent: .pinnedFolder(inner))

        try apply("removeTree", ["id": BookmarkNodeID.pinnedFolder(outer).rawValue])

        XCTAssertNil(store.folder(outer, in: spaceA))
        XCTAssertNil(store.folder(inner, in: spaceA))
        XCTAssertEqual(store.tab(outerTab)?.section, .archived)
        XCTAssertEqual(store.tab(innerTab)?.section, .archived)
        XCTAssertEqual(childIDs(of: .pinned(spaceA)), [])
    }

    func testRemoveTreeOnALeafBehavesLikeRemove() throws {
        let tabID = try createBookmark("Article", "https://read.example.com", parent: .pinned(spaceA))
        let favorite = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Alpha", "url": "https://alpha.example.com",
        ])

        try apply("removeTree", ["id": BookmarkNodeID.pinnedTab(tabID).rawValue])
        try apply("removeTree", ["id": favorite.rawValue])

        XCTAssertEqual(store.tab(tabID)?.section, .archived)
        XCTAssertEqual(store.favorites(for: spaceB).count, 0)
    }

    // MARK: - Refusals

    func testEveryPermanentNodeRefusesEveryMutation() throws {
        let permanent: [BookmarkNodeID] = [.root, .space(spaceA), .favorites(spaceA), .pinned(spaceA)]

        for id in permanent {
            assertRefused("move", ["id": id.rawValue, "parentId": BookmarkNodeID.pinned(spaceB).rawValue], BookmarkErrors.modifySpecial)
            assertRefused("update", ["id": id.rawValue, "title": "Renamed"], BookmarkErrors.modifySpecial)
            assertRefused("remove", ["id": id.rawValue], BookmarkErrors.modifySpecial)
            assertRefused("removeTree", ["id": id.rawValue], BookmarkErrors.modifySpecial)
        }
        assertRefused("create", ["parentId": BookmarkNodeID.root.rawValue, "title": "New"], BookmarkErrors.modifySpecial)
        assertRefused("create", ["parentId": BookmarkNodeID.space(spaceA).rawValue, "title": "New"], BookmarkErrors.modifySpecial)
    }

    func testAFolderCannotBeCreatedInFavourites() {
        assertRefused(
            "create",
            ["parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Folder"],
            BookmarkErrors.favoritesCannotContainFolders
        )
    }

    func testAFavouriteCannotBeMovedOutOfFavourites() throws {
        let favorite = try apply("create", [
            "parentId": BookmarkNodeID.favorites(spaceB).rawValue, "title": "Alpha", "url": "https://alpha.example.com",
        ])

        assertRefused(
            "move", ["id": favorite.rawValue, "parentId": BookmarkNodeID.pinned(spaceB).rawValue],
            BookmarkErrors.favoriteOutOfFavorites
        )
        assertRefused(
            "move", ["id": favorite.rawValue, "parentId": BookmarkNodeID.favorites(spaceA).rawValue],
            BookmarkErrors.favoriteOutOfFavorites
        )
    }

    func testAFolderCannotBeMovedBetweenSpaces() throws {
        let folderID = try createFolder("Reading", in: spaceA)

        assertRefused(
            "move",
            ["id": BookmarkNodeID.pinnedFolder(folderID).rawValue, "parentId": BookmarkNodeID.pinned(spaceB).rawValue],
            BookmarkErrors.folderBetweenSpaces
        )
    }

    func testAFolderCannotBeMovedIntoItsOwnDescendant() throws {
        let outer = try createFolder("Outer", in: spaceA)
        let inner = try createFolder("Inner", in: spaceA, parent: .pinnedFolder(outer))

        assertRefused(
            "move",
            ["id": BookmarkNodeID.pinnedFolder(outer).rawValue, "parentId": BookmarkNodeID.pinnedFolder(inner).rawValue],
            BookmarkErrors.invalidMoveDestination
        )
        assertRefused(
            "move",
            ["id": BookmarkNodeID.pinnedFolder(outer).rawValue, "parentId": BookmarkNodeID.pinnedFolder(outer).rawValue],
            BookmarkErrors.invalidMoveDestination
        )
    }

    func testAFolderCannotBeGivenAUrl() throws {
        let folderID = try createFolder("Reading", in: spaceA)

        assertRefused(
            "update",
            ["id": BookmarkNodeID.pinnedFolder(folderID).rawValue, "url": "https://example.com"],
            BookmarkErrors.cannotSetURLOfFolder
        )
    }

    func testANonEmptyFolderCannotBeRemovedWithoutRemoveTree() throws {
        let folderID = try createFolder("Reading", in: spaceA)
        _ = try createBookmark("Article", "https://read.example.com", parent: .pinnedFolder(folderID))

        assertRefused(
            "remove", ["id": BookmarkNodeID.pinnedFolder(folderID).rawValue], BookmarkErrors.folderNotEmpty
        )
    }

    func testUnusableArgumentsAreRefusedWithUpstreamsOwnStrings() {
        assertRefused(
            "create",
            ["parentId": BookmarkNodeID.pinned(spaceA).rawValue, "title": "Bad", "url": "not a url"],
            BookmarkErrors.invalidURL
        )
        assertRefused(
            "create", ["parentId": "p:" + UUID().uuidString.lowercased(), "title": "Nowhere"], BookmarkErrors.noParent
        )
        assertRefused("create", ["parentId": "nonsense", "title": "Nowhere"], BookmarkErrors.noParent)
        assertRefused("remove", ["id": "nonsense"], BookmarkErrors.invalidID)
        assertRefused("remove", ["id": "t:" + UUID().uuidString.lowercased()], BookmarkErrors.noNode)
        assertRefused(
            "create",
            ["parentId": BookmarkNodeID.pinned(spaceA).rawValue, "title": "Out of range", "index": 7],
            BookmarkErrors.invalidIndex
        )
    }

    func testAnUnknownMethodIsRefused() {
        assertRefused("getRecent", ["id": BookmarkNodeID.root.rawValue], BookmarkErrors.unavailable)
    }
}
