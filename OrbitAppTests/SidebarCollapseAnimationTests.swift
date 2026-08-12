import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SidebarCollapseAnimationTests: XCTestCase {

    private let columnWidth: CGFloat = 200
    private let windowWidth: CGFloat = 400
    private let rowY = 20

    private let markerLeading: CGFloat = 170
    private let markerWidth: CGFloat = 20

    private var markerCentreWhenDocked: CGFloat { markerLeading + markerWidth / 2 }

    // MARK: - Fixture

    private static let markerColor = Color(red: 1, green: 0, blue: 0)
    private static let contentColor = Color(red: 0, green: 0, blue: 1)

    private var columnStandIn: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: markerLeading)
            SidebarCollapseAnimationTests.markerColor.frame(width: markerWidth)
            Color.clear
        }
        .frame(width: columnWidth)
    }

    private func renderFrame(progress: Double, renderWidth: CGFloat) -> RenderedImage {
        let view = HStack(spacing: 0) {
            columnStandIn
                .modifier(SidebarCollapseModifier(progress: progress, fullWidth: columnWidth))
            SidebarCollapseAnimationTests.contentColor
        }
        .frame(width: windowWidth, height: 40, alignment: .leading)

        return render(view, size: CGSize(width: renderWidth, height: 40))
    }

    // MARK: - Colour predicates

    private func isMarker(_ sample: RGBA) -> Bool {
        sample.a > 0.05 && sample.r > sample.b + 0.05 && sample.r > sample.g + 0.05
    }

    private func isContentColumn(_ sample: RGBA) -> Bool {
        sample.a > 0.5 && sample.b > sample.r + 0.5 && sample.b > sample.g + 0.5
    }

    private func contentColumnLeadingEdge(_ image: RenderedImage) -> CGFloat? {
        for x in 0..<Int(windowWidth) where isContentColumn(image.color(atX: x, y: rowY)) {
            return CGFloat(x)
        }
        return nil
    }

    private func markerCentre(_ image: RenderedImage) -> CGFloat? {
        var first: Int?
        var last: Int?
        for x in 0..<Int(windowWidth) where isMarker(image.color(atX: x, y: rowY)) {
            if first == nil { first = x }
            last = x
        }
        guard let first, let last else { return nil }
        return (CGFloat(first) + CGFloat(last) + 1) / 2
    }

    // MARK: - The resting states (unchanged by this fix, asserted so they stay that way)

    func test_docked_columnOccupiesItsFullWidthAndContentStartsAfterIt() throws {
        let image = renderFrame(progress: 1, renderWidth: windowWidth)
        image.writeDiagnosticPNG(named: "sidebar-collapse-progress-100")

        XCTAssertEqual(
            contentColumnLeadingEdge(image) ?? -1,
            columnWidth,
            accuracy: 1,
            "Fully docked, the content column must begin exactly where the sidebar column ends (\(columnWidth)pt)."
        )
        XCTAssertEqual(
            markerCentre(image) ?? -1,
            markerCentreWhenDocked,
            accuracy: 1,
            "Fully docked, the column's interior must sit at its natural position — the identity end of the transition has to be a no-op, or docking the sidebar would shift every row sideways."
        )
    }

    func test_collapsed_columnIsGoneAndContentOwnsTheWholeWindow() throws {
        let image = renderFrame(progress: 0, renderWidth: windowWidth + 1)
        image.writeDiagnosticPNG(named: "sidebar-collapse-progress-0")

        XCTAssertEqual(
            contentColumnLeadingEdge(image) ?? -1,
            0,
            accuracy: 1,
            "Fully collapsed, the content column must start at the window's leading edge — the sidebar has given all of its width back."
        )
        XCTAssertNil(
            markerCentre(image),
            "Fully collapsed, nothing of the sidebar's interior may still be painted. `.clipped()` in `SidebarCollapseModifier` is what guarantees it, and a marker surviving here means the interior is overflowing into the page instead of sliding out under the column's own edge."
        )
    }

    // MARK: - The frames in between: what the user actually reported

    func test_midCollapse_contentsTravelExactlyAsFarAsTheContentColumnsEdge() throws {
        let frames: [(progress: Double, renderWidth: CGFloat)] = [
            (0.75, windowWidth + 2),
            (0.5, windowWidth + 3),
            (0.25, windowWidth + 4),
        ]

        for frame in frames {
            let image = renderFrame(progress: frame.progress, renderWidth: frame.renderWidth)
            image.writeDiagnosticPNG(named: "sidebar-collapse-progress-\(Int(frame.progress * 100))")

            let edge = try XCTUnwrap(
                contentColumnLeadingEdge(image),
                "No content column found at progress \(frame.progress)."
            )
            let centre = try XCTUnwrap(
                markerCentre(image),
                "The marker sits \(markerCentreWhenDocked)pt into a \(columnWidth)pt column, so it must still be on screen at progress \(frame.progress) — its absence means the interior is being clipped from the wrong edge."
            )

            XCTAssertEqual(
                edge,
                columnWidth * frame.progress,
                accuracy: 1,
                "At progress \(frame.progress) the content column must begin at \(columnWidth * frame.progress)pt."
            )

            XCTAssertEqual(
                edge - centre,
                columnWidth - markerCentreWhenDocked,
                accuracy: 1,
                """
                At progress \(frame.progress) the sidebar's contents are \(edge - centre)pt from the content column's leading edge, \
                but docked they are \(columnWidth - markerCentreWhenDocked)pt from it. The interior is not travelling with the column — \
                this is the user's "favicons stay put as the sidepanel collapses" verbatim.
                """
            )
        }
    }

    func test_midCollapse_interiorIsTranslatedNeverReflowed() throws {
        let image = renderFrame(progress: 0.6, renderWidth: windowWidth + 5)

        var first: Int?
        var last: Int?
        for x in 0..<Int(windowWidth) where isMarker(image.color(atX: x, y: rowY)) {
            if first == nil { first = x }
            last = x
        }
        let width = CGFloat(try XCTUnwrap(last) - (try XCTUnwrap(first)) + 1)

        XCTAssertEqual(
            width,
            markerWidth,
            accuracy: 1,
            "A \(markerWidth)pt mark inside the column must still measure \(markerWidth)pt mid-collapse. Anything narrower means the column's interior is being squeezed into the shrinking frame — a relayout — instead of sliding out of it, which is what makes rows shuffle against each other mid-animation."
        )
    }
}
