import XCTest
import SwiftUI
@testable import Orbit

@MainActor
// Excluded renders below: a MeshGradient theme render stalls past five minutes on a hosted runner.
final class CommandBarPlacementTests: XCTestCase {

    // MARK: - Helpers

    private static let panelSize = CGSize(width: 200, height: 120)

    private func renderCentringProbe(containerSize: CGSize, targetRect: CGRect? = nil) -> RenderedImage {
        let layout = CommandBarOverlayLayout(targetRect: targetRect, scrimOpacity: 0) { _ in
            Color.white
                .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        }
        return render(layout, size: containerSize)
    }

    // MARK: - 1. The panel's centre is the window's centre, on both axes

    func testPanelCentreMatchesWindowCentreOnBothAxesAtEveryWindowSize() {
        let windowSizes: [CGSize] = [
            CGSize(width: 1200, height: 800),
            CGSize(width: 900, height: 1400),
            CGSize(width: 1000, height: 1000),
            CGSize(width: 1600, height: 900),
        ]

        for windowSize in windowSizes {
            let rendered = renderCentringProbe(containerSize: windowSize)
            guard let box = rendered.boundingBoxOfContent(tolerance: 0.05) else {
                rendered.writeDiagnosticPNG(named: "CommandBarOverlayLayout-\(Int(windowSize.width))x\(Int(windowSize.height))-FAILED-empty")
                XCTFail("Expected the overlay to draw its panel at \(windowSize) — nothing was rendered, so the assertions below would pass vacuously.")
                continue
            }

            let windowCentre = CGPoint(x: windowSize.width / 2, y: windowSize.height / 2)
            let panelCentre = CGPoint(x: box.midX, y: box.midY)

            let tolerance: CGFloat = 2

            XCTAssertEqual(
                panelCentre.x, windowCentre.x, accuracy: tolerance,
                "Command Bar is not HORIZONTALLY centred in a \(Int(windowSize.width))x\(Int(windowSize.height)) window: panel centre x = \(panelCentre.x), window centre x = \(windowCentre.x)."
            )
            XCTAssertEqual(
                panelCentre.y, windowCentre.y, accuracy: tolerance,
                "Command Bar is not VERTICALLY centred in a \(Int(windowSize.width))x\(Int(windowSize.height)) window: panel centre y = \(panelCentre.y), window centre y = \(windowCentre.y). This is the defect the user reported twice — a top-pinned layout fails exactly here."
            )
        }
    }

    func testGapsAroundThePanelAreSymmetricOnBothAxes() {
        let windowSize = CGSize(width: 1100, height: 780)
        let rendered = renderCentringProbe(containerSize: windowSize)
        guard let box = rendered.boundingBoxOfContent(tolerance: 0.05) else {
            rendered.writeDiagnosticPNG(named: "CommandBarOverlayLayout-symmetry-FAILED-empty")
            XCTFail("Expected the overlay to draw its panel.")
            return
        }

        let gapAbove = box.minY
        let gapBelow = windowSize.height - box.maxY
        let gapLeading = box.minX
        let gapTrailing = windowSize.width - box.maxX

        XCTAssertEqual(gapLeading, gapTrailing, accuracy: 2, "Leading gap \(gapLeading) != trailing gap \(gapTrailing).")
        XCTAssertEqual(gapAbove, gapBelow, accuracy: 2, "Gap above the Command Bar (\(gapAbove)) != gap below it (\(gapBelow)) — it is still anchored to one edge rather than centred.")
    }

    // MARK: - 2. Width is a proportion of the window, capped by the token

    func testWidthTracksTheMeasuredArcProportionWhileBelowTheCap() {
        for windowWidth in [560.0, 640.0, 720.0, 800.0, 900.0] as [CGFloat] {
            let resolved = CommandBarPlacement.width(forAvailableWidth: windowWidth)
            XCTAssertLessThan(resolved, OrbitMetrics.commandBarWidth, "test precondition: \(windowWidth) should be in the fraction-governed range")
            XCTAssertEqual(
                resolved / windowWidth, CommandBarPlacement.widthFraction, accuracy: 0.001,
                "At a \(windowWidth)pt window the bar should occupy Arc's measured fraction of the window width."
            )
        }
    }

    func testBarNeverExceedsTheWindowItFloatsIn() {
        for windowWidth in [400.0, 500.0, 620.0, 700.0, 1200.0, 2400.0] as [CGFloat] {
            let resolved = CommandBarPlacement.width(forAvailableWidth: windowWidth)
            XCTAssertLessThanOrEqual(resolved, windowWidth, "Bar (\(resolved)pt) is wider than its \(windowWidth)pt window.")
        }
    }

    func testWidthIsMonotonicInWindowWidthAndCappedByTheToken() {
        let widths: [CGFloat] = [320, 500, 700, 900, 1100, 1440, 1920, 3840]
        let resolved = widths.map(CommandBarPlacement.width(forAvailableWidth:))

        for (index, value) in resolved.enumerated().dropFirst() {
            XCTAssertGreaterThanOrEqual(value, resolved[index - 1], "A wider window produced a narrower bar at \(widths[index])pt.")
        }
        for value in resolved {
            XCTAssertLessThanOrEqual(value, OrbitMetrics.commandBarWidth, "Bar exceeded OrbitMetrics.commandBarWidth.")
        }
        XCTAssertEqual(resolved.last, OrbitMetrics.commandBarWidth, "A very wide window should land exactly on the cap.")
    }

    func testDegenerateAvailableWidthFallsBackToTheToken() {
        XCTAssertEqual(CommandBarPlacement.width(forAvailableWidth: 0), OrbitMetrics.commandBarWidth)
        XCTAssertEqual(CommandBarPlacement.width(forAvailableWidth: -100), OrbitMetrics.commandBarWidth)
        XCTAssertEqual(CommandBarPlacement.width(forAvailableWidth: .infinity), OrbitMetrics.commandBarWidth)
    }

    // MARK: - 3. Which region the bar centres on

    private static let contentRegion = CGRect(x: 300, y: 40, width: 1100, height: 860)
    private static let leftPane = CGRect(x: 300, y: 40, width: 545, height: 860)
    private static let rightPane = CGRect(x: 855, y: 40, width: 545, height: 860)

    private static let leftTab = TabID()
    private static let rightTab = TabID()

    private static let splitAnchors: [CommandBarAnchorID: CGRect] = [
        .contentRegion: contentRegion,
        .pane(leftTab): leftPane,
        .pane(rightTab): rightPane,
    ]

    func testNewTabModeCentresOnTheWholeContentRegionEvenInASplit() {
        let resolved = CommandBarPlacement.targetRect(
            mode: .newTab, activeTabID: Self.rightTab, anchors: Self.splitAnchors
        )

        XCTAssertEqual(resolved, Self.contentRegion, "⌘T should centre between the split's panes, not over the focused one.")
        guard let resolved else { return XCTFail("no region resolved") }
        XCTAssertGreaterThan(resolved.midX, Self.leftPane.maxX, "Centre is inside the left pane rather than between the panes.")
        XCTAssertLessThan(resolved.midX, Self.rightPane.minX, "Centre is inside the right pane rather than between the panes.")
    }

    func testResolvedRegionNeverIncludesTheSidebarColumn() {
        for mode in [CommandBarMode.newTab, .chatGPT, .editURL(nil)] {
            let resolved = CommandBarPlacement.targetRect(
                mode: mode, activeTabID: nil, anchors: Self.splitAnchors
            )
            XCTAssertEqual(
                resolved?.minX, Self.contentRegion.minX,
                "\(mode) resolved a region starting at \(String(describing: resolved?.minX)) — the sidebar column is being centred over."
            )
        }
    }

    func testEditURLModeCentresOnTheFocusedPane() {
        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .editURL(nil), activeTabID: Self.leftTab, anchors: Self.splitAnchors),
            Self.leftPane
        )
        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .editURL(nil), activeTabID: Self.rightTab, anchors: Self.splitAnchors),
            Self.rightPane
        )
    }

    func testChatGPTModeCentresOnTheContentRegion() {
        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .chatGPT, activeTabID: Self.rightTab, anchors: Self.splitAnchors),
            Self.contentRegion
        )
    }

    func testBlankPaneModeCentresOnTheNamedPaneNotTheFocusedOne() {
        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .blankPane(Self.rightTab), activeTabID: Self.leftTab, anchors: Self.splitAnchors),
            Self.rightPane,
            "The bar must land over the blank pane it is about to fill in, even though the other pane is the active tab."
        )
        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .blankPane(Self.leftTab), activeTabID: Self.rightTab, anchors: Self.splitAnchors),
            Self.leftPane
        )
    }

    func testBlankPaneWithNoPaneAnchorFallsBackToTheContentRegion() {
        let anchors: [CommandBarAnchorID: CGRect] = [.contentRegion: Self.contentRegion]

        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .blankPane(Self.leftTab), activeTabID: Self.leftTab, anchors: anchors),
            Self.contentRegion
        )
    }

    func testEditURLWithNoPaneAnchorFallsBackToTheContentRegion() {
        let anchors: [CommandBarAnchorID: CGRect] = [.contentRegion: Self.contentRegion]

        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .editURL(nil), activeTabID: Self.leftTab, anchors: anchors),
            Self.contentRegion
        )
        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .editURL(nil), activeTabID: nil, anchors: Self.splitAnchors),
            Self.contentRegion,
            "No active tab means no pane to be editing the URL of."
        )
    }

    func testDegenerateAnchorsAreIgnoredRatherThanCentredOn() {
        let degenerate: [CommandBarAnchorID: CGRect] = [
            .contentRegion: .zero,
            .pane(Self.leftTab): CGRect(x: 300, y: 40, width: 0, height: 860),
        ]
        XCTAssertNil(CommandBarPlacement.targetRect(mode: .newTab, activeTabID: Self.leftTab, anchors: degenerate))
        XCTAssertNil(CommandBarPlacement.targetRect(mode: .editURL(nil), activeTabID: Self.leftTab, anchors: degenerate))

        let mixed: [CommandBarAnchorID: CGRect] = [
            .contentRegion: Self.contentRegion,
            .pane(Self.leftTab): .zero,
        ]
        XCTAssertEqual(
            CommandBarPlacement.targetRect(mode: .editURL(nil), activeTabID: Self.leftTab, anchors: mixed),
            Self.contentRegion
        )
    }

    func testNoAnchorsResolvesToNoRegion() {
        XCTAssertNil(CommandBarPlacement.targetRect(mode: .newTab, activeTabID: Self.leftTab, anchors: [:]))
    }

    // MARK: - 4. The resolved region is what the rendered panel actually lands on

    func testRenderedPanelCentresOnTheTargetRegionRatherThanTheContainer() {
        let containerSize = CGSize(width: 1400, height: 900)
        let region = CGRect(x: 855, y: 140, width: 545, height: 620)

        let rendered = renderCentringProbe(containerSize: containerSize, targetRect: region)
        guard let box = rendered.boundingBoxOfContent(tolerance: 0.05) else {
            rendered.writeDiagnosticPNG(named: "CommandBarOverlayLayout-targetRegion-FAILED-empty")
            return XCTFail("Expected the overlay to draw its panel inside the target region.")
        }

        XCTAssertEqual(box.midX, region.midX, accuracy: 2, "Panel is not centred on the target region horizontally — it is at \(box.midX), the region's centre is \(region.midX), the window's is \(containerSize.width / 2).")
        XCTAssertEqual(box.midY, region.midY, accuracy: 2, "Panel is not centred on the target region vertically — it is at \(box.midY), the region's centre is \(region.midY), the window's is \(containerSize.height / 2).")
    }

    func testPanelIsSizedToTheRegionSoItNeverOverhangsIt() {
        let containerSize = CGSize(width: 1400, height: 900)
        let region = CGRect(x: 855, y: 140, width: 420, height: 620)

        var handedWidth: CGFloat = .nan
        let layout = CommandBarOverlayLayout(targetRect: region, scrimOpacity: 0) { width in
            Color.white
                .frame(width: width, height: Self.panelSize.height)
                .onAppear { handedWidth = width }
        }
        let rendered = render(layout, size: containerSize)
        guard let box = rendered.boundingBoxOfContent(tolerance: 0.05) else {
            rendered.writeDiagnosticPNG(named: "CommandBarOverlayLayout-regionWidth-FAILED-empty")
            return XCTFail("Expected the overlay to draw its panel.")
        }

        XCTAssertEqual(
            box.width, CommandBarPlacement.width(forAvailableWidth: region.width), accuracy: 2,
            "Panel width was resolved against the window (\(containerSize.width)pt) rather than the region (\(region.width)pt)."
        )
        XCTAssertGreaterThanOrEqual(box.minX, region.minX - 2, "Panel overhangs the region's leading edge.")
        XCTAssertLessThanOrEqual(box.maxX, region.maxX + 2, "Panel overhangs the region's trailing edge.")
        if !handedWidth.isNaN {
            XCTAssertLessThanOrEqual(handedWidth, region.width, "The width handed to the content is wider than the region it must fit in.")
        }
    }

    // MARK: - 5. The regions the *real* window publishes

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private final class AnchorBox: @unchecked Sendable {
        var anchors: [CommandBarAnchorID: CGRect] = [:]
    }

    private static let realWindowSize = CGSize(width: 1320, height: 840)
    private static let realSidebarWidth: CGFloat = 240

    private func anchorsFromRealWindow() async -> (anchors: [CommandBarAnchorID: CGRect], left: TabID, right: TabID)? {
        PeekState.shared.dismiss()

        let profileID = env.createDefaultProfileIfNeeded()
        let spaceID = env.createSpace(
            name: "Command Bar Placement",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
        env.state.activeSpaceID = spaceID
        env.isSidebarVisible = true
        env.sidebarWidth = Self.realSidebarWidth

        let left = env.openTab(url: URL(string: "https://example.com/left")!, in: spaceID)
        let right = env.openTab(url: URL(string: "https://example.com/right")!, in: spaceID)
        guard env.createSplit(existingTabID: left, newTabID: right, edge: .right) != nil else {
            XCTFail("Could not build the two-pane split this measurement is about.")
            return nil
        }
        env.activateTab(left)

        let box = AnchorBox()
        _ = await renderForScreenshot(
            BrowserWindowView(skipOnboarding: true)
                .environment(env)
                .withScreenshotModeDragDisabled()
                .onPreferenceChange(CommandBarAnchorsKey.self) { anchors in
                    box.anchors = anchors
                },
            size: Self.realWindowSize
        )
        return (box.anchors, left, right)
    }

    func test_realWindow_contentRegionStartsAfterTheSidebarAndSpansTheRest() async {
        guard let (anchors, _, _) = await anchorsFromRealWindow() else { return }

        guard let content = anchors[.contentRegion] else {
            return XCTFail("The real window published no content region. Published: \(anchors.keys.map(String.init(describing:)).sorted()).")
        }

        let expectedLeading = Self.realSidebarWidth + OrbitMetrics.sidebarResizeHandleWidth + OrbitMetrics.cardInset
        XCTAssertEqual(
            content.minX, expectedLeading, accuracy: 2,
            "The content region starts at \(content.minX) — expected \(expectedLeading), i.e. clear of the \(Self.realSidebarWidth)pt sidebar. Anything near 0 means the Command Bar is centring over the sidebar again."
        )
        XCTAssertEqual(
            content.maxX, Self.realWindowSize.width - OrbitMetrics.cardInset, accuracy: 2,
            "The content region should run to the window's trailing edge less the card inset."
        )
        XCTAssertGreaterThan(content.height, Self.realWindowSize.height / 2, "A content region shorter than half the window is not the content area.")

        XCTAssertEqual(
            content.midX - Self.realWindowSize.width / 2,
            (Self.realSidebarWidth + OrbitMetrics.sidebarResizeHandleWidth) / 2,
            accuracy: 3,
            "Centring on the content region should offset the bar from the window's centre by half the sidebar column."
        )
    }

    func test_realWindow_eachSplitPanePublishesItsOwnRegionInsideTheContentRegion() async {
        guard let (anchors, left, right) = await anchorsFromRealWindow() else { return }

        guard let content = anchors[.contentRegion],
              let leftPane = anchors[.pane(left)],
              let rightPane = anchors[.pane(right)]
        else {
            return XCTFail("Expected a content region and one region per split pane. Published: \(anchors.keys.map(String.init(describing:)).sorted()).")
        }

        XCTAssertLessThan(leftPane.maxX, rightPane.minX, "The two panes overlap — one of these is not the pane it claims to be.")
        XCTAssertEqual(leftPane.minX, content.minX, accuracy: 2, "The leading pane should start where the content region does.")
        XCTAssertEqual(rightPane.maxX, content.maxX, accuracy: 2, "The trailing pane should end where the content region does.")

        let newTab = CommandBarPlacement.targetRect(mode: .newTab, activeTabID: left, anchors: anchors)
        XCTAssertEqual(newTab, content, "⌘T over a real split should centre between the panes.")
        XCTAssertGreaterThan(newTab?.midX ?? 0, leftPane.maxX, "⌘T's centre landed inside the left pane.")
        XCTAssertLessThan(newTab?.midX ?? .greatestFiniteMagnitude, rightPane.minX, "⌘T's centre landed inside the right pane.")

        for (label, tabID, pane) in [("left", left, leftPane), ("right", right, rightPane)] {
            let editURL = CommandBarPlacement.targetRect(mode: .editURL(nil), activeTabID: tabID, anchors: anchors)
            XCTAssertEqual(editURL, pane, "⌘L with the \(label) pane focused should centre over that pane.")
        }
    }
}

private struct AnchorRoundTripProbe: View {
    var sidebarWidth: CGFloat
    var panelSize: CGSize

    @State private var anchors: [CommandBarAnchorID: CGRect] = [:]

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear.ignoresSafeArea()

            HStack(spacing: 0) {
                Color.clear.frame(width: sidebarWidth)
                Color.clear.commandBarAnchor(.contentRegion)
            }
        }
        .coordinateSpace(.named(OrbitWindowCoordinateSpace.name))
        .overlay {
            CommandBarOverlayLayout(
                targetRect: CommandBarPlacement.targetRect(mode: .newTab, activeTabID: nil, anchors: anchors),
                scrimOpacity: 0
            ) { _ in
                Color.white.frame(width: panelSize.width, height: panelSize.height)
            }
        }
        .onPreferenceChange(CommandBarAnchorsKey.self) { published in
            anchors = published
        }
    }
}

extension CommandBarPlacementTests {

    // MARK: - 6. The whole round trip, rendered

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anchorRoundTrip_placesThePanelOnTheContentRegionNotTheWindow

    func test_anchorRoundTrip_placesThePanelOnTheContentRegionNotTheWindow() async {
        let windowSize = CGSize(width: 1200, height: 800)
        let sidebarWidth: CGFloat = 300

        let rendered = await renderForScreenshot(
            AnchorRoundTripProbe(sidebarWidth: sidebarWidth, panelSize: CGSize(width: 200, height: 120)),
            size: windowSize
        )
        guard let box = rendered.boundingBoxOfContent(tolerance: 0.05) else {
            rendered.writeDiagnosticPNG(named: "CommandBarAnchorRoundTrip-FAILED-empty")
            return XCTFail("The probe drew nothing, so the assertions below would pass vacuously.")
        }

        let contentCentreX = sidebarWidth + (windowSize.width - sidebarWidth) / 2
        XCTAssertEqual(
            box.midX, contentCentreX, accuracy: 3,
            """
            The panel is at x=\(box.midX). The content region's centre is \
            \(contentCentreX); the window's is \(windowSize.width / 2). Landing on \
            the latter means the anchor never reached the overlay; landing on \
            neither means the anchor's coordinate space and the overlay's do not \
            share an origin.
            """
        )
        XCTAssertEqual(box.midY, windowSize.height / 2, accuracy: 3, "The panel should still be vertically centred on the content region, which is full-height here.")
    }

    // MARK: - 7. The dim covers the region, not the app

    private static let dimContainer = CGSize(width: 1400, height: 900)
    private static let dimRegion = CGRect(x: 340, y: 60, width: 1020, height: 780)

    private func renderDimOnly(targetRect: CGRect?, containerSize: CGSize = CommandBarPlacementTests.dimContainer) -> RenderedImage {
        let layout = CommandBarOverlayLayout(targetRect: targetRect) { _ in
            Color.clear
        }
        return render(layout, size: containerSize)
    }

    func testTheDimCoversTheTargetRegionAndNothingElse() {
        let rendered = renderDimOnly(targetRect: Self.dimRegion)
        guard let box = rendered.boundingBoxOfContent(tolerance: 0.02) else {
            rendered.writeDiagnosticPNG(named: "CommandBarOverlayLayout-dim-FAILED-empty")
            return XCTFail("Nothing was dimmed at all, so the assertions below would pass vacuously.")
        }

        XCTAssertEqual(box.minX, Self.dimRegion.minX, accuracy: 2, "The dim starts at x=\(box.minX); the region does at \(Self.dimRegion.minX). Anything smaller means it spills over the sidebar.")
        XCTAssertEqual(box.maxX, Self.dimRegion.maxX, accuracy: 2, "The dim ends at x=\(box.maxX); the region does at \(Self.dimRegion.maxX).")
        XCTAssertEqual(box.minY, Self.dimRegion.minY, accuracy: 2, "The dim starts at y=\(box.minY); the region does at \(Self.dimRegion.minY).")
        XCTAssertEqual(box.maxY, Self.dimRegion.maxY, accuracy: 2, "The dim ends at y=\(box.maxY); the region does at \(Self.dimRegion.maxY).")
    }

    func testTheSidebarColumnIsNotDimmed() {
        let rendered = renderDimOnly(targetRect: Self.dimRegion)
        let background = rendered.color(atX: 0, y: 0)
        let sidebarStrip = CGRect(x: 0, y: 0, width: Self.dimRegion.minX - 2, height: Self.dimContainer.height)

        XCTAssertFalse(
            rendered.containsNonBackgroundPixels(in: sidebarStrip, background: background, tolerance: 0.02),
            "Something is drawn over the sidebar column. The Command Bar acts on the content region; dimming past its edge is what made the whole app read as disabled."
        )
        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: Self.dimRegion.insetBy(dx: 20, dy: 20), background: background, tolerance: 0.02),
            "The region itself is not dimmed, so this suite is measuring an overlay that draws nothing."
        )
    }

    func testTheDimIsRoundedLikeThePaneCardItCovers() {
        let rendered = renderDimOnly(targetRect: Self.dimRegion)
        let probe: CGFloat = 6
        let corner = rendered.averageColor(in: CGRect(x: Self.dimRegion.minX, y: Self.dimRegion.minY, width: probe, height: probe))
        let edge = rendered.averageColor(in: CGRect(x: Self.dimRegion.midX - probe / 2, y: Self.dimRegion.minY, width: probe, height: probe))

        XCTAssertLessThan(
            corner.a, edge.a,
            "The corner is as covered as the edge (\(corner.a) vs \(edge.a)), i.e. the dim is a square patch. `OrbitMetrics.cardCornerRadius` is \(OrbitMetrics.cardCornerRadius)pt, so it should be visibly clipped there."
        )
    }

    func testWithNoRegionTheDimStillCoversEverything() {
        let rendered = renderDimOnly(targetRect: nil)
        let background = rendered.color(atX: 0, y: 0)
        XCTAssertFalse(
            rendered.containsNonBackgroundPixels(in: CGRect(origin: .zero, size: rendered.pointSize), background: background, tolerance: 0.02),
            "The fallback dim is not uniform across the container — some part of it is covered differently from the corner."
        )
        XCTAssertGreaterThan(rendered.color(atX: 0, y: 0).a, 0.05, "The fallback drew nothing at all, so the uniformity assertion above is vacuous.")
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
