import XCTest
import SwiftUI
@testable import Orbit

@MainActor
final class SidebarRenderTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        env.isSidebarVisible = true
        env.isSidebarHoverRevealed = false
        env.state = OrbitState()
    }

    // MARK: - D6: no circular profile/account indicator

    func test_D6_sidebarBottomBar_hasNoProfileIndicatorCircle() {
        let forbiddenProfileCircleColor = RGBA(r: 0.45, g: 0.42, b: 0.95, a: 1.0)

        var state = OrbitState()
        let profile = Profile(name: "Personal", tint: ThemeColor(red: 0.45, green: 0.42, blue: 0.95))
        state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        state.spaces = [space]
        state.activeSpaceID = space.id

        let env = self.env
        env.state = state

        let theme = SpaceTheme()
        let size = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: OrbitMetrics.sidebarBottomBarHeight)
        let rendered = render(SidebarBottomBar(theme: theme).environment(env), size: size)

        let found = containsColor(rendered, matching: forbiddenProfileCircleColor, tolerance: 0.03)
        if found {
            rendered.writeDiagnosticPNG(named: "D6-sidebarBottomBar-FAILED")
        }
        XCTAssertFalse(
            found,
            "refs/DEFECTS.md D6: found a solid pixel matching the old profile-tint colour " +
            "\(forbiddenProfileCircleColor) inside SidebarBottomBar's rendered output — the " +
            "removed profile/account circle appears to have been reintroduced. " +
            "See the diagnostic PNG path RenderHarness printed to the console."
        )
    }

    // MARK: - R14: favourites/"Top Apps" grid renders exactly three columns

    func test_R14_tabRowView_rowHeightMatchesToken() {
        let env = self.env
        let theme = SpaceTheme()
        let tab = Tab(spaceID: SpaceID(), url: URL(string: "https://r14-row-height.example.com")!)
        let width: CGFloat = 260
        let size = CGSize(width: width, height: OrbitMetrics.sidebarRowHeight)

        let rendered = render(TabRowView(tab: tab, theme: theme).environment(env), size: size)

        XCTAssertEqual(
            rendered.pointSize, size,
            "TabRowView must lay out at exactly its declared OrbitMetrics.sidebarRowHeight " +
            "(\(OrbitMetrics.sidebarRowHeight)pt), never overflowing or collapsing its own frame."
        )

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "R14-tabRowView-rowHeight-FAILED-empty")
            XCTFail("Expected TabRowView to draw its title label; rendered image was entirely background.")
            return
        }
        if box.maxY > size.height + 0.5 {
            rendered.writeDiagnosticPNG(named: "R14-tabRowView-rowHeight-FAILED")
        }
        XCTAssertLessThanOrEqual(
            box.maxY, size.height + 0.5,
            "TabRowView's content must stay within its own \(OrbitMetrics.sidebarRowHeight)pt frame, not overflow it."
        )
    }

    // MARK: - The loading bar belongs to the pill, not to the row frame

    func test_loadingProgressBar_drawsInsideThePillRatherThanUnderTheRow() {
        let env = self.env
        let theme = SpaceTheme()
        let tab = Tab(spaceID: SpaceID(), url: URL(string: "https://loading-bar.example.com")!)
        env.navigationStates[tab.id] = NavigationState(url: tab.url, isLoading: true, progress: 0.5)

        let width: CGFloat = 260
        let size = CGSize(width: width, height: OrbitMetrics.sidebarRowHeight)
        let rendered = render(TabRowView(tab: tab, theme: theme).environment(env), size: size)

        let verticalInset = OrbitMetrics.sidebarRowPillVerticalInset
        let horizontalInset = OrbitMetrics.sidebarHorizontalPadding
        let barHeight = OrbitMetrics.sidebarRowLoadingBarHeight
        let pillBottom = size.height - verticalInset          // 33
        let barTop = pillBottom - barHeight                   // 31
        let pillWidth = width - 2 * horizontalInset           // 240

        let barSample = CGRect(x: horizontalInset + 2, y: barTop + 1, width: 8, height: 1)
        if !rendered.containsNonBackgroundPixels(in: barSample, background: .clear) {
            rendered.writeDiagnosticPNG(named: "loadingBar-FAILED-missing")
        }
        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: barSample, background: .clear),
            "A loading row must show its progress bar along the bottom edge of its pill."
        )

        let belowPill = CGRect(x: 0, y: pillBottom + 1, width: width, height: verticalInset)
        if rendered.containsNonBackgroundPixels(in: belowPill, background: .clear) {
            rendered.writeDiagnosticPNG(named: "loadingBar-FAILED-below-pill")
        }
        XCTAssertFalse(
            rendered.containsNonBackgroundPixels(in: belowPill, background: .clear),
            "The loading bar must not draw below the pill — that band is the gap between two rows, not part of either."
        )

        let leftGutter = CGRect(x: 0, y: barTop, width: horizontalInset - 1, height: barHeight)
        if rendered.containsNonBackgroundPixels(in: leftGutter, background: .clear) {
            rendered.writeDiagnosticPNG(named: "loadingBar-FAILED-overhangs-left")
        }
        XCTAssertFalse(
            rendered.containsNonBackgroundPixels(in: leftGutter, background: .clear),
            "The loading bar must start at the pill's left edge, not at the sidebar's."
        )

        let pastHalfway = CGRect(
            x: horizontalInset + pillWidth * 0.5 + 4,
            y: barTop,
            width: pillWidth * 0.5 - 4,
            height: barHeight
        )
        if rendered.containsNonBackgroundPixels(in: pastHalfway, background: .clear) {
            rendered.writeDiagnosticPNG(named: "loadingBar-FAILED-overshoots")
        }
        XCTAssertFalse(
            rendered.containsNonBackgroundPixels(in: pastHalfway, background: .clear),
            "A bar at progress 0.5 must cover half the pill's width, no more."
        )
    }

    func test_loadingProgressBar_isAbsentOnARowThatIsNotLoading() {
        let env = self.env
        let theme = SpaceTheme()
        let tab = Tab(spaceID: SpaceID(), url: URL(string: "https://settled-row.example.com")!)
        env.navigationStates[tab.id] = NavigationState(url: tab.url, isLoading: false, progress: 1)

        let width: CGFloat = 262
        let size = CGSize(width: width, height: OrbitMetrics.sidebarRowHeight)
        let rendered = render(TabRowView(tab: tab, theme: theme).environment(env), size: size)

        let barBand = CGRect(
            x: 0,
            y: size.height - OrbitMetrics.sidebarRowPillVerticalInset - OrbitMetrics.sidebarRowLoadingBarHeight,
            width: width,
            height: OrbitMetrics.sidebarRowPillVerticalInset + OrbitMetrics.sidebarRowLoadingBarHeight
        )
        XCTAssertFalse(
            rendered.containsNonBackgroundPixels(in: barBand, background: .clear),
            "A row that has finished loading must draw nothing in the bar's band."
        )
    }

    // MARK: - D9: sidebar toggle sits in the traffic-light row, not below it

    func test_D9_sidebarTopRow_toggleSitsInSameBandAsTrafficLights() {
        let env = self.env
        let theme = SpaceTheme()
        let width: CGFloat = 200
        let renderHeight: CGFloat = OrbitMetrics.sidebarTopRowHeight + 24
        let rendered = render(SidebarTopRow(theme: theme).environment(env), size: CGSize(width: width, height: renderHeight))

        let trafficLightsClusterWidth = OrbitMetrics.trafficLightDiameter * 3 + OrbitMetrics.trafficLightSpacing * 2
        let toggleLeadingX = OrbitMetrics.trafficLightLeadingInset + trafficLightsClusterWidth + OrbitMetrics.trafficLightSpacing

        let sameRowRegion = CGRect(
            x: toggleLeadingX - 4,
            y: OrbitMetrics.trafficLightTopInset - 4,
            width: OrbitMetrics.sidebarTopRowIconSize + 8,
            height: OrbitMetrics.trafficLightDiameter + 8
        )
        let hasContentInSameRow = rendered.containsNonBackgroundPixels(in: sameRowRegion, background: .clear, tolerance: 0.03)

        let belowRowRegion = CGRect(
            x: 0,
            y: OrbitMetrics.sidebarTopRowHeight + 6,
            width: width,
            height: renderHeight - OrbitMetrics.sidebarTopRowHeight - 6
        )
        let hasContentBelowRow = rendered.containsNonBackgroundPixels(in: belowRowRegion, background: .clear, tolerance: 0.03)

        if !hasContentInSameRow || hasContentBelowRow {
            rendered.writeDiagnosticPNG(named: "D9-sidebarTopRow-FAILED")
        }

        XCTAssertTrue(
            hasContentInSameRow,
            "refs/DEFECTS.md D9 / refs/ARC_VISUAL_REFERENCE.md §1: expected the sidebar toggle " +
            "icon to render inside \(sameRowRegion) — the same horizontal band as the " +
            "traffic-light reservation (measured toggle x=96, same y as traffic lights at " +
            "x=50/64/78). Found nothing there. See the diagnostic PNG path RenderHarness " +
            "printed to the console."
        )
        XCTAssertFalse(
            hasContentBelowRow,
            "refs/ARC_PANE_CHROME.md: SidebarTopRow must be exactly one row — the traffic-light " +
            "reservation and the toggle, nothing else. Nav controls and the URL field belong in " +
            "the per-pane header (ToolbarView), never here. Found drawn pixels below " +
            "OrbitMetrics.sidebarTopRowHeight at \(belowRowRegion). See the diagnostic PNG path " +
            "RenderHarness printed to the console."
        )
    }

    // MARK: - D5: tab rows show the page title, not the URL

    func test_D5_tabDisplayTitle_prefersPageTitleOverHost() {
        var tab = Tab(spaceID: SpaceID(), url: URL(string: "https://www.google.com")!)
        XCTAssertEqual(tab.displayTitle, "www.google.com", "With no title set yet, displayTitle must fall back to the host.")

        tab.title = "Google"
        XCTAssertEqual(tab.displayTitle, "Google", "Once title is set, displayTitle must prefer it over the host.")
    }

    func test_D5_storeLevel_titleWrittenTheWayTheDelegateWritesItIsRetained() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-D5-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let store = BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
        let space = try XCTUnwrap(store.activeSpace)
        let tabID = store.openTab(url: URL(string: "https://www.google.com")!, in: space.id)

        XCTAssertEqual(store.tab(tabID)?.displayTitle, "www.google.com", "Before any title arrives, displayTitle correctly falls back to the host.")

        store.state.tabs[tabID]?.title = "Google"

        XCTAssertEqual(store.tab(tabID)?.title, "Google", "The delegate's title write must be retained by the store.")
        XCTAssertEqual(store.tab(tabID)?.displayTitle, "Google", "...and reflected by displayTitle, which is what every sidebar row actually reads.")
    }

    func test_D5_tabRowView_renderedContentRespondsToTitleChange() {
        let env = self.env
        let theme = SpaceTheme()
        let spaceID = SpaceID()
        let rowSize = CGSize(width: 200, height: OrbitMetrics.sidebarRowHeight)

        let hostOnlyTab = Tab(spaceID: spaceID, url: URL(string: "https://www.google.com")!)
        var titledTab = hostOnlyTab
        titledTab.title = "Google"

        // orbitScreenshotModeDragDisabled: ImageRenderer paints a corrupted block over an
        // NSViewRepresentable click catcher it can't flatten (see ToolbarHoverHighlightTests.swift's
        // own note) — TabRowView's full-row activation catcher is exactly that, and without this flag
        // its own block dominates boundingBoxOfContent regardless of the title text this test measures.
        let hostRender = render(
            TabRowView(tab: hostOnlyTab, theme: theme).environment(env).environment(\.orbitScreenshotModeDragDisabled, true),
            size: rowSize
        )
        let titledRender = render(
            TabRowView(tab: titledTab, theme: theme).environment(env).environment(\.orbitScreenshotModeDragDisabled, true),
            size: rowSize
        )

        guard let hostBox = hostRender.boundingBoxOfContent(tolerance: 0.03),
              let titledBox = titledRender.boundingBoxOfContent(tolerance: 0.03) else {
            hostRender.writeDiagnosticPNG(named: "D5-tabRowView-host-FAILED-empty")
            titledRender.writeDiagnosticPNG(named: "D5-tabRowView-titled-FAILED-empty")
            XCTFail("Expected TabRowView to draw a visible label in both the host-fallback and titled cases.")
            return
        }

        if hostBox.width <= titledBox.width {
            hostRender.writeDiagnosticPNG(named: "D5-tabRowView-host-FAILED")
            titledRender.writeDiagnosticPNG(named: "D5-tabRowView-titled-FAILED")
        }
        XCTAssertGreaterThan(
            hostBox.width, titledBox.width,
            "refs/DEFECTS.md D5: rendering the same tab with url=https://www.google.com should " +
            "produce a visibly narrower label once title=\"Google\" is set (host box width " +
            "\(hostBox.width)pt, titled box width \(titledBox.width)pt) — if these are equal, " +
            "TabRowView's label isn't responding to the title at all. See the diagnostic PNG " +
            "paths RenderHarness printed to the console."
        )
    }
}

// MARK: - Test-only helpers

@MainActor
private func containsColor(_ rendered: RenderedImage, matching target: RGBA, tolerance: Double) -> Bool {
    let width = Int(rendered.pointSize.width.rounded(.up))
    let height = Int(rendered.pointSize.height.rounded(.up))
    guard width > 0, height > 0 else { return false }
    for y in 0..<height {
        for x in 0..<width {
            if rendered.color(atX: x, y: y).isApproximately(target, tolerance: tolerance) {
                return true
            }
        }
    }
    return false
}
