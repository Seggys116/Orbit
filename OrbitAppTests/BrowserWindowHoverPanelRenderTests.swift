import XCTest
import SwiftUI
@testable import Orbit

@MainActor
// Excluded renders below: a MeshGradient theme render stalls past five minutes on a hosted runner.
final class BrowserWindowHoverPanelRenderTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private let size = CGSize(width: 260, height: 220)

    override func setUp() {
        super.setUp()
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        state.spaces = [space]
        state.activeSpaceID = space.id
        env.state = state
        env.sidebarWidth = 200
    }

    private func renderPanel() -> RenderedImage {
        render(HoverRevealedFloatingPanel().environment(env).withScreenshotModeDragDisabled(), size: size)
    }

    // MARK: - R8: the panel is inset from top/left/bottom, not flush

    private static var maxShadowAlpha: Double {
        OrbitHoverPanelMetrics.shadowOpacity + OrbitHoverPanelMetrics.contactShadowOpacity
    }

    private static let shadowColourFloor = 0.03

    private func firstSurfacePixel(in rect: CGRect, of rendered: RenderedImage) -> (x: Int, y: Int, colour: RGBA)? {
        let clamped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clamped.isEmpty, !clamped.isNull else { return nil }
        for y in Int(clamped.minY.rounded(.down))..<Int(clamped.maxY.rounded(.up)) {
            for x in Int(clamped.minX.rounded(.down))..<Int(clamped.maxX.rounded(.up)) {
                let colour = rendered.color(atX: x, y: y)
                let isShadowOrEmpty = max(colour.r, colour.g, colour.b) <= Self.shadowColourFloor
                    && colour.a <= Self.maxShadowAlpha
                if !isShadowOrEmpty { return (x, y, colour) }
            }
        }
        return nil
    }

    func test_R8_panel_leavesTopLeftAndBottomEdgesTransparent() {
        let rendered = renderPanel()

        let inset = OrbitHoverPanelMetrics.edgeInset
        let clearance: CGFloat = 4

        let leftEdge = CGRect(x: 0, y: inset + clearance, width: 1, height: size.height - (inset + clearance) * 2)
        let topEdge = CGRect(x: inset + clearance, y: 0, width: env.sidebarWidth, height: 1)
        let bottomEdge = CGRect(x: inset + clearance, y: size.height - 1, width: env.sidebarWidth, height: 1)

        let surfaceAtLeftEdge = firstSurfacePixel(in: leftEdge, of: rendered)
        let surfaceAtTopEdge = firstSurfacePixel(in: topEdge, of: rendered)
        let surfaceAtBottomEdge = firstSurfacePixel(in: bottomEdge, of: rendered)

        if surfaceAtLeftEdge != nil || surfaceAtTopEdge != nil || surfaceAtBottomEdge != nil {
            rendered.writeDiagnosticPNG(named: "R8-hoverPanel-edges-FAILED")
        }
        XCTAssertNil(surfaceAtLeftEdge, "refs/DEFECTS.md R8: the hover panel must be inset from the window's left edge, not flush — found panel surface (not shadow) at x=0: \(String(describing: surfaceAtLeftEdge)). See the diagnostic PNG path RenderHarness printed to the console.")
        XCTAssertNil(surfaceAtTopEdge, "refs/DEFECTS.md R8: the hover panel must be inset from the window's top edge, not flush — found panel surface (not shadow) at y=0: \(String(describing: surfaceAtTopEdge)). See the diagnostic PNG path RenderHarness printed to the console.")
        XCTAssertNil(surfaceAtBottomEdge, "refs/DEFECTS.md R8: the hover panel must be inset from the window's bottom edge, not flush — found panel surface (not shadow) at the bottom row: \(String(describing: surfaceAtBottomEdge)). See the diagnostic PNG path RenderHarness printed to the console.")
    }

    func test_R8_panel_actuallyDrawsContentWellInsideTheInset() {
        let rendered = renderPanel()

        let interior = CGRect(
            x: OrbitHoverPanelMetrics.edgeInset + 15,
            y: OrbitHoverPanelMetrics.edgeInset + 15,
            width: 30, height: 30
        )
        let hasContent = rendered.containsNonBackgroundPixels(in: interior, background: .clear, tolerance: 0.03)

        if !hasContent {
            rendered.writeDiagnosticPNG(named: "R8-hoverPanel-interior-FAILED")
        }
        XCTAssertTrue(
            hasContent,
            "Expected the hover panel to actually draw content at \(interior) — just inside OrbitHoverPanelMetrics.edgeInset (\(OrbitHoverPanelMetrics.edgeInset)pt) from the top and left. See the diagnostic PNG path RenderHarness printed to the console."
        )
    }

    func test_R8_panel_widthMatchesSidebarWidthPlusLeadingInset() {
        let rendered = renderPanel()
        // A real, soft Gaussian shadow's alpha never hard-clips at its declared radius -- it fades
        // out gradually well past it. Measured directly: at 0.03 this picked up that fade a few
        // points beyond shadowRadius + shadowXOffset even with nothing else drawn there. 0.1 is
        // comfortably above the fade's own peak (~0.09 here) while staying far below any genuinely
        // opaque "something wider than the panel" defect this assertion exists to catch.
        guard let box = rendered.boundingBoxOfContent(tolerance: 0.1) else {
            XCTFail("Expected the hover panel to draw something.")
            return
        }
        let expectedTrailingEdge = OrbitHoverPanelMetrics.edgeInset + env.sidebarWidth
        let maxShadowReach = OrbitHoverPanelMetrics.shadowRadius + OrbitHoverPanelMetrics.shadowXOffset + 2
        XCTAssertGreaterThanOrEqual(
            box.maxX, expectedTrailingEdge - 2,
            "The panel is narrower than it should be: its drawn content ends at \(box.maxX)pt, short of edgeInset + sidebarWidth (\(expectedTrailingEdge)pt)."
        )
        XCTAssertLessThanOrEqual(
            box.maxX, expectedTrailingEdge + maxShadowReach,
            "The panel's drawn content reaches \(box.maxX)pt, past edgeInset + sidebarWidth (\(expectedTrailingEdge)pt) by more than its drop shadow's own reach (\(maxShadowReach)pt) — so something wider than the panel is being drawn, not just its shadow."
        )
    }

    // MARK: - The panel's background is the window's gradient, sliced to position

    private static let rampTheme = SpaceTheme(
        style: .linear,
        colors: [
            ThemeColor(red: 0.05, green: 0.10, blue: 0.85),
            ThemeColor(red: 0.95, green: 0.85, blue: 0.10),
        ],
        angle: 90,
        grain: 0
    )

    private static let sliceWindowSize = CGSize(width: 400, height: 120)
    private static let sliceLeadingInset: CGFloat = 40
    private static let sliceWidth: CGFloat = 80

    private func renderWindowGradient() -> RenderedImage {
        render(
            ThemeBackgroundView(theme: Self.rampTheme)
                .frame(width: Self.sliceWindowSize.width, height: Self.sliceWindowSize.height),
            size: Self.sliceWindowSize
        )
    }

    private func renderSlice() -> RenderedImage {
        render(
            ZStack(alignment: .topLeading) {
                Color.clear
                WindowSlicedThemeBackground(theme: Self.rampTheme)
                    .frame(width: Self.sliceWidth, height: Self.sliceWindowSize.height)
                    .padding(.leading, Self.sliceLeadingInset)
            }
            .frame(width: Self.sliceWindowSize.width, height: Self.sliceWindowSize.height)
            .coordinateSpace(.named(OrbitWindowCoordinateSpace.name)),
            size: Self.sliceWindowSize
        )
    }

    func test_windowSlicedBackground_matchesTheWindowGradientAtItsOwnCoordinates() {
        let window = renderWindowGradient()
        let slice = renderSlice()
        let y = Int(Self.sliceWindowSize.height / 2)

        for x in stride(from: Int(Self.sliceLeadingInset) + 4, to: Int(Self.sliceLeadingInset + Self.sliceWidth) - 4, by: 8) {
            let expected = window.color(atX: x, y: y)
            let actual = slice.color(atX: x, y: y)
            XCTAssertTrue(
                actual.isApproximately(expected, tolerance: 0.03),
                "At x=\(x) the sliced background should carry the window gradient's own colour \(expected), found \(actual) — the slice is either scaled to its own bounds or offset to the wrong origin."
            )
        }
    }

    func test_ownBoundsCopy_divergesFromTheWindowGradient_soThePreviousTestIsMeaningful() {
        let window = renderWindowGradient()
        let compressed = render(
            ZStack(alignment: .topLeading) {
                Color.clear
                ThemeBackgroundView(theme: Self.rampTheme)
                    .frame(width: Self.sliceWidth, height: Self.sliceWindowSize.height)
                    .padding(.leading, Self.sliceLeadingInset)
            }
            .frame(width: Self.sliceWindowSize.width, height: Self.sliceWindowSize.height),
            size: Self.sliceWindowSize
        )

        let x = Int(Self.sliceLeadingInset + Self.sliceWidth) - 6
        let y = Int(Self.sliceWindowSize.height / 2)
        let expected = window.color(atX: x, y: y)
        let actual = compressed.color(atX: x, y: y)

        XCTAssertGreaterThan(
            abs(actual.r - expected.r), 0.3,
            "An own-bounds copy is supposed to diverge hard from the window gradient at x=\(x) (window \(expected), copy \(actual)). If it no longer does, the ramp theme has gone flat and the slice test above proves nothing."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_hoverPanel_inRealWindow_paintsTheWindowsLeftSliverNotTheWholeRamp

    func test_hoverPanel_inRealWindow_paintsTheWindowsLeftSliverNotTheWholeRamp() async {
        OrbitScreenshotFixtures.configure(env)
        let windowSize = CGSize(width: 1320, height: 840)
        env.isSidebarVisible = false
        env.isSidebarHoverRevealed = true
        env.sidebarWidth = 240
        guard let activeSpaceID = env.activeSpace?.id else {
            return XCTFail("The screenshot fixture is expected to leave a Space active — nothing to theme otherwise.")
        }
        env.updateSpaceTheme(activeSpaceID, theme: Self.rampTheme)

        let rendered = await renderForScreenshot(
            BrowserWindowView(skipOnboarding: true)
                .environment(env)
                .withScreenshotModeDragDisabled(),
            size: windowSize
        )

        let panelTrailingEdge = OrbitHoverPanelMetrics.edgeInset + env.sidebarWidth
        let column = CGRect(
            x: panelTrailingEdge - 24, y: 120,
            width: 16, height: windowSize.height - 240
        )
        let mean = rendered.averageColor(in: column)

        if mean.r > 0.5 {
            rendered.writeDiagnosticPNG(named: "hoverPanel-gradientSlice-FAILED")
        }
        XCTAssertLessThan(
            mean.r, 0.5,
            """
            The hover panel's background is running the whole ramp inside its own \
            width: mean red \(mean.r) over \(column), where the window's own gradient \
            at that x sits near 0.2. That means something under the panel is painting \
            a Space gradient sized to its own bounds again instead of \
            WindowSlicedThemeBackground's window-scale slice — check that \
            BrowserWindowView's root ZStack still declares \
            .coordinateSpace(.named(OrbitWindowCoordinateSpace.name)), which is what \
            lets the slice find the window at all.
            """
        )
    }

    // MARK: - R7: the window controls are inset with the panel, not flush at the window's true corner

    func test_R7_windowControls_doNotRenderAtTheWindowsTrueTopLeftCorner() {
        let rendered = renderPanel()

        let corner = CGRect(x: 0, y: 0, width: OrbitHoverPanelMetrics.edgeInset - 2, height: OrbitHoverPanelMetrics.edgeInset - 2)
        let surface = firstSurfacePixel(in: corner, of: rendered)

        if surface != nil {
            rendered.writeDiagnosticPNG(named: "R7-windowControls-corner-FAILED")
        }
        XCTAssertNil(
            surface,
            "refs/DEFECTS.md R7/R8: the window controls live inside the inset hover panel, so nothing but the panel's shadow should reach the window's true top-left corner \(corner) — found \(String(describing: surface)). See the diagnostic PNG path RenderHarness printed to the console."
        )
    }

    func test_R7_windowControls_renderInsideThePanelAtTheExpectedOffset() {
        let rendered = renderPanel()

        let controlsRegion = CGRect(
            x: OrbitHoverPanelMetrics.edgeInset + OrbitWindowControlMetrics.leadingInset - 2,
            y: OrbitHoverPanelMetrics.edgeInset + OrbitWindowControlMetrics.topInset - 2,
            width: OrbitWindowControlMetrics.clusterWidth + 4,
            height: OrbitWindowControlMetrics.diameter + 4
        )
        let hasContent = rendered.containsNonBackgroundPixels(in: controlsRegion, background: .clear, tolerance: 0.03)

        if !hasContent {
            rendered.writeDiagnosticPNG(named: "R7-windowControls-position-FAILED")
        }
        XCTAssertTrue(
            hasContent,
            "Expected the window controls to render at \(controlsRegion), inside the inset panel. See the diagnostic PNG path RenderHarness printed to the console."
        )
    }

    // MARK: - Contrast: `PositionedWindowControls` alone is flush (no R8 inset applied)

    func test_dockedOverlay_positionedWindowControls_rendersFlushAtTheTrueCorner() {
        let rendered = render(PositionedWindowControls(), size: size)

        let flushCorner = CGRect(
            x: OrbitWindowControlMetrics.leadingInset - 2,
            y: OrbitWindowControlMetrics.topInset - 2,
            width: OrbitWindowControlMetrics.clusterWidth + 4,
            height: OrbitWindowControlMetrics.diameter + 4
        )
        let hasContentAtFlushCorner = rendered.containsNonBackgroundPixels(in: flushCorner, background: .clear, tolerance: 0.03)

        if !hasContentAtFlushCorner {
            rendered.writeDiagnosticPNG(named: "docked-positionedWindowControls-FAILED")
        }
        XCTAssertTrue(
            hasContentAtFlushCorner,
            "Expected PositionedWindowControls (the docked-sidebar overlay) to render flush at \(flushCorner), with no R8 hover-panel inset applied. See the diagnostic PNG path RenderHarness printed to the console."
        )
    }

    func test_dockedOverlay_positionedWindowControls_boundingBoxStartsAtLeadingInset_notShiftedByHoverInset() {
        let rendered = render(PositionedWindowControls(), size: size)
        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            XCTFail("Expected PositionedWindowControls to draw something.")
            return
        }
        XCTAssertEqual(
            box.minX, OrbitWindowControlMetrics.leadingInset, accuracy: 2,
            "PositionedWindowControls' own content should start right at OrbitWindowControlMetrics.leadingInset (\(OrbitWindowControlMetrics.leadingInset)pt), found x=\(box.minX)pt — if this drifts toward OrbitHoverPanelMetrics.edgeInset + leadingInset (\(OrbitHoverPanelMetrics.edgeInset + OrbitWindowControlMetrics.leadingInset)pt) instead, the R8 hover-panel inset has leaked into the docked-overlay's own geometry."
        )
    }

    // MARK: - `HoverRevealSidebarLayer` itself (HoverEdgeDetector included)

    func test_hoverRevealSidebarLayer_showsPanelOnlyWhenRevealed() {
        env.isSidebarHoverRevealed = false
        let collapsed = render(HoverRevealSidebarLayer(onHoverChanged: { _ in }).environment(env), size: size)

        env.isSidebarHoverRevealed = true
        let revealed = render(HoverRevealSidebarLayer(onHoverChanged: { _ in }).environment(env), size: size)

        let panelInterior = CGRect(
            x: OrbitHoverPanelMetrics.edgeInset + 15,
            y: OrbitHoverPanelMetrics.edgeInset + 15,
            width: 30, height: 30
        )

        let hasContentWhenRevealed = revealed.containsNonBackgroundPixels(in: panelInterior, background: .clear, tolerance: 0.03)
        if !hasContentWhenRevealed {
            revealed.writeDiagnosticPNG(named: "hoverRevealSidebarLayer-revealed-FAILED")
        }
        XCTAssertTrue(
            hasContentWhenRevealed,
            "Expected HoverRevealSidebarLayer to draw panel content at \(panelInterior) once env.isSidebarHoverRevealed == true. See the diagnostic PNG path RenderHarness printed to the console."
        )

        let hasContentWhenCollapsed = collapsed.containsNonBackgroundPixels(in: panelInterior, background: .clear, tolerance: 0.03)
        if hasContentWhenCollapsed {
            collapsed.writeDiagnosticPNG(named: "hoverRevealSidebarLayer-collapsed-FAILED")
        }
        XCTAssertFalse(
            hasContentWhenCollapsed,
            "Expected HoverRevealSidebarLayer to draw nothing at \(panelInterior) while env.isSidebarHoverRevealed == false — found content there. See the diagnostic PNG path RenderHarness printed to the console."
        )
    }
}

private extension View {
    func withScreenshotModeDragDisabled() -> some View {
        #if DEBUG
        return environment(\.orbitScreenshotModeDragDisabled, true)
        #else
        return self
        #endif
    }
}
