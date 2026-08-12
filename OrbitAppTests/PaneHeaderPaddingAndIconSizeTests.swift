import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class PaneHeaderPaddingAndIconSizeTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
    }

    private func makeTab(url: String = "https://example.com") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func cleanup(_ tabIDs: [TabID]) {
        for id in tabIDs {
            env.state.tabs.removeValue(forKey: id)
            env.themeColors.removeValue(forKey: id)
        }
    }

    // MARK: - "missing padding on the top"

    func test_R14_topPadding_isPositive() {
        XCTAssertGreaterThan(
            OrbitToolbarMetrics.topPadding, 0,
            "refs/DEFECTS.md R14: the pane header must have real clearance above its icon row — topPadding regressed to zero (flush against the pane's top edge again)."
        )
    }

    func test_R14_totalHeaderHeight_exceedsTheBareIconRowBand() {
        XCTAssertGreaterThan(
            OrbitToolbarMetrics.totalHeight, OrbitToolbarMetrics.height,
            "refs/DEFECTS.md R14: the header's total height must exceed the bare icon-row band (`height`) — otherwise the 'missing top padding' fix isn't actually visible."
        )
    }

    func test_R14_headerActuallyRendersAtItsFullTotalHeight() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }
        env.themeColors[tab.id] = ThemeColor(red: 0.22, green: 0.2, blue: 0.26)

        let overshoot: CGFloat = 40
        let canvasHeight = OrbitToolbarMetrics.totalHeight + overshoot
        let rendered = render(ToolbarView(tab: tab).environment(env), size: CGSize(width: 400, height: canvasHeight))

        let justInsideTotalHeight = rendered.color(atX: 200, y: max(0, Int(OrbitToolbarMetrics.totalHeight) - 2))
        let wellBeyondTotalHeight = rendered.color(atX: 200, y: Int(OrbitToolbarMetrics.totalHeight) + Int(overshoot) - 4)

        if justInsideTotalHeight.a < 0.9 || wellBeyondTotalHeight.a > 0.1 {
            rendered.writeDiagnosticPNG(named: "paneHeader-totalHeight-FAILED")
        }
        XCTAssertGreaterThan(
            justInsideTotalHeight.a, 0.9,
            "refs/DEFECTS.md R14: the header should still be painting its own background just inside its claimed totalHeight (alpha \(justInsideTotalHeight.a))."
        )
        XCTAssertLessThan(
            wellBeyondTotalHeight.a, 0.1,
            "refs/DEFECTS.md R14: nothing should be painted below the header's own claimed totalHeight (alpha \(wellBeyondTotalHeight.a)) — if this is opaque, the header rendered taller than it reports, and every geometry test keyed off totalHeight is now measuring the wrong canvas."
        )
    }

    // MARK: - R23: the address field's security glyph is a LINK, not a padlock

    func test_R23_secureAddress_drawsAChainLinkNotAPadlock() {
        XCTAssertEqual(
            ToolbarSecurityGlyph.symbol(for: .secure), "link",
            "Arc draws a chain link before the domain, not a padlock — verified in refs/reference/arc-split-panes.png and arc-real-1.png."
        )
        XCTAssertFalse(
            (ToolbarSecurityGlyph.symbol(for: .secure) ?? "").contains("lock"),
            "No padlock variant may creep back in for the secure state."
        )
        XCTAssertFalse(
            ToolbarSecurityGlyph.isWarning(.secure),
            "A secure page's link glyph is ordinary header chrome, not a warning — it must take the header's own contrast-derived foreground."
        )
    }

    func test_R23_warningSecurityStates_keepTheirOwnDistinctGlyphs() {
        XCTAssertEqual(ToolbarSecurityGlyph.symbol(for: .insecure), "lock.slash")
        XCTAssertEqual(ToolbarSecurityGlyph.symbol(for: .mixedContent), "lock.slash")
        XCTAssertEqual(ToolbarSecurityGlyph.symbol(for: .certificateError), "exclamationmark.triangle.fill")
        for state: SecurityLevel in [.insecure, .mixedContent, .certificateError] {
            XCTAssertTrue(ToolbarSecurityGlyph.isWarning(state), "\(state) must be drawn in a warning colour.")
        }
    }

    func test_R23_localAndUnknownSecurity_drawNoGlyphAtAll() {
        XCTAssertNil(ToolbarSecurityGlyph.symbol(for: .local))
        XCTAssertNil(ToolbarSecurityGlyph.symbol(for: .unknown))
    }

    func test_R23_securityGlyphSize_isOneTokenAndReadsAtTheAddressLabelsScale() {
        XCTAssertGreaterThan(
            OrbitToolbarMetrics.securityGlyphSize, 9,
            "The security glyph was three hardcoded 9pt literals; at that size it painted ~10pt beside a 12pt domain label. Arc's own paints 12.2pt (refs/reference/arc-split-panes.png)."
        )
        XCTAssertLessThan(
            OrbitToolbarMetrics.securityGlyphSize, OrbitToolbarMetrics.headerIconSize,
            "The security glyph is an inline text-run marker, not one of the header's tap-target controls — it must stay smaller than the shared control box."
        )
    }

    // MARK: - "all of the icons and buttons are now way too big"

    func test_R14_trailingGlyphSize_isSmallerThanItsOwnTapTarget() {
        XCTAssertLessThan(
            OrbitToolbarMetrics.trailingGlyphSize, OrbitToolbarMetrics.trailingIconSize,
            "refs/DEFECTS.md R14: the trailing icons' glyph (\(OrbitToolbarMetrics.trailingGlyphSize)) must render smaller than their own tap-target box (\(OrbitToolbarMetrics.trailingIconSize)) so there's visible margin inside it."
        )
    }

    func test_R14_navGlyphSize_isSmallerThanItsOwnTapTarget() {
        XCTAssertLessThan(
            OrbitToolbarMetrics.navGlyphSize, OrbitToolbarMetrics.navIconSize,
            "refs/DEFECTS.md R14: the nav cluster's glyph (\(OrbitToolbarMetrics.navGlyphSize)) must render smaller than its own tap-target box (\(OrbitToolbarMetrics.navIconSize))."
        )
    }

    func test_R14_trailingGlyphSize_stillTracesToTheWindowControlDiameter() {
        XCTAssertEqual(
            OrbitToolbarMetrics.trailingGlyphSize,
            (OrbitWindowControlMetrics.diameter * trailingGlyphScale).rounded(),
            "The trailing glyph base must still be derived from the window controls' own dot diameter."
        )
    }

    // MARK: - "Inconsistent icon sizing" (the two trailing glyphs)

    func test_trailingGlyphs_layDownComparableInk_soTheyReadAsTheSameSize() {
        let siteControlInk = paintedArea(of: ToolbarTrailingGlyph.siteControl)
        let splitViewInk = paintedArea(of: ToolbarTrailingGlyph.splitView)

        XCTAssertGreaterThan(siteControlInk, 0, "Nothing rendered for the Site Control glyph — this measurement is broken, not the view.")
        XCTAssertGreaterThan(splitViewInk, 0, "Nothing rendered for the Split View glyph — this measurement is broken, not the view.")

        let ratio = siteControlInk / splitViewInk
        XCTAssertTrue(
            (0.80...1.25).contains(ratio),
            """
            The pane header's two trailing glyphs are not laying down comparable ink (switch.2 / square.split.2x1 = \(String(format: "%.3f", ratio))), \
            so they will not read as the same size — the user's "Inconsistent icon sizing" report \
            (refs/reference/user-reports/orbit-toolbar-icon-size-mismatch.png). At one shared font size this ratio is ~1.48; \
            retune `siteControlGlyphScale`/`splitViewGlyphScale` in ToolbarView.swift, and look at a regenerated \
            refs/screenshots/window-full.png rather than trusting the number alone.
            """
        )
    }

    func test_trailingGlyphs_paintedExtentsStayClose_soNeitherIsShrunkIntoOblivion() {
        guard let siteControl = paintedBox(of: ToolbarTrailingGlyph.siteControl),
              let splitView = paintedBox(of: ToolbarTrailingGlyph.splitView) else {
            return XCTFail("One of the trailing glyphs rendered nothing at all.")
        }

        let ratio = siteControl.height / splitView.height
        XCTAssertTrue(
            (0.78...1.28).contains(ratio),
            "The two trailing glyphs' painted heights have drifted too far apart (\(String(format: "%.3f", ratio))): \(siteControl.height)pt vs \(splitView.height)pt. One of them is now visibly the smaller icon."
        )
    }

    func test_trailingGlyphs_carryGenuinelyDifferentPerGlyphCorrections() {
        XCTAssertNotEqual(
            siteControlGlyphScale, splitViewGlyphScale,
            "Both trailing glyphs are back on one identical scale factor — that is exactly the state refs/reference/user-reports/orbit-toolbar-icon-size-mismatch.png was filed against."
        )
        XCTAssertNotEqual(
            OrbitToolbarMetrics.siteControlGlyphSize, OrbitToolbarMetrics.splitViewGlyphSize,
            "The two trailing glyphs resolved to the same drawn font size, so no per-glyph optical correction is actually being applied."
        )
    }

    // MARK: - The third trailing glyph (a split pane's own close control)

    func test_splitCloseGlyph_paintsNoLargerThanTheGlyphsItSitsBeside() {
        guard let close = paintedBox(of: ToolbarTrailingGlyph.splitClose),
              let splitView = paintedBox(of: ToolbarTrailingGlyph.splitView),
              let siteControl = paintedBox(of: ToolbarTrailingGlyph.siteControl) else {
            return XCTFail("One of the trailing glyphs rendered nothing at all.")
        }

        for (name, neighbour) in [("square.split.2x1", splitView), ("switch.2", siteControl)] {
            XCTAssertLessThanOrEqual(
                close.height, neighbour.height,
                """
                The split-pane close glyph paints \(close.height)pt tall against \(name)'s \(neighbour.height)pt. \
                A cross reads larger than its own bounding box, so it must not also *be* the largest box in the cluster — \
                the user's "That x is too big btw". Lower `splitCloseGlyphScale` in ToolbarView.swift.
                """
            )
        }

        let ratio = close.height / siteControl.height
        XCTAssertGreaterThan(
            ratio, 0.65,
            "The close glyph has been shrunk into a speck beside its neighbours (\(String(format: "%.3f", ratio)) of switch.2's painted height) — the mirror-image failure of the one above."
        )
    }

    func test_trailingGlyphs_bothDrawnSizesStayInsideTheSharedTapTarget() {
        for (name, size) in [
            ("Site Control", OrbitToolbarMetrics.siteControlGlyphSize),
            ("Split View", OrbitToolbarMetrics.splitViewGlyphSize),
            ("Split Pane Close", OrbitToolbarMetrics.splitCloseGlyphSize)
        ] {
            XCTAssertLessThan(
                size, OrbitToolbarMetrics.trailingIconSize,
                "The \(name) glyph (\(size)) must stay strictly inside its own tap-target box (\(OrbitToolbarMetrics.trailingIconSize)) — a per-glyph scale above 1 has pushed it past its own frame."
            )
        }
    }

    // MARK: Glyph measurement helpers

    private func paintedArea(of glyph: ToolbarTrailingGlyph) -> Double {
        let bitmap = renderIsolated(glyph).bitmap
        var total = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let sample = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += Double(sample.alphaComponent)
            }
        }
        return total / Double(glyphRenderScale * glyphRenderScale)
    }

    private func paintedBox(of glyph: ToolbarTrailingGlyph) -> CGRect? {
        renderIsolated(glyph).boundingBoxOfContent()
    }

    private let glyphRenderScale: CGFloat = 8

    private func renderIsolated(_ glyph: ToolbarTrailingGlyph) -> RenderedImage {
        let inset = OrbitToolbarMetrics.trailingIconSize
        let canvas = CGSize(width: inset * 3, height: inset * 3)
        return render(
            glyph.foregroundStyle(Color.white).padding(inset),
            size: canvas,
            scale: glyphRenderScale
        )
    }

    func test_R14_totalHeaderHeight_comfortablyFitsTheTrailingIconWithPaddingToSpare() {
        XCTAssertGreaterThan(
            OrbitToolbarMetrics.totalHeight, OrbitToolbarMetrics.trailingIconSize,
            "The header's total height must comfortably exceed a single trailing icon's own tap target, or the icon can't fit inside it at all."
        )
    }
}
