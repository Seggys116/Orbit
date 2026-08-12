//  Renders real production views through RenderHarness rather than reading a
//  boolean, so a pass reflects what the bitmap actually shows.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SpaceSwitcherPagerRemovalTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private static let pagerCanvas = CGSize(width: 320, height: 80)
    private static let bottomBarCanvas = CGSize(width: 320, height: 80)

    // MARK: - The pager always renders now, including at one Space

    func testPagerRendersAtASingleSpace() {
        let theme = reduceToASingleSpace()
        let rendered = renderPager(theme: theme)

        let content = rendered.boundingBoxOfContent()
        if content == nil {
            rendered.writeDiagnosticPNG(named: "SpaceSwitcherPager-singleSpace-EMPTY")
        }
        XCTAssertNotNil(
            content,
            """
            The Space switcher painted nothing at all with only one Space. User, verbatim (this \
            task): "Obviously, there's only one space to begin with, but still, it should show up \
            at the bottom of the sidebar, centred." It must render the one Space's own dot, exactly \
            as it would with several — see this file's header for the full instruction, which \
            reverses this suite's own prior name. A diagnostic PNG of the (empty) render has been \
            written — open it before changing this assertion.
            """
        )
    }

    func testPagerOccupiesSpaceWithASingleSpace() {
        XCTAssertGreaterThan(env.spaces.count, 1, "Precondition: the demo environment must seed more than one Space.")
        guard let multiSpaceTheme = env.activeSpace?.theme else {
            XCTFail("Precondition: the demo environment must have an active Space.")
            return
        }
        let multiSpaceFootprint = renderPagerFootprintProbe(theme: multiSpaceTheme).boundingBoxOfContent()
        XCTAssertNotNil(
            multiSpaceFootprint,
            """
            The footprint probe measured nothing even with \(env.spaces.count) Spaces, where the \
            pager demonstrably occupies space. The probe is broken, so the single-Space assertion \
            below would pass for the wrong reason — fix the probe, do not delete the test.
            """
        )

        let theme = reduceToASingleSpace()
        let rendered = renderPagerFootprintProbe(theme: theme)
        let footprint = rendered.boundingBoxOfContent()
        if footprint == nil {
            rendered.writeDiagnosticPNG(named: "SpaceSwitcherPager-singleSpace-NO-FOOTPRINT")
        }

        XCTAssertNotNil(
            footprint,
            """
            The Space switcher occupies no space at all with one Space (expected a real footprint, \
            got none). User, verbatim (this task): "there's only one space to begin with, but \
            still, it should show up at the bottom of the sidebar, centred" — a control that is \
            asked to show up must actually be laid out, not just theoretically paintable. See this \
            file's own header for the instruction this reverses.
            """
        )
    }

    func testPagerIsCentredInTheBottomBarWithASingleSpace() {
        let theme = reduceToASingleSpace()
        let rendered = renderBottomBar(theme: theme)
        let background = rendered.color(atX: 0, y: 0)
        let intervals = paintedColumnIntervals(in: rendered, background: background)

        guard intervals.count == 3 else {
            rendered.writeDiagnosticPNG(named: "SpaceSwitcherPager-singleSpace-centring-FAILED-count")
            XCTFail(
                """
                Expected exactly 3 separate painted regions in the bottom bar at one Space (Library, \
                the pager's one dot, `+`) — found \(intervals.count): \(intervals). Either a control \
                is missing, two controls are touching, or something extra is being drawn. See the \
                diagnostic PNG path RenderHarness printed to the console.
                """
            )
            return
        }

        let pagerInterval = intervals[1]
        let pagerCenter = (CGFloat(pagerInterval.lowerBound) + CGFloat(pagerInterval.upperBound) + 1) / 2
        let barCenter = Self.bottomBarCanvas.width / 2
        let tolerance: CGFloat = 3

        if abs(pagerCenter - barCenter) > tolerance {
            rendered.writeDiagnosticPNG(named: "SpaceSwitcherPager-singleSpace-centring-FAILED")
        }
        XCTAssertEqual(
            pagerCenter, barCenter, accuracy: tolerance,
            """
            The pager's single dot is centred at x=\(pagerCenter)pt but the bar itself is \
            \(Self.bottomBarCanvas.width)pt wide (centre x=\(barCenter)pt) — not centred within the \
            \(tolerance)pt tolerance. Painted intervals were \(intervals). See the diagnostic PNG \
            path RenderHarness printed to the console.
            """
        )
    }

    func testBottomBarLibraryButtonLeadingEdgeIsStableRegardlessOfSpaceCount() {
        let multiSpaceLeadingEdge = leadingContentEdgeOfBottomBar()
        let theme = reduceToASingleSpace()
        let singleSpaceLeadingEdge = leadingContentEdgeOfBottomBar(theme: theme)

        guard let multiSpaceLeadingEdge, let singleSpaceLeadingEdge else {
            XCTFail("""
            The bottom bar rendered no content in one of the two states \
            (several Spaces: \(String(describing: multiSpaceLeadingEdge)), one Space: \
            \(String(describing: singleSpaceLeadingEdge))). It must always draw its Library and \
            `+` controls, so this is a broken render, not a passing test.
            """)
            return
        }

        XCTAssertEqual(
            singleSpaceLeadingEdge, multiSpaceLeadingEdge, accuracy: 0.5,
            """
            The bottom bar's leading content starts at \(singleSpaceLeadingEdge)pt with one Space but \
            \(multiSpaceLeadingEdge)pt with several — the Library button's own leading position must \
            not depend on the Space pager's width or Space count at all.
            """
        )
    }

    // MARK: - What must NOT be lost

    func testPagerRendersTheRowOfIconsWithSeveralSpaces() {
        XCTAssertGreaterThan(
            env.spaces.count, 1,
            "Precondition: the demo environment must seed more than one Space for this to be the multi-Space case."
        )
        guard let theme = env.activeSpace?.theme else {
            XCTFail("Precondition: the demo environment must have an active Space.")
            return
        }
        let rendered = renderPager(theme: theme)

        let content = rendered.boundingBoxOfContent()
        if content == nil {
            rendered.writeDiagnosticPNG(named: "SpaceSwitcherPager-multiSpace-EMPTY")
        }
        XCTAssertNotNil(
            content,
            """
            The Space switcher drew nothing with \(env.spaces.count) Spaces. Switching Spaces is \
            real functionality and Arc shows this row (refs/ARC_VISUAL_REFERENCE.md §5).
            """
        )
    }

    func testBottomBarKeepsItsOtherControlsWithASingleSpace() {
        let theme = reduceToASingleSpace()
        let rendered = renderBottomBar(theme: theme)

        XCTAssertNotNil(
            rendered.boundingBoxOfContent(),
            """
            The sidebar's bottom bar drew nothing at all with one Space. The Library button and \
            the `+` menu must always render.
            """
        )
    }

    // MARK: - A picture of the corner, for a human

    func testWriteCornerImagesForHumanInspection() {
        guard let multiSpaceTheme = env.activeSpace?.theme else {
            XCTFail("Precondition: the demo environment must have an active Space.")
            return
        }
        let spaceCount = env.spaces.count
        renderCorner(theme: multiSpaceTheme)
            .writeDiagnosticPNG(named: "SidebarCorner-\(spaceCount)-Spaces")

        let theme = reduceToASingleSpace()
        renderCorner(theme: theme)
            .writeDiagnosticPNG(named: "SidebarCorner-1-Space")
    }

    private func renderCorner(theme: SpaceTheme) -> RenderedImage {
        let view = SidebarBottomBar(theme: theme)
            .environment(env)
            .orbitScreenshotDragSuppressed()
            .background { ThemeBackgroundView(theme: theme, blur: 0) }
        return render(view, size: CGSize(width: env.sidebarWidth, height: OrbitMetrics.sidebarBottomBarHeight))
    }

    // MARK: - Overflow protection: SpaceSwitcherPagerView.sizeScale(forSpaceCount:availableWidth:)

    func testSizeScaleIsOneWhenTheRowAlreadyFits() {
        let generousWidth = SpaceSwitcherPagerView.idealWidth(forSpaceCount: 4, scale: 1) + 100
        XCTAssertEqual(SpaceSwitcherPagerView.sizeScale(forSpaceCount: 1, availableWidth: generousWidth), 1)
        XCTAssertEqual(SpaceSwitcherPagerView.sizeScale(forSpaceCount: 4, availableWidth: generousWidth), 1)
    }

    func testSizeScaleShrinksToExactlyFitWhenAboveTheFloor() {
        let count = 6
        let fullWidth = SpaceSwitcherPagerView.idealWidth(forSpaceCount: count, scale: 1)
        let constrainedWidth = fullWidth * 0.8
        let scale = SpaceSwitcherPagerView.sizeScale(forSpaceCount: count, availableWidth: constrainedWidth)

        XCTAssertGreaterThan(scale, OrbitMetrics.spacePagerMinimumSizeScale, "This case should not need the floor.")
        XCTAssertEqual(
            SpaceSwitcherPagerView.idealWidth(forSpaceCount: count, scale: scale), constrainedWidth, accuracy: 0.01,
            "The returned scale should make the row's own ideal width land exactly on the available width."
        )
    }

    func testSizeScaleNeverGoesBelowTheFloor() {
        let scale = SpaceSwitcherPagerView.sizeScale(forSpaceCount: 40, availableWidth: 60)
        XCTAssertEqual(scale, OrbitMetrics.spacePagerMinimumSizeScale, accuracy: 0.0001)
    }

    func testSizeScaleHandlesDegenerateInputsSafely() {
        XCTAssertEqual(SpaceSwitcherPagerView.sizeScale(forSpaceCount: 0, availableWidth: 200), 1)
        XCTAssertEqual(SpaceSwitcherPagerView.sizeScale(forSpaceCount: 4, availableWidth: 0), 1)
        XCTAssertEqual(SpaceSwitcherPagerView.idealWidth(forSpaceCount: 0, scale: 1), 0)
    }

    // MARK: - State

    @discardableResult
    private func reduceToASingleSpace() -> SpaceTheme {
        var document = env.state
        guard let active = document.spaces.first(where: { $0.id == document.activeSpaceID }) ?? document.spaces.first else {
            XCTFail("Precondition: the demo environment must seed at least one Space.")
            return SpaceTheme()
        }
        document.spaces = [active]
        document.activeSpaceID = active.id
        env.state = document

        XCTAssertEqual(env.spaces.count, 1, "Precondition: the document must now hold exactly one Space.")
        return active.theme
    }

    // MARK: - Rendering

    private func renderPager(theme: SpaceTheme) -> RenderedImage {
        render(
            SpaceSwitcherPagerView(theme: theme)
                .environment(env)
                .orbitScreenshotDragSuppressed(),
            size: Self.pagerCanvas
        )
    }

    private func renderBottomBar(theme: SpaceTheme) -> RenderedImage {
        render(
            SidebarBottomBar(theme: theme)
                .environment(env)
                .orbitScreenshotDragSuppressed(),
            size: Self.bottomBarCanvas
        )
    }

    private func leadingContentEdgeOfBottomBar(theme: SpaceTheme? = nil) -> CGFloat? {
        let theme = theme ?? env.activeSpace?.theme ?? SpaceTheme()
        return renderBottomBar(theme: theme).boundingBoxOfContent()?.minX
    }

    private func renderPagerFootprintProbe(theme: SpaceTheme) -> RenderedImage {
        let probe = HStack(spacing: 0) {
            SpaceSwitcherPagerView(theme: theme)
                .environment(env)
                .orbitScreenshotDragSuppressed()
                .background(Color.red)
            Spacer(minLength: 0)
        }
        return render(probe, size: Self.pagerCanvas)
    }
}

// MARK: - Column-interval scanning (for the centring test)

@MainActor
private func paintedColumnIntervals(in rendered: RenderedImage, background: RGBA, tolerance: Double = 0.04) -> [ClosedRange<Int>] {
    let width = Int(rendered.pointSize.width.rounded(.up))
    let height = Int(rendered.pointSize.height.rounded(.up))
    guard width > 0, height > 0 else { return [] }

    var isColumnPainted = [Bool](repeating: false, count: width)
    for x in 0..<width {
        for y in 0..<height where !rendered.color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
            isColumnPainted[x] = true
            break
        }
    }

    var intervals: [ClosedRange<Int>] = []
    var runStart: Int?
    for x in 0..<width {
        if isColumnPainted[x] {
            if runStart == nil { runStart = x }
        } else if let start = runStart {
            intervals.append(start...(x - 1))
            runStart = nil
        }
    }
    if let start = runStart { intervals.append(start...(width - 1)) }
    return intervals
}

// MARK: - Screenshot-mode drag suppression

private extension View {
    func orbitScreenshotDragSuppressed() -> some View {
        #if DEBUG
        return self.environment(\.orbitScreenshotModeDragDisabled, true)
        #else
        return self
        #endif
    }
}
