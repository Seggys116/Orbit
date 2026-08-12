import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SplitPaneCloseControlTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func makeTab(url: String = "https://example.com") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func makeSplitPair() -> (Orbit.Tab, Orbit.Tab, UUID)? {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return nil
        }
        return (tabA, tabB, groupID)
    }

    // MARK: - "ONLY IN SPLIT MODE!"

    func test_closeControl_appliesOnlyToAPaneThatIsPartOfASplit() {
        let lone = makeTab()
        defer { env.state.tabs.removeValue(forKey: lone.id) }

        XCTAssertFalse(
            SplitPaneCloseControl.isApplicable(to: lone, in: env),
            "A pane that is not in a split must draw no close control — user, verbatim: \"ONLY IN SPLIT MODE!\". The window's own close button already owns closing a lone pane."
        )

        guard let (tabA, tabB, groupID) = makeSplitPair() else { return }
        defer {
            env.store.dissolveSplit(groupID)
            env.state.tabs.removeValue(forKey: tabA.id)
            env.state.tabs.removeValue(forKey: tabB.id)
        }

        XCTAssertTrue(SplitPaneCloseControl.isApplicable(to: tabA, in: env), "Every pane of a split gets its own close control.")
        XCTAssertTrue(SplitPaneCloseControl.isApplicable(to: tabB, in: env), "Every pane of a split gets its own close control.")
    }

    func test_closeControl_paintsNothingForALonePane() {
        let lone = makeTab()
        defer { env.state.tabs.removeValue(forKey: lone.id) }

        let size = CGSize(width: OrbitToolbarMetrics.trailingIconSize, height: OrbitToolbarMetrics.trailingIconSize)
        let loneInk = paintedAlpha(
            of: SplitPaneCloseControl(tab: lone, foreground: .white).environment(env),
            size: size
        )

        XCTAssertEqual(loneInk, 0, accuracy: 0.5, "A lone pane's header must paint no close control at all; this one painted \(loneInk) of alpha.")
    }

    func test_closeGlyph_paintsAVisibleMark() {
        let size = CGSize(width: OrbitToolbarMetrics.trailingIconSize, height: OrbitToolbarMetrics.trailingIconSize)
        let glyphInk = paintedAlpha(of: ToolbarTrailingGlyph.splitClose.foregroundStyle(Color.white), size: size)

        XCTAssertGreaterThan(glyphInk, 0, "The split-pane close glyph must actually paint an X.")
    }

    // MARK: - Where it sits

    func test_addressReserve_clearsTheWholeTrailingClusterWhenThePaneIsSplit() {
        let withoutClose = OrbitToolbarMetrics.addressSideReserve(withSidebarToggle: false, withSplitClose: false)
        let withClose = OrbitToolbarMetrics.addressSideReserve(withSidebarToggle: false, withSplitClose: true)
        let fullTrailingCluster = OrbitToolbarMetrics.trailingClusterWidth + OrbitToolbarMetrics.splitCloseClusterWidth

        XCTAssertGreaterThanOrEqual(
            withClose, fullTrailingCluster,
            "A split pane's centred address field must reserve at least \(fullTrailingCluster)pt — Site Control, Split View and the close control — or a full URL runs underneath the close button."
        )
        XCTAssertGreaterThanOrEqual(
            withClose, withoutClose,
            "Adding an icon to the trailing cluster must never *shrink* the address field's reserve."
        )
        XCTAssertEqual(
            OrbitToolbarMetrics.splitCloseClusterWidth,
            OrbitToolbarMetrics.trailingIconSize + OrbitToolbarMetrics.trailingIconSpacing,
            accuracy: 0.001,
            "The reserve must be derived from the icon and gap it is reserving for, not from an independent literal."
        )
        XCTAssertEqual(
            OrbitToolbarMetrics.addressSideReserve(withSidebarToggle: false),
            withoutClose,
            accuracy: 0.001,
            "The default must stay the non-split geometry `ToolbarModeTests` asserts the address field's frame against."
        )
    }

    func test_headerChrome_fitsInsideTheNarrowestPaneTheAppCanProduce() {
        let narrowestPane = 760.0 / 2
        let headerMinimum =
            OrbitToolbarMetrics.leadingPadding
            + OrbitToolbarMetrics.navClusterWidth
            + OrbitToolbarMetrics.trailingClusterWidth
            + OrbitToolbarMetrics.splitCloseClusterWidth
            + OrbitToolbarMetrics.trailingPadding

        XCTAssertLessThanOrEqual(
            headerMinimum, narrowestPane,
            "A split pane's header chrome (\(headerMinimum)pt with the close control) no longer fits inside a \(narrowestPane)pt pane, so the cluster row will overflow and draw outside the pane card."
        )
    }

    // MARK: - What it does

    func test_closeSplitPane_removesTheSpecificPaneRegardlessOfFocus() {
        guard let (tabA, tabB, groupID) = makeSplitPair() else { return }
        defer {
            if let remaining = env.splitGroup(for: tabA.id) { env.store.dissolveSplit(remaining.id) }
            else if let remaining = env.splitGroup(for: tabB.id) { env.store.dissolveSplit(remaining.id) }
            else { env.store.dissolveSplit(groupID) }
            env.state.tabs.removeValue(forKey: tabA.id)
            env.state.tabs.removeValue(forKey: tabB.id)
        }
        env.focusedSplitPaneIndex = 0

        env.closeSplitPane(tabB.id)

        XCTAssertNil(env.splitGroup(for: tabB.id), "Pane B should no longer be part of any split group.")
        XCTAssertNotNil(env.tab(tabB.id), "Closing a pane separates it — it must not delete the tab outright.")
    }

    // MARK: - Helpers

    private func paintedAlpha(of view: some View, size: CGSize) -> Double {
        let bitmap = render(view, size: size).bitmap
        var total = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let sample = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += Double(sample.alphaComponent)
            }
        }
        return total
    }
}
