import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class TodayNewTabRowPositionTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        env.isSidebarVisible = true
        env.state = OrbitState()
    }

    private static let renderSize = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: 220)

    private static let lightTheme = SpaceTheme(
        style: .solid,
        colors: [ThemeColor(red: 0.92, green: 0.92, blue: 0.94)],
        grain: 0,
        followsSystemAppearance: false,
        prefersDarkContent: false
    )

    private func renderTodaySection(todayTabCount: Int) -> RenderedImage {
        let env = self.env
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        state.profiles = [profile]
        let space = Space(name: "Work", theme: Self.lightTheme, profileID: profile.id)
        state.spaces = [space]
        state.activeSpaceID = space.id
        env.state = state

        for index in 0..<todayTabCount {
            env.openTab(url: URL(string: "https://example\(index).com")!, in: space.id)
        }

        let view = TodaySectionView(spaceID: space.id, theme: Self.lightTheme, revealsBroom: false)
            .environment(env)
            // The + New Tab row is an NSViewRepresentable, which ImageRenderer paints as a
            // saturated block; suppressed here the same way the screenshot generator does it.
            .environment(\.orbitScreenshotModeDragDisabled, true)
            .background(Color(Self.lightTheme.primary.nsColor))
        return render(view, size: Self.renderSize, appearance: .aqua)
    }

    private func topBandIsIdentical(_ lhs: RenderedImage, _ rhs: RenderedImage, height: Int, tolerance: Double = 0.04) -> Bool {
        let width = Int(Self.renderSize.width.rounded(.down))
        for y in 0..<height {
            for x in 0..<width {
                if !lhs.color(atX: x, y: y).isApproximately(rhs.color(atX: x, y: y), tolerance: tolerance) {
                    return false
                }
            }
        }
        return true
    }

    private func imagesDifferAnywhere(_ lhs: RenderedImage, _ rhs: RenderedImage, tolerance: Double = 0.04) -> Bool {
        let width = Int(Self.renderSize.width.rounded(.down))
        let height = Int(Self.renderSize.height.rounded(.down))
        for y in 0..<height {
            for x in 0..<width {
                if !lhs.color(atX: x, y: y).isApproximately(rhs.color(atX: x, y: y), tolerance: tolerance) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - The regression

    func test_addingATodayTab_doesNotDisturbTheFirstRow_soNewTabStaysAtTheTop() {
        let empty = renderTodaySection(todayTabCount: 0)
        let populated = renderTodaySection(todayTabCount: 1)

        XCTAssertTrue(
            imagesDifferAnywhere(empty, populated),
            "Adding a Today tab must change the render somewhere. If it does not, the section drew nothing and the band comparison below would pass vacuously — see this file's header."
        )

        let bandHeight = Int(OrbitMetrics.sidebarRowHeight.rounded(.down))
        XCTAssertTrue(
            topBandIsIdentical(empty, populated, height: bandHeight),
            """
            The first row of the Today section changed when a tab was added, which means `+ New Tab` is not the first row.
            Arc puts it directly under the Pinned/Today divider and above the first Today tab — three captures, all opened: \
            arc-sidebar-today-list-clear.png, arc-hover-preview-pinned-tab.png, and frame 0 of \
            web/arc-library-window-sections-tour.gif. With the row at the bottom of the list instead, the affordance slides \
            down the sidebar as the user accumulates tabs.
            """
        )
    }

    func test_theNewTabRowIsOrderedBeforeTheTodayTabList() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Orbit/UI/Sidebar/TodaySectionView.swift"),
            encoding: .utf8
        )

        let bodyStart = try XCTUnwrap(
            source.range(of: "var body: some View {"),
            "Could not find TodaySectionView's body — this guard's own source walk is broken."
        )
        let body = source[bodyStart.upperBound...]

        let newTabMention = try XCTUnwrap(
            body.range(of: "\n            newTabRow"),
            "TodaySectionView's body must render `newTabRow`. If this fails the sidebar has no new-tab affordance at all."
        )
        let forEachMention = try XCTUnwrap(
            body.range(of: "ForEach(tidyGroupedTodayItems"),
            "TodaySectionView's body must render the Today tab list — this guard's own source walk is broken, or the list was renamed."
        )

        XCTAssertTrue(
            newTabMention.lowerBound < forEachMention.lowerBound,
            "`newTabRow` must appear before the Today tab `ForEach` in TodaySectionView's body — Arc puts `+ New Tab` above the tabs, not below them."
        )
    }
}
