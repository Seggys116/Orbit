import SwiftUI
import XCTest
@testable import Orbit

// OrbitNSActionButton renders as an opaque block unless orbitScreenshotModeDragDisabled is set.
@MainActor
final class TabRowHoverCloseControlTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private let rowWidth: CGFloat = 260

    private func makeTab(title: String) -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        var tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://example.com")!, title: title)
        tab.title = title
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func renderRow(tab: Orbit.Tab, hovered: Bool) -> RenderedImage {
        let size = CGSize(width: rowWidth, height: OrbitMetrics.sidebarRowHeight)
        let content = TabRowView(tab: tab, theme: SpaceTheme(), forcesHoveredAppearanceForTesting: hovered)
            .environment(env)
            .environment(\.orbitScreenshotModeDragDisabled, true)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        return render(content, size: size)
    }

    private func hasInk(in image: RenderedImage, xRange: Range<Int>, yRange: Range<Int>, background: RGBA, tolerance: Double = 0.06) -> Bool {
        for y in yRange {
            for x in xRange where !image.color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
                return true
            }
        }
        return false
    }

    private func rightmostInk(in image: RenderedImage, xRange: Range<Int>, yRange: Range<Int>, background: RGBA, tolerance: Double = 0.06) -> Int? {
        var maxX: Int?
        for y in yRange {
            for x in xRange where !image.color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
                if maxX == nil || x > maxX! { maxX = x }
            }
        }
        return maxX
    }

    // MARK: - 1. Close control presence, gated purely on hover

    // A SHORT title, so its ink stays clear of the close button's trailing region.
    func test_closeControl_isAbsentWhenNotHoveredAndPresentWhenHovered() {
        let tab = makeTab(title: "Hi")

        let hovered = renderRow(tab: tab, hovered: true)
        let unhovered = renderRow(tab: tab, hovered: false)

        // Just inside the row's own trailing padding — empty in both states regardless of hover,
        // since neither the pill nor the button paint out here.
        let hoveredBackground = hovered.color(atX: 252, y: 4)
        let unhoveredBackground = unhovered.color(atX: 252, y: 4)

        let buttonRegionX = 222..<250
        let buttonRegionY = 8..<28

        XCTAssertFalse(
            hasInk(in: unhovered, xRange: buttonRegionX, yRange: buttonRegionY, background: unhoveredBackground),
            "The close control must be invisible while the row is not hovered — found ink in its own region with nothing hovering."
        )
        XCTAssertTrue(
            hasInk(in: hovered, xRange: buttonRegionX, yRange: buttonRegionY, background: hoveredBackground),
            "The close control must be visible once the row is hovered — found no ink at all in its own region."
        )
    }

    // MARK: - 2. Hovering reserves trailing width, narrowing what the title can use

    // Long enough to be truncated in BOTH states (so a real width difference has something to
    // bite on) but never reaching the close button's own region either way.
    func test_title_reachesFurtherRightWhenNotHoveredThanWhenHovered() {
        let tab = makeTab(title: "This Is A Fairly Long Tab Title Indeed")

        let hovered = renderRow(tab: tab, hovered: true)
        let unhovered = renderRow(tab: tab, hovered: false)

        // Sample the hovered pill's own fill, or the whole pill registers as ink.
        let hoveredBackground = hovered.color(atX: 12, y: 18)
        let unhoveredBackground = unhovered.color(atX: 2, y: 2)

        // Same x-range for both, excluding the close button, so only title ink differs.
        let titleRegionX = 0..<220
        // A tight vertical band around the text's own centre, well clear of the pill's rounded
        // top/bottom corners (whose antialiasing doesn't exactly match the flat-fill sample above).
        let titleRegionY = 14..<24

        guard let hoveredRight = rightmostInk(in: hovered, xRange: titleRegionX, yRange: titleRegionY, background: hoveredBackground) else {
            return XCTFail("no title ink found while hovered — test precondition is wrong")
        }
        guard let unhoveredRight = rightmostInk(in: unhovered, xRange: titleRegionX, yRange: titleRegionY, background: unhoveredBackground) else {
            return XCTFail("no title ink found while not hovered — test precondition is wrong")
        }

        XCTAssertGreaterThan(
            unhoveredRight, hoveredRight + 4,
            "With nothing hovered, the title has the row's full width and must reach measurably further right (more text visible before truncation) than while hovered, when the close control's reserved trailing width narrows it — got unhovered=\(unhoveredRight), hovered=\(hoveredRight)."
        )
    }
}
