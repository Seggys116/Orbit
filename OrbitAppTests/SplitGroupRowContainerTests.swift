//  Regression cover: a split pair used to draw as one undivided pill with a single trailing x
//  that closed both panes at once, instead of a container with per-pane pills and close controls.

import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SplitGroupRowContainerTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var spaceID: SpaceID {
        env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
    }

    private func makeTab(url: String, title: String) -> Orbit.Tab {
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: title)
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func makeSplitPair(
        titleA: String = "Pane A",
        titleB: String = "Pane B"
    ) -> (Orbit.Tab, Orbit.Tab, SplitGroup)? {
        let tabA = makeTab(url: "https://a.example.com", title: titleA)
        let tabB = makeTab(url: "https://b.example.com", title: titleB)
        guard env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) != nil,
              let group = env.splitGroup(for: tabA.id) else {
            XCTFail("Failed to create a split group.")
            return nil
        }
        return (tabA, tabB, group)
    }

    // MARK: - A container with one pill per pane

    func test_splitGroupRow_drawsOnePillPerPane_withTheContainerVisibleBetweenThem() {
        guard let (tabA, tabB, group) = makeSplitPair() else { return }
        defer { env.store.dissolveSplit(group.id) }

        // Wide enough that the 3pt gap between pills is several backing pixels across, so a
        // sample lands inside it rather than on an antialiased pill edge.
        let size = CGSize(width: 400, height: OrbitMetrics.sidebarRowHeight)
        let rendered = render(
            SplitGroupRowView(group: group, tabs: [tabA, tabB], theme: SpaceTheme())
                .environment(env),
            size: size
        )

        let centreY = Int(size.height / 2)
        let leftPill = rendered.color(atX: Int(size.width * 0.30), y: centreY)
        let gap = rendered.color(atX: Int(size.width / 2), y: centreY)
        let rightPill = rendered.color(atX: Int(size.width * 0.70), y: centreY)

        if !(leftPill.a > gap.a && rightPill.a > gap.a) {
            rendered.writeDiagnosticPNG(named: "splitGroupRow-containerAndPills-FAILED")
        }

        XCTAssertGreaterThan(
            leftPill.a, gap.a,
            "The left pane's pill (alpha \(leftPill.a)) must paint denser than the container gap beside it (\(gap.a)) — user: the split pair should read as \"a container\" with a pill per tab, not one undivided row."
        )
        XCTAssertGreaterThan(
            rightPill.a, gap.a,
            "The right pane's pill (alpha \(rightPill.a)) must paint denser than the container gap beside it (\(gap.a))."
        )
        XCTAssertGreaterThan(
            gap.a, 0,
            "The container itself must paint behind the pills — with no container fill at all the pills would float on the sidebar with nothing joining them."
        )
    }

    // The test above samples only the row's vertical centre, so it cannot catch
    // equal insets making the container and pane pills coincide exactly.
    func test_theContainerIsVisibleAboveAndBelowThePillsToo() {
        guard let (tabA, tabB, group) = makeSplitPair() else { return }
        defer { env.store.dissolveSplit(group.id) }

        let size = CGSize(width: 400, height: OrbitMetrics.sidebarRowHeight)
        let rendered = render(
            SplitGroupRowView(group: group, tabs: [tabA, tabB], theme: SpaceTheme())
                .environment(env),
            size: size
        )

        let pillTop = OrbitMetrics.sidebarRowPillVerticalInset
        let paneTop = pillTop + OrbitMetrics.sidebarSplitGroupInnerInset
        let x = Int(size.width * 0.30)

        let aboveThePill = rendered.color(atX: x, y: Int((pillTop + paneTop) / 2))
        let belowThePill = rendered.color(atX: x, y: Int(size.height - (pillTop + paneTop) / 2))
        let onThePill = rendered.color(atX: x, y: Int(size.height / 2))

        if !(onThePill.a > aboveThePill.a && onThePill.a > belowThePill.a) {
            rendered.writeDiagnosticPNG(named: "splitGroupRow-verticalContainerBands-FAILED")
        }

        XCTAssertGreaterThan(
            aboveThePill.a, 0,
            "The container must paint above the pane pills; with nothing there the row has no top edge and the pills read as bursting out of it."
        )
        XCTAssertGreaterThan(
            onThePill.a, aboveThePill.a,
            "The pane pill (alpha \(onThePill.a)) must paint denser than the container band above it (\(aboveThePill.a)) — equal means the pill runs to the container's own top edge, which is the reported defect."
        )
        XCTAssertGreaterThan(
            onThePill.a, belowThePill.a,
            "The pane pill (alpha \(onThePill.a)) must paint denser than the container band below it (\(belowThePill.a))."
        )
        XCTAssertEqual(
            aboveThePill.a, belowThePill.a, accuracy: 0.02,
            "The top and bottom bands must be the same depth as each other, or the pills sit off-centre in the container."
        )
    }

    // Regression cover: on a 240pt sidebar the fixed chrome left the title only 6pt, because 30
    // of those points were reserved for a close control that is now an overlay instead.
    func test_aPaneTitleGetsRealWidthNotOneCharacter() {
        guard let (tabA, tabB, group) = makeSplitPair(
            titleA: "Chromium Content Embedder Notes",
            titleB: "How to build a browser"
        ) else { return }
        defer { env.store.dissolveSplit(group.id) }

        let size = CGSize(width: 240, height: OrbitMetrics.sidebarRowHeight)
        // Opaque backdrop, not the transparent canvas: the row's near-white foreground would
        // make a transparent diagnostic PNG unreadable, and sampling is unaffected either way.
        let rendered = render(
            SplitGroupRowView(group: group, tabs: [tabA, tabB], theme: SpaceTheme())
                .environment(env)
                .background(Color(red: 0.16, green: 0.13, blue: 0.22)),
            size: size
        )
        rendered.writeDiagnosticPNG(named: "splitGroupRow-titleWidth")

        let contentInset = OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset
            + OrbitMetrics.sidebarSplitGroupInnerInset
        let paneWidth = (size.width - 2 * contentInset - OrbitMetrics.sidebarSplitGroupInnerInset) / 2
        let titleStart = contentInset + OrbitMetrics.sidebarSplitGroupInnerInset
            + OrbitMetrics.faviconSize + OrbitMetrics.sidebarSplitGroupContentSpacing
        let titleEnd = contentInset + paneWidth - OrbitMetrics.sidebarSplitGroupInnerInset

        let baseline = Int(size.height / 2)
        let background = rendered.color(atX: Int(titleStart), y: Int(OrbitMetrics.sidebarRowPillVerticalInset) + 2)
        var glyphColumns = 0
        for x in Int(titleStart)..<Int(titleEnd) {
            let sample = rendered.color(atX: x, y: baseline)
            if abs(sample.r - background.r) > 0.02 || abs(sample.a - background.a) > 0.02 {
                glyphColumns += 1
            }
        }

        XCTAssertGreaterThan(
            glyphColumns, 12,
            "Only \(glyphColumns) columns of the first pane's title painted, out of \(Int(titleEnd - titleStart)) available — the title is being cut to a character or two, which is the reported defect. See the diagnostic PNG."
        )
    }

    func test_aThreePaneSplitStillShowsReadableTitles() {
        let tabs = [
            makeTab(url: "https://a.example.com", title: "Wikipedia Chromium"),
            makeTab(url: "https://b.example.com", title: "Hacker News"),
            makeTab(url: "https://c.example.com", title: "Medium Guide")
        ]
        guard env.store.createSplit(with: tabs.map(\.id), axis: .horizontal) != nil,
              let group = env.splitGroup(for: tabs[0].id) else {
            return XCTFail("Failed to create a three-pane split group.")
        }
        defer { env.store.dissolveSplit(group.id) }

        let size = CGSize(width: 240, height: OrbitMetrics.sidebarRowHeight)
        let rendered = render(
            SplitGroupRowView(group: group, tabs: tabs, theme: SpaceTheme())
                .environment(env)
                .background(Color(red: 0.16, green: 0.13, blue: 0.22)),
            size: size
        )
        rendered.writeDiagnosticPNG(named: "splitGroupRow-threePaneTitleWidth")

        let contentInset = OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset
            + OrbitMetrics.sidebarSplitGroupInnerInset
        let paneWidth = (size.width - 2 * contentInset - 2 * OrbitMetrics.sidebarSplitGroupInnerInset) / 3
        let middleStart = contentInset + paneWidth + OrbitMetrics.sidebarSplitGroupInnerInset
        let titleStart = middleStart + OrbitMetrics.sidebarSplitGroupInnerInset
            + OrbitMetrics.faviconSize + OrbitMetrics.sidebarSplitGroupContentSpacing
        let titleEnd = middleStart + paneWidth - OrbitMetrics.sidebarSplitGroupInnerInset

        let baseline = Int(size.height / 2)
        let background = rendered.color(atX: Int(titleStart), y: Int(OrbitMetrics.sidebarRowPillVerticalInset) + 2)
        var glyphColumns = 0
        for x in Int(titleStart)..<Int(titleEnd) {
            let sample = rendered.color(atX: x, y: baseline)
            if abs(sample.r - background.r) > 0.02 || abs(sample.a - background.a) > 0.02 {
                glyphColumns += 1
            }
        }

        XCTAssertGreaterThan(
            glyphColumns, 6,
            "The middle pane of a three-way split painted only \(glyphColumns) columns of title out of \(Int(titleEnd - titleStart)) available. See the diagnostic PNG."
        )
    }

    func test_containerFill_staysBelowThePillsItHolds() {
        XCTAssertLessThan(
            OrbitMetrics.sidebarSplitGroupContainerOpacity,
            OrbitMetrics.sidebarSplitGroupPaneOpacity,
            "The container must read as a recessed surface the pane pills sit on."
        )
        XCTAssertLessThan(
            OrbitMetrics.sidebarSplitGroupPaneOpacity,
            OrbitMetrics.sidebarSplitGroupPaneHoverOpacity,
            "Hovering a pane pill must actually lift it — that hover is also what reveals its close control."
        )
        XCTAssertLessThanOrEqual(
            OrbitMetrics.sidebarSplitGroupPaneHoverOpacity,
            OrbitMetrics.sidebarActiveRowOpacity,
            "A hovered inactive pane must not out-shout the active one."
        )
        XCTAssertGreaterThan(
            OrbitMetrics.sidebarSplitGroupPaneCornerRadius, 0,
            "The pane pills must actually be rounded — a zero radius is a rectangle inside a rounded container, which is the shape the container was supposed to stop looking like."
        )
        XCTAssertLessThan(
            OrbitMetrics.sidebarSplitGroupPaneCornerRadius,
            OrbitMetrics.sidebarRowCornerRadius,
            "The pills sit inset inside the container, so their rounding must be tighter than the container's to stay concentric with it."
        )
    }

    // MARK: - Per-pane close

    func test_closingOnePane_leavesTheOtherAsAnOrdinaryOpenTab() {
        guard let (tabA, tabB, group) = makeSplitPair() else { return }
        defer { if env.splitGroup(for: tabA.id) != nil { env.store.dissolveSplit(group.id) } }

        env.closeTab(tabA.id)

        XCTAssertNil(env.splitGroup(for: tabB.id), "With its partner closed, the surviving pane must go back to being an ordinary full-width tab.")
        XCTAssertEqual(env.tab(tabB.id)?.section, .today, "The surviving tab must still be open — closing one pane must never close both.")
        XCTAssertEqual(env.tab(tabA.id)?.section, .archived, "The closed pane's tab must actually be closed (archived), not merely separated.")
    }

    func test_closingEveryPane_closesTheWholeSplit() {
        guard let (tabA, tabB, _) = makeSplitPair() else { return }

        for tab in [tabA, tabB] { env.closeTab(tab.id) }

        XCTAssertEqual(env.tab(tabA.id)?.section, .archived)
        XCTAssertEqual(env.tab(tabB.id)?.section, .archived)
        XCTAssertNil(env.splitGroup(for: tabA.id))
        XCTAssertNil(env.splitGroup(for: tabB.id))
    }
}
