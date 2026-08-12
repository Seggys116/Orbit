import XCTest
@testable import Orbit

final class ToolbarWindowControlAlignmentTests: XCTestCase {

    func test_R13_trailingGlyphSize_derivesFromTheTrafficLightDiameter() {
        XCTAssertEqual(
            OrbitToolbarMetrics.trailingGlyphSize,
            (OrbitMetrics.trafficLightDiameter * trailingGlyphScale).rounded(),
            "OrbitToolbarMetrics.trailingGlyphSize must be OrbitMetrics.trafficLightDiameter (the platform " +
            "constant) scaled by trailingGlyphScale — refs/DEFECTS.md R13's 'match the window controls' " +
            "relationship, kept on the glyph rather than on its tap target."
        )
        XCTAssertGreaterThan(
            OrbitToolbarMetrics.trailingGlyphSize, OrbitMetrics.trafficLightDiameter,
            "Arc's own trailing pane-header glyphs paint 13.6-14.9pt against 12pt traffic lights " +
            "(refs/reference/arc-split-panes.png) — larger, not smaller. A trailing glyph at or below the " +
            "traffic-light diameter is the 'the others are too small' half of the user's R23 report."
        )
    }

    func test_R23_everyPaneHeaderControlSharesOneTapTarget() {
        XCTAssertEqual(
            OrbitToolbarMetrics.navIconSize, OrbitToolbarMetrics.headerIconSize,
            "The nav cluster's tap target must be the header's one shared tap target."
        )
        XCTAssertEqual(
            OrbitToolbarMetrics.trailingIconSize, OrbitToolbarMetrics.headerIconSize,
            "The trailing cluster's tap target must be the header's one shared tap target."
        )
        XCTAssertLessThanOrEqual(
            OrbitToolbarMetrics.headerIconSize, OrbitToolbarMetrics.height,
            "The shared tap target (\(OrbitToolbarMetrics.headerIconSize)pt) must fit inside the header's own " +
            "icon-row band (\(OrbitToolbarMetrics.height)pt) — otherwise the controls are clipped by the band " +
            "that is supposed to contain them."
        )
    }

    func test_R13_paneHeaderIconsShareTheWindowControlsOpticalBand() {
        let windowControlCentre = OrbitMetrics.sidebarTopRowHeight / 2
        let paneHeaderIconCentre = OrbitMetrics.cardInset
            + OrbitToolbarMetrics.topPadding
            + OrbitToolbarMetrics.height / 2
        let offset = abs(paneHeaderIconCentre - windowControlCentre)

        XCTAssertLessThan(
            offset, OrbitMetrics.sidebarTopRowHeight / 2,
            "The pane header's icon centreline sits \(paneHeaderIconCentre)pt below the window's top edge and " +
            "the traffic lights' sits at \(windowControlCentre)pt — \(offset)pt apart, which is outside the " +
            "window-controls band itself (\(OrbitMetrics.sidebarTopRowHeight)pt tall). refs/DEFECTS.md R13: the " +
            "two clusters must sit on the same optical baseline, i.e. read as one row of chrome, not two."
        )

        let expectedWindowControlTopInset = (OrbitMetrics.sidebarTopRowHeight - OrbitWindowControlMetrics.diameter) / 2
        XCTAssertEqual(
            OrbitWindowControlMetrics.topInset, expectedWindowControlTopInset,
            "OrbitWindowControlMetrics.topInset must centre the cluster within OrbitMetrics.sidebarTopRowHeight."
        )
    }

    func test_R23_paneHeaderIsShorterThanTheSidebarsOwnTopBand() {
        XCTAssertLessThan(
            OrbitToolbarMetrics.totalHeight, OrbitMetrics.sidebarTopRowHeight * 1.2,
            "The pane header's total height (\(OrbitToolbarMetrics.totalHeight)pt) must stay close to or below " +
            "the sidebar's own traffic-lights band (\(OrbitMetrics.sidebarTopRowHeight)pt) — Arc's measures " +
            "27-30pt against a 35.8pt sidebar band (refs/reference/arc-real-1.png, arc-split-panes.png). A " +
            "header substantially taller than that band reads as a second row of chrome above every page."
        )
        XCTAssertGreaterThan(
            OrbitToolbarMetrics.totalHeight, OrbitToolbarMetrics.headerIconSize,
            "The pane header must still be taller than the controls it contains."
        )
    }

    func test_R13_windowControlDiameterTracesToTheTrafficLightDiameter_notTheIconLadder() {
        XCTAssertEqual(OrbitWindowControlMetrics.diameter, OrbitMetrics.trafficLightDiameter)
        for rung in [OrbitMetrics.iconFavicon, OrbitMetrics.iconChrome, OrbitMetrics.iconMedium, OrbitMetrics.iconLarge] {
            XCTAssertNotEqual(
                OrbitWindowControlMetrics.diameter, rung,
                "The window controls must not equal a rung of Orbit's own icon ladder (\(rung)pt) — see " +
                "OrbitMetrics.trafficLightDiameter's own comment for the regression that caused."
            )
        }
    }
}
