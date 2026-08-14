import XCTest
import SwiftUI

// MARK: - Tests

@MainActor
final class LibraryTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    // MARK: Date-group titles

    func test_dateGroupTitle_sameDayIsToday() {
        let now = Date()
        XCTAssertEqual(LibraryDateGrouping.title(for: now, calendar: calendar, now: now), "Today")
    }

    func test_dateGroupTitle_oneDayBackIsYesterday() {
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(LibraryDateGrouping.title(for: yesterday, calendar: calendar, now: now), "Yesterday")
    }

    func test_dateGroupTitle_withinPastWeekIsAWeekdayName() {
        let now = Date()
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        let title = LibraryDateGrouping.title(for: threeDaysAgo, calendar: calendar, now: now)
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        XCTAssertEqual(title, weekdayFormatter.string(from: threeDaysAgo))
        XCTAssertNotEqual(title, "Today")
        XCTAssertNotEqual(title, "Yesterday")
    }

    func test_dateGroupTitle_overAWeekAgoIsAFullDate() {
        let now = Date()
        let threeWeeksAgo = calendar.date(byAdding: .day, value: -21, to: now)!
        let title = LibraryDateGrouping.title(for: threeWeeksAgo, calendar: calendar, now: now)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d"
        XCTAssertEqual(title, dateFormatter.string(from: threeWeeksAgo))
    }

    func test_dateGroupTitle_previousYearIncludesTheYear() {
        let now = Date()
        let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
        let title = LibraryDateGrouping.title(for: lastYear, calendar: calendar, now: now)
        XCTAssertTrue(title.contains(String(calendar.component(.year, from: lastYear))))
    }

    // MARK: Grouping order, against the real `DownloadItem` model

    func test_group_ordersNewestGroupFirstAndNewestItemFirstWithinAGroup() {
        // A fixed noon anchor, not Date(): anchoring on the real clock made
        // this test fail deterministically whenever the suite ran near local midnight.
        let now = Self.fixedNoon
        let today1 = makeDownload(startedAt: now.addingTimeInterval(-60))
        let today2 = makeDownload(startedAt: now.addingTimeInterval(-3600))
        let yesterday = makeDownload(startedAt: calendar.date(byAdding: .day, value: -1, to: now)!)

        let groups = LibraryDateGrouping.group([yesterday, today2, today1], now: now, date: \.startedAt)

        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(groups[0].items.map(\.id), [today1.id, today2.id], "newest download in the Today bucket must render first")
        XCTAssertEqual(groups[1].items.map(\.id), [yesterday.id])
    }

    // MARK: Grouping order, against the real `Tab` model (Archived Tabs)

    func test_group_bucketsArchivedTabsByArchivedDate() {
        let now = Date()
        let spaceID = SpaceID()
        let recentlyArchived = makeTab(spaceID: spaceID, archivedAt: now.addingTimeInterval(-120))
        let olderArchive = makeTab(spaceID: spaceID, archivedAt: calendar.date(byAdding: .day, value: -10, to: now)!)

        let groups = LibraryDateGrouping.group(
            [olderArchive, recentlyArchived],
            now: now,
            date: { $0.archivedAt ?? $0.lastAccessedAt }
        )

        XCTAssertEqual(groups.first?.items.first?.id, recentlyArchived.id, "most recently archived tab must sort into the newest bucket first")
        XCTAssertEqual(groups.count, 2)
    }

    // MARK: - Archive folder tree construction (ArchivedTabTreeBuilder)

    func test_treeBuilder_tabWithNoTrailRendersFlatAtRoot() {
        let tab = makeTab(spaceID: SpaceID(), archivedAt: Date())
        let nodes = ArchivedTabTreeBuilder.build(from: [tab])
        XCTAssertEqual(nodes.count, 1)
        guard case .tab(let rendered) = nodes.first else {
            return XCTFail("An un-foldered archived tab must still render as a flat row, matching the old behavior.")
        }
        XCTAssertEqual(rendered.id, tab.id)
    }

    func test_treeBuilder_reconstructsNestedFolderFromTrail() {
        let parentCrumb = ArchivedFolderCrumb(id: FolderID(), name: "Reading")
        let childCrumb = ArchivedFolderCrumb(id: FolderID(), name: "Long Reads")
        var tab = makeTab(spaceID: SpaceID(), archivedAt: Date())
        tab.archivedFolderTrail = [parentCrumb, childCrumb]

        let nodes = ArchivedTabTreeBuilder.build(from: [tab])
        XCTAssertEqual(nodes.count, 1)
        guard case .folder(let parent) = nodes.first else {
            return XCTFail("Expected the root node to be the outer folder.")
        }
        XCTAssertEqual(parent.id, parentCrumb.id)
        XCTAssertEqual(parent.name, "Reading")
        XCTAssertEqual(parent.children.count, 1)

        guard case .folder(let child) = parent.children.first else {
            return XCTFail("Expected a nested subfolder, not a flattened tab.")
        }
        XCTAssertEqual(child.id, childCrumb.id)
        XCTAssertEqual(child.name, "Long Reads")
        XCTAssertEqual(child.children.count, 1)

        guard case .tab(let leaf) = child.children.first else {
            return XCTFail("Expected the tab at the bottom of the nested chain.")
        }
        XCTAssertEqual(leaf.id, tab.id, "The tab must keep its folder membership through the rebuild.")
    }

    func test_treeBuilder_groupsSiblingTabsUnderTheSameFolderNodeInstance() {
        let crumb = ArchivedFolderCrumb(id: FolderID(), name: "Recipes")
        var first = makeTab(spaceID: SpaceID(), archivedAt: Date())
        first.archivedFolderTrail = [crumb]
        var second = makeTab(spaceID: SpaceID(), archivedAt: Date())
        second.archivedFolderTrail = [crumb]

        let nodes = ArchivedTabTreeBuilder.build(from: [first, second])
        XCTAssertEqual(nodes.count, 1, "Two tabs from the same folder must not produce two separate folder rows.")
        guard case .folder(let folder) = nodes.first else {
            return XCTFail("Expected a single folder node.")
        }
        XCTAssertEqual(folder.children.map(\.id), [first.id, second.id])
    }

    func test_treeBuilder_mixesFolderedAndFlatTabsAtRoot() {
        let crumb = ArchivedFolderCrumb(id: FolderID(), name: "Work")
        var foldered = makeTab(spaceID: SpaceID(), archivedAt: Date())
        foldered.archivedFolderTrail = [crumb]
        let flat = makeTab(spaceID: SpaceID(), archivedAt: Date())

        let nodes = ArchivedTabTreeBuilder.build(from: [foldered, flat])
        XCTAssertEqual(nodes.count, 2, "A folder and a loose tab must coexist as siblings at the root.")
    }

    // MARK: - BrowserStore: folder membership survives archive/restore

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-LibraryArchive-\(UUID().uuidString)", isDirectory: true)
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

    func test_archiveTab_capturesNestedFolderTrail_andRestorePutsItBack() {
        let store = makeStore()
        let space = store.activeSpace!
        let parentID = store.createFolder(name: "Reading", in: space.id)
        let childID = store.createFolder(name: "Long Reads", in: space.id, parent: parentID)

        let tabID = store.openTab(url: URL(string: "https://example.com/article")!, in: space.id, section: .today)
        store.pin(tabID, toParent: childID, atIndex: 0, in: space.id)

        store.archiveTab(tabID)

        let trail = store.tab(tabID)?.archivedFolderTrail
        XCTAssertEqual(trail?.map(\.id), [parentID, childID], "Trail must be root-to-parent, deepest last.")
        XCTAssertEqual(trail?.map(\.name), ["Reading", "Long Reads"])
        XCTAssertNil(PinnedNodeTree.find(tabID, in: store.pinnedNodes(in: space.id)), "Archiving must still remove the tab from the live pinned tree.")

        store.restoreFromArchive(tabID, to: .pinned)

        XCTAssertNil(store.tab(tabID)?.archivedFolderTrail, "A restored tab is live again; it should not carry a stale trail.")
        guard let restoredParentID = PinnedNodeTree.parentFolderID(of: tabID, in: store.pinnedNodes(in: space.id)) else {
            return XCTFail("Restoring to .pinned must put the tab back somewhere in the pinned tree.")
        }
        XCTAssertEqual(restoredParentID, childID, "The tab must land back in the exact nested subfolder it was archived from.")
    }

    func test_archiveTab_recreatesADeletedFolderChainOnRestore() {
        let store = makeStore()
        let space = store.activeSpace!
        let folderID = store.createFolder(name: "Temp", in: space.id)
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id, section: .today)
        store.pin(tabID, toParent: folderID, atIndex: 0, in: space.id)

        store.archiveTab(tabID)
        store.deleteFolder(folderID, in: space.id)
        XCTAssertNil(PinnedNodeTree.findFolder(folderID, in: store.pinnedNodes(in: space.id)), "test precondition: the folder is gone")

        store.restoreFromArchive(tabID, to: .pinned)

        guard let folder = PinnedNodeTree.findFolder(folderID, in: store.pinnedNodes(in: space.id)) else {
            return XCTFail("Restoring must recreate a deleted folder so the tab's membership is not silently dropped.")
        }
        XCTAssertEqual(folder.name, "Temp")
        XCTAssertEqual(folder.allTabIDs, [tabID])
    }

    func test_archiveTab_topLevelPinnedTabHasNoFolderTrail() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id, section: .pinned)

        store.archiveTab(tabID)

        XCTAssertNil(store.tab(tabID)?.archivedFolderTrail, "A tab pinned at the top level, outside any folder, must not gain a synthetic trail.")
    }

    func test_archiveTab_todayTabHasNoFolderTrail() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id, section: .today)

        store.archiveTab(tabID)

        XCTAssertNil(store.tab(tabID)?.archivedFolderTrail, "Today tabs have no folder support in the sidebar; nothing to capture.")
    }

    // MARK: Palette fidelity — `refs/ARC_VISUAL_REFERENCE.md` §2 measured hex values

    func test_libraryPalette_sidebarBackground_matchesMeasuredArcHex() {
        // #2A2532
        let components = LibraryPalette.sidebarBackground.srgbComponents
        XCTAssertEqual(components.red, (0x2A).u8Fraction, accuracy: 0.01)
        XCTAssertEqual(components.green, (0x25).u8Fraction, accuracy: 0.01)
        XCTAssertEqual(components.blue, (0x32).u8Fraction, accuracy: 0.01)
    }

    func test_libraryPalette_contentBackground_matchesMeasuredArcHex() {
        // #332C3A
        let components = LibraryPalette.contentBackground.srgbComponents
        XCTAssertEqual(components.red, (0x33).u8Fraction, accuracy: 0.01)
        XCTAssertEqual(components.green, (0x2C).u8Fraction, accuracy: 0.01)
        XCTAssertEqual(components.blue, (0x3A).u8Fraction, accuracy: 0.01)
    }

    func test_libraryPalette_contentIsSlightlyLighterThanSidebar() {
        let sidebarLuma = LibraryPalette.sidebarBackground.approximateLuminance
        let contentLuma = LibraryPalette.contentBackground.approximateLuminance
        XCTAssertGreaterThan(contentLuma, sidebarLuma)
    }

    // MARK: - Fixtures

    private static let fixedNoon: Date = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12, minute: 0, second: 0))!

    private func makeDownload(startedAt: Date) -> DownloadItem {
        DownloadItem(
            sourceURL: URL(string: "https://example.com/file.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file-\(UUID().uuidString).zip"),
            suggestedFileName: "file.zip",
            startedAt: startedAt
        )
    }

    private func makeTab(spaceID: SpaceID, archivedAt: Date) -> Tab {
        Tab(
            spaceID: spaceID,
            section: .archived,
            url: URL(string: "https://example.com")!,
            archivedAt: archivedAt
        )
    }
}

private extension Int {
    /// `0xNN` treated as an 8-bit sRGB channel, as the `0...1` fraction `ThemeColor`/`Color` store.
    var u8Fraction: Double { Double(self) / 255.0 }
}
