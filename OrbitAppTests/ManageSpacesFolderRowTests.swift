import SwiftUI
import XCTest
@testable import Orbit

// Renders ManageSpacesColumnsView directly: ImageRenderer cannot rasterise its ScrollView.
@MainActor
final class ManageSpacesFolderRowTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var spaceID: SpaceID!

    // A new Space is appended last, so this is its column's x-offset.
    private var columnXOffset: CGFloat = 0

    override func setUp() {
        super.setUp()
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(name: "Folder Row Scratch", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        let columnIndex = env.spaces.firstIndex { $0.id == spaceID } ?? 0
        columnXOffset = CGFloat(columnIndex) * (ManageSpacesMetrics.columnWidth + ManageSpacesMetrics.columnSpacing)
    }

    private func makeTab(_ title: String) -> TabID {
        let tabID = env.openTab(url: URL(string: "https://example.com/\(UUID().uuidString)")!, in: spaceID, section: .today, activate: false)
        env.state.tabs[tabID]?.title = title
        return tabID
    }

    private func renderColumn(height: CGFloat = 700) -> RenderedImage {
        let width = columnXOffset + ManageSpacesMetrics.columnWidth + 24
        let view = ManageSpacesColumnsView(onAddSpace: {})
            .environment(env)
            .environment(\.orbitScreenshotModeDragDisabled, true)
        return render(view, size: CGSize(width: width, height: height))
    }

    // The column background is opaque, so alpha can't tell text from background: sample instead.
    private func rightmostInk(in image: RenderedImage, xRange: Range<Int>, yRange: Range<Int>, background: RGBA, tolerance: Double = 0.12) -> Int? {
        var maxX: Int?
        for y in yRange {
            for x in xRange where !image.color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
                if maxX == nil || x > maxX! { maxX = x }
            }
        }
        return maxX
    }

    private func leftmostInk(in image: RenderedImage, xRange: Range<Int>, yRange: Range<Int>, background: RGBA, tolerance: Double = 0.12) -> Int? {
        var minX: Int?
        for y in yRange {
            for x in xRange where !image.color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
                if minX == nil || x < minX! { minX = x }
            }
        }
        return minX
    }

    // MARK: - 1. Folder row's own count reflects folder.children.count

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_folderRow_itemCount_reflectsChildrenCountNotAHardcodedValue

    func test_folderRow_itemCount_reflectsChildrenCountNotAHardcodedValue() {
        let smallFolderID = env.createFolder(name: "Small", in: spaceID)
        env.pinTab(makeTab("Small Child"), toParent: smallFolderID, atIndex: 0, in: spaceID)

        let bigFolderID = env.createFolder(name: "Big", in: spaceID)
        for index in 0..<12 {
            env.pinTab(makeTab("Big Child \(index)"), toParent: bigFolderID, atIndex: index, in: spaceID)
        }

        guard let smallFolder = env.store.folder(smallFolderID, in: spaceID),
              let bigFolder = env.store.folder(bigFolderID, in: spaceID)
        else {
            return XCTFail("test precondition: folders missing")
        }
        XCTAssertEqual(smallFolder.children.count, 1, "test precondition")
        XCTAssertEqual(bigFolder.children.count, 12, "test precondition")

        let image = renderColumn()

        let background = image.color(atX: Int(columnXOffset) + 20, y: 650)
        let columnRight = Int(columnXOffset + ManageSpacesMetrics.columnWidth)

        // Both are trailing-aligned, so the LEFT edge is what differs between "1" and "12".
        let smallInkX = leftmostInk(in: image, xRange: (columnRight - 40)..<columnRight, yRange: 28..<58, background: background)
        let bigInkX = leftmostInk(in: image, xRange: (columnRight - 40)..<columnRight, yRange: 66..<96, background: background)

        guard let smallInkX, let bigInkX else {
            return XCTFail("no count-badge ink found — test precondition (row position) is wrong; smallInkX=\(String(describing: smallInkX)) bigInkX=\(String(describing: bigInkX))")
        }

        XCTAssertLessThan(
            bigInkX, smallInkX - 2,
            "A folder with 12 children ('12', two digits) must render a count badge starting visibly further left (wider) than one with 1 child ('1', one digit), since both are pushed against the same trailing edge — got leftmost ink at x=\(bigInkX) (12 children) vs x=\(smallInkX) (1 child). Equal-or-later positions mean the badge is not actually reading folder.children.count."
        )
    }

    // MARK: - 2. A nested child tab does not appear as a top-level row

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_nestedChildTab_doesNotRenderAsATopLevelRow

    func test_nestedChildTab_doesNotRenderAsATopLevelRow() {
        let folderID = env.createFolder(name: "Parent", in: spaceID)
        env.pinTab(makeTab("NestedChild"), toParent: folderID, atIndex: 0, in: spaceID)
        env.pinTab(makeTab("LooseTopLevel"), toParent: nil, atIndex: 1, in: spaceID)

        guard let folder = env.store.folder(folderID, in: spaceID) else {
            return XCTFail("test precondition: folder missing")
        }
        XCTAssertTrue(folder.isExpanded, "test precondition: folder starts expanded so its child is actually on screen")

        let topLevelNodes = env.pinnedNodes(in: spaceID)
        XCTAssertEqual(
            topLevelNodes.count, 2,
            "pinnedNodes(in:) must return exactly the folder and the loose tab at the top level (2 nodes), not the folder plus its nested child flattened alongside it — got \(topLevelNodes.count)."
        )
        XCTAssertFalse(
            topLevelNodes.contains { if case .tab = $0, $0.id == folder.children.first?.id { return true }; return false },
            "the nested child must not itself be one of the top-level SidebarNodes returned for the space"
        )

        let image = renderColumn()
        let background = image.color(atX: Int(columnXOffset) + 20, y: 650)
        let columnLeft = Int(columnXOffset)
        let columnRight = Int(columnXOffset + ManageSpacesMetrics.columnWidth)

        // Rows: Parent, its expanded NestedChild, then LooseTopLevel, ~20pt apart.
        let nestedLeftX = leftmostInk(in: image, xRange: columnLeft..<columnRight, yRange: 64..<80, background: background)
        let looseLeftX = leftmostInk(in: image, xRange: columnLeft..<columnRight, yRange: 88..<104, background: background)

        guard let nestedLeftX, let looseLeftX else {
            return XCTFail("no row ink found — test precondition (row position) is wrong; nestedLeftX=\(String(describing: nestedLeftX)) looseLeftX=\(String(describing: looseLeftX))")
        }

        XCTAssertGreaterThan(
            nestedLeftX, looseLeftX + 4,
            "The nested child's row must be indented further right than a genuine top-level row (a real depth>0 SidebarNode), not start at the same leading edge — nested started at x=\(nestedLeftX), loose top-level at x=\(looseLeftX)."
        )
    }
}
