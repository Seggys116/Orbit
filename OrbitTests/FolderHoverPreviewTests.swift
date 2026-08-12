import XCTest
import SwiftUI

@MainActor
final class FolderHoverPreviewTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTab(_ title: String, host: String = "example.com", lastAccessedAt: Date = Date()) -> Tab {
        Tab(
            spaceID: SpaceID(),
            section: .pinned,
            url: URL(string: "https://\(host)/\(title)")!,
            title: title,
            lastAccessedAt: lastAccessedAt
        )
    }

    // isExpanded: false is passed explicitly because Folder.init defaults it
    // to true; the peek only applies to a collapsed folder.
    private func makeNestedForest() -> (nodes: [SidebarNode], folder: Folder, outer: Tab, inner: Tab) {
        let outer = makeTab("Outer")
        let inner = makeTab("Inner")
        let sub = Folder(name: "Sub", isExpanded: false, children: [.tab(inner.id)])
        let folder = Folder(name: "Reading", isExpanded: false, children: [.tab(outer.id), .folder(sub)])
        return ([.folder(folder)], folder, outer, inner)
    }

    // MARK: - Flattening (`allPossibleChildren`)

    func test_folderPreviewState_flattensNestedSubfolderTabs() {
        let (nodes, folder, outer, inner) = makeNestedForest()
        let byID = [outer.id: outer, inner.id: inner]

        let state = FolderPreviewState.make(folderID: folder.id, in: nodes) { byID[$0] }

        XCTAssertNotNil(state, "Expected a preview state for a folder that is in the forest.")
        XCTAssertEqual(
            state?.allPossibleChildren.map(\.tabID),
            [outer.id, inner.id],
            "allPossibleChildren must flatten every descendant tab depth-first, including tabs inside nested subfolders — not just the folder's direct children."
        )
    }

    func test_folderPreviewItem_carriesTitleURLAndLastVisitFromTheTab() {
        let visited = Date(timeIntervalSince1970: 1_700_000_000)
        var tab = makeTab("Docs", host: "swift.org", lastAccessedAt: visited)
        tab.faviconURL = URL(string: "https://swift.org/favicon.ico")
        var folder = Folder(name: "Reading")
        folder.children = [.tab(tab.id)]

        let state = FolderPreviewState.make(folderID: folder.id, in: [.folder(folder)]) { $0 == tab.id ? tab : nil }
        let item = state?.allPossibleChildren.first

        XCTAssertEqual(item?.title, tab.displayTitle)
        XCTAssertEqual(item?.url, tab.url)
        XCTAssertEqual(item?.faviconURL, tab.faviconURL)
        XCTAssertEqual(item?.lastVisitedAt, visited, "The row's subtitle is Arc's lastVisitDate; Orbit's is Tab.lastAccessedAt.")
    }

    func test_folderPreviewState_dropsNodesWhoseTabNoLongerResolves() {
        let present = makeTab("Present")
        let missing = makeTab("Missing")
        var folder = Folder(name: "Reading")
        folder.children = [.tab(present.id), .tab(missing.id)]

        let state = FolderPreviewState.make(folderID: folder.id, in: [.folder(folder)]) { $0 == present.id ? present : nil }

        XCTAssertEqual(state?.allPossibleChildren.map(\.tabID), [present.id])
    }

    func test_folderPreviewState_isNilForAFolderNotInTheForest() {
        let state = FolderPreviewState.make(folderID: FolderID(), in: [], resolveTab: { _ in nil })
        XCTAssertNil(state)
    }

    func test_folderPreviewState_carriesTheFolderNameForTheHeader() {
        let tab = makeTab("Anything")
        var folder = Folder(name: "Trip Planning")
        folder.children = [.tab(tab.id)]

        let state = FolderPreviewState.make(folderID: folder.id, in: [.folder(folder)]) { _ in tab }

        XCTAssertEqual(state?.title, "Trip Planning")
    }

    // MARK: - Presentation gate

    func test_shouldPresentFolderPreview_isFalseForAnEmptyFolder() {
        let folder = Folder(name: "Empty")
        let state = FolderPreviewState.make(folderID: folder.id, in: [.folder(folder)], resolveTab: { _ in nil })

        XCTAssertEqual(state?.hasContent, false)
        XCTAssertFalse(
            PinnedFolderRowView.shouldPresentFolderPreview(state: state, isRenaming: false, isExpanded: false),
            "Hovering a folder with no tabs must present nothing, not an empty panel."
        )
    }

    func test_shouldPresentFolderPreview_isTrueForAFolderWithTabs() {
        let tab = makeTab("Something")
        var folder = Folder(name: "Reading")
        folder.children = [.tab(tab.id)]
        let state = FolderPreviewState.make(folderID: folder.id, in: [.folder(folder)]) { _ in tab }

        XCTAssertEqual(state?.hasContent, true)
        XCTAssertTrue(PinnedFolderRowView.shouldPresentFolderPreview(state: state, isRenaming: false, isExpanded: false))
    }

    func test_shouldPresentFolderPreview_isFalseWhileRenaming() {
        let tab = makeTab("Something")
        var folder = Folder(name: "Reading")
        folder.children = [.tab(tab.id)]
        let state = FolderPreviewState.make(folderID: folder.id, in: [.folder(folder)]) { _ in tab }

        XCTAssertFalse(PinnedFolderRowView.shouldPresentFolderPreview(state: state, isRenaming: true, isExpanded: false))
    }

    func test_shouldPresentFolderPreview_isFalseWithNoState() {
        XCTAssertFalse(PinnedFolderRowView.shouldPresentFolderPreview(state: nil, isRenaming: false, isExpanded: false))
    }

    func test_shouldPresentFolderPreview_isFalseWhenExpanded_evenWithRealContent() {
        let tab = makeTab("Something")
        var folder = Folder(name: "Reading")
        folder.children = [.tab(tab.id)]
        let state = FolderPreviewState.make(folderID: folder.id, in: [.folder(folder)]) { _ in tab }

        XCTAssertEqual(state?.hasContent, true, "Precondition: this folder genuinely has content to preview.")
        XCTAssertFalse(
            PinnedFolderRowView.shouldPresentFolderPreview(state: state, isRenaming: false, isExpanded: true),
            "An expanded folder's children are already visible in the sidebar beneath this row — the hover " +
            "preview must not present a second copy of them."
        )
    }

    func test_shouldPresentFolderPreview_isTrueWhenCollapsedAndNotRenaming() {
        let tab = makeTab("Something")
        var folder = Folder(name: "Reading")
        folder.children = [.tab(tab.id)]
        let state = FolderPreviewState.make(folderID: folder.id, in: [.folder(folder)]) { _ in tab }

        XCTAssertTrue(PinnedFolderRowView.shouldPresentFolderPreview(state: state, isRenaming: false, isExpanded: false))
    }

    // MARK: - Peek (selecting from the preview)

    func test_peekedTabID_returnsTheActiveTabForACollapsedFolderContainingIt() {
        let (_, folder, outer, _) = makeNestedForest()

        XCTAssertEqual(PinnedNodeTree.peekedTabID(inCollapsedFolder: folder, activeTabID: outer.id), outer.id)
    }

    func test_peekedTabID_reachesATabInsideANestedSubfolder() {
        let (_, folder, _, inner) = makeNestedForest()

        XCTAssertEqual(PinnedNodeTree.peekedTabID(inCollapsedFolder: folder, activeTabID: inner.id), inner.id)
    }

    func test_peekedTabID_isNilWhenTheFolderIsExpanded() {
        var (_, folder, outer, _) = makeNestedForest()
        folder.isExpanded = true

        XCTAssertNil(PinnedNodeTree.peekedTabID(inCollapsedFolder: folder, activeTabID: outer.id))
    }

    func test_peekedTabID_isNilWhenTheActiveTabIsElsewhere() {
        let (_, folder, _, _) = makeNestedForest()
        let unrelated = makeTab("Unrelated")

        XCTAssertNil(PinnedNodeTree.peekedTabID(inCollapsedFolder: folder, activeTabID: unrelated.id))
    }

    func test_peekedTabID_isNilWithNoActiveTab() {
        let (_, folder, _, _) = makeNestedForest()

        XCTAssertNil(PinnedNodeTree.peekedTabID(inCollapsedFolder: folder, activeTabID: nil))
    }

    // MARK: - Row subtitle

    func test_relativeVisitDescription_distinguishesJustNowFromACountedInterval() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = FolderHoverPreviewRow.relativeVisitDescription(for: now.addingTimeInterval(-5), now: now)
        let older = FolderHoverPreviewRow.relativeVisitDescription(for: now.addingTimeInterval(-18 * 60), now: now)

        XCTAssertEqual(recent, "Just now")
        XCTAssertNotEqual(older, "Just now", "A visit 18 minutes ago must read as an interval, not 'Just now'.")
        XCTAssertTrue(older.contains("18"), "Expected a counted interval mentioning 18 minutes; got \(older).")
    }

    // MARK: - Render

    // Targets FolderHoverPreviewList, not FolderHoverPreviewView: ImageRenderer renders ScrollView content blank, so rasterising the whole panel would assert against an empty bitmap and pass for the wrong reason.
    func test_folderHoverPreviewList_drawsItsRows() {
        let env = AppEnvironment()
        let now = Date()
        let items = [
            FolderPreviewItem(tabID: TabID(), title: "Modern Classic Dinnerware", url: URL(string: "https://mmmhome.io/a")!, faviconURL: nil, lastVisitedAt: now.addingTimeInterval(-18 * 60)),
            FolderPreviewItem(tabID: TabID(), title: "Two Five Stoneware", url: URL(string: "https://mmmhome.io/b")!, faviconURL: nil, lastVisitedAt: now)
        ]
        let size = CGSize(width: OrbitMetrics.folderPreviewWidth, height: OrbitMetrics.commandBarRowHeight * 2)

        let rendered = render(
            FolderHoverPreviewList(items: items, onSelect: { _ in }).environment(env),
            size: size
        )

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "folderPreviewList-empty-FAILED")
            return XCTFail("Expected FolderHoverPreviewList to draw its rows; the rendered image was entirely background.")
        }
        XCTAssertGreaterThan(
            box.height, OrbitMetrics.commandBarRowHeight,
            "Expected content spanning both rows, not just one; drew \(box)."
        )
        XCTAssertGreaterThan(
            box.width, OrbitMetrics.iconFavicon * 2,
            "Expected a title and subtitle beside the favicon, not a favicon alone; drew \(box)."
        )
    }
}
