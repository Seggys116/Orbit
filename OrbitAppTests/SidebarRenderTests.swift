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
        let rendered = render(
            TabRowView(tab: tab, theme: theme).environment(env).environment(\.orbitScreenshotModeDragDisabled, true),
            size: size
        )

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
        let rendered = render(
            TabRowView(tab: tab, theme: theme).environment(env).environment(\.orbitScreenshotModeDragDisabled, true),
            size: size
        )

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

// MARK: - New Tab page

@MainActor
final class NewTabPageTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private let profileID = UUID()

    override func setUp() {
        super.setUp()
        env.state = OrbitState()
    }

    private func entry(_ urlString: String, title: String = "", visits: Int = 1) -> HistoryEntry {
        HistoryEntry(url: URL(string: urlString)!, title: title, visitCount: visits, profileID: profileID)
    }

    private func favorite(_ urlString: String, title: String, emoji: String? = nil) -> Favorite {
        Favorite(url: URL(string: urlString)!, title: title, customIcon: emoji, customIconIsEmoji: emoji != nil)
    }

    // MARK: - Fixtures for the tab-level tests

    private func makeLiveSpace() -> SpaceID {
        let profileID = env.createDefaultProfileIfNeeded()
        let spaceID = env.createSpace(
            name: "Pages",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
        env.state.activeSpaceID = spaceID
        env._test_webContentsFactory = { _, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }
        return spaceID
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - One entry in the sidebar, not two

    func test_aNewTabPageTabIsNotListedInToday_whileANormalTabIs() {
        let spaceID = makeLiveSpace()
        let normal = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID)
        let page = env.openTab(url: NewTabPageModel.url, in: spaceID)

        XCTAssertTrue(env.todayTabs(in: spaceID).map(\.id).contains(page), "Precondition: the page is a real Today tab in the store.")
        XCTAssertEqual(
            env.listedTodayTabs(in: spaceID).map(\.id), [normal],
            "A blank New Tab page must not get its own row next to the '+ New Tab' row."
        )
    }

    func test_aNewTabPageInASplitStaysListed_becauseItsPaneRowIsTheOnlyHandleOnIt() {
        let spaceID = makeLiveSpace()
        let anchor = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID)
        let blank = env.openTab(url: NewTabPageModel.url, in: spaceID, section: .today, activate: false)
        env.createSplit(existingTabID: anchor, newTabID: blank, edge: .right)

        XCTAssertTrue(env.listedTodayTabs(in: spaceID).map(\.id).contains(blank))
    }

    func test_aNewTabPageThatHasNavigatedBecomesAnOrdinaryListedTab() throws {
        let spaceID = makeLiveSpace()
        let page = env.openTab(url: NewTabPageModel.url, in: spaceID)
        XCTAssertTrue(env.listedTodayTabs(in: spaceID).isEmpty)

        env.loadInTab(page, url: URL(string: "https://example.com/next")!)

        XCTAssertEqual(env.listedTodayTabs(in: spaceID).map(\.id), [page])
        XCTAssertFalse(env.isNewTabPageActive(in: spaceID), "Once the page navigates the New Tab row returns to its normal state.")
    }

    func test_theNewTabRowIsActiveExactlyWhileTheActiveTabIsABlankPage() {
        let spaceID = makeLiveSpace()
        let normal = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID)
        XCTAssertFalse(env.isNewTabPageActive(in: spaceID))

        SidebarNewTabRowAction.perform(in: env)
        let page = env.activeTabID
        XCTAssertNotEqual(page, normal)
        XCTAssertTrue(env.isNewTabPageActive(in: spaceID))
        XCTAssertFalse(env.isCommandBarPresented, "The '+ New Tab' row opens the page, not the Command Bar.")

        env.activateTab(normal)
        XCTAssertFalse(env.isNewTabPageActive(in: spaceID))
    }

    func test_theNewTabRowDoesNotStackASecondPageWhileOneIsAlreadyOpen() {
        let spaceID = makeLiveSpace()
        SidebarNewTabRowAction.perform(in: env)
        let count = env.state.tabs.count
        SidebarNewTabRowAction.perform(in: env)
        XCTAssertEqual(env.state.tabs.count, count)
        XCTAssertTrue(env.isNewTabPageActive(in: spaceID))
    }

    func test_leavingAnUntouchedNewTabPageDiscardsIt_withNoArchiveEntry() throws {
        let spaceID = makeLiveSpace()
        let normal = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID)
        SidebarNewTabRowAction.perform(in: env)
        let page = try XCTUnwrap(env.activeTabID)

        env.activateTab(normal)

        XCTAssertNil(env.tab(page), "An unlisted page that is no longer active has no row, so it must not linger.")
        XCTAssertTrue(env.archivedTabs(in: spaceID).isEmpty)
    }

    func test_closingTheNewTabPageWithCommandW_removesItAndReturnsToTheTabBefore() throws {
        let spaceID = makeLiveSpace()
        let normal = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID)
        SidebarNewTabRowAction.perform(in: env)
        let page = try XCTUnwrap(env.activeTabID)

        _ = env.perform(.closeTabOrWindow)

        XCTAssertNil(env.tab(page))
        XCTAssertEqual(env.activeTabID, normal)
        XCTAssertFalse(env.isNewTabPageActive(in: spaceID))
    }

    func test_aSavedNewTabPageThatIsNoLongerActiveIsSweptWhenTheSidebarAppears() {
        let spaceID = makeLiveSpace()
        let normal = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID)
        let stray = env.openTab(url: NewTabPageModel.url, in: spaceID, section: .today, activate: false)
        XCTAssertNotNil(env.tab(stray))

        env.sweepAbandonedNewTabPages(in: spaceID)

        XCTAssertNil(env.tab(stray))
        XCTAssertEqual(env.activeTabID, normal)
    }

    func test_steppingToThePreviousTabFromTheNewTabPage_leavesAndClosesIt() throws {
        let spaceID = makeLiveSpace()
        let first = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID)
        SidebarNewTabRowAction.perform(in: env)
        let page = try XCTUnwrap(env.activeTabID)

        _ = env.perform(.previousTab)

        XCTAssertEqual(env.activeTabID, first)
        XCTAssertNil(env.tab(page), "Stepping away from an untouched page closes it, as clicking away does.")
    }

    // MARK: - Command T is the Command Bar and nothing else

    func test_commandT_createsNoTabBeforeAResultIsCommitted() throws {
        let spaceID = makeLiveSpace()
        env.openTab(url: URL(string: "https://example.com/")!, in: spaceID)
        env.isCommandBarPresented = false
        let before = env.state.tabs.count

        _ = env.perform(.newTabCommandBar)

        XCTAssertTrue(env.isCommandBarPresented)
        XCTAssertEqual(env.commandBarMode, .newTab)
        XCTAssertEqual(env.state.tabs.count, before, "Cmd+T must not create a blank tab up front.")

        XCTAssertTrue(CommandBarActivation.commitTypedText("example.org", siteEngine: nil, in: env))
        XCTAssertEqual(env.state.tabs.count, before + 1, "The tab appears only when the user commits.")
    }

    func test_commandT_onAnOpenNewTabPage_fillsThatPageInPlace() throws {
        let spaceID = makeLiveSpace()
        SidebarNewTabRowAction.perform(in: env)
        let page = try XCTUnwrap(env.activeTabID)
        env.isCommandBarPresented = false

        _ = env.perform(.newTabCommandBar)
        XCTAssertEqual(env.commandBarMode, .blankPane(page))

        let count = env.state.tabs.count
        XCTAssertTrue(CommandBarActivation.commitTypedText("example.org", siteEngine: nil, in: env))
        XCTAssertEqual(env.state.tabs.count, count)
        XCTAssertEqual(env.tab(page)?.url.host(), "example.org")
        XCTAssertEqual(env.listedTodayTabs(in: spaceID).count, 1)
    }

    // MARK: - The page is Recently visited and a Command Bar field, nothing else

    func test_thePageHasNoSitesSectionAndNoLogo() throws {
        let source = try sourceText("Orbit/UI/Content/NewTabPageView.swift")
        for removed in ["OrbitGlyph", "NewTabSite", "sitesRow", "func sites(", "Image(\"", "OrbitSegmentedControl"] {
            XCTAssertFalse(source.contains(removed), "NewTabPageView.swift still contains `\(removed)`.")
        }
        XCTAssertEqual(source.components(separatedBy: "Text(\"").count - 1, 1, "Recently visited is the only labelled section.")
        XCTAssertTrue(source.contains("Recently visited"))
        XCTAssertTrue(source.contains("CommandBarView("), "The page's field is the Command Bar, embedded.")
    }

    func test_theEmbeddedBarTargetsItsOwnPane() {
        let pane = UUID()
        XCTAssertEqual(CommandBarView.Embedding(paneTabID: pane, seedQuery: nil, onInputChange: { _ in }).mode, .blankPane(pane))
        XCTAssertEqual(CommandBarView.Embedding(paneTabID: nil, seedQuery: nil, onInputChange: { _ in }).mode, .newTab)
    }

    private final class ResultsBox {
        var latest: [String: [CommandResult]] = [:]
    }

    private func host(_ view: some View, size: CGSize = CGSize(width: 1200, height: 800), appearance: NSAppearance.Name = .aqua) async throws -> (NSWindow, NSHostingView<AnyView>) {
        let hosting = NSHostingView(
            rootView: AnyView(
                view
                    .environment(env)
                    .environment(\.orbitScreenshotModeDragDisabled, true)
            )
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFront(nil)
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    func test_typingOnThePageYieldsTheSameRankedRowsAsTheCommandBar() async throws {
        let (state, space) = makeSpaceState(incognito: false)
        env.state = state
        env._test_webContentsFactory = { _, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }
        await seedHistory(in: space)
        env.openTab(url: URL(string: "https://history-open.example.org/")!, in: space.id)
        let pageID = env.openTab(url: NewTabPageModel.url, in: space.id)
        let page = try XCTUnwrap(env.tab(pageID))

        let box = ResultsBox()
        CommandBarView.testResultsObserver = { text, rows in box.latest[text] = rows }
        defer { CommandBarView.testResultsObserver = nil }

        let query = "history"
        let (window, _) = try await host(NewTabPageView(tab: page, initialQuery: query))
        defer { window.close() }

        let expected = CommandBarEngine.results(
            query: query,
            mode: .blankPane(pageID),
            env: env,
            suggestions: [],
            searchEngine: env.searchEngine,
            siteSearch: env.siteSearchStore.state(active: nil),
            isChatGPTCommandBarAvailable: ChatGPTCommandBar.isAvailable(
                featureEnabled: AssistSettings.isChatGPTCommandBarEnabled,
                isIncognito: env.activeSpace.map { env.isIncognito($0) } ?? true
            ),
            isInstantLinksEnabled: AssistSettings.isInstantLinksEnabled
        )
        let shown = try XCTUnwrap(box.latest[query], "The page's field never ran the Command Bar's ranking for \"\(query)\".")

        XCTAssertGreaterThan(expected.count, 1)
        XCTAssertEqual(shown.prefix(5).map(\.id), expected.prefix(5).map(\.id))
    }

    func test_committingFromThePageLoadsTheDestinationInThatTab() throws {
        let spaceID = makeLiveSpace()
        SidebarNewTabRowAction.perform(in: env)
        let pageID = try XCTUnwrap(env.activeTabID)
        let count = env.state.tabs.count
        let mode = CommandBarView.Embedding(paneTabID: pageID, seedQuery: nil, onInputChange: { _ in }).mode

        let rows = CommandBarEngine.results(
            query: "swift concurrency", mode: mode, env: env, suggestions: [],
            searchEngine: env.searchEngine, siteSearch: env.siteSearchStore.state(active: nil)
        )
        let top = try XCTUnwrap(rows.first)
        XCTAssertTrue(CommandBarActivation.activate(top, in: env, mode: mode))

        XCTAssertEqual(env.state.tabs.count, count, "Committing fills this tab in; it opens no other.")
        XCTAssertEqual(env.tab(pageID)?.url, env.searchEngine.searchURL(for: "swift concurrency"))
        XCTAssertEqual(env.activeTabID, pageID)
        XCTAssertEqual(env.listedTodayTabs(in: spaceID).map(\.id), [pageID], "Now an ordinary tab, so it is listed.")
    }

    // MARK: - Recents

    func test_recents_keepNewestFirstDropDuplicatesAndNonWebAndStopAtSix() {
        var entries = [entry("about:blank")]
        entries.append(entry("https://r.example.com/p0"))
        entries.append(entry("https://r.example.com/p1"))
        entries.append(entry("https://r.example.com/p1", title: "again"))
        for index in 2..<10 { entries.append(entry("https://r.example.com/p\(index)")) }

        let recents = NewTabPageModel.recents(from: entries)

        XCTAssertEqual(recents.map(\.url.absoluteString), (0..<6).map { "https://r.example.com/p\($0)" })
    }

    func test_recents_returnEverythingWhenThereAreFewerThanTheCap() {
        let recents = NewTabPageModel.recents(from: [entry("https://one.example.com/"), entry("https://two.example.com/")])
        XCTAssertEqual(recents.map { $0.url.host() }, ["one.example.com", "two.example.com"])
    }

    func test_displayHost_stripsWwwAndShowsNoSchemeOrPath() {
        XCTAssertEqual(
            NewTabPageModel.displayHost(URL(string: "https://www.example.com/path/to?x=1#frag")!),
            "example.com"
        )
    }

    // MARK: - Tab title and icon

    func test_displayTitle_isNewTabForTheNewTabPageWithNoTitle() {
        let tab = Tab(spaceID: UUID(), url: URL(string: "orbit://new-tab")!)
        XCTAssertEqual(tab.displayTitle, "New Tab")
    }

    func test_displayTitle_prefersARealTitleOverNewTab() {
        let titled = Tab(spaceID: UUID(), url: URL(string: "orbit://new-tab")!, title: "Docs")
        XCTAssertEqual(titled.displayTitle, "Docs")
        let renamed = Tab(spaceID: UUID(), url: URL(string: "orbit://new-tab")!, title: "Docs", customTitle: "Mine")
        XCTAssertEqual(renamed.displayTitle, "Mine")
    }

    func test_displayTitle_otherOrbitPagesAndWebPagesStillFallBackToTheirHost() {
        XCTAssertEqual(Tab(spaceID: UUID(), url: URL(string: "orbit://settings")!).displayTitle, "settings")
        XCTAssertEqual(Tab(spaceID: UUID(), url: URL(string: "https://example.com/a")!).displayTitle, "example.com")
    }

    func test_faviconCache_returnsTheDrawnNewTabIconNotALetterTile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NewTabPageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FaviconCache(diskDirectory: directory)

        XCTAssertEqual(FaviconCache.newTabHost, "new-tab")
        let icon = try XCTUnwrap(cache.cachedImage(forHost: "new-tab"), "an empty cache must still answer for the new-tab host")
        XCTAssertNotNil(cache.cachedImage(forHost: "NEW-TAB"), "host matching is case-insensitive")
        XCTAssertNil(cache.cachedImage(forHost: "never-seen.example.com"), "ordinary hosts are not answered from nothing")

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(icon.tiffRepresentation)))
        let sample = try XCTUnwrap(
            bitmap.colorAt(x: bitmap.pixelsWide / 8, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        )
        XCTAssertEqual(sample.redComponent, sample.greenComponent, accuracy: 0.02, "the drawn icon is neutral grey")
        XCTAssertEqual(sample.greenComponent, sample.blueComponent, accuracy: 0.02, "the drawn icon is neutral grey")
        XCTAssertLessThan(sample.alphaComponent, 0.6, "the drawn icon is a translucent tile, unlike the opaque letter tile")

        let letter = FaviconCache.fallbackIcon(forHost: "new-tab")
        XCTAssertNotEqual(icon.tiffRepresentation, letter.tiffRepresentation)
    }

    // MARK: - Rendering

    private func makeSpaceState(incognito: Bool) -> (OrbitState, Space) {
        let profile = incognito
            ? Profile(id: profileID, name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
            : Profile(id: profileID, name: "Personal")
        let theme = SpaceTheme(
            style: .solid,
            colors: [ThemeColor(red: 0.5, green: 0.5, blue: 0.5)],
            grain: 0,
            followsSystemAppearance: true,
            prefersDarkContent: false
        )
        let favorites = (0..<4).map { favorite("https://fav\($0).example.com/", title: "Favorite \($0)") }
        let space = Space(
            name: incognito ? "Incognito" : "Personal",
            theme: theme,
            profileID: profile.id,
            favorites: favorites,
            isEphemeral: incognito
        )
        var state = OrbitState()
        state.profiles = [profile]
        state.spaces = [space]
        state.activeSpaceID = space.id
        return (state, space)
    }

    private func seedHistory(in space: Space) async {
        for index in 0..<8 {
            await env.recordVisitReportingItem(
                url: URL(string: "https://history\(index).example.org/page")!,
                title: "History Page \(index)",
                profileID: space.profileID,
                spaceID: space.id
            )
        }
    }

    private func renderPage(incognito: Bool, appearance: NSAppearance.Name, query: String? = nil) async throws -> RenderedImage {
        let (state, _) = makeSpaceState(incognito: incognito)
        env.state = state
        let size = CGSize(width: 1200, height: 800)
        let host = NSHostingView(
            rootView: NewTabPageView(tab: nil, initialQuery: query)
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true)
        )
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return RenderedImage(bitmap: rep, pointSize: size, scale: CGFloat(rep.pixelsWide) / size.width)
    }

    private var outputDirectory: URL {
        if let configured = ProcessInfo.processInfo.environment["ORBIT_RENDER_OUT"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NewTabPageTests-render", isDirectory: true)
    }

    private func horizontalExtent(of image: RenderedImage, rows: Range<Int>) -> (min: Int, max: Int)? {
        let background = image.color(atX: 2, y: 2)
        var lowest = Int.max
        var highest = Int.min
        let width = Int(image.pointSize.width)
        for y in rows {
            for x in 0..<width where !image.color(atX: x, y: y).isApproximately(background, tolerance: 0.04) {
                lowest = min(lowest, x)
                highest = max(highest, x)
            }
        }
        return lowest == Int.max ? nil : (lowest, highest)
    }

    private func lowestContentRow(of image: RenderedImage) -> Int? {
        let background = image.color(atX: 2, y: 2)
        let width = Int(image.pointSize.width)
        for y in stride(from: Int(image.pointSize.height) - 1, through: 0, by: -1) {
            for x in stride(from: 0, to: width, by: 2) where !image.color(atX: x, y: y).isApproximately(background, tolerance: 0.04) {
                return y
            }
        }
        return nil
    }

    func test_render_newTabPageIsPaintedAndCentredInLightAndDark() async throws {
        let (state, space) = makeSpaceState(incognito: false)
        env.state = state
        await seedHistory(in: space)
        XCTAssertFalse(env.historyResults(matching: "", limit: 300).isEmpty, "seeded visits must reach the history cache")

        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var averages: [Double] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let image = try await renderPage(incognito: false, appearance: appearance)
            let url = directory.appendingPathComponent("new-tab-\(name)-1200x800.png")
            XCTAssertTrue(image.writePNG(to: url), "could not write \(url.path)")
            print("NewTabPageTests: wrote \(url.path)")

            let wholePage = image.averageColor(in: CGRect(origin: .zero, size: image.pointSize))
            averages.append((wholePage.r + wholePage.g + wholePage.b) / 3)

            let background = image.color(atX: 2, y: 2)
            var differing = 0
            let sampleStep = 4
            var total = 0
            for y in stride(from: 0, to: 800, by: sampleStep) {
                for x in stride(from: 0, to: 1200, by: sampleStep) {
                    total += 1
                    if !image.color(atX: x, y: y).isApproximately(background, tolerance: 0.04) { differing += 1 }
                }
            }
            XCTAssertGreaterThan(Double(differing) / Double(total), 0.01, "\(name): the page rendered as a blank field")

            let extent = try XCTUnwrap(horizontalExtent(of: image, rows: 0..<400), "\(name): nothing drawn in the upper half")
            let width = Double(image.pointSize.width)
            let widest = Double(extent.max - extent.min)
            XCTAssertGreaterThan(widest, width * 0.4, "\(name): the search field must span a large part of the page")
            let centre = Double(extent.min + extent.max) / 2
            XCTAssertEqual(centre, width / 2, accuracy: width * 0.03, "\(name): the search field is off-centre")
        }
        XCTAssertGreaterThan(abs(averages[0] - averages[1]), 0.1, "light and dark renders are the same page")
    }

    func test_render_aTypedQueryReplacesRecentsWithTheSuggestionsListInLightAndDark() async throws {
        let (state, space) = makeSpaceState(incognito: false)
        env.state = state
        await seedHistory(in: space)

        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let idle = try await renderPage(incognito: false, appearance: appearance)
            let typed = try await renderPage(incognito: false, appearance: appearance, query: "history")
            let url = directory.appendingPathComponent("new-tab-query-\(name)-1200x800.png")
            XCTAssertTrue(typed.writePNG(to: url), "could not write \(url.path)")
            print("NewTabPageTests: wrote \(url.path)")

            let belowField = 224 + 54 + 8
            var differing = 0
            var total = 0
            for y in stride(from: belowField, to: 790, by: 4) {
                for x in stride(from: 0, to: 1200, by: 4) {
                    total += 1
                    if !typed.color(atX: x, y: y).isApproximately(idle.color(atX: x, y: y), tolerance: 0.04) { differing += 1 }
                }
            }
            XCTAssertGreaterThan(
                Double(differing) / Double(total), 0.01,
                "\(name): typing a query must put the suggestions list where Recently visited was"
            )
        }
    }

    func test_render_incognitoHidesTheHistoryBackedRecentCards() async throws {
        let (state, space) = makeSpaceState(incognito: false)
        env.state = state
        await seedHistory(in: space)
        XCTAssertFalse(env.historyResults(matching: "", limit: 300).isEmpty, "seeded visits must reach the history cache")

        let normal = try await renderPage(incognito: false, appearance: .aqua)
        let incognito = try await renderPage(incognito: true, appearance: .aqua)

        let normalBottom = try XCTUnwrap(lowestContentRow(of: normal))
        let incognitoBottom = try XCTUnwrap(lowestContentRow(of: incognito))
        XCTAssertGreaterThan(
            normalBottom - incognitoBottom, 40,
            "Incognito must drop the Recently visited section: the content block should end clearly higher (normal \(normalBottom), incognito \(incognitoBottom))."
        )
    }
}

@MainActor
final class DownloadsPanelHostedTests: XCTestCase {

    private static let darkTheme = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.16, green: 0.14, blue: 0.22)], followsSystemAppearance: false)
    private static let lightTheme = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.93, green: 0.91, blue: 0.86)], followsSystemAppearance: false)

    private func makeEnvironment() -> (AppEnvironment, Space) {
        let env = AppEnvironment.demo
        env.state = OrbitState.demo
        env.isSidebarVisible = true
        env.isSidebarHoverRevealed = false
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        for index in 0..<6 {
            let item = env.downloadStore.beginDownload(
                sourceURL: URL(string: "https://example.com/file\(index)")!,
                destinationURL: directory.appendingPathComponent("orbit-panel-file\(index).bin"),
                suggestedFileName: "file\(index).bin",
                totalBytes: 1_000
            )
            if index == 0 {
                env.downloadStore.updateProgress(id: item.id, progress: DownloadProgress(receivedBytes: 400, totalBytes: 1_000, state: .inProgress))
            } else {
                if index <= 2 {
                    try? Data(repeating: 0x2A, count: 1_000).write(to: item.destinationURL)
                }
                env.downloadStore.updateProgress(id: item.id, progress: DownloadProgress(receivedBytes: 1_000, totalBytes: 1_000, state: .completed))
            }
        }
        var space = env.state.spaces.first!
        space.theme = Self.darkTheme
        return (env, space)
    }

    private func capture(env: AppEnvironment, space: Space, size: CGSize, forcesPreview: Bool) async throws -> RenderedImage {
        try await captureHosted(
            SidebarView(space: space)
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true)
                .environment(\.orbitForcesDownloadsPreview, forcesPreview),
            size: size
        )
    }

    private func captureHosted<V: View>(_ view: V, size: CGSize) async throws -> RenderedImage {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return RenderedImage(bitmap: rep, pointSize: size, scale: CGFloat(rep.pixelsWide) / size.width)
    }

    private func expectedSurface(of theme: SpaceTheme) async throws -> RGBA {
        let swatchSize = CGSize(width: 40, height: 40)
        let swatch = try await captureHosted(
            Color(theme.primary.nsColor)
                .overlay(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity))
                .frame(width: swatchSize.width, height: swatchSize.height),
            size: swatchSize
        )
        return swatch.color(atX: 20, y: 20)
    }

    private func surfaceBounds(in image: RenderedImage, surface: RGBA) -> CGRect? {
        let width = Int(image.pointSize.width)
        let height = Int(image.pointSize.height)
        var rowCounts = [Int](repeating: 0, count: height)
        var columnCounts = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = image.color(atX: x, y: y)
                if pixel.a > 0.9, pixel.isApproximately(surface, tolerance: 0.01) {
                    rowCounts[y] += 1
                    columnCounts[x] += 1
                }
            }
        }
        let rows = rowCounts.indices.filter { rowCounts[$0] >= 40 }
        let columns = columnCounts.indices.filter { columnCounts[$0] >= 40 }
        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    func test_downloadsPanel_isNeitherClippedNorCoveredInTheRealSidebar() async throws {
        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("DownloadsPanelHostedTests", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var references: [String: RGBA] = [:]
        defer {
            if let dark = references["dark"], let light = references["light"] {
                XCTAssertFalse(dark.isApproximately(light, tolerance: 0.05), "The dark and light Spaces paint the same panel colour \(dark); it is not following the Space's theme.")
            }
        }

        for (themeName, theme) in [("dark", Self.darkTheme), ("light", Self.lightTheme)] {
            for size in [CGSize(width: 220, height: 420), CGSize(width: 320, height: 420), CGSize(width: 220, height: 900), CGSize(width: 320, height: 900)] {
                let label = "\(themeName) \(Int(size.width))x\(Int(size.height))"
                let (env, baseSpace) = makeEnvironment()
                var space = baseSpace
                space.theme = theme

                let image = try await capture(env: env, space: space, size: size, forcesPreview: true)
                let url = outputDirectory.appendingPathComponent("panel-\(themeName)-\(Int(size.width))x\(Int(size.height)).png")
                XCTAssertTrue(image.writePNG(to: url), "[DOWNLOADS-PANEL] could not write \(url.path)")
                print("[DOWNLOADS-PANEL] \(label): \(url.path)")

                let swatch = try await expectedSurface(of: theme)
                let placement = DownloadsPreviewLayout.placement(containerWidth: size.width, anchorMinX: 0)
                let barTop = size.height - OrbitMetrics.sidebarInterSectionGap - OrbitMetrics.sidebarBottomBarHeight
                let referenceY = Int(barTop - DownloadsPreviewLayout.gap) - 3
                let surface = image.color(atX: Int(placement.originX + placement.width / 2), y: referenceY)
                print("[DOWNLOADS-PANEL] \(label): reference \(surface) at y \(referenceY), theme swatch \(swatch)")
                XCTAssertTrue(
                    surface.isApproximately(swatch, tolerance: 0.03),
                    "\(label): the panel interior \(surface) is not the Space's themed surface \(swatch)."
                )
                references[themeName] = surface
                let panel = try XCTUnwrap(
                    surfaceBounds(in: image, surface: surface),
                    "\(label): no themed panel surface was painted by the real sidebar (hidden behind a sibling, or clipped away)."
                )

                let inset = DownloadsPreviewLayout.edgeInset
                XCTAssertGreaterThanOrEqual(panel.minX, inset - 2, "\(label): panel is cut at the sidebar's left edge, \(panel).")
                XCTAssertLessThanOrEqual(panel.maxX, size.width - inset + 2, "\(label): panel is cut at the sidebar's right edge, \(panel).")
                XCTAssertGreaterThanOrEqual(panel.minY, inset - 2, "\(label): panel is cut at the sidebar's top edge, \(panel).")
                XCTAssertGreaterThan(
                    image.color(atX: Int(panel.midX), y: Int(panel.minY) - 1).a, 0.5,
                    "\(label): nothing is painted above the panel's surface, so its border is missing or cut."
                )

                let corner = Int(DownloadsPreviewPanel.cornerRadius)
                let flatLeft = Int(placement.originX) + 3
                let flatRight = Int(placement.originX + placement.width) - 4
                let flatTop = Int(panel.minY) + 3
                let flatBottom = Int(panel.maxY) - 4
                let verticalRange = (flatTop + corner)..<(flatBottom - corner)
                let horizontalRange = (flatLeft + corner)..<(flatRight - corner)
                XCTAssertGreaterThan(verticalRange.count * 2, Int(panel.height), "\(label): the sampled gutter column is too short to prove anything, \(panel).")
                XCTAssertGreaterThan(horizontalRange.count, 40, "\(label): the sampled top band is too short to prove anything, \(panel).")

                let strips: [(String, [RGBA])] = [
                    ("left gutter", verticalRange.map { image.color(atX: flatLeft, y: $0) }),
                    ("right gutter", verticalRange.map { image.color(atX: flatRight, y: $0) }),
                    ("top padding", horizontalRange.map { image.color(atX: $0, y: flatTop) }),
                    ("bottom padding", horizontalRange.map { image.color(atX: $0, y: flatBottom) }),
                ]
                for (name, pixels) in strips {
                    let bad = pixels.enumerated().filter { !$0.element.isApproximately(surface, tolerance: 0.05) }
                    if !bad.isEmpty {
                        let first = bad[0]
                        let last = bad[bad.count - 1]
                        print("[DOWNLOADS-PANEL] \(label) \(name): \(bad.count)/\(pixels.count) off surface \(surface) (panel \(panel), left x \(flatLeft), right x \(flatRight), top y \(flatTop), bottom y \(flatBottom)); first #\(first.offset) \(first.element), last #\(last.offset) \(last.element)")
                        image.writeDiagnosticPNG(named: "DOWNLOADS-PANEL-\(label)-\(name)")
                    }
                    XCTAssertEqual(bad.count, 0, "\(label): \(bad.count) of \(pixels.count) pixels in the panel's \(name) are not the panel colour, so something draws over it.")
                }

                if size.height == 420 {
                    let baseline = try await capture(env: env, space: space, size: size, forcesPreview: false)
                    XCTAssertTrue(
                        baseline.containsNonBackgroundPixels(in: panel.insetBy(dx: 4, dy: 4), background: .clear, tolerance: 0.2),
                        "\(label): the sidebar draws nothing where the panel sits, so this case does not prove the panel is on top of the tab list."
                    )
                }
            }
        }
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

// Mounted as production mounts the Space title row, so the hit test is AppKit's own, click recovery included.
@MainActor
final class SpaceTitleRowWindowDragTests: XCTestCase {

    private static let size = CGSize(width: 280, height: 700)
    private static let spaceName = "Home"

    private var env: AppEnvironment!
    private var window: NSWindow?
    private var container: OrbitWindowContentView?

    override func setUp() {
        super.setUp()
        env = AppEnvironment.demo
        env.isSidebarVisible = true
        env.isSidebarHoverRevealed = false
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        container = nil
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
        }
    }

    private func mount() throws -> NSWindow {
        let space = try XCTUnwrap(env.activeSpace, "AppEnvironment.demo has no active Space to title the sidebar with.")
        env.renameSpace(space.id, to: Self.spaceName)
        XCTAssertFalse(env.isTornOffWindow(for: space), "Harness error: a torn-off window has no SpaceTitleRow.")

        let window = UnconstrainedTestWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        let host = NSHostingView(rootView: SidebarView()
            .orbitRightClickBackdropMenu { [.item(OrbitContextMenuItem(title: Self.backdropTitle) {})] }
            .environment(env))
        host.safeAreaRegions = []
        host.sizingOptions = []
        let container = OrbitWindowContentView(frame: NSRect(origin: .zero, size: Self.size))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.container = container
        pump(0.8)
        return window
    }

    private static var leading: CGFloat {
        OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset
    }

    private struct TitleRowGeometry {
        var row: NSRect
        var name: NSRect
    }

    private struct Probe {
        var label: String
        var point: NSPoint
        var isName: Bool
    }

    private func dragSurfaces(in root: NSView) -> [SidebarChromeDragView] {
        var found: [SidebarChromeDragView] = []
        if let surface = root as? SidebarChromeDragView { found.append(surface) }
        for subview in root.subviews { found += dragSurfaces(in: subview) }
        return found
    }

    private func windowFrame(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    private func titleRowGeometry(in container: NSView) throws -> TitleRowGeometry {
        let surfaces = dragSurfaces(in: container)
        let nameSurface = try XCTUnwrap(
            surfaces.first { $0.doubleClickAction != nil },
            "No drag surface over the Space name. Surfaces: \(surfaces.map { windowFrame($0) })"
        )
        let name = windowFrame(nameSurface)
        let row = try XCTUnwrap(
            surfaces
                .filter { $0.doubleClickAction == nil }
                .map { windowFrame($0) }
                .filter { $0.contains(NSPoint(x: name.midX, y: name.midY)) && abs($0.height - OrbitMetrics.sidebarSpaceNameRowHeight) < 1 }
                .min { $0.width * $0.height < $1.width * $1.height },
            "No row-sized drag surface behind the Space name at \(name). Surfaces: \(surfaces.map { windowFrame($0) })"
        )
        return TitleRowGeometry(row: row, name: name)
    }

    private func probes(_ geometry: TitleRowGeometry) -> [Probe] {
        let midY = geometry.row.midY
        return [
            Probe(label: "the Space icon", point: NSPoint(x: geometry.name.minX - OrbitMetrics.sidebarRowContentSpacing - OrbitMetrics.sidebarSpaceIconSize / 2, y: midY), isName: false),
            Probe(label: "the Space name", point: NSPoint(x: geometry.name.midX, y: geometry.name.midY), isName: true),
            Probe(label: "the empty row right of the name", point: NSPoint(x: (geometry.name.maxX + geometry.row.maxX) / 2, y: midY), isName: false),
        ]
    }

    private func firstFavoriteTileCentre(below geometry: TitleRowGeometry) -> NSPoint {
        let metrics = FavoritesGridMetrics(availableWidth: geometry.row.width - 2 * Self.leading)
        return NSPoint(
            x: geometry.row.minX + Self.leading + metrics.tileWidth / 2,
            y: geometry.row.minY - OrbitMetrics.favoriteGridVerticalPadding - metrics.tileHeight / 2
        )
    }

    private static let backdropTitle = "New Space…"

    private func describe(_ anchor: OrbitRightClickAnchorView?, at point: NSPoint) -> String {
        guard let anchor else { return "none" }
        return "\(windowFrame(anchor)) bounds \(anchor.bounds) visibleRect \(anchor.visibleRect) point-in-anchor \(anchor.convert(point, from: nil)) flipped=\(anchor.isFlipped) in \(chain(from: anchor.superview))"
    }

    private func anchorReport(_ container: NSView) -> String {
        rightClickAnchors(in: container)
            .filter { $0.entriesProvider != nil }
            .map { "\(titles($0.entriesProvider?(.zero) ?? []).first ?? "-")@\(windowFrame($0))\($0.isBackdrop ? "[backdrop]" : "")" }
            .joined(separator: ", ")
    }

    private func hit(_ window: NSWindow, at point: NSPoint) -> NSView? {
        window.contentView?.superview?.hitTest(point)
    }

    private func chain(from view: NSView?) -> String {
        var names: [String] = []
        var node = view
        while let current = node {
            names.append("\(type(of: current))[canMoveWindow=\(current.mouseDownCanMoveWindow)]")
            node = current.superview
        }
        return names.isEmpty ? "nil" : names.joined(separator: " < ")
    }

    private func mouseDown(_ window: NSWindow, at point: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    private func rightClickAnchors(in root: NSView) -> [OrbitRightClickAnchorView] {
        var found: [OrbitRightClickAnchorView] = []
        if let anchor = root as? OrbitRightClickAnchorView { found.append(anchor) }
        for subview in root.subviews { found += rightClickAnchors(in: subview) }
        return found
    }

    private func titles(_ entries: [OrbitContextMenuEntry]) -> [String] {
        entries.compactMap { if case .item(let item) = $0 { return item.title } else { return nil } }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_everyPointOfTheSpaceTitleRowStartsAWindowDrag

    func test_everyPointOfTheSpaceTitleRowStartsAWindowDrag() throws {
        let window = try mount()
        let container = try XCTUnwrap(container)
        for probe in probes(try titleRowGeometry(in: container)) {
            let resolved = hit(window, at: probe.point)
            XCTAssertNil(
                OrbitWindowContentView.topmostClickCatcher(in: container, atPointInWindow: probe.point),
                "Click recovery hands a click on \(probe.label) to a catcher underneath. Hit chain: \(chain(from: resolved))"
            )
            guard let surface = resolved as? SidebarChromeDragView else {
                XCTFail("A click on \(probe.label) at \(probe.point) resolves to \(chain(from: resolved)), not a SidebarChromeDragView, so it never moves the window.")
                continue
            }
            let single = surface.mouseDownAction(for: try mouseDown(window, at: probe.point, clickCount: 1))
            guard case .windowDrag = single else {
                XCTFail("A press on \(probe.label) does not start a window drag; the drag surface resolves it to \(single).")
                continue
            }
            let double = surface.mouseDownAction(for: try mouseDown(window, at: probe.point, clickCount: 2))
            if probe.isName {
                guard case .doubleClickAction = double else {
                    XCTFail("A double-click on the Space name no longer renames it; it resolves to \(double).")
                    continue
                }
            } else {
                guard case .titleBarDoubleClick = double else {
                    XCTFail("A double-click on \(probe.label) no longer runs the title-bar double-click (zoom); it resolves to \(double).")
                    continue
                }
            }
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_doubleClickingTheSpaceNameOpensItsRenameField

    func test_doubleClickingTheSpaceNameOpensItsRenameField() throws {
        let window = try mount()
        let point = probes(try titleRowGeometry(in: try XCTUnwrap(container)))[1].point
        let surface = try XCTUnwrap(hit(window, at: point) as? SidebarChromeDragView, "Hit chain: \(chain(from: hit(window, at: point)))")
        surface.mouseDown(with: try mouseDown(window, at: point, clickCount: 2))
        pump(0.5)
        let after = hit(window, at: point)
        XCTAssertTrue(
            after is NSTextField || after is NSTextView,
            "Double-clicking the Space name did not swap in the rename field. Hit chain after: \(chain(from: after))"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rightClickingTheSpaceTitleRowStillOffersTheSpaceMenu

    func test_rightClickingTheSpaceTitleRowStillOffersTheSpaceMenu() throws {
        let window = try mount()
        let container = try XCTUnwrap(container)
        let geometry = try titleRowGeometry(in: container)
        for probe in probes(geometry) {
            let target = OrbitRightClickAnchorView.menuTarget(at: probe.point, in: window)
            let entries = titles(target?.entriesProvider?(.zero) ?? [])
            XCTAssertTrue(
                entries.contains("Rename Space"),
                """
                Right-clicking \(probe.label) at \(probe.point) opens \(entries), not the Space menu. \
                Chosen anchor: \(describe(target, at: probe.point)). \
                Title row \(geometry.row), name \(geometry.name). Hit chain: \(chain(from: hit(window, at: probe.point))). \
                Anchors: \(anchorReport(container))
                """
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anAnchorClaimsAPointOnlyInsideItsOwnWindowFrame

    func test_anAnchorClaimsAPointOnlyInsideItsOwnWindowFrame() throws {
        _ = try mount()
        let container = try XCTUnwrap(container)
        let geometry = try titleRowGeometry(in: container)
        let points = probes(geometry).map(\.point) + [firstFavoriteTileCentre(below: geometry), backdropGapPoint(geometry)]
        for anchor in rightClickAnchors(in: container) where anchor.entriesProvider != nil {
            for point in points {
                XCTAssertEqual(
                    anchor.contains(point), windowFrame(anchor).contains(point),
                    "The anchor for \(titles(anchor.entriesProvider?(.zero) ?? []).first ?? "-") claims \(point) wrongly: \(describe(anchor, at: point))"
                )
            }
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rightClickingAFavoriteTileStillOffersTheFavoriteMenu

    func test_rightClickingAFavoriteTileStillOffersTheFavoriteMenu() throws {
        let window = try mount()
        let container = try XCTUnwrap(container)
        XCTAssertFalse(env.favorites(for: try XCTUnwrap(env.activeSpace).id).isEmpty, "Harness error: the demo Space has no favourites to right-click.")
        let geometry = try titleRowGeometry(in: container)
        let point = firstFavoriteTileCentre(below: geometry)
        let resolved = hit(window, at: point)
        XCTAssertFalse(
            resolved is SidebarChromeDragView,
            "Harness error: \(point) is empty chrome, not the first favourite tile. Title row \(geometry.row). Hit chain: \(chain(from: resolved))"
        )
        let target = OrbitRightClickAnchorView.menuTarget(at: point, in: window)
        let entries = titles(target?.entriesProvider?(.zero) ?? [])
        XCTAssertTrue(
            entries.contains("Remove from Favorites") && !entries.contains("Rename Space"),
            """
            Right-clicking the first favourite tile at \(point) opens \(entries), not the favourite's menu. \
            Chosen anchor: \(describe(target, at: point)). Title row \(geometry.row). Anchors: \(anchorReport(container))
            """
        )
        XCTAssertTrue(
            target.map { windowFrame($0).contains(point) } ?? false,
            "The favourite menu came from another tile's anchor, not the one under the pointer: \(describe(target, at: point))"
        )
    }

    private func backdropGapPoint(_ geometry: TitleRowGeometry) -> NSPoint {
        NSPoint(x: geometry.row.midX, y: geometry.row.minY - OrbitMetrics.favoriteGridVerticalPadding / 2)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rightClickingTheGapBetweenRowsOffersTheSidebarBackdropMenu

    func test_rightClickingTheGapBetweenRowsOffersTheSidebarBackdropMenu() throws {
        let window = try mount()
        let container = try XCTUnwrap(container)
        let geometry = try titleRowGeometry(in: container)
        let point = backdropGapPoint(geometry)
        let covering = rightClickAnchors(in: container).filter { !$0.isBackdrop && $0.entriesProvider != nil && windowFrame($0).contains(point) }
        XCTAssertTrue(
            covering.isEmpty,
            "Harness error: \(point) is not a gap; regular anchors cover it: \(covering.map { describe($0, at: point) })"
        )
        let target = OrbitRightClickAnchorView.menuTarget(at: point, in: window)
        let entries = titles(target?.entriesProvider?(.zero) ?? [])
        XCTAssertTrue(
            target?.isBackdrop == true && entries.contains(Self.backdropTitle),
            """
            Right-clicking the gap between the title row and the favourites at \(point) opens \(entries), not the sidebar's backdrop menu. \
            Chosen anchor: \(describe(target, at: point)). Anchors: \(anchorReport(container))
            """
        )
    }
}
