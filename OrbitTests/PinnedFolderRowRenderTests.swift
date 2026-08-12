import XCTest
import SwiftUI

@MainActor
final class PinnedFolderRowRenderTests: XCTestCase {

    private func makeFolder(name: String = "Reading") -> Folder {
        Folder(name: name)
    }

    // MARK: - Folder glyph + label

    func test_R1_pinnedFolderRowView_rendersFolderGlyphAndLabel() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let folder = makeFolder(name: "Reading")
        let size = CGSize(width: 200, height: OrbitMetrics.sidebarRowHeight)

        let rendered = render(
            PinnedFolderRowView(folder: folder, spaceID: SpaceID(), theme: theme, depth: 0).environment(env),
            size: size
        )

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "R1-folderRow-empty-FAILED")
            XCTFail("Expected PinnedFolderRowView to draw its folder glyph and label; the rendered image was entirely background.")
            return
        }

        XCTAssertEqual(
            box.minX, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset, accuracy: 3,
            "refs/ARC_VISUAL_REFERENCE.md §3: every sidebar row's content starts at sidebarHorizontalPadding + " +
            "sidebarRowContentInset at depth 0 — a folder row's glyph must line up with a tab row's " +
            "favicon, not sit at some other, folder-specific inset. See the diagnostic PNG if this fails."
        )
        XCTAssertGreaterThan(
            box.width, 40,
            "refs/DEFECTS.md R1: expected both a folder glyph and a rendered 'Reading' text label — the drawn " +
            "content's width (\(box.width)pt) is too narrow to be more than a bare glyph. See the diagnostic PNG."
        )
    }

    // Can't use boundingBoxOfContent's right edge: fixed trailing controls saturate the row's bounding box to the same width regardless of label length.
    func test_R1_pinnedFolderRowView_labelWidthRespondsToFolderName() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let size = CGSize(width: 500, height: OrbitMetrics.sidebarRowHeight)
        let labelSearchRect = CGRect(x: 0, y: 0, width: 350, height: OrbitMetrics.sidebarRowHeight)
        let background = RGBA(r: 0, g: 0, b: 0, a: 0)

        let shortRender = render(
            PinnedFolderRowView(folder: makeFolder(name: "A"), spaceID: SpaceID(), theme: theme, depth: 0)
                .environment(env),
            size: size
        )
        let longRender = render(
            PinnedFolderRowView(folder: makeFolder(name: "Imported From Chrome"), spaceID: SpaceID(), theme: theme, depth: 0)
                .environment(env),
            size: size
        )

        guard let shortRightEdge = rightmostContentX(shortRender, searchRect: labelSearchRect, background: background, tolerance: 0.03),
              let longRightEdge = rightmostContentX(longRender, searchRect: labelSearchRect, background: background, tolerance: 0.03) else {
            shortRender.writeDiagnosticPNG(named: "R1-folderRow-shortName-FAILED-empty")
            longRender.writeDiagnosticPNG(named: "R1-folderRow-longName-FAILED-empty")
            XCTFail("Expected PinnedFolderRowView to draw a visible label for both a short and a long folder name.")
            return
        }

        if longRightEdge <= shortRightEdge {
            shortRender.writeDiagnosticPNG(named: "R1-folderRow-shortName-FAILED")
            longRender.writeDiagnosticPNG(named: "R1-folderRow-longName-FAILED")
        }
        XCTAssertGreaterThan(
            longRightEdge, shortRightEdge,
            "'Imported From Chrome' (refs/reference/arc-bookmarks-structure.png's own example folder name) must " +
            "extend measurably further right than 'A' — proving the label isn't frozen on a fixed layout. Short " +
            "label's rightmost drawn pixel at x=\(shortRightEdge)pt, long label's at x=\(longRightEdge)pt."
        )
    }

    // MARK: - Indentation increases with nesting depth

    func test_R1_pinnedFolderRowView_indentsByExactlyIndentPerDepthTimesDepth() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let folder = makeFolder(name: "Inner")
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarRowHeight)

        let depth0 = render(PinnedFolderRowView(folder: folder, spaceID: SpaceID(), theme: theme, depth: 0).environment(env), size: size)
        let depth2 = render(PinnedFolderRowView(folder: folder, spaceID: SpaceID(), theme: theme, depth: 2).environment(env), size: size)

        guard let box0 = depth0.boundingBoxOfContent(tolerance: 0.03),
              let box2 = depth2.boundingBoxOfContent(tolerance: 0.03) else {
            depth0.writeDiagnosticPNG(named: "R1-folderRow-depth0-FAILED-empty")
            depth2.writeDiagnosticPNG(named: "R1-folderRow-depth2-FAILED-empty")
            XCTFail("Expected PinnedFolderRowView to draw content at both depth 0 and depth 2.")
            return
        }

        let expectedShift = 2 * OrbitMetrics.sidebarIndentPerDepth
        let actualShift = box2.minX - box0.minX
        if abs(actualShift - expectedShift) > 3 {
            depth0.writeDiagnosticPNG(named: "R1-folderRow-depth0-FAILED")
            depth2.writeDiagnosticPNG(named: "R1-folderRow-depth2-FAILED")
        }
        XCTAssertEqual(
            actualShift, expectedShift, accuracy: 3,
            "A folder nested two levels deep (SidebarNodeRow recursing depth: depth + 1 twice) must render " +
            "\(expectedShift)pt (2 × OrbitMetrics.sidebarIndentPerDepth) to the right of the same folder at the " +
            "root. Measured shift: \(actualShift)pt (depth 0 minX=\(box0.minX), depth 2 minX=\(box2.minX))."
        )
    }

    func test_R1_pinnedFolderRowView_indentationStepIsConsistentAcrossConsecutiveDepths() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let folder = makeFolder(name: "Inner")
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarRowHeight)

        let leadingXs: [CGFloat] = (0...3).map { depth in
            let rendered = render(PinnedFolderRowView(folder: folder, spaceID: SpaceID(), theme: theme, depth: depth).environment(env), size: size)
            guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
                rendered.writeDiagnosticPNG(named: "R1-folderRow-depth\(depth)-FAILED-empty")
                XCTFail("Expected content at depth \(depth).")
                return -1
            }
            return box.minX
        }
        guard leadingXs.allSatisfy({ $0 >= 0 }) else { return }

        for depth in 1..<leadingXs.count {
            let step = leadingXs[depth] - leadingXs[depth - 1]
            XCTAssertEqual(
                step, OrbitMetrics.sidebarIndentPerDepth, accuracy: 3,
                "Depth \(depth - 1) → \(depth) should shift the row's leading content by exactly one " +
                "sidebarIndentPerDepth (\(OrbitMetrics.sidebarIndentPerDepth)pt); measured \(step)pt. Full series: \(leadingXs)."
            )
        }
    }
}

// MARK: - Test-only helpers

@MainActor
private func rightmostContentX(_ rendered: RenderedImage, searchRect: CGRect, background: RGBA, tolerance: Double) -> CGFloat? {
    let minX = max(0, Int(searchRect.minX.rounded(.down)))
    let maxX = Int(searchRect.maxX.rounded(.up))
    let minY = max(0, Int(searchRect.minY.rounded(.down)))
    let maxY = Int(searchRect.maxY.rounded(.up))
    guard minX < maxX, minY < maxY else { return nil }

    for x in stride(from: maxX - 1, through: minX, by: -1) {
        for y in minY..<maxY {
            if !rendered.color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
                return CGFloat(x)
            }
        }
    }
    return nil
}
