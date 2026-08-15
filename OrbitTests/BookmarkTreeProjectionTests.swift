import XCTest

final class BookmarkTreeProjectionTests: XCTestCase {

    // MARK: - Fixture

    private let profileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let spaceAID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let spaceBID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    private let favA1ID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    private let favA2ID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
    private let favB1ID = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
    private let folder1ID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private let folder2ID = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
    private let tab1ID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let tab2ID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private let tab3ID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    private let tab4ID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
    private let missingTabID = UUID(uuidString: "10000000-0000-0000-0000-0000000000FF")!

    private let spaceACreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let spaceBCreatedAt = Date(timeIntervalSince1970: 1_700_000_100)
    private let tab1CreatedAt = Date(timeIntervalSince1970: 1_700_001_000)
    private let tab2CreatedAt = Date(timeIntervalSince1970: 1_700_002_000)
    private let tab3CreatedAt = Date(timeIntervalSince1970: 1_700_003_000)
    private let tab4CreatedAt = Date(timeIntervalSince1970: 1_700_004_000)

    private func makeState() -> OrbitState {
        let profile = Profile(id: profileID, name: "default")

        let spaceA = Space(
            id: spaceAID,
            name: "Personal",
            profileID: profileID,
            order: 0,
            favorites: [
                Favorite(id: favA1ID, url: URL(string: "https://www.google.com")!, title: "Google"),
                Favorite(id: favA2ID, url: URL(string: "https://www.apple.com")!, title: "Apple"),
            ],
            pinned: [
                .folder(Folder(
                    id: folder1ID,
                    name: "Reading",
                    children: [
                        .tab(tab1ID),
                        .folder(Folder(id: folder2ID, name: "Deep", children: [.tab(tab2ID)])),
                    ]
                )),
                .tab(tab3ID),
                .tab(missingTabID),
            ],
            createdAt: spaceACreatedAt
        )

        let spaceB = Space(
            id: spaceBID,
            name: "Work",
            profileID: profileID,
            order: 1,
            favorites: [Favorite(id: favB1ID, url: URL(string: "https://github.com")!, title: "GitHub")],
            pinned: [.tab(tab4ID)],
            createdAt: spaceBCreatedAt
        )

        var tabs: [TabID: Tab] = [:]
        tabs[tab1ID] = Tab(
            id: tab1ID, spaceID: spaceAID, section: .pinned,
            url: URL(string: "https://example.com/current")!, title: "Live page title",
            customTitle: "Renamed by the user",
            createdAt: tab1CreatedAt,
            pinnedURL: URL(string: "https://example.com/pinned")!, pinnedTitle: "Origin title"
        )
        tabs[tab2ID] = Tab(
            id: tab2ID, spaceID: spaceAID, section: .pinned,
            url: URL(string: "https://example.com/deep")!, title: "Deep tab",
            createdAt: tab2CreatedAt
        )
        tabs[tab3ID] = Tab(
            id: tab3ID, spaceID: spaceAID, section: .pinned,
            url: URL(string: "https://example.com/standalone")!, title: "Standalone",
            customTitle: "Renamed standalone",
            createdAt: tab3CreatedAt
        )
        tabs[tab4ID] = Tab(
            id: tab4ID, spaceID: spaceBID, section: .pinned,
            url: URL(string: "https://work.example.com")!, title: "Work tab",
            createdAt: tab4CreatedAt
        )

        return OrbitState(profiles: [profile], spaces: [spaceA, spaceB], tabs: tabs)
    }

    // MARK: - Reading helpers

    private func children(_ node: [String: Any]) -> [[String: Any]] {
        node["children"] as? [[String: Any]] ?? []
    }

    private func child(_ node: [String: Any], _ index: Int) -> [String: Any] {
        let all = children(node)
        XCTAssertTrue(all.indices.contains(index), "no child at \(index)")
        return all.indices.contains(index) ? all[index] : [:]
    }

    private func id(_ node: [String: Any]) -> String { node["id"] as? String ?? "" }

    private func find(_ rawID: String, in node: [String: Any]) -> [String: Any]? {
        if id(node) == rawID { return node }
        for child in children(node) {
            if let found = find(rawID, in: child) { return found }
        }
        return nil
    }

    private func allNodes(in node: [String: Any]) -> [[String: Any]] {
        [node] + children(node).flatMap { allNodes(in: $0) }
    }

    // MARK: - Shape

    func testRootHoldsOneFolderPerSpaceInSpaceOrder() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())

        XCTAssertEqual(id(tree), "0")
        XCTAssertEqual(tree["title"] as? String, "")
        XCTAssertEqual(tree["permanent"] as? Bool, true)
        XCTAssertNil(tree["parentId"], "the root has no parent")
        XCTAssertNil(tree["index"], "the root has no index")
        XCTAssertNil(tree["url"], "the root is a folder")

        XCTAssertEqual(children(tree).count, 2)
        XCTAssertEqual(id(child(tree, 0)), "s:" + spaceAID.uuidString.lowercased())
        XCTAssertEqual(id(child(tree, 1)), "s:" + spaceBID.uuidString.lowercased())
        XCTAssertEqual(child(tree, 0)["title"] as? String, "Personal")
        XCTAssertEqual(child(tree, 1)["title"] as? String, "Work")
    }

    func testSpaceOrderComparatorFallsBackToCreatedAtThenIdentifier() {
        var state = makeState()
        state.spaces[0].order = 3
        state.spaces[1].order = 3

        let tree = BookmarkTreeProjection.treeObject(for: state)

        XCTAssertEqual(
            children(tree).map { id($0) },
            ["s:" + spaceAID.uuidString.lowercased(), "s:" + spaceBID.uuidString.lowercased()],
            "equal orders must fall back to createdAt, and Space A was created first"
        )
    }

    func testEverySpaceHoldsFavouritesThenPinned() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())
        let spaceA = child(tree, 0)

        let favorites = child(spaceA, 0)
        let pinned = child(spaceA, 1)
        XCTAssertEqual(id(favorites), "f:" + spaceAID.uuidString.lowercased())
        XCTAssertEqual(favorites["title"] as? String, "Favourites")
        XCTAssertEqual(id(pinned), "p:" + spaceAID.uuidString.lowercased())
        XCTAssertEqual(pinned["title"] as? String, "Pinned")
    }

    func testPermanentFlagIsOnRootSpaceFavouritesAndPinnedOnly() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())

        let permanent = allNodes(in: tree).filter { $0["permanent"] as? Bool == true }.map { id($0) }.sorted()
        let expected = [
            "0",
            "f:" + spaceAID.uuidString.lowercased(),
            "f:" + spaceBID.uuidString.lowercased(),
            "p:" + spaceAID.uuidString.lowercased(),
            "p:" + spaceBID.uuidString.lowercased(),
            "s:" + spaceAID.uuidString.lowercased(),
            "s:" + spaceBID.uuidString.lowercased(),
        ].sorted()
        XCTAssertEqual(permanent, expected)

        for node in allNodes(in: tree) where !expected.contains(id(node)) {
            XCTAssertNil(node["permanent"], "\(id(node)) must not claim to be permanent")
        }
    }

    func testLeavesCarryAUrlAndFoldersCarryChildren() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())

        for node in allNodes(in: tree) {
            let rawID = id(node)
            let isLeaf = rawID.hasPrefix("b:") || rawID.hasPrefix("t:")
            if isLeaf {
                XCTAssertNotNil(node["url"], "\(rawID) is a bookmark and must carry a url")
                XCTAssertNil(node["children"], "\(rawID) is a bookmark and must not carry children")
            } else {
                XCTAssertNil(node["url"], "\(rawID) is a folder and must not carry a url")
                XCTAssertNotNil(node["children"], "\(rawID) is a folder and must carry children")
            }
            XCTAssertEqual(node["syncing"] as? Bool, false, "\(rawID)")
            XCTAssertNil(node["folderType"], "\(rawID)")
            XCTAssertNil(node["unmodifiable"], "\(rawID)")
        }
    }

    func testFavouritesAreLeavesInSpaceOrderWithTitleAndUrl() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())
        let favorites = child(child(tree, 0), 0)

        XCTAssertEqual(children(favorites).map { id($0) }, [
            "b:" + favA1ID.uuidString.lowercased(),
            "b:" + favA2ID.uuidString.lowercased(),
        ])
        XCTAssertEqual(child(favorites, 0)["title"] as? String, "Google")
        XCTAssertEqual(child(favorites, 0)["url"] as? String, "https://www.google.com")
        XCTAssertEqual(child(favorites, 1)["url"] as? String, "https://www.apple.com")
    }

    func testPinnedForestIsDepthFirstWithFolderAndTabIdentifiers() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())
        let pinned = child(child(tree, 0), 1)

        XCTAssertEqual(children(pinned).map { id($0) }, [
            "d:" + folder1ID.uuidString.lowercased(),
            "t:" + tab3ID.uuidString.lowercased(),
        ])

        let reading = child(pinned, 0)
        XCTAssertEqual(reading["title"] as? String, "Reading")
        XCTAssertEqual(children(reading).map { id($0) }, [
            "t:" + tab1ID.uuidString.lowercased(),
            "d:" + folder2ID.uuidString.lowercased(),
        ])
        XCTAssertEqual(children(child(reading, 1)).map { id($0) }, ["t:" + tab2ID.uuidString.lowercased()])
    }

    func testAPinnedTabReportsTheTitleTheSidebarShowsAndTheUrlItWasBookmarkedAt() {
        let state = makeState()
        let tab = state.tabs[tab1ID]!
        XCTAssertNotNil(tab.pinnedTitle)
        XCTAssertNotEqual(tab.customTitle, tab.pinnedTitle)
        XCTAssertNotEqual(tab.url, tab.pinnedURL, "the fixture must have navigated away from its pinned URL")

        let tree = BookmarkTreeProjection.treeObject(for: state)
        let reading = child(child(child(tree, 0), 1), 0)

        XCTAssertEqual(child(reading, 0)["title"] as? String, "Renamed by the user", "displayTitle, not pinnedTitle")
        XCTAssertEqual(child(reading, 0)["url"] as? String, "https://example.com/pinned", "pinnedURL, not the live url")

        let standalone = child(child(child(tree, 0), 1), 1)
        XCTAssertEqual(standalone["title"] as? String, "Renamed standalone", "displayTitle prefers customTitle")
        XCTAssertEqual(standalone["url"] as? String, "https://example.com/standalone")
    }

    // MARK: - parentId / index

    func testParentIdAndIndexAreCorrectAtEveryLevel() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())

        func assertChildren(of node: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
            for (index, child) in children(node).enumerated() {
                XCTAssertEqual(child["parentId"] as? String, id(node), "\(id(child))", file: file, line: line)
                XCTAssertEqual(child["index"] as? Int, index, "\(id(child))", file: file, line: line)
                assertChildren(of: child, file: file, line: line)
            }
        }
        assertChildren(of: tree)
    }

    func testAPinnedNodeWhoseTabIsMissingIsSkippedAndDoesNotLeaveAGapInTheIndices() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())
        let pinned = child(child(tree, 0), 1)

        XCTAssertNil(find("t:" + missingTabID.uuidString.lowercased(), in: tree))
        XCTAssertEqual(children(pinned).count, 2)
        XCTAssertEqual(children(pinned).map { $0["index"] as? Int }, [0, 1])
    }

    // MARK: - dateAdded

    func testDateAddedIsEmittedForSpacesAndPinnedTabsOnly() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())

        for node in allNodes(in: tree) {
            let rawID = id(node)
            if rawID.hasPrefix("s:") || rawID.hasPrefix("t:") {
                XCTAssertNotNil(node["dateAdded"], "\(rawID) stores a real date")
            } else {
                XCTAssertNil(node["dateAdded"], "\(rawID) stores no creation date and must not invent one")
            }
        }
    }

    func testDateAddedIsMillisecondsSinceEpoch() {
        let tree = BookmarkTreeProjection.treeObject(for: makeState())

        XCTAssertEqual(child(tree, 0)["dateAdded"] as? Int, Int(spaceACreatedAt.timeIntervalSince1970 * 1000))
        let tab1 = find("t:" + tab1ID.uuidString.lowercased(), in: tree)
        XCTAssertEqual(tab1?["dateAdded"] as? Int, Int(tab1CreatedAt.timeIntervalSince1970 * 1000))
    }

    // MARK: - Stability

    func testIdentifiersAreStableAcrossCallsAndAcrossAMutationElsewhere() {
        let state = makeState()
        let first = allNodes(in: BookmarkTreeProjection.treeObject(for: state)).map { id($0) }
        let second = allNodes(in: BookmarkTreeProjection.treeObject(for: state)).map { id($0) }
        XCTAssertEqual(first, second)

        var mutated = state
        mutated.spaces[1].favorites.append(Favorite(url: URL(string: "https://added.example.com")!, title: "Added"))
        let afterMutation = allNodes(in: BookmarkTreeProjection.treeObject(for: mutated)).map { id($0) }

        XCTAssertEqual(
            afterMutation.filter { first.contains($0) },
            first,
            "an edit in one Space renumbered or reordered ids elsewhere"
        )
        XCTAssertEqual(afterMutation.count, first.count + 1)
    }

    func testTreeJSONParsesBackToTheSameObject() throws {
        let state = makeState()
        let json = BookmarkTreeProjection.treeJSON(for: state)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertEqual(allNodes(in: parsed).map { id($0) }, allNodes(in: BookmarkTreeProjection.treeObject(for: state)).map { id($0) })
        XCTAssertEqual(json, BookmarkTreeProjection.treeJSON(for: state), "the same state must serialise byte-identically")
    }

    // MARK: - BookmarkNodeID

    func testIdentifiersRoundTripThroughRawValue() {
        let spaceID = UUID()
        let cases: [BookmarkNodeID] = [
            .root,
            .space(spaceID),
            .favorites(spaceID),
            .pinned(spaceID),
            .favorite(UUID()),
            .pinnedFolder(UUID()),
            .pinnedTab(UUID()),
        ]

        for value in cases {
            XCTAssertEqual(BookmarkNodeID(rawValue: value.rawValue), value, value.rawValue)
        }
        XCTAssertEqual(BookmarkNodeID.space(spaceID).rawValue, "s:" + spaceID.uuidString.lowercased())
    }

    func testPermanentIdentifiersAreExactlyRootSpaceFavouritesAndPinned() {
        let id = UUID()
        XCTAssertTrue(BookmarkNodeID.root.isPermanent)
        XCTAssertTrue(BookmarkNodeID.space(id).isPermanent)
        XCTAssertTrue(BookmarkNodeID.favorites(id).isPermanent)
        XCTAssertTrue(BookmarkNodeID.pinned(id).isPermanent)
        XCTAssertFalse(BookmarkNodeID.favorite(id).isPermanent)
        XCTAssertFalse(BookmarkNodeID.pinnedFolder(id).isPermanent)
        XCTAssertFalse(BookmarkNodeID.pinnedTab(id).isPermanent)
    }

    func testUnrecognisedIdentifiersAreRejected() {
        let rubbish = [
            "", "1", "s", "s:", "s:not-a-uuid", "x:" + UUID().uuidString, ":" + UUID().uuidString,
            UUID().uuidString, "b:" + UUID().uuidString + "-extra", "00",
        ]
        for raw in rubbish {
            XCTAssertNil(BookmarkNodeID(rawValue: raw), "accepted \(raw)")
        }
        XCTAssertEqual(BookmarkNodeID(rawValue: "0"), .root)
    }
}
