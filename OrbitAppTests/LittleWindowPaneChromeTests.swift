import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class LittleWindowPaneChromeTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
    }

    // MARK: - Fixtures

    private func makeTab(url: String = "https://example.com", splitIndex: Int = 0) -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        var tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        tab.splitIndex = splitIndex
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func cleanup(_ tabIDs: [TabID]) {
        for id in tabIDs {
            env.state.tabs.removeValue(forKey: id)
            env.navigationStates.removeValue(forKey: id)
            env.themeColors.removeValue(forKey: id)
        }
    }

    // MARK: - 1. `ToolbarPaneCapabilities.singlePageWindow`/`.full`: the real values

    func test_toolbarPaneCapabilities_theRealStaticValues() {
        XCTAssertTrue(ToolbarPaneCapabilities.full.allowsSplit)
        XCTAssertTrue(ToolbarPaneCapabilities.full.allowsSidebarToggle)
        XCTAssertEqual(ToolbarPaneCapabilities.full.leadingInset, 0, "the main window's own pane draws its traffic lights in the sidebar row, not this header")
        XCTAssertFalse(ToolbarPaneCapabilities.full.showsOpenInOrbit)

        XCTAssertFalse(
            ToolbarPaneCapabilities.singlePageWindow.allowsSplit,
            "a single-page window (Peek) has no SplitViewContainer to host a second pane in"
        )
        XCTAssertFalse(
            ToolbarPaneCapabilities.singlePageWindow.allowsSidebarToggle,
            "a single-page window has no sidebar of its own for the toggle to show/hide"
        )
        XCTAssertEqual(ToolbarPaneCapabilities.singlePageWindow.leadingInset, 0, "Peek is a floating panel, not a window with traffic lights of its own")
        XCTAssertFalse(
            ToolbarPaneCapabilities.singlePageWindow.showsOpenInOrbit,
            "Peek already presents its own, differently-shaped \"Open as Tab\" control outside this header (PeekPanelView) — this must not add a second, redundant one inside it"
        )

        XCTAssertFalse(ToolbarPaneCapabilities.littleOrbitWindow.allowsSplit)
        XCTAssertFalse(ToolbarPaneCapabilities.littleOrbitWindow.allowsSidebarToggle)
        XCTAssertEqual(
            ToolbarPaneCapabilities.littleOrbitWindow.leadingInset,
            OrbitMetrics.trafficLightLeadingInset + OrbitWindowControlMetrics.clusterWidth,
            "the little window's own traffic-light gutter must be the same reservation SidebarTopRow makes for the main window's lights, not a re-guessed literal"
        )
        XCTAssertTrue(
            ToolbarPaneCapabilities.littleOrbitWindow.showsOpenInOrbit,
            "the little window's promote control must be real — it is the one surface `.singlePageWindow` intentionally omits it from"
        )
    }

    // MARK: - 2. Split View is suppressed by `.singlePageWindow`, kept by `.full`

    private func secondFromTrailingEdgeBox(width: CGFloat) -> CGRect {
        let iconY = OrbitToolbarMetrics.topPadding + (OrbitToolbarMetrics.height - OrbitToolbarMetrics.trailingIconSize) / 2
        let rightEdgeBoxLeadingX = width - OrbitToolbarMetrics.trailingPadding - OrbitToolbarMetrics.trailingIconSize
        let secondBoxLeadingX = rightEdgeBoxLeadingX - OrbitToolbarMetrics.trailingIconSpacing - OrbitToolbarMetrics.trailingIconSize
        return CGRect(x: secondBoxLeadingX + 2, y: iconY, width: OrbitToolbarMetrics.trailingIconSize - 4, height: OrbitToolbarMetrics.trailingIconSize)
    }

    private func renderHeader(tab: Orbit.Tab, paneCapabilities: ToolbarPaneCapabilities, width: CGFloat) -> RenderedImage {
        render(
            ToolbarView(tab: tab, paneCapabilities: paneCapabilities)
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true),
            size: CGSize(width: width, height: OrbitToolbarMetrics.totalHeight)
        )
    }

    func test_singlePageWindow_suppressesSplitControl() throws {
        let tab = makeTab()
        defer { cleanup([tab.id]) }

        let rendered = renderHeader(tab: tab, paneCapabilities: .singlePageWindow, width: 640)
        let box = secondFromTrailingEdgeBox(width: 640)
        let background = rendered.color(atX: 2, y: 2)

        if rendered.containsNonBackgroundPixels(in: box, background: background) {
            rendered.writeDiagnosticPNG(named: "singlePageWindow-splitControl-FAILED")
        }
        XCTAssertFalse(
            rendered.containsNonBackgroundPixels(in: box, background: background),
            "`.singlePageWindow` must suppress the Split View control entirely — LittleOrbitWindowController.swift's own header records the real defect this closes: a click here used to create a SplitGroup with no SplitViewContainer anywhere to host its second pane, and stole the main window's active tab in the process."
        )
    }

    func test_full_rendersSplitControl() throws {
        let tab = makeTab()
        defer { cleanup([tab.id]) }

        let rendered = renderHeader(tab: tab, paneCapabilities: .full, width: 640)
        let box = secondFromTrailingEdgeBox(width: 640)
        let background = rendered.color(atX: 2, y: 2)

        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: box, background: background),
            "`.full` (the main window's own pane) must keep drawing Split View beside Site Control — this test is the control for the suppression assertion above: without it, a `.singlePageWindow` regression that always hid the icon would pass unnoticed."
        )
    }

    // MARK: - 3. The collapsed-sidebar toggle is suppressed by `.singlePageWindow`, kept by `.full`

    private var fourthNavBox: CGRect {
        let x = OrbitToolbarMetrics.leadingPadding
            + OrbitToolbarMetrics.navIconSize * 3
            + OrbitToolbarMetrics.navIconSpacing * 3
        return CGRect(x: x + 2, y: OrbitToolbarMetrics.topPadding, width: OrbitToolbarMetrics.navIconSize - 4, height: OrbitToolbarMetrics.height)
    }

    func test_singlePageWindow_suppressesTheSidebarToggle_evenWithTheMainWindowsSidebarCollapsed() throws {
        let tab = makeTab()
        defer { cleanup([tab.id]) }

        env.isSidebarVisible = false
        let rendered = renderHeader(tab: tab, paneCapabilities: .singlePageWindow, width: 640)
        let background = rendered.color(atX: 2, y: 2)

        if rendered.containsNonBackgroundPixels(in: fourthNavBox, background: background) {
            rendered.writeDiagnosticPNG(named: "singlePageWindow-sidebarToggle-FAILED")
        }
        XCTAssertFalse(
            rendered.containsNonBackgroundPixels(in: fourthNavBox, background: background),
            "`.singlePageWindow` must suppress the sidebar toggle regardless of the main window's own env.isSidebarVisible — this window has no sidebar of its own for the flag to describe."
        )
    }

    func test_full_rendersTheSidebarToggleWhenTheSharedSidebarFlagIsCollapsed() throws {
        let tab = makeTab()
        defer { cleanup([tab.id]) }

        env.isSidebarVisible = false
        let rendered = renderHeader(tab: tab, paneCapabilities: .full, width: 640)
        let background = rendered.color(atX: 2, y: 2)

        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: fourthNavBox, background: background),
            "the control for the suppression assertion above: `.full` must still draw the toggle when the sidebar it actually describes is collapsed."
        )
    }

    // MARK: - 4. The little window's header reflects its OWN tab, not the main window's active tab

    func test_littleWindowsHeader_reflectsItsOwnTabsNavigationState_notTheMainWindowsActiveTab() throws {
        let tabA = makeTab(url: "https://main-window-active-tab.example.com")
        let tabB = makeTab(url: "https://little-orbit-own-tab.example.com")
        defer { cleanup([tabA.id, tabB.id]) }

        env.activeTabID = tabA.id
        env.isSidebarVisible = true // keep the nav cluster's leading edge fixed regardless of `.littleOrbitWindow`'s own toggle suppression.
        env.navigationStates[tabA.id] = NavigationState(url: tabA.url, canGoBack: true)
        env.navigationStates[tabB.id] = NavigationState(url: tabB.url, canGoBack: false)

        let width: CGFloat = 640
        let leadingInset = ToolbarPaneCapabilities.littleOrbitWindow.leadingInset
        let iconY = OrbitToolbarMetrics.topPadding + (OrbitToolbarMetrics.height - OrbitToolbarMetrics.navIconSize) / 2
        let backIconRect = CGRect(x: OrbitToolbarMetrics.leadingPadding + leadingInset, y: iconY, width: OrbitToolbarMetrics.navIconSize, height: OrbitToolbarMetrics.navIconSize)
        let barRect = CGRect(x: (OrbitToolbarMetrics.leadingPadding + leadingInset) / 4, y: iconY, width: OrbitToolbarMetrics.leadingPadding / 2, height: OrbitToolbarMetrics.navIconSize)

        func luminance(_ c: RGBA) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        func contrast(_ rendered: RenderedImage) -> Double {
            abs(luminance(rendered.averageColor(in: backIconRect)) - luminance(rendered.averageColor(in: barRect)))
        }

        let littleWindowHeader = renderHeader(tab: tabB, paneCapabilities: .littleOrbitWindow, width: width)
        let littleWindowContrast = contrast(littleWindowHeader)

        env.navigationStates[tabB.id] = NavigationState(url: tabB.url, canGoBack: true)
        let groundTruthEnabledContrast = contrast(renderHeader(tab: tabB, paneCapabilities: .littleOrbitWindow, width: width))
        env.navigationStates[tabB.id] = NavigationState(url: tabB.url, canGoBack: false)
        let groundTruthDisabledContrast = contrast(renderHeader(tab: tabB, paneCapabilities: .littleOrbitWindow, width: width))

        if abs(littleWindowContrast - groundTruthDisabledContrast) > abs(littleWindowContrast - groundTruthEnabledContrast) {
            littleWindowHeader.writeDiagnosticPNG(named: "littleWindow-navigationState-FAILED")
        }
        XCTAssertLessThan(
            abs(littleWindowContrast - groundTruthDisabledContrast),
            abs(littleWindowContrast - groundTruthEnabledContrast),
            """
            The little window's header (tab B, canGoBack == false) rendered closer to tab B's own \
            'enabled' ground truth (contrast \(groundTruthEnabledContrast)) than to tab B's own \
            'disabled' ground truth (contrast \(groundTruthDisabledContrast)) — got \(littleWindowContrast). \
            Since env.activeTabID names tab A (canGoBack == true) throughout, this is exactly what a \
            regression to reading the environment's shared active tab, instead of this pane's own \
            tab: parameter, would produce.
            """
        )
    }

    func test_littleOrbitWindowControllersOwnSourceBuildsThisExactHeader() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Orbit/UI/Window/LittleOrbitWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("ToolbarView(tab: tab, paneCapabilities: .littleOrbitWindow)"),
            "LittleOrbitWindowController.swift no longer builds its header with ToolbarView(tab: tab, paneCapabilities: .littleOrbitWindow) — the render assertions above no longer prove anything about what this window actually shows."
        )
        XCTAssertTrue(
            source.contains("private var tab: Tab? { env.tab(tabID) }"),
            "LittleOrbitView's own `tab` must resolve from this window's own stored `tabID`, never from env.activeTabID — that is the entire property under test here."
        )
    }

    // MARK: - 5. `siteControlPresentedTabID` distinguishes panes

    func test_siteControlPresentedTabID_isPerTab_notSharedAcrossPanes() {
        let tabA = makeTab(url: "https://pane-a.example.com")
        let tabB = makeTab(url: "https://pane-b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }

        XCTAssertNil(env.siteControlPresentedTabID, "precondition: nothing presented at the start")

        env.siteControlPresentedTabID = tabA.id

        XCTAssertEqual(env.siteControlPresentedTabID, tabA.id, "pane A's own popover binding (env.siteControlPresentedTabID == tab.id) must read true for tab A")
        XCTAssertNotEqual(
            env.siteControlPresentedTabID, tabB.id,
            "pane B's popover binding must read false while pane A's is presented — a shared, non-tab-keyed flag would make this equal and open both panes' popovers at once"
        )

        env.siteControlPresentedTabID = tabB.id
        XCTAssertNotEqual(env.siteControlPresentedTabID, tabA.id)
        XCTAssertEqual(env.siteControlPresentedTabID, tabB.id)
    }

    func test_toolbarViewsSiteControlWiring_isKeyedByTabID_inSource() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Orbit/UI/Toolbar/ToolbarView.swift"),
            encoding: .utf8
        )

        let marker = "private var siteControlPopoverBinding: Binding<Bool> {"
        let start = try XCTUnwrap(
            source.range(of: marker),
            "Could not find `siteControlPopoverBinding` in ToolbarView.swift — this guard's own source walk is broken, or the property was renamed."
        )
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "Could not find the end of `siteControlPopoverBinding`.")
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(
            body.contains("env.siteControlPresentedTabID == tab.id"),
            "the popover's own `get` must compare env.siteControlPresentedTabID against THIS pane's tab.id, not env.activeTabID or a shared Bool."
        )
        XCTAssertTrue(
            body.contains("env.siteControlPresentedTabID = tab.id"),
            "the popover's own `set` must write this pane's tab.id."
        )
    }
}
