// Fixtures below are literals in the exact shapes Arc writes, each checked against a
// real StorableSidebar.json/StorableArchiveItems.json; nothing here reads that file.

import XCTest

final class ArcSidebarDocumentTests: XCTestCase {

    // MARK: - 1. The alternating [id, object, …] encoding

    func testAlternatingIDObjectArraysAreDeInterleaved() throws {
        let container = Fixture.uuid(1)
        let firstTab = Fixture.uuid(2)
        let secondTab = Fixture.uuid(3)
        let spaceID = Fixture.uuid(4)

        let items: [[String: Any]] = [
            Fixture.containerItem(id: container, children: [firstTab, secondTab], spaceID: spaceID),
            Fixture.tabItem(id: firstTab, url: "https://www.swift.org/", savedTitle: "Swift.org", parentID: container),
            Fixture.tabItem(id: secondTab, url: "https://developer.apple.com/", savedTitle: "Apple Developer", parentID: container),
        ]
        let data = try Fixture.sidebarData(
            items: items,
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Dev", pinnedContainerID: container)]
        )

        let rawItems = try Self.rawItemsArray(in: data)
        XCTAssertEqual(rawItems.count, 6, "Three item objects must be encoded as six array elements.")
        for (index, element) in rawItems.enumerated() {
            if index.isMultiple(of: 2) {
                XCTAssertTrue(element is String, "Element \(index) of an Arc items array must be the id string.")
            } else {
                XCTAssertTrue(element is [String: Any], "Element \(index) of an Arc items array must be the object.")
            }
        }
        XCTAssertNil(
            rawItems as? [[String: Any]],
            "A naive homogeneous decode of Arc's items array must be impossible — if this cast succeeds the fixture is wrong."
        )
        XCTAssertEqual(
            ArcSidebarDocument.objects(in: rawItems).count,
            rawItems.count / 2,
            "objects(in:) must return exactly the object half of the array."
        )

        let document = try ArcSidebarDocument.parse(data: data, browser: .arc)
        let space = try XCTUnwrap(document.spaces.first)
        XCTAssertEqual(
            space.pinned.compactMap { if case .tab(let tab) = $0 { return tab.title } else { return nil } },
            ["Swift.org", "Apple Developer"],
            "Both interleaved items must come through; dropping every other element would yield one of these."
        )

        XCTAssertEqual(space.pinned.count, 2)
        XCTAssertEqual(
            rawItems.count,
            2 * (space.pinned.count + 1),
            "Raw element count must be 2x the item count (the +1 is the invisible container row)."
        )
    }

    // MARK: - 2. Space identity and title

    func testSpaceIdentityAndTitleFallback() throws {
        let named = Fixture.uuid(10)
        let blank = Fixture.uuid(11)
        let whitespace = Fixture.uuid(12)
        let absent = Fixture.uuid(13)

        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: named, title: "  Uni Stuff  "),
            Fixture.spaceJSON(id: blank, title: ""),
            Fixture.spaceJSON(id: whitespace, title: "   \n\t "),
            Fixture.spaceJSON(id: absent),
        ])

        let document = try ArcSidebarDocument.parse(data: data, browser: .arc)
        XCTAssertEqual(document.spaces.count, 4, "Every spaces entry must survive the de-interleave.")
        XCTAssertEqual(
            document.spaces.map(\.arcID),
            [named, blank, whitespace, absent].map { UUID(uuidString: $0)! },
            "Space ids must be Arc's own ids, in Arc's own order."
        )
        XCTAssertEqual(document.spaces[0].title, "Uni Stuff", "A Space's title is trimmed, not rewritten.")
        XCTAssertEqual(document.spaces[1].title, "Untitled Space", "An empty title must become the placeholder.")
        XCTAssertEqual(document.spaces[2].title, "Untitled Space", "An all-whitespace title must become the placeholder.")
        XCTAssertEqual(document.spaces[3].title, "Untitled Space", "A missing title must become the placeholder.")
    }

    // MARK: - 3. containerIDs pairing

    func testContainerIDsPairPinnedAndUnpinnedSections() throws {
        let spaceID = Fixture.uuid(20)
        let pinnedContainer = Fixture.uuid(21)
        let unpinnedContainer = Fixture.uuid(22)
        let pinnedTab = Fixture.uuid(23)
        let todayTab = Fixture.uuid(24)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: pinnedContainer, children: [pinnedTab], spaceID: spaceID),
                Fixture.containerItem(id: unpinnedContainer, children: [todayTab], spaceID: spaceID),
                Fixture.tabItem(id: pinnedTab, url: "https://pinned.example.com/", savedTitle: "Pinned", parentID: pinnedContainer),
                Fixture.tabItem(id: todayTab, url: "https://today.example.com/", savedTitle: "Today", parentID: unpinnedContainer),
            ],
            spaces: [Fixture.spaceJSON(
                id: spaceID,
                title: "General",
                pinnedContainerID: pinnedContainer,
                unpinnedContainerID: unpinnedContainer
            )]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(Self.titles(space.pinned), ["Pinned"], "The \"pinned\" key must route into Space.pinned.")
        XCTAssertEqual(
            Self.titles(space.today),
            ["Today"],
            "Arc's \"unpinned\" container is what its UI calls Today and must route into Space.today, not Space.pinned."
        )
    }

    // MARK: - 4. newContainerIDs fallback and precedence

    func testNewContainerIDsResolveBothSectionsWhenTheFlatFormIsAbsent() throws {
        let spaceID = Fixture.uuid(30)
        let pinnedContainer = Fixture.uuid(31)
        let unpinnedContainer = Fixture.uuid(32)
        let pinnedTab = Fixture.uuid(33)
        let todayTab = Fixture.uuid(34)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: pinnedContainer, children: [pinnedTab], spaceID: spaceID),
                Fixture.containerItem(id: unpinnedContainer, children: [todayTab], spaceID: spaceID),
                Fixture.tabItem(id: pinnedTab, url: "https://pinned.example.com/", savedTitle: "Pinned", parentID: pinnedContainer),
                Fixture.tabItem(id: todayTab, url: "https://today.example.com/", savedTitle: "Today", parentID: unpinnedContainer),
            ],
            spaces: [Fixture.spaceJSON(
                id: spaceID,
                title: "Older Arc",
                newPinnedContainerID: pinnedContainer,
                newUnpinnedContainerID: unpinnedContainer
            )]
        )

        let rawSpace = try XCTUnwrap(Self.rawSpaceObjects(in: data).first)
        XCTAssertNil(rawSpace["containerIDs"], "This fixture must carry only newContainerIDs.")
        XCTAssertNotNil(rawSpace["newContainerIDs"])

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(Self.titles(space.pinned), ["Pinned"], "{\"pinned\": {}} must unwrap to the \"pinned\" key.")
        XCTAssertEqual(
            Self.titles(space.today),
            ["Today"],
            "{\"unpinned\": {\"_0\": {\"shared\": {}}}} must unwrap to the \"unpinned\" key."
        )
    }

    func testContainerIDsWinsOverNewContainerIDsWhenBothArePresent() throws {
        let spaceID = Fixture.uuid(40)
        let flatPinned = Fixture.uuid(41)
        let flatUnpinned = Fixture.uuid(42)
        let wrappedPinned = Fixture.uuid(43)
        let wrappedUnpinned = Fixture.uuid(44)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: flatPinned, children: [Fixture.uuid(45)], spaceID: spaceID),
                Fixture.containerItem(id: flatUnpinned, children: [Fixture.uuid(46)], spaceID: spaceID),
                Fixture.containerItem(id: wrappedPinned, children: [Fixture.uuid(47)], spaceID: spaceID),
                Fixture.containerItem(id: wrappedUnpinned, children: [Fixture.uuid(48)], spaceID: spaceID),
                Fixture.tabItem(id: Fixture.uuid(45), url: "https://flat.example.com/pinned", savedTitle: "Flat Pinned"),
                Fixture.tabItem(id: Fixture.uuid(46), url: "https://flat.example.com/today", savedTitle: "Flat Today"),
                Fixture.tabItem(id: Fixture.uuid(47), url: "https://wrapped.example.com/pinned", savedTitle: "Wrapped Pinned"),
                Fixture.tabItem(id: Fixture.uuid(48), url: "https://wrapped.example.com/today", savedTitle: "Wrapped Today"),
            ],
            spaces: [Fixture.spaceJSON(
                id: spaceID,
                title: "Newer Arc",
                pinnedContainerID: flatPinned,
                unpinnedContainerID: flatUnpinned,
                newPinnedContainerID: wrappedPinned,
                newUnpinnedContainerID: wrappedUnpinned
            )]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(Self.titles(space.pinned), ["Flat Pinned"], "containerIDs must be read first when both encodings are present.")
        XCTAssertEqual(Self.titles(space.today), ["Flat Today"], "containerIDs must be read first when both encodings are present.")
    }

    // MARK: - 5. Order comes from childrenIds

    func testChildOrderFollowsChildrenIdsRatherThanParentIDGrouping() throws {
        let spaceID = Fixture.uuid(50)
        let container = Fixture.uuid(51)
        let alpha = Fixture.uuid(52)
        let bravo = Fixture.uuid(53)
        let charlie = Fixture.uuid(54)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: container, children: [charlie, alpha, bravo], spaceID: spaceID),
                Fixture.tabItem(id: alpha, url: "https://example.com/alpha", savedTitle: "Alpha", parentID: container),
                Fixture.tabItem(id: bravo, url: "https://example.com/bravo", savedTitle: "Bravo", parentID: container),
                Fixture.tabItem(id: charlie, url: "https://example.com/charlie", savedTitle: "Charlie", parentID: container),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Ordering", pinnedContainerID: container)]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(
            Self.titles(space.pinned),
            ["Charlie", "Alpha", "Bravo"],
            "Order must come from childrenIds. Grouping by parentID would give Alpha, Bravo, Charlie; "
                + "iterating childrenIds backwards would give Bravo, Alpha, Charlie."
        )
    }

    // MARK: - 6. Nested folders

    func testFoldersNestThreeDeepWithTabsAtEveryLevel() throws {
        let spaceID = Fixture.uuid(60)
        let container = Fixture.uuid(61)
        let rootTab = Fixture.uuid(62)
        let level1 = Fixture.uuid(63)
        let level1Tab = Fixture.uuid(64)
        let level2 = Fixture.uuid(65)
        let level2Tab = Fixture.uuid(66)
        let level3 = Fixture.uuid(67)
        let level3Tab = Fixture.uuid(68)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: container, children: [rootTab, level1], spaceID: spaceID),
                Fixture.tabItem(id: rootTab, url: "https://example.com/root", savedTitle: "Root Tab", parentID: container),
                Fixture.folderItem(id: level1, title: "Projects", children: [level1Tab, level2], parentID: container,
                                   iconType: ["icon": "folder"]),
                Fixture.tabItem(id: level1Tab, url: "https://example.com/one", savedTitle: "One", parentID: level1),
                Fixture.folderItem(id: level2, title: "Orbit", children: [level2Tab, level3], parentID: level1),
                Fixture.tabItem(id: level2Tab, url: "https://example.com/two", savedTitle: "Two", parentID: level2),
                Fixture.folderItem(id: level3, title: "Import", children: [level3Tab], parentID: level2),
                Fixture.tabItem(id: level3Tab, url: "https://example.com/three", savedTitle: "Three", parentID: level3),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Nesting", pinnedContainerID: container)]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(Self.titles(space.pinned), ["Root Tab", "Projects"], "A tab and a folder must sit side by side at the top level.")

        guard case .folder(let projects) = space.pinned[1] else { return XCTFail("Second row must be a folder.") }
        XCTAssertEqual(projects.name, "Projects", "A folder's name is the item's `title`.")
        XCTAssertEqual(projects.icon, .materialSymbol("folder"))
        XCTAssertEqual(Self.titles(projects.children), ["One", "Orbit"])

        guard case .folder(let orbit) = projects.children[1] else { return XCTFail("Second level must be a folder.") }
        XCTAssertEqual(orbit.name, "Orbit")
        XCTAssertNil(orbit.icon, "A folder with no customInfo must have no icon rather than a fabricated one.")
        XCTAssertEqual(Self.titles(orbit.children), ["Two", "Import"])

        guard case .folder(let importFolder) = orbit.children[1] else { return XCTFail("Third level must be a folder.") }
        XCTAssertEqual(importFolder.name, "Import")
        XCTAssertEqual(Self.titles(importFolder.children), ["Three"])

        XCTAssertEqual(
            space.pinned.flatMap(\.allTabs).map(\.title),
            ["Root Tab", "One", "Two", "Three"],
            "allTabs must flatten depth-first in childrenIds order."
        )
        XCTAssertEqual(
            space.pinned.flatMap(\.allFolders).map(\.name),
            ["Projects", "Orbit", "Import"],
            "allFolders must find every folder at every depth."
        )
    }

    // MARK: - 7. Dangling child ids

    func testDanglingChildIDIsSkippedAndSiblingsStillImport() throws {
        let spaceID = Fixture.uuid(70)
        let container = Fixture.uuid(71)
        let before = Fixture.uuid(72)
        let after = Fixture.uuid(73)
        let missing = Fixture.uuid(74)
        let missingInFolder = Fixture.uuid(75)
        let folder = Fixture.uuid(76)
        let insideFolder = Fixture.uuid(77)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: container, children: [before, missing, folder, after], spaceID: spaceID),
                Fixture.tabItem(id: before, url: "https://example.com/before", savedTitle: "Before", parentID: container),
                Fixture.tabItem(id: after, url: "https://example.com/after", savedTitle: "After", parentID: container),
                Fixture.folderItem(id: folder, title: "Folder", children: [missingInFolder, insideFolder], parentID: container),
                Fixture.tabItem(id: insideFolder, url: "https://example.com/inside", savedTitle: "Inside", parentID: folder),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Tombstones", pinnedContainerID: container)]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(
            Self.titles(space.pinned),
            ["Before", "Folder", "After"],
            "A child id naming no item is an uncompacted sync tombstone: it must be skipped, and both siblings must survive."
        )
        guard case .folder(let parsedFolder) = space.pinned[1] else { return XCTFail("Expected a folder.") }
        XCTAssertEqual(Self.titles(parsedFolder.children), ["Inside"], "A dangling id nested inside a folder must be skipped too.")
    }

    // MARK: - 8. Cycle guard

    func testChildrenIdsCycleTerminatesWithAFiniteTree() throws {
        let spaceID = Fixture.uuid(80)
        let container = Fixture.uuid(81)
        let folderA = Fixture.uuid(82)
        let folderB = Fixture.uuid(83)
        let leaf = Fixture.uuid(84)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: container, children: [folderA], spaceID: spaceID),
                Fixture.folderItem(id: folderA, title: "A", children: [folderB], parentID: container),
                Fixture.folderItem(id: folderB, title: "B", children: [folderA, leaf], parentID: folderA),
                Fixture.tabItem(id: leaf, url: "https://example.com/leaf", savedTitle: "Leaf", parentID: folderB),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Cycle", pinnedContainerID: container)]
        )

        let document = try parseUnderWatchdog(data)
        let space = try XCTUnwrap(document.spaces.first)

        guard case .folder(let a) = space.pinned.first else { return XCTFail("Expected folder A at the top of the cycle.") }
        XCTAssertEqual(space.pinned.count, 1)
        XCTAssertEqual(a.name, "A")
        XCTAssertEqual(a.children.count, 1)
        guard case .folder(let b) = a.children[0] else { return XCTFail("Folder A must contain folder B.") }
        XCTAssertEqual(b.name, "B")
        XCTAssertEqual(
            Self.titles(b.children),
            ["Leaf"],
            "Folder B lists A as a child; revisiting A must be cut, while the non-cyclic sibling still imports."
        )
        XCTAssertEqual(space.pinned.flatMap(\.allFolders).map(\.name), ["A", "B"], "A cycle must not duplicate folders into the tree.")
        XCTAssertEqual(space.pinned.flatMap(\.allTabs).count, 1)
    }

    // MARK: - 9. title vs savedTitle

    func testUserRenameIsCarriedSeparatelyFromTheSavedPageTitle() throws {
        let spaceID = Fixture.uuid(90)
        let container = Fixture.uuid(91)
        let untouched = Fixture.uuid(92)
        let renamed = Fixture.uuid(93)
        let whitespaceRename = Fixture.uuid(94)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: container, children: [untouched, renamed, whitespaceRename], spaceID: spaceID),
                Fixture.tabItem(id: untouched, url: "https://www.swift.org/", savedTitle: "Swift.org", title: NSNull(), parentID: container),
                Fixture.tabItem(id: renamed, url: "https://linear.app/", savedTitle: "Linear – Plan and build products",
                                title: "Work Board", parentID: container),
                Fixture.tabItem(id: whitespaceRename, url: "https://example.com/", savedTitle: "Example Domain",
                                title: "   \n ", parentID: container),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Titles", pinnedContainerID: container)]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        let tabs = space.pinned.compactMap { item -> ArcTab? in if case .tab(let tab) = item { return tab } else { return nil } }
        XCTAssertEqual(tabs.count, 3)

        XCTAssertNil(tabs[0].customTitle, "A null `title` must not become a user-set name.")
        XCTAssertEqual(tabs[0].title, "Swift.org", "An un-renamed tab's title is its savedTitle.")

        XCTAssertEqual(tabs[1].customTitle, "Work Board", "A real `title` is the user's rename and must be carried.")
        XCTAssertEqual(tabs[1].title, "Linear – Plan and build products", "The page's own savedTitle must survive alongside the rename.")
        XCTAssertNotEqual(
            tabs[1].customTitle,
            tabs[1].title,
            "Collapsing title and savedTitle would turn every page title into a permanent user-set name."
        )

        XCTAssertNil(tabs[2].customTitle, "An all-whitespace rename is no rename, not a tab named \" \".")
        XCTAssertEqual(tabs[2].title, "Example Domain")
    }

    // MARK: - 10. Scheme filtering

    func testNonWebSchemesAreExcludedAndFileURLsAreKept() throws {
        let spaceID = Fixture.uuid(100)
        let container = Fixture.uuid(101)
        let ids = (102...107).map { Fixture.uuid($0) }

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: container, children: ids, spaceID: spaceID),
                Fixture.tabItem(id: ids[0], url: "arc://library", savedTitle: "Library", parentID: container),
                Fixture.tabItem(id: ids[1], url: "chrome://settings", savedTitle: "Settings", parentID: container),
                Fixture.tabItem(id: ids[2], url: "https://www.swift.org/", savedTitle: "Swift.org", parentID: container),
                Fixture.tabItem(id: ids[3], url: "file:///Users/example/notes.html", savedTitle: "Notes", parentID: container),
                Fixture.tabItem(id: ids[4], url: "http://example.com/plain", savedTitle: "Plain HTTP", parentID: container),
                Fixture.tabItem(id: ids[5], url: "javascript:alert(1)", savedTitle: "Bookmarklet", parentID: container),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Schemes", pinnedContainerID: container)]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(
            Self.titles(space.pinned),
            ["Swift.org", "Notes", "Plain HTTP"],
            "arc://, chrome:// and javascript: are internal pages that would 404 in Orbit; file:// is a real, openable document."
        )
        XCTAssertFalse(
            space.pinned.flatMap(\.allTabs).contains { ["arc", "chrome", "javascript"].contains($0.url.scheme ?? "") },
            "No internal-scheme tab may reach the imported tree."
        )
        XCTAssertEqual(
            space.pinned.flatMap(\.allTabs).first(where: { $0.title == "Notes" })?.url.absoluteString,
            "file:///Users/example/notes.html"
        )
    }

    // MARK: - 11. Empty savedTitle

    func testTabWithNoSavedTitleFallsBackToTheURLHost() throws {
        let spaceID = Fixture.uuid(110)
        let container = Fixture.uuid(111)
        let empty = Fixture.uuid(112)
        let whitespace = Fixture.uuid(113)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: container, children: [empty, whitespace], spaceID: spaceID),
                Fixture.tabItem(id: empty, url: "https://www.swift.org/blog/", savedTitle: "", parentID: container),
                Fixture.tabItem(id: whitespace, url: "https://news.ycombinator.com/item?id=1", savedTitle: "   ", parentID: container),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Untitled tabs", pinnedContainerID: container)]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(
            Self.titles(space.pinned),
            ["www.swift.org", "news.ycombinator.com"],
            "A tab Arc never recorded a page title for must show its host, not an empty row."
        )
    }

    // MARK: - 12. The epoch. The most important test in this file.

    func testCFAbsoluteTimeStampsAreConvertedFromThe2001Epoch() throws {
        let spaceID = Fixture.uuid(120)
        let container = Fixture.uuid(121)
        let dated = Fixture.uuid(122)
        let zero = Fixture.uuid(123)
        let noActivity = Fixture.uuid(124)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: container, children: [dated, zero, noActivity], spaceID: spaceID),
                Fixture.tabItem(id: dated, url: "https://www.swift.org/", savedTitle: "Swift.org", parentID: container,
                                createdAt: 700_000_000.0, lastActiveAt: 700_000_000.0),
                Fixture.tabItem(id: zero, url: "https://example.com/", savedTitle: "Example", parentID: container,
                                createdAt: 0.0, lastActiveAt: 0.0),
                Fixture.tabItem(id: noActivity, url: "https://example.org/", savedTitle: "No Activity", parentID: container,
                                createdAt: 700_000_000.0),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "Timestamps", pinnedContainerID: container)]
        )

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        let tabs = space.pinned.flatMap(\.allTabs)
        XCTAssertEqual(tabs.count, 3)

        XCTAssertEqual(
            tabs[0].createdAt,
            Date(timeIntervalSince1970: 1_678_307_200),
            "createdAt 700000000.0 is 2023-03-08T20:26:40Z. Reading it as a Unix timestamp would date this tab to 1992."
        )
        XCTAssertEqual(Self.iso8601(tabs[0].createdAt), "2023-03-08T20:26:40Z")
        XCTAssertEqual(
            try XCTUnwrap(tabs[0].lastActiveAt),
            Date(timeIntervalSince1970: 1_678_307_200),
            "timeLastActiveAt uses the same CFAbsoluteTime epoch as createdAt."
        )
        XCTAssertEqual(Self.iso8601(try XCTUnwrap(tabs[0].lastActiveAt)), "2023-03-08T20:26:40Z")

        XCTAssertEqual(tabs[1].createdAt, Date(timeIntervalSince1970: 978_307_200))
        XCTAssertEqual(Self.iso8601(tabs[1].createdAt), "2001-01-01T00:00:00Z", "0.0 is the CFAbsoluteTime reference date, not the Unix epoch.")
        XCTAssertEqual(Self.iso8601(try XCTUnwrap(tabs[1].lastActiveAt)), "2001-01-01T00:00:00Z")

        XCTAssertNil(tabs[2].lastActiveAt, "A tab with no timeLastActiveAt must report nil, not the reference date.")
    }

    // MARK: - 13. Icons

    func testEmojiV2IconKeepsTheFullGraphemeClusterAndWinsOverTheLegacyInteger() throws {
        let spaceID = Fixture.uuid(130)
        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: spaceID, title: "Dev", iconType: ["emoji_v2": "👨🏻‍💻", "emoji": 11036]),
        ])

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        guard case .emoji(let emoji) = try XCTUnwrap(space.icon) else {
            return XCTFail("emoji_v2 must decode to ArcIcon.emoji, not a Material symbol.")
        }
        XCTAssertEqual(emoji, "👨🏻‍💻", "emoji_v2 must be carried through byte-for-byte.")
        XCTAssertGreaterThan(
            emoji.unicodeScalars.count,
            1,
            "A ZWJ/skin-tone emoji is several scalars. Falling back to the legacy single-scalar `emoji` integer downgrades it."
        )
        XCTAssertEqual(emoji.count, 1, "The whole thing is one grapheme cluster.")
        XCTAssertNotEqual(emoji, "⬜", "11036 is the legacy integer on this very icon; preferring it gives the wrong emoji entirely.")
    }

    func testLegacyEmojiIntegerIconDecodesToItsScalar() throws {
        let spaceID = Fixture.uuid(131)
        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: spaceID, title: "Uni Stuff", iconType: ["emoji": 128218]),
        ])

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(space.icon, .emoji("📚"), "128218 is U+1F4DA, and a Space with only the legacy encoding must still get its icon.")
    }

    func testMaterialSymbolIconIsCarriedAsAnOpaqueName() throws {
        let spaceID = Fixture.uuid(132)
        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: spaceID, title: "Food", iconType: ["icon": "restaurant"]),
        ])

        let space = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first)
        XCTAssertEqual(
            space.icon,
            .materialSymbol("restaurant"),
            "A Google Material Symbols name means nothing to Orbit and must be carried whole, not guessed into an SF Symbol."
        )
    }

    func testMalformedIconTypeYieldsNoIconRatherThanCrashing() throws {
        let noKeys = Fixture.uuid(133)
        let outOfRange = Fixture.uuid(134)
        let surrogate = Fixture.uuid(135)

        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: noKeys, title: "No Keys", iconType: ["somethingNew": "value"]),
            Fixture.spaceJSON(id: outOfRange, title: "Out Of Range", iconType: ["emoji": 99_999_999_999.0]),
            Fixture.spaceJSON(id: surrogate, title: "Surrogate", iconType: ["emoji": 55296]),
        ])

        let document = try ArcSidebarDocument.parse(data: data, browser: .arc)
        XCTAssertEqual(document.spaces.count, 3, "A malformed icon must not lose the Space it was attached to.")
        XCTAssertNil(document.spaces[0].icon)
        XCTAssertNil(document.spaces[1].icon)
        XCTAssertNil(document.spaces[2].icon)
    }

    // MARK: - 14 & 15. Themes

    func testGradientThemeCarriesBaseColoursOverlaysAndModifiers() throws {
        let spaceID = Fixture.uuid(140)
        let first = Fixture.colorJSON(0.25, 0.5, 0.75, 1)
        let second = Fixture.colorJSON(0.125, 0.375, 0.625, 1)
        let overlayA = Fixture.colorJSON(0, 0, 0, 0)
        let overlayB = Fixture.colorJSON(0.5, 0.25, 0.125, 0.75)

        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: spaceID, title: "Gradient", windowTheme: Fixture.gradientTheme(
                baseColors: [first, second],
                overlayColors: [overlayA, overlayB],
                modifiers: ["noiseFactor": 0.25, "intensityFactor": 0.75, "overlay": "grain"],
                appearance: "dark",
                primaryShaded: Fixture.colorJSON(0.0625, 0.125, 0.1875, 1)
            )),
        ])

        let theme = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first?.theme)
        XCTAssertEqual(
            theme.baseColors,
            [
                ArcColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1),
                ArcColor(red: 0.125, green: 0.375, blue: 0.625, alpha: 1),
            ],
            "baseColors must come through in document order with every RGBA component intact — a gradient reversed is a different theme."
        )
        XCTAssertEqual(
            theme.overlayColors,
            [
                ArcColor(red: 0, green: 0, blue: 0, alpha: 0),
                ArcColor(red: 0.5, green: 0.25, blue: 0.125, alpha: 0.75),
            ],
            "A fully transparent overlay stop is what Arc wrote and must be kept, not filtered."
        )
        XCTAssertEqual(theme.noiseFactor, 0.25, accuracy: 1e-12)
        XCTAssertEqual(theme.intensityFactor, 0.75, accuracy: 1e-12)
        XCTAssertEqual(theme.overlayTexture, "grain")
        XCTAssertEqual(theme.primaryShaded, ArcColor(red: 0.0625, green: 0.125, blue: 0.1875, alpha: 1))
        XCTAssertEqual(theme.prefersDarkContent, true)
        XCTAssertEqual(theme.baseColors.first?.colorSpace, "extendedSRGB", "The colour space Arc named must be carried, not assumed.")
    }

    func testContentOverBackgroundAppearanceMapsToPrefersDarkContent() throws {
        let dark = Fixture.uuid(141)
        let light = Fixture.uuid(142)
        let unstated = Fixture.uuid(143)
        let base = [Fixture.colorJSON(0.5, 0.5, 0.5, 1)]

        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: dark, title: "Dark", windowTheme: Fixture.gradientTheme(
                baseColors: base, overlayColors: [], modifiers: [:], appearance: "dark", primaryShaded: nil)),
            Fixture.spaceJSON(id: light, title: "Light", windowTheme: Fixture.gradientTheme(
                baseColors: base, overlayColors: [], modifiers: [:], appearance: "light", primaryShaded: nil)),
            Fixture.spaceJSON(id: unstated, title: "Unstated", windowTheme: Fixture.gradientTheme(
                baseColors: base, overlayColors: [], modifiers: [:], appearance: nil, primaryShaded: nil)),
        ])

        let spaces = try ArcSidebarDocument.parse(data: data, browser: .arc).spaces
        XCTAssertEqual(spaces.count, 3)
        XCTAssertEqual(spaces[0].theme?.prefersDarkContent, true, "\"dark\" must map to true.")
        XCTAssertEqual(spaces[1].theme?.prefersDarkContent, false, "\"light\" must map to false.")
        XCTAssertNil(
            spaces[2].theme?.prefersDarkContent,
            "An absent contentOverBackgroundAppearance means Arc did not say, which is not the same fact as \"light\"."
        )
        XCTAssertNotNil(spaces[2].theme, "The theme itself must still be produced when only the appearance is missing.")

        XCTAssertEqual(spaces[0].theme?.noiseFactor, 0, "noiseFactor defaults to 0 — no noise — when unstated.")
        XCTAssertEqual(spaces[0].theme?.intensityFactor, 1, "intensityFactor defaults to 1 — full intensity — when unstated.")
        XCTAssertNil(spaces[0].theme?.overlayTexture)
    }

    func testSingleColourThemeProducesExactlyOneBaseColour() throws {
        let spaceID = Fixture.uuid(150)
        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: spaceID, title: "Solid", windowTheme: Fixture.singleColorTheme(
                color: Fixture.colorJSON(0.75, 0.25, 0.5, 0.5),
                modifiers: ["noiseFactor": 0.5, "intensityFactor": 0.25, "overlay": "sand"],
                appearance: "light"
            )),
        ])

        let theme = try XCTUnwrap(try ArcSidebarDocument.parse(data: data, browser: .arc).spaces.first?.theme)
        XCTAssertEqual(
            theme.baseColors,
            [ArcColor(red: 0.75, green: 0.25, blue: 0.5, alpha: 0.5)],
            "blendedSingleColor._0.color must become exactly one base colour."
        )
        XCTAssertEqual(theme.overlayColors, [], "A single-colour background has no overlay stops.")
        XCTAssertEqual(theme.noiseFactor, 0.5, accuracy: 1e-12, "The single-colour form carries the same modifiers as the gradient form.")
        XCTAssertEqual(theme.intensityFactor, 0.25, accuracy: 1e-12)
        XCTAssertEqual(theme.overlayTexture, "sand")
        XCTAssertEqual(theme.prefersDarkContent, false)
        XCTAssertNil(theme.primaryShaded)
    }

    // MARK: - 16. Theme fallback and absence

    func testThemeFallsBackToThePrimaryColorPaletteAndIsNilWithoutAWindowTheme() throws {
        let paletteOnly = Fixture.uuid(160)
        let noTheme = Fixture.uuid(161)
        let noCustomInfo = Fixture.uuid(162)

        let data = try Fixture.sidebarData(items: [], spaces: [
            Fixture.spaceJSON(id: paletteOnly, title: "Palette Only", windowTheme: [
                "primaryColorPalette": ["shaded": Fixture.colorJSON(0.25, 0.125, 0.5, 1)],
            ]),
            Fixture.spaceJSON(id: noTheme, title: "Icon Only", iconType: ["emoji_v2": "📺"]),
            Fixture.spaceJSON(id: noCustomInfo, title: "Bare"),
        ])

        let spaces = try ArcSidebarDocument.parse(data: data, browser: .arc).spaces
        let fallback = try XCTUnwrap(spaces[0].theme, "A Space with only a primaryColorPalette is still a Space worth theming.")
        XCTAssertEqual(
            fallback.baseColors,
            [ArcColor(red: 0.25, green: 0.125, blue: 0.5, alpha: 1)],
            "primaryColorPalette.shaded must become the single base colour when there is no background."
        )
        XCTAssertEqual(fallback.primaryShaded, ArcColor(red: 0.25, green: 0.125, blue: 0.5, alpha: 1))
        XCTAssertNil(fallback.prefersDarkContent)

        XCTAssertNil(spaces[1].theme, "A Space with customInfo but no windowTheme must have no theme, not an invented one.")
        XCTAssertEqual(spaces[1].icon, .emoji("📺"), "…and its icon must still be read.")
        XCTAssertNil(spaces[2].theme, "A Space with no customInfo at all must have no theme.")
        XCTAssertNil(spaces[2].icon)
    }

    // MARK: - 17. topApps

    func testTopAppsAreReturnedOnceAndNotDuplicatedIntoASpace() throws {
        let spaceID = Fixture.uuid(170)
        let spaceContainer = Fixture.uuid(171)
        let spaceTab = Fixture.uuid(172)
        let topContainer = Fixture.uuid(173)
        let favouriteA = Fixture.uuid(174)
        let favouriteFolder = Fixture.uuid(175)
        let favouriteB = Fixture.uuid(176)

        let data = try Fixture.sidebarData(
            items: [
                Fixture.containerItem(id: spaceContainer, children: [spaceTab], spaceID: spaceID),
                Fixture.tabItem(id: spaceTab, url: "https://space.example.com/", savedTitle: "In A Space", parentID: spaceContainer),
                Fixture.topAppsContainerItem(id: topContainer, children: [favouriteA, favouriteFolder]),
                Fixture.tabItem(id: favouriteA, url: "https://github.com/", savedTitle: "GitHub", parentID: topContainer),
                Fixture.folderItem(id: favouriteFolder, title: "Group", children: [favouriteB], parentID: topContainer),
                Fixture.tabItem(id: favouriteB, url: "https://linear.app/", savedTitle: "Linear", parentID: favouriteFolder),
            ],
            spaces: [Fixture.spaceJSON(id: spaceID, title: "General", pinnedContainerID: spaceContainer)],
            topAppsContainerID: topContainer
        )

        let document = try ArcSidebarDocument.parse(data: data, browser: .arc)
        XCTAssertEqual(
            document.topApps.map(\.title),
            ["GitHub", "Linear"],
            "The topAppsContainerIDs container's tabs are Arc's favourites row, flattened, in childrenIds order."
        )

        let space = try XCTUnwrap(document.spaces.first)
        XCTAssertEqual(Self.titles(space.pinned), ["In A Space"], "Favourites are per-profile and must not be duplicated into a Space.")
        XCTAssertEqual(Self.titles(space.today), [])
        XCTAssertFalse(
            (space.pinned + space.today).flatMap(\.allTabs).contains { document.topApps.map(\.arcID).contains($0.arcID) },
            "No top-app tab may appear in a Space's tree as well as in topApps."
        )
    }

    func testDocumentWithNoTopAppsContainerReturnsNoTopApps() throws {
        let spaceID = Fixture.uuid(180)
        let data = try Fixture.sidebarData(items: [], spaces: [Fixture.spaceJSON(id: spaceID, title: "General")])
        XCTAssertEqual(try ArcSidebarDocument.parse(data: data, browser: .arc).topApps, [], "topApps must be empty, never fabricated.")
    }

    // MARK: - 18. The archive

    func testArchiveParsesTimestampsReasonAndSourceSpaceNewestFirst() throws {
        let spaceA = Fixture.uuid(190)
        let spaceB = Fixture.uuid(191)

        let data = try Fixture.archiveData(entries: [
            Fixture.archiveEntry(
                id: Fixture.uuid(192),
                sidebarItem: Fixture.tabItem(id: Fixture.uuid(193), url: "https://old.example.com/", savedTitle: "Older",
                                             createdAt: 0.0, lastActiveAt: 100.0),
                archivedAt: 0.0,
                reason: "auto",
                sourceSpaceID: spaceB
            ),
            Fixture.archiveEntry(
                id: Fixture.uuid(194),
                sidebarItem: Fixture.tabItem(id: Fixture.uuid(195), url: "https://new.example.com/", savedTitle: "Newer",
                                             title: "Renamed In Archive", createdAt: 700_000_000.0),
                archivedAt: 700_000_000.0,
                reason: "manual",
                sourceSpaceID: spaceA
            ),
            Fixture.archiveEntry(
                id: Fixture.uuid(196),
                sidebarItem: Fixture.tabItem(id: Fixture.uuid(197), url: "https://middle.example.com/", savedTitle: "Middle",
                                             createdAt: 500_000_000.0),
                archivedAt: 500_000_000.0,
                reason: nil,
                sourceSpaceID: nil,
                standaloneSource: true
            ),
            Fixture.archiveEntry(
                id: Fixture.uuid(198),
                sidebarItem: Fixture.tabItem(id: Fixture.uuid(199), url: "arc://library", savedTitle: "Library"),
                archivedAt: 800_000_000.0,
                reason: "manual",
                sourceSpaceID: spaceA
            ),
            Fixture.archiveEntry(
                id: Fixture.uuid(200),
                sidebarItem: Fixture.tabItem(id: Fixture.uuid(201), url: "https://undated.example.com/", savedTitle: "Undated"),
                archivedAt: nil,
                reason: "manual",
                sourceSpaceID: spaceA
            ),
        ])

        let archived = try ArcArchiveDocument.parse(data: data, browser: .arc)
        XCTAssertEqual(
            archived.map(\.tab.title),
            ["Newer", "Middle", "Older"],
            "The archive must come back most-recently-archived first, with internal-scheme and undated rows excluded."
        )

        XCTAssertEqual(
            archived[0].archivedAt,
            Date(timeIntervalSince1970: 1_678_307_200),
            "archivedAt is CFAbsoluteTime, the same 2001 epoch as createdAt."
        )
        XCTAssertEqual(Self.iso8601(archived[0].archivedAt), "2023-03-08T20:26:40Z")
        XCTAssertEqual(archived[0].reason, "manual", "Arc's own reason string must be carried, not invented.")
        XCTAssertEqual(archived[0].sourceSpaceID, UUID(uuidString: spaceA), "source.space._0 must resolve to the Space the tab left.")
        XCTAssertEqual(archived[0].tab.customTitle, "Renamed In Archive", "The nested sidebarItem goes through the same code path as a live tab.")
        XCTAssertEqual(archived[0].tab.url, URL(string: "https://new.example.com/"))
        XCTAssertEqual(Self.iso8601(archived[0].tab.createdAt), "2023-03-08T20:26:40Z", "The archived tab's own createdAt is CFAbsoluteTime too.")

        XCTAssertNil(archived[1].reason, "A missing reason must stay nil rather than being defaulted to \"manual\".")
        XCTAssertNil(archived[1].sourceSpaceID, "A {\"standaloneSidebar\": {}} source carries no Space.")

        XCTAssertEqual(Self.iso8601(archived[2].archivedAt), "2001-01-01T00:00:00Z", "archivedAt 0.0 is 2001-01-01, not 1970-01-01.")
        XCTAssertEqual(archived[2].reason, "auto")
        XCTAssertEqual(archived[2].sourceSpaceID, UUID(uuidString: spaceB))
        XCTAssertEqual(Self.iso8601(try XCTUnwrap(archived[2].tab.lastActiveAt)), "2001-01-01T00:01:40Z", "100 seconds after the 2001 reference date.")
    }

    func testArchiveLimitClampsToTheMostRecentEntries() throws {
        let entries = (0..<5).map { index in
            Fixture.archiveEntry(
                id: Fixture.uuid(210 + index * 2),
                sidebarItem: Fixture.tabItem(id: Fixture.uuid(211 + index * 2), url: "https://example.com/\(index)",
                                             savedTitle: "Tab \(index)"),
                archivedAt: Double(index) * 1_000_000,
                reason: "manual",
                sourceSpaceID: nil
            )
        }
        let data = try Fixture.archiveData(entries: entries)

        XCTAssertEqual(try ArcArchiveDocument.parse(data: data, browser: .arc).map(\.tab.title),
                       ["Tab 4", "Tab 3", "Tab 2", "Tab 1", "Tab 0"],
                       "With no limit every entry comes back, newest first.")
        XCTAssertEqual(try ArcArchiveDocument.parse(data: data, browser: .arc, limit: 2).map(\.tab.title),
                       ["Tab 4", "Tab 3"],
                       "A limit must keep the most recently archived tabs, not the first ones in the file.")
        XCTAssertEqual(try ArcArchiveDocument.parse(data: data, browser: .arc, limit: 0), [],
                       "A limit of 0 must return nothing rather than everything.")
        XCTAssertEqual(try ArcArchiveDocument.parse(data: data, browser: .arc, limit: 50).count, 5,
                       "A limit larger than the document must not truncate or pad.")
    }

    func testArchivedFolderContributesOnlyItsTabsAndNeverAPhantomRow() throws {
        let data = try Fixture.archiveData(entries: [
            Fixture.archiveEntry(
                id: Fixture.uuid(230),
                sidebarItem: Fixture.tabItem(id: Fixture.uuid(231), url: "https://before.example.com/", savedTitle: "Before"),
                archivedAt: 300.0, reason: "manual", sourceSpaceID: nil
            ),
            Fixture.archiveEntry(
                id: Fixture.uuid(232),
                sidebarItem: Fixture.folderItem(id: Fixture.uuid(233), title: "Archived Folder",
                                                children: [Fixture.uuid(234), Fixture.uuid(235)]),
                archivedAt: 200.0, reason: "manual", sourceSpaceID: nil
            ),
            Fixture.archiveEntry(
                id: Fixture.uuid(236),
                sidebarItem: Fixture.tabItem(id: Fixture.uuid(237), url: "https://after.example.com/", savedTitle: "After"),
                archivedAt: 100.0, reason: "manual", sourceSpaceID: nil
            ),
        ])

        let archived = try ArcArchiveDocument.parse(data: data, browser: .arc)
        XCTAssertEqual(
            archived.map(\.tab.title),
            ["Before", "After"],
            "A folder in the archive flattens to its tabs — of which it has none here — and must not become an ArcArchivedTab itself."
        )
        XCTAssertFalse(archived.contains { $0.tab.title == "Archived Folder" }, "A folder must never be reported as an archived tab.")
    }

    // MARK: - 19. Error paths

    func testMalformedSidebarDocumentsThrowUnreadable() throws {
        try assertUnreadable(
            Data("this is definitely not JSON at all".utf8),
            "Non-JSON bytes must throw .unreadable rather than producing an empty import."
        )
        try assertUnreadable(
            try JSONSerialization.data(withJSONObject: [["global": [:] as [String: Any]]]),
            "A JSON array root must throw .unreadable — Arc's document is always an object."
        )
        try assertUnreadable(
            try JSONSerialization.data(withJSONObject: ["version": 3, "firebaseSyncState": [:] as [String: Any]]),
            "A document with no `sidebar` key must throw .unreadable."
        )
        try assertUnreadable(
            try JSONSerialization.data(withJSONObject: ["sidebar": ["version": 3] as [String: Any]]),
            "A `sidebar` with no `containers` array must throw .unreadable."
        )
        try assertUnreadable(
            try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": "not-an-array"] as [String: Any]]),
            "A `containers` value that is not an array must throw .unreadable."
        )
        try assertUnreadable(
            try JSONSerialization.data(withJSONObject: [
                "sidebar": ["containers": [["global": [:] as [String: Any]], ["spaces": [] as [Any]]]] as [String: Any],
            ]),
            "A containers array with no member carrying `items` must throw .unreadable rather than importing nothing silently."
        )
        try assertUnreadable(
            try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [] as [Any]] as [String: Any]]),
            "An empty containers array must throw .unreadable."
        )

        let empty = try Fixture.sidebarData(items: [], spaces: [])
        let document = try ArcSidebarDocument.parse(data: empty, browser: .arc)
        XCTAssertEqual(document.spaces, [])
        XCTAssertEqual(document.topApps, [])
    }

    func testMalformedArchiveDocumentsThrowUnreadable() throws {
        for (data, message) in [
            (Data("{ not json".utf8), "Non-JSON archive bytes must throw .unreadable."),
            (try JSONSerialization.data(withJSONObject: [[String: Any]()]), "A JSON array root must throw .unreadable."),
        ] {
            do {
                _ = try ArcArchiveDocument.parse(data: data, browser: .arc)
                XCTFail(message)
            } catch let error as BrowserImportError {
                guard case .unreadable(let browser, let reason) = error else {
                    return XCTFail("Expected .unreadable, got \(error).")
                }
                XCTAssertEqual(browser, .arc)
                XCTAssertFalse(reason.isEmpty, "The failure reason must say what was wrong.")
            }
        }

        let empty = try JSONSerialization.data(withJSONObject: ["version": 1])
        XCTAssertEqual(try ArcArchiveDocument.parse(data: empty, browser: .arc), [])
    }

    // MARK: - Assertion helpers

    private func assertUnreadable(_ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        do {
            _ = try ArcSidebarDocument.parse(data: data, browser: .arc)
            XCTFail(message, file: file, line: line)
        } catch let error as BrowserImportError {
            guard case .unreadable(let browser, let reason) = error else {
                return XCTFail("Expected .unreadable, got \(error). \(message)", file: file, line: line)
            }
            XCTAssertEqual(browser, .arc, file: file, line: line)
            XCTAssertFalse(reason.isEmpty, "The failure reason must say what was wrong.", file: file, line: line)
            XCTAssertNotNil(error.errorDescription, file: file, line: line)
        }
    }

    private static func titles(_ items: [ArcSidebarItem]) -> [String] {
        items.map { item in
            switch item {
            case .tab(let tab): return tab.title
            case .folder(let folder): return folder.name
            }
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func rawItemsArray(in data: Data) throws -> [Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let containers = try XCTUnwrap((root["sidebar"] as? [String: Any])?["containers"] as? [Any])
        let container = try XCTUnwrap(containers.compactMap { $0 as? [String: Any] }.first { $0["items"] != nil })
        return try XCTUnwrap(container["items"] as? [Any])
    }

    private static func rawSpaceObjects(in data: Data) throws -> [[String: Any]] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let containers = try XCTUnwrap((root["sidebar"] as? [String: Any])?["containers"] as? [Any])
        let container = try XCTUnwrap(containers.compactMap { $0 as? [String: Any] }.first { $0["spaces"] != nil })
        return (container["spaces"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private func parseUnderWatchdog(
        _ data: Data,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ArcSidebarDocument {
        let box = ParseResultBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.document = try ArcSidebarDocument.parse(data: data, browser: .arc)
            } catch {
                box.error = error
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            XCTFail(
                "Parsing did not terminate within \(timeout)s. The childrenIds cycle guard is not doing its job.",
                file: file,
                line: line
            )
            throw XCTSkip("Parse did not terminate; the rest of this test cannot run.")
        }
        if let error = box.error { throw error }
        return try XCTUnwrap(box.document, file: file, line: line)
    }

    private final class ParseResultBox: @unchecked Sendable {
        var document: ArcSidebarDocument?
        var error: Error?
    }

    // MARK: - Fixtures

    private enum Fixture {

        static func uuid(_ number: Int) -> String {
            String(format: "00000000-0000-4000-8000-%012d", number)
        }

        static let originatingDevice = "25AD00D0-2F74-4703-B6D7-DFDFC8FEB1D2"

        // MARK: Alternating arrays

        static func alternating(_ entries: [(id: String, object: [String: Any])]) -> [Any] {
            entries.flatMap { [$0.id as Any, $0.object as Any] }
        }

        static func alternating(_ objects: [[String: Any]]) -> [Any] {
            alternating(objects.map { (id: ($0["id"] as? String) ?? UUID().uuidString, object: $0) })
        }

        // MARK: Items

        static func tabItem(
            id: String,
            url: String,
            savedTitle: String = "",
            title: Any = NSNull(),
            parentID: Any = NSNull(),
            createdAt: Double = 0,
            lastActiveAt: Double? = nil,
            muteStatus: String = "allowAudio"
        ) -> [String: Any] {
            var tab: [String: Any] = [
                "savedURL": url,
                "savedTitle": savedTitle,
                "savedMuteStatus": muteStatus,
            ]
            if let lastActiveAt { tab["timeLastActiveAt"] = lastActiveAt }
            return [
                "id": id,
                "parentID": parentID,
                "title": title,
                "createdAt": createdAt,
                "isUnread": false,
                "originatingDevice": originatingDevice,
                "childrenIds": [] as [Any],
                "data": ["tab": tab],
            ]
        }

        static func folderItem(
            id: String,
            title: Any = NSNull(),
            children: [String] = [],
            parentID: Any = NSNull(),
            createdAt: Double = 0,
            iconType: [String: Any]? = nil
        ) -> [String: Any] {
            var list: [String: Any] = [:]
            if let iconType { list["customInfo"] = ["iconType": iconType] }
            return [
                "id": id,
                "parentID": parentID,
                "title": title,
                "createdAt": createdAt,
                "isUnread": false,
                "originatingDevice": originatingDevice,
                "childrenIds": children,
                "data": ["list": list],
            ]
        }

        static func containerItem(id: String, children: [String], spaceID: String) -> [String: Any] {
            [
                "id": id,
                "parentID": NSNull(),
                "title": NSNull(),
                "createdAt": 0,
                "isUnread": false,
                "originatingDevice": originatingDevice,
                "childrenIds": children,
                "data": ["itemContainer": ["containerType": ["spaceItems": ["_0": spaceID]]]],
            ]
        }

        static func topAppsContainerItem(id: String, children: [String]) -> [String: Any] {
            [
                "id": id,
                "parentID": NSNull(),
                "title": NSNull(),
                "createdAt": 0,
                "isUnread": false,
                "originatingDevice": originatingDevice,
                "childrenIds": children,
                "data": ["itemContainer": ["containerType": ["topApps": [:] as [String: Any]]]],
            ]
        }

        // MARK: Spaces

        static func spaceJSON(
            id: String,
            title: Any = NSNull(),
            pinnedContainerID: String? = nil,
            unpinnedContainerID: String? = nil,
            newPinnedContainerID: String? = nil,
            newUnpinnedContainerID: String? = nil,
            iconType: [String: Any]? = nil,
            windowTheme: [String: Any]? = nil
        ) -> [String: Any] {
            var space: [String: Any] = [
                "id": id,
                "title": title,
                "profile": ["default": [:] as [String: Any]],
            ]

            var containerIDs: [Any] = []
            if let pinnedContainerID { containerIDs += ["pinned", pinnedContainerID] }
            if let unpinnedContainerID { containerIDs += ["unpinned", unpinnedContainerID] }
            if !containerIDs.isEmpty { space["containerIDs"] = containerIDs }

            var newContainerIDs: [Any] = []
            if let newUnpinnedContainerID {
                newContainerIDs += [["unpinned": ["_0": ["shared": [:] as [String: Any]]]], newUnpinnedContainerID]
            }
            if let newPinnedContainerID {
                newContainerIDs += [["pinned": [:] as [String: Any]], newPinnedContainerID]
            }
            if !newContainerIDs.isEmpty { space["newContainerIDs"] = newContainerIDs }

            var customInfo: [String: Any] = [:]
            if let iconType { customInfo["iconType"] = iconType }
            if let windowTheme { customInfo["windowTheme"] = windowTheme }
            space["customInfo"] = customInfo

            return space
        }

        // MARK: Colours and themes

        static func colorJSON(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double,
                              colorSpace: String = "extendedSRGB") -> [String: Any] {
            ["red": red, "green": green, "blue": blue, "alpha": alpha, "colorSpace": colorSpace]
        }

        static func gradientTheme(
            baseColors: [[String: Any]],
            overlayColors: [[String: Any]],
            modifiers: [String: Any],
            appearance: String?,
            primaryShaded: [String: Any]?
        ) -> [String: Any] {
            var gradient: [String: Any] = [
                "baseColors": baseColors,
                "overlayColors": overlayColors,
                "wheel": ["analogous": [:] as [String: Any]],
                "translucencyStyle": "light",
            ]
            if !modifiers.isEmpty { gradient["modifiers"] = modifiers }
            return windowTheme(
                colorPayload: ["blendedGradient": ["_0": gradient]],
                appearance: appearance,
                primaryShaded: primaryShaded
            )
        }

        static func singleColorTheme(color: [String: Any], modifiers: [String: Any], appearance: String?) -> [String: Any] {
            var solid: [String: Any] = ["color": color]
            if !modifiers.isEmpty { solid["modifiers"] = modifiers }
            return windowTheme(
                colorPayload: ["blendedSingleColor": ["_0": solid]],
                appearance: appearance,
                primaryShaded: nil
            )
        }

        private static func windowTheme(
            colorPayload: [String: Any],
            appearance: String?,
            primaryShaded: [String: Any]?
        ) -> [String: Any] {
            var single: [String: Any] = [
                "isVibrant": true,
                "style": ["color": ["_0": colorPayload]],
            ]
            if let appearance { single["contentOverBackgroundAppearance"] = appearance }

            var theme: [String: Any] = ["background": ["single": ["_0": single]]]
            if let primaryShaded {
                theme["primaryColorPalette"] = ["shaded": primaryShaded, "tintedLight": colorJSON(0.9, 0.9, 0.9, 1)]
            }
            return theme
        }

        // MARK: Documents

        static func sidebarData(
            items: [[String: Any]],
            spaces: [[String: Any]],
            topAppsContainerID: String? = nil
        ) throws -> Data {
            var container: [String: Any] = [
                "items": alternating(items),
                "spaces": alternating(spaces),
            ]
            if let topAppsContainerID {
                container["topAppsContainerIDs"] = [["default": true], topAppsContainerID]
            }

            let root: [String: Any] = [
                "version": 3,
                "firebaseSyncState": ["serverChangeToken": "AQAAAF+…", "tombstones": [] as [Any]],
                "sidebarSyncState": ["lastSyncedAt": 800_000_000.0],
                "sidebar": ["containers": [["global": [:] as [String: Any]], container]],
            ]
            return try JSONSerialization.data(withJSONObject: root)
        }

        static func archiveEntry(
            id: String,
            sidebarItem: [String: Any],
            archivedAt: Double?,
            reason: String?,
            sourceSpaceID: String?,
            standaloneSource: Bool = false
        ) -> (id: String, object: [String: Any]) {
            var entry: [String: Any] = ["sidebarItem": sidebarItem]
            if let archivedAt { entry["archivedAt"] = archivedAt }
            if let reason { entry["reason"] = reason }
            if let sourceSpaceID {
                entry["source"] = ["space": ["_0": sourceSpaceID]]
            } else if standaloneSource {
                entry["source"] = ["standaloneSidebar": [:] as [String: Any]]
            }
            return (id: id, object: entry)
        }

        static func archiveData(entries: [(id: String, object: [String: Any])]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 1, "items": alternating(entries)])
        }
    }
}
