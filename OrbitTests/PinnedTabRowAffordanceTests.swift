import XCTest
import SwiftUI

@MainActor
final class PinnedTabRowAffordanceTests: XCTestCase {

    private let pinnedURL = URL(string: "https://www.typeform.com/results")!
    private let wanderedURL = URL(string: "https://www.typeform.com/workspaces")!

    private func makeTab(navigatedAway: Bool, section: TabSection = .pinned) -> Tab {
        Tab(
            spaceID: SpaceID(),
            section: section,
            url: navigatedAway ? wanderedURL : pinnedURL,
            title: "Workspaces",
            pinnedURL: pinnedURL,
            pinnedTitle: "Typeform - Results"
        )
    }

    // MARK: - The Command-click decision

    func testCommandHeldAsksForThePriorURLInANewTab() {
        XCTAssertTrue(TabRowView.shouldOpenPriorURLInNewTab(modifiers: [.command]))
        XCTAssertTrue(
            TabRowView.shouldOpenPriorURLInNewTab(modifiers: [.command, .shift]),
            "Command with something else held is still Command."
        )
    }

    func testWithoutCommandTheResetHappensInPlace() {
        XCTAssertFalse(TabRowView.shouldOpenPriorURLInNewTab(modifiers: []))
        XCTAssertFalse(
            TabRowView.shouldOpenPriorURLInNewTab(modifiers: [.shift, .option, .control]),
            "Only Command opts into the second tab; Arc documents no other modifier for this gesture."
        )
    }

    // MARK: - The `/` marker

    private static let rowRenderSize = CGSize(width: 240, height: OrbitMetrics.sidebarRowHeight)

    // Screenshot mode: the row's full-size click catcher is an NSViewRepresentable,
    // which ImageRenderer paints as an opaque block over everything below it.
    private func renderRow(_ tab: Tab) -> RenderedImage {
        render(
            TabRowView(tab: tab, theme: SpaceTheme())
                .environment(AppEnvironment())
                .environment(\.orbitScreenshotModeDragDisabled, true),
            size: Self.rowRenderSize
        )
    }

    private func differingPointCount(_ a: RenderedImage, _ b: RenderedImage) -> Int {
        var differing = 0
        for x in 0..<Int(Self.rowRenderSize.width) {
            for y in 0..<Int(Self.rowRenderSize.height) {
                if !a.color(atX: x, y: y).isApproximately(b.color(atX: x, y: y), tolerance: 0.02) {
                    differing += 1
                }
            }
        }
        return differing
    }

    func testARowThatHasNavigatedAwayRendersDifferentlyFromOneThatHasNot() {
        let atOriginTab = makeTab(navigatedAway: false)
        let awayTab = makeTab(navigatedAway: true)
        XCTAssertFalse(atOriginTab.hasNavigatedAwayFromPinnedURL, "Fixture check.")
        XCTAssertTrue(awayTab.hasNavigatedAwayFromPinnedURL, "Fixture check: the 'away' row must actually be away.")

        let atOrigin = renderRow(atOriginTab)
        let away = renderRow(awayTab)

        XCTAssertNotNil(atOrigin.boundingBoxOfContent(tolerance: 0.03), "Sanity: the control row must draw its favicon and label.")

        let differing = differingPointCount(atOrigin, away)
        if differing <= 20 {
            atOrigin.writeDiagnosticPNG(named: "pinnedSlash-atOrigin-FAILED")
            away.writeDiagnosticPNG(named: "pinnedSlash-away-FAILED")
        }
        XCTAssertGreaterThan(
            differing, 20,
            """
            A pinned row showing a different page than the one it was pinned at must draw the `/` \
            marker (Arc Help Center 25625148480279; \
            refs/reference/web/arc-pinned-tab-resetting-demo.gif renders the row as \
            `[favicon] / Workspaces`). Only \(differing) point(s) of the row differ from the same \
            tab sitting on its pinned URL — far too few to be a rendered glyph. See the \
            diagnostic PNGs.
            """
        )
    }

    func testATodayRowCarryingAnOriginRendersIdenticallyToOneWithout() {
        let todayTab = makeTab(navigatedAway: true, section: .today)
        XCTAssertNotNil(todayTab.pinnedURL, "Fixture check: the Today tab still carries an origin.")
        XCTAssertFalse(todayTab.hasNavigatedAwayFromPinnedURL, "A Today row is never reported as navigated away.")

        var plainTab = todayTab
        plainTab.pinnedURL = nil
        plainTab.pinnedTitle = nil

        let differing = differingPointCount(renderRow(todayTab), renderRow(plainTab))

        XCTAssertEqual(
            differing, 0,
            "A Today row must not change by one point just because the tab remembers where it was once pinned."
        )
    }
}
