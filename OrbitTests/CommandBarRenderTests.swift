import XCTest
import SwiftUI

@MainActor
final class CommandBarRenderTests: XCTestCase {

    private func makeSearchSuggestionResult() -> CommandResult {
        CommandResult(
            id: "action-test",
            kind: .searchSuggestion("orbit browser"),
            title: "orbit browser",
            subtitle: "Search Google",
            symbolName: "magnifyingglass",
            score: 500,
            faviconURL: nil,
            faviconHost: nil
        )
    }

    // MARK: - Row height matches OrbitMetrics.commandBarRowHeight

    func test_commandResultRow_heightMatchesOrbitMetrics() {
        let result = makeSearchSuggestionResult()
        let width: CGFloat = 560
        let renderHeight: CGFloat = 80
        let rendered = render(
            CommandResultRow(result: result, isSelected: false),
            size: CGSize(width: width, height: renderHeight)
        )

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "CommandResultRow-height-FAILED-empty")
            XCTFail("Expected CommandResultRow to draw visible content (icon + title).")
            return
        }

        XCTAssertLessThanOrEqual(
            box.maxY, OrbitMetrics.commandBarRowHeight + 1,
            "CommandResultRow's content must not draw below its own OrbitMetrics.commandBarRowHeight=\(OrbitMetrics.commandBarRowHeight)pt row band. See the diagnostic PNG if this is unexpectedly failing."
        )
    }

    func test_commandResultRow_selectedFillOccupiesFullRowHeight() {
        let result = makeSearchSuggestionResult()
        let width: CGFloat = 560
        let renderHeight: CGFloat = 80
        let rendered = render(
            CommandResultRow(result: result, isSelected: true)
                .preferredColorScheme(.dark),
            size: CGSize(width: width, height: renderHeight)
        )

        let stripInRow = CGRect(x: width / 2 - 2, y: 2, width: 4, height: OrbitMetrics.commandBarRowHeight - 4)
        let stripBelowRow = CGRect(x: width / 2 - 2, y: OrbitMetrics.commandBarRowHeight + 4, width: 4, height: renderHeight - OrbitMetrics.commandBarRowHeight - 4)

        let hasFillInRow = rendered.containsNonBackgroundPixels(in: stripInRow, background: .clear, tolerance: 0.03)
        let hasFillBelowRow = rendered.containsNonBackgroundPixels(in: stripBelowRow, background: .clear, tolerance: 0.03)

        if !hasFillInRow || hasFillBelowRow {
            rendered.writeDiagnosticPNG(named: "CommandResultRow-selectedHeight-FAILED")
        }
        XCTAssertTrue(hasFillInRow, "Expected the selected row's fill to cover a vertical strip within OrbitMetrics.commandBarRowHeight=\(OrbitMetrics.commandBarRowHeight)pt.")
        XCTAssertFalse(hasFillBelowRow, "The selected row's fill must not extend past OrbitMetrics.commandBarRowHeight=\(OrbitMetrics.commandBarRowHeight)pt.")
    }

    // MARK: - Selected-state fill is a subtle neutral tint, never Color.accentColor

    func test_commandResultRow_selectedFill_isNotASaturatedAccentColor() {
        let forbiddenSaturatedBlue = RGBA(r: 0.0, g: 0.48, b: 1.0, a: 1.0)

        let result = makeSearchSuggestionResult()
        let rendered = render(
            CommandResultRow(result: result, isSelected: true)
                .preferredColorScheme(.dark),
            size: CGSize(width: 560, height: OrbitMetrics.commandBarRowHeight)
        )

        let sampled = rendered.averageColor(in: CGRect(x: 480, y: 4, width: 60, height: OrbitMetrics.commandBarRowHeight - 8))
        let matchesForbiddenBlue = sampled.isApproximately(forbiddenSaturatedBlue, tolerance: 0.15)

        if matchesForbiddenBlue {
            rendered.writeDiagnosticPNG(named: "CommandResultRow-selectedFill-FAILED")
        }
        XCTAssertFalse(
            matchesForbiddenBlue,
            "Sampled selected-row background \(sampled) reads as a saturated accent blue — spec: \"no saturated highlight; the selected row is a subtle lighter fill\" (refs/reference/arc-bookmarks-search.png). Got a fill matching \(forbiddenSaturatedBlue)."
        )
    }

    func test_commandResultRow_unselectedRow_hasNoFill() {
        let result = makeSearchSuggestionResult()
        let rendered = render(
            CommandResultRow(result: result, isSelected: false)
                .preferredColorScheme(.dark),
            size: CGSize(width: 560, height: OrbitMetrics.commandBarRowHeight)
        )
        let region = CGRect(x: 520, y: 2, width: 30, height: OrbitMetrics.commandBarRowHeight - 4)
        let hasFill = rendered.containsNonBackgroundPixels(in: region, background: .clear, tolerance: 0.03)
        if hasFill {
            rendered.writeDiagnosticPNG(named: "CommandResultRow-unselected-FAILED")
        }
        XCTAssertFalse(hasFill, "An unselected row must not draw any background fill.")
    }

    // MARK: - Site Search: the selected row takes the site's own colour

    func test_commandResultRow_whileSiteScoped_selectedRowTakesTheSiteTint() {
        let tint = CommandRowTint(
            fill: Color(red: 0.80, green: 0.24, blue: 0.30),
            foreground: .white
        )

        let sampleRect = CGRect(x: 480, y: 4, width: 60, height: OrbitMetrics.commandBarRowHeight - 8)
        let size = CGSize(width: 560, height: OrbitMetrics.commandBarRowHeight)

        let tintedRender = render(
            CommandResultRow(result: makeSearchSuggestionResult(), isSelected: true, siteTint: tint)
                .preferredColorScheme(.dark),
            size: size
        )
        let neutralRender = render(
            CommandResultRow(result: makeSearchSuggestionResult(), isSelected: true)
                .preferredColorScheme(.dark),
            size: size
        )

        let tinted = tintedRender.averageColor(in: sampleRect)
        let neutral = neutralRender.averageColor(in: sampleRect)

        func chroma(_ c: RGBA) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }

        let tintedChroma = chroma(tinted)
        let neutralChroma = chroma(neutral)

        if tintedChroma <= neutralChroma + 0.2 {
            tintedRender.writeDiagnosticPNG(named: "CommandResultRow-siteTint-FAILED")
        }
        XCTAssertGreaterThan(
            tintedChroma, neutralChroma + 0.2,
            "A selected row in a site-scoped Command Bar must be filled with the site's own colour, solid "
                + "(refs/reference/web/arc-site-search-command-bar-youtube.png). The tinted fill \(tinted) "
                + "(chroma \(tintedChroma)) is no more chromatic than the untinted neutral fill \(neutral) "
                + "(chroma \(neutralChroma)) — the tint is not reaching the row's background."
        )

        XCTAssertGreaterThan(
            tinted.r, tinted.b,
            "The fill must be the tint that was supplied. It was red-dominant (r 0.80 > b 0.30 > g 0.24); sampled \(tinted)."
        )
        XCTAssertGreaterThan(
            tinted.b, tinted.g,
            "The fill must be the tint that was supplied. Its blue channel exceeded its green (b 0.30 > g 0.24); sampled \(tinted)."
        )
    }

    func test_commandResultRow_whileSiteScoped_unselectedRowStaysUntinted() {
        let tint = CommandRowTint(
            fill: Color(red: 1.0, green: 0.0, blue: 0.0),
            foreground: .white
        )

        let rendered = render(
            CommandResultRow(result: makeSearchSuggestionResult(), isSelected: false, siteTint: tint)
                .preferredColorScheme(.dark),
            size: CGSize(width: 560, height: OrbitMetrics.commandBarRowHeight)
        )

        let region = CGRect(x: 520, y: 2, width: 30, height: OrbitMetrics.commandBarRowHeight - 4)
        let hasFill = rendered.containsNonBackgroundPixels(in: region, background: .clear, tolerance: 0.03)
        if hasFill {
            rendered.writeDiagnosticPNG(named: "CommandResultRow-siteTintUnselected-FAILED")
        }
        XCTAssertFalse(
            hasFill,
            "An unselected row must draw no fill even while the Command Bar is scoped to a site — "
                + "no Arc reference frame shows an unselected scoped row, so it must not be given one."
        )
    }
}
