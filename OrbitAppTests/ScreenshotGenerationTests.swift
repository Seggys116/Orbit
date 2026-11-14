import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: the suite needs a running app, and MeshGradient theme renders stall past five minutes.
final class ScreenshotGenerationTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrbitAppTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("refs/screenshots", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        PeekState.shared.dismiss()
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_windowFull

    func test_windowFull() async {
        OrbitScreenshotFixtures.configure(env)
        await renderAndSave(
            windowView(),
            name: "window-full",
            size: Self.windowSize
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_windowFullLight

    func test_windowFullLight() async {
        OrbitScreenshotFixtures.configure(env)
        await renderAndSave(
            windowView(),
            name: "window-full-light",
            size: Self.windowSize,
            appearance: .aqua
        )
    }

    // Only the window is adaptive here: Settings and Library paint from a fixed LibraryPalette.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_windowAppearance_lightAndDarkRenderDifferently
    func test_windowAppearance_lightAndDarkRenderDifferently() {
        OrbitScreenshotFixtures.configure(env)
        let dark = render(windowView(), size: Self.windowSize, appearance: .darkAqua)
        let light = render(windowView(), size: Self.windowSize, appearance: .aqua)
        XCTAssertTrue(
            Self.rendersDiffer(dark, light, size: Self.windowSize),
            "The main window rendered pixel-identical in light and dark appearance — the Space theme's own light/dark adaptation is not reaching the rendered window."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_windowSidebarCollapsed

    func test_windowSidebarCollapsed() async {
        OrbitScreenshotFixtures.configure(env)
        env.isSidebarVisible = false
        env.isSidebarHoverRevealed = false
        await renderAndSave(
            windowView(),
            name: "window-sidebar-collapsed",
            size: Self.windowSize
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_windowHoverOverlay

    func test_windowHoverOverlay() async {
        OrbitScreenshotFixtures.configure(env)
        env.isSidebarVisible = false
        env.isSidebarHoverRevealed = true
        await renderAndSave(
            windowView(),
            name: "window-hover-overlay",
            size: Self.windowSize
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_sidebarVisibilityStates_eachRenderVisiblyDifferently
    func test_sidebarVisibilityStates_eachRenderVisiblyDifferently() {
        OrbitScreenshotFixtures.configure(env)

        env.isSidebarVisible = true
        env.isSidebarHoverRevealed = false
        let full = render(windowView(), size: Self.windowSize)

        env.isSidebarVisible = false
        env.isSidebarHoverRevealed = false
        let collapsed = render(windowView(), size: Self.windowSize)

        env.isSidebarVisible = false
        env.isSidebarHoverRevealed = true
        let hoverOverlay = render(windowView(), size: Self.windowSize)

        XCTAssertTrue(
            Self.rendersDiffer(full, collapsed, size: Self.windowSize),
            "Collapsing the sidebar (isSidebarVisible = false) did not change anything rendered — refs/screenshots/window-sidebar-collapsed.png would be a copy of window-full.png."
        )
        XCTAssertTrue(
            Self.rendersDiffer(collapsed, hoverOverlay, size: Self.windowSize),
            "Hover-revealing the sidebar over a collapsed window did not change anything rendered — refs/screenshots/window-hover-overlay.png would be a copy of window-sidebar-collapsed.png."
        )
    }

    // Not a direct render of SidebarView: ImageRenderer renders ScrollView content blank, so ScreenshotSidebarComposition swaps it for a plain VStack.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_sidebar

    func test_sidebar() async {
        OrbitScreenshotFixtures.configure(env)
        guard let space = env.space(OrbitScreenshotFixtures.IDs.workSpaceID) else {
            XCTFail("Expected OrbitScreenshotFixtures' Work space to exist.")
            return
        }
        seedNowPlayingCard()
        let view = ScreenshotSidebarComposition(space: space)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(view, name: "sidebar", size: CGSize(width: env.sidebarWidth, height: 900))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_sidebar_nowPlayingCard_isVisibleInTheBottomTrayBand
    func test_sidebar_nowPlayingCard_isVisibleInTheBottomTrayBand() {
        OrbitScreenshotFixtures.configure(env)
        guard let space = env.space(OrbitScreenshotFixtures.IDs.workSpaceID) else {
            XCTFail("Expected OrbitScreenshotFixtures' Work space to exist.")
            return
        }
        let size = CGSize(width: env.sidebarWidth, height: 900)
        // SidebarBottomBar sits below the tray, so SidebarMiniPlayerTray paints in this band (~90-140pt above the canvas floor).
        let trayBand = CGRect(x: 8, y: size.height - 140, width: size.width - 16, height: 50)

        func sidebarView() -> some View {
            ScreenshotSidebarComposition(space: space).environment(env).orbitScreenshotModeDragDisabledForTests()
        }

        let withoutNowPlaying = render(sidebarView(), size: size)
        seedNowPlayingCard()
        let withNowPlaying = render(sidebarView(), size: size)

        XCTAssertTrue(
            withNowPlaying.containsNonBackgroundPixels(in: trayBand, background: withNowPlaying.color(atX: 0, y: 0)),
            "The now-playing tray band painted nothing once a track was seeded as playing."
        )
        XCTAssertTrue(
            Self.rendersDiffer(withoutNowPlaying, withNowPlaying, size: size),
            "Seeding an audible, now-playing tab did not change anything rendered in the sidebar."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_sidebarNestedFolders

    func test_sidebarNestedFolders() async {
        OrbitScreenshotFixtures.configure(env)
        guard let space = env.space(OrbitScreenshotFixtures.IDs.personalSpaceID) else {
            XCTFail("Expected OrbitScreenshotFixtures' Personal space to exist.")
            return
        }
        let view = ScreenshotSidebarComposition(space: space)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(view, name: "sidebar-nested-folders", size: CGSize(width: env.sidebarWidth, height: 1000))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_sidebarSingleSpace

    func test_sidebarSingleSpace() async {
        OrbitScreenshotFixtures.configure(env)
        guard let space = reduceFixtureToSingleSpace(keeping: OrbitScreenshotFixtures.IDs.personalSpaceID) else {
            XCTFail("Expected OrbitScreenshotFixtures' Personal space to exist.")
            return
        }
        let view = ScreenshotSidebarComposition(space: space)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        // 1100, not 900: ScreenshotSidebarComposition is a non-scrolling VStack, so content taller than the canvas is cropped rather than clipped-with-scroll, and at 900pt the bottom bar was cropped off.
        await renderAndSave(view, name: "sidebar-single-space", size: CGSize(width: env.sidebarWidth, height: 1100))
    }


    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_tabRowHoverCloseButton

    func test_tabRowHoverCloseButton() async {
        let width: CGFloat = 260
        let rowHeight = OrbitMetrics.sidebarRowHeight
        let theme = SpaceTheme()
        let tabs = Self.longTitledTabsForHoverTest()

        let view = VStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                TabRowView(tab: tab, theme: theme, forcesHoveredAppearanceForTesting: index.isMultiple(of: 2))
                    .environment(self.env)
            }
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .orbitScreenshotModeDragDisabledForTests()

        await renderAndSave(
            view,
            name: "tab-row-hover-close-button",
            size: CGSize(width: width, height: rowHeight * CGFloat(tabs.count))
        )
    }

    func test_tabRowLongTitle_notHoveredUsesFullWidth_hoveredRevealsCloseButtonInPlace() {
        let width: CGFloat = 260
        let theme = SpaceTheme()
        let size = CGSize(width: width, height: OrbitMetrics.sidebarRowHeight)
        var tab = Orbit.Tab(spaceID: SpaceID(), url: URL(string: "https://long-title.example.com")!)
        tab.title = "[ASMR] How many more years can this channel possibly keep going for, honestly"

        // The close control's .orbitTooltip rasterises as a block whatever its opacity, so the not-hovered row would read as having a button.
        let notHovered = render(
            TabRowView(tab: tab, theme: theme, forcesHoveredAppearanceForTesting: false)
                .environment(env)
                .orbitScreenshotModeDragDisabledForTests(),
            size: size
        )
        let hovered = render(
            TabRowView(tab: tab, theme: theme, forcesHoveredAppearanceForTesting: true)
                .environment(env)
                .orbitScreenshotModeDragDisabledForTests(),
            size: size
        )

        let rowTrailingInset = OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset
        let buttonSize = OrbitMetrics.sidebarCloseButtonSize
        let closeButtonRect = CGRect(
            x: width - rowTrailingInset - buttonSize - 2,
            y: (OrbitMetrics.sidebarRowHeight - buttonSize) / 2 - 2,
            width: buttonSize + 4,
            height: buttonSize + 4
        )

        // Use a short title: on the long-titled row, unhovered ink legitimately occupies the trailing slot.
        var shortTab = Orbit.Tab(spaceID: tab.spaceID, url: URL(string: "https://short.example.com")!)
        shortTab.title = "Inbox"
        let shortNotHovered = render(
            TabRowView(tab: shortTab, theme: theme, forcesHoveredAppearanceForTesting: false)
                .environment(env)
                .orbitScreenshotModeDragDisabledForTests(),
            size: size
        )
        let shortHovered = render(
            TabRowView(tab: shortTab, theme: theme, forcesHoveredAppearanceForTesting: true)
                .environment(env)
                .orbitScreenshotModeDragDisabledForTests(),
            size: size
        )

        if shortNotHovered.containsNonBackgroundPixels(in: closeButtonRect, background: .clear, tolerance: 0.06) {
            shortNotHovered.writeDiagnosticPNG(named: "tabRow-hover-FAILED-closeButtonVisibleWhileNotHovering")
        }
        XCTAssertFalse(
            shortNotHovered.containsNonBackgroundPixels(in: closeButtonRect, background: .clear, tolerance: 0.06),
            "The close (x) button must be invisible while the row is not hovered; found ink in its reserved slot at \(closeButtonRect) with no hover."
        )

        if !shortHovered.containsNonBackgroundPixels(in: closeButtonRect, background: .clear, tolerance: 0.06) {
            shortHovered.writeDiagnosticPNG(named: "tabRow-hover-FAILED-closeButtonMissingWhileHovering")
        }
        XCTAssertTrue(
            shortHovered.containsNonBackgroundPixels(in: closeButtonRect, background: .clear, tolerance: 0.06),
            "The close (x) button must appear at \(closeButtonRect) once the row is hovered."
        )

        // Not boundingBoxOfContent: it would pick up the close glyph and the ~0.06-alpha hover pill; this scans only opaque ink outside the close column.
        let excludedColumns = closeButtonRect.minX...closeButtonRect.maxX
        guard let notHoveredTitleMaxX = Self.rightmostOpaqueInkX(in: notHovered, size: size, excludingX: excludedColumns),
              let hoveredTitleMaxX = Self.rightmostOpaqueInkX(in: hovered, size: size, excludingX: excludedColumns) else {
            notHovered.writeDiagnosticPNG(named: "tabRow-hover-FAILED-empty-notHovered")
            hovered.writeDiagnosticPNG(named: "tabRow-hover-FAILED-empty-hovered")
            XCTFail("Expected both hover states of a long-titled row to draw visible title ink.")
            return
        }

        let reclaimedWidth = notHoveredTitleMaxX - hoveredTitleMaxX
        if reclaimedWidth < 18 {
            notHovered.writeDiagnosticPNG(named: "tabRow-hover-FAILED-titleNotWider")
            hovered.writeDiagnosticPNG(named: "tabRow-hover-FAILED-titleNotWider")
        }
        XCTAssertGreaterThanOrEqual(
            reclaimedWidth, 18,
            "A long title must reach noticeably further right while not hovered (reclaiming the " +
            "close button's \(OrbitMetrics.sidebarCloseButtonSize + OrbitMetrics.sidebarRowContentSpacing)pt " +
            "of width) than while hovered — not-hovered title ink reached x=\(notHoveredTitleMaxX), " +
            "hovered title ink reached x=\(hoveredTitleMaxX)."
        )
    }

    private static func rightmostOpaqueInkX(
        in image: RenderedImage,
        size: CGSize,
        excludingX excludedColumns: ClosedRange<CGFloat>,
        alphaThreshold: Double = 0.5
    ) -> CGFloat? {
        var maxX: CGFloat = -1
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        for x in 0..<width {
            let fx = CGFloat(x)
            if excludedColumns.contains(fx) { continue }
            for y in 0..<height where image.color(atX: x, y: y).a > alphaThreshold {
                maxX = max(maxX, fx)
                break
            }
        }
        return maxX >= 0 ? maxX : nil
    }

    private static func longTitledTabsForHoverTest() -> [Orbit.Tab] {
        let titles = [
            "[ASMR] How many more years can this channel possibly keep going for, honestly",
            "(3) Fixing a Viewer's OLD & BROKEN mechanical keyboard from 2003",
            "Why every senior engineer eventually rewrites their build system from scratch",
            "The absolute longest possible page title anyone would ever realistically use",
        ]
        return titles.map { title in
            var tab = Orbit.Tab(spaceID: SpaceID(), url: URL(string: "https://example.com/\(UUID().uuidString)")!)
            tab.title = title
            return tab
        }
    }

    private func reduceFixtureToSingleSpace(keeping spaceID: SpaceID) -> Space? {
        var document = env.state
        guard let kept = document.spaces.first(where: { $0.id == spaceID }) else { return nil }
        document.spaces = [kept]
        document.activeSpaceID = kept.id
        env.state = document
        return kept
    }

    private func seedNowPlayingCard() {
        let tabID = OrbitScreenshotFixtures.IDs.audibleTabID
        let contents = MockWebContents()
        contents.mediaState = MediaState(
            isAudible: true,
            hasVideo: false,
            nowPlayingTitle: "Saturdays (feat. HAIM)",
            nowPlayingArtist: "Twin Shadow",
            isPlaying: true
        )
        env._test_attachWebContents(contents, for: tabID)
        env._test_engineCapabilitiesOverride = [.pictureInPicture, .audioMuting]

        // The tray shows a tab you are not looking at, so the audible fixture tab must not be the active one.
        if let spaceID = env.tab(tabID)?.spaceID, env.state.activeTabBySpace[spaceID] == tabID {
            env.state.activeTabBySpace[spaceID] = env.todayTabs(in: spaceID).first { $0.id != tabID }?.id
        }

        XCTAssertTrue(
            env.nowPlayingTabs.contains { $0.id == tabID },
            "The now-playing tray is empty, so refs/screenshots/sidebar.png would show no card at all."
        )
        // Audio-only has nothing to float, so the card must offer no picture-in-picture control.
        XCTAssertFalse(
            env.canDrivePictureInPicture(for: tabID),
            "An audio-only now-playing tab has no video to float, so its card must not offer a picture-in-picture control."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_splitTwoPanes

    func test_splitTwoPanes() async {
        OrbitScreenshotFixtures.configure(env)
        OrbitScreenshotFixtures.seedSplitGroup(env)
        await renderAndSave(
            windowView(),
            name: "split-two-panes",
            size: Self.windowSize
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_commandBar

    func test_commandBar() async {
        OrbitScreenshotFixtures.configure(env)
        env.commandBarMode = .editURL(URL(string: "https://github.com")!)
        env.isCommandBarPresented = true
        let view = CommandBarView().environment(env).orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(view, name: "command-bar", size: CGSize(width: OrbitMetrics.commandBarWidth, height: 520))
    }

    // Scoped to the input row: ImageRenderer rasterises TextField as a solid block and ScrollView content not at all.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_commandBarSiteSearch
    func test_commandBarSiteSearch() async {
        OrbitScreenshotFixtures.configure(env)
        env.commandBarMode = .newTab
        env.isCommandBarPresented = true
        let youTube = env.siteSearchStore.engines.first { $0.shortcut.lowercased() == "yt" }
        let view = CommandBarView(
            initialSiteSearchScope: youTube.map {
                CommandBarView.InitialSiteSearchScope(engine: $0, query: "Yaeji - With a Hammer")
            }
        )
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(view, name: "command-bar-site-search", size: CGSize(width: OrbitMetrics.commandBarWidth, height: 66))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_commandBar_paintsContentAcrossItsFullDeclaredWidth
    func test_commandBar_paintsContentAcrossItsFullDeclaredWidth() {
        OrbitScreenshotFixtures.configure(env)
        env.commandBarMode = .editURL(URL(string: "https://github.com")!)
        env.isCommandBarPresented = true
        let view = CommandBarView().environment(env).orbitScreenshotModeDragDisabledForTests()
        let width = OrbitMetrics.commandBarWidth
        let rendered = render(view, size: CGSize(width: width, height: 52), appearance: .darkAqua)

        let leadingEdge = CGRect(x: 2, y: 4, width: 6, height: 44)
        let trailingEdge = CGRect(x: width - 8, y: 4, width: 6, height: 44)

        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: leadingEdge, background: .clear),
            "The command bar's leading edge, well inside its declared \(Int(width))pt width, painted nothing."
        )
        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: trailingEdge, background: .clear),
            "The command bar's trailing edge, well inside its declared \(Int(width))pt width, painted nothing — exactly the class of 'rendered narrower than its declared frame' defect a PNG-only check would miss."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsGeneral

    func test_settingsGeneral() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .general
        let view = ScreenshotSettingsComposition(pane: .general)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-general",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsData

    func test_settingsData() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .data
        let view = ScreenshotSettingsComposition(pane: .data)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-data",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: 1400)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsProfiles

    func test_settingsProfiles() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .profiles
        let view = ScreenshotSettingsComposition(pane: .profiles)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-profiles",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // Captures the Links pane, not the Air Traffic Control sheet: a .sheet has no presented content off-screen.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsLinks
    func test_settingsLinks() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .links
        let view = ScreenshotSettingsComposition(pane: .links)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-links",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsShortcuts

    func test_settingsShortcuts() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .shortcuts
        let view = ScreenshotSettingsComposition(pane: .shortcuts)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-shortcuts",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsAssist

    func test_settingsAssist() async {
        OrbitScreenshotFixtures.configure(env)
        let suite = withEmptyAssistDefaults()
        defer { restoreAssistDefaults(suite) }

        SettingsRouter.shared.selectedPane = .assist
        let view = ScreenshotSettingsComposition(pane: .assist)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-assist",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsAssistTurnedOn

    func test_settingsAssistTurnedOn() async {
        OrbitScreenshotFixtures.configure(env)
        let suite = withEmptyAssistDefaults()
        defer { restoreAssistDefaults(suite) }

        AssistSettings.isEnabled = true
        AssistSettings.providerKind = .anthropic
        AssistSettings.model = "claude-haiku-4-5"
        AssistKeychain.inMemoryOverride = [AssistKeychain.account(for: .anthropic): "sk-ant-demo"]
        AssistSettings.isAskOnPageEnabled = true
        AssistSettings.isTidyTabsEnabled = true
        AssistSettings.isInstantLinksEnabled = true

        SettingsRouter.shared.selectedPane = .assist
        let view = ScreenshotSettingsComposition(pane: .assist)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-assist-on",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsAssist_turnedOnRendersDifferentlyThanOff
    func test_settingsAssist_turnedOnRendersDifferentlyThanOff() {
        let size = CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        OrbitScreenshotFixtures.configure(env)
        let suite = withEmptyAssistDefaults()
        defer { restoreAssistDefaults(suite) }

        SettingsRouter.shared.selectedPane = .assist
        func paneView() -> some View {
            ScreenshotSettingsComposition(pane: .assist).environment(env).orbitScreenshotModeDragDisabledForTests()
        }

        let off = render(paneView(), size: size, appearance: .darkAqua)

        AssistSettings.isEnabled = true
        AssistSettings.providerKind = .anthropic
        AssistSettings.model = "claude-haiku-4-5"
        AssistKeychain.inMemoryOverride = [AssistKeychain.account(for: .anthropic): "sk-ant-demo"]
        AssistSettings.isAskOnPageEnabled = true
        AssistSettings.isTidyTabsEnabled = true
        AssistSettings.isInstantLinksEnabled = true

        let on = render(paneView(), size: size, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(off, on, size: size),
            "Turning Assist on (a configured provider plus three enabled features) did not change anything rendered in the Assist pane."
        )
    }

    /// The pane reads live preferences, so a render off this machine's own defaults is not a picture of the shipped state.
    private func withEmptyAssistDefaults() -> String {
        let name = "AssistScreenshot-\(UUID().uuidString)"
        AssistSettings.defaults = UserDefaults(suiteName: name)!
        AssistKeychain.inMemoryOverride = [:]
        return name
    }

    private func restoreAssistDefaults(_ suiteName: String) {
        AssistSettings.defaults.removePersistentDomain(forName: suiteName)
        AssistSettings.defaults = OrbitDefaults.standard
        AssistKeychain.inMemoryOverride = nil
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsExtensions

    func test_settingsExtensions() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .extensions
        let view = ScreenshotSettingsComposition(pane: .extensions)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-extensions",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsAdBlocker

    func test_settingsAdBlocker() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .adBlocker
        let view = ScreenshotSettingsComposition(pane: .adBlocker)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-ad-blocker",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsICloud

    func test_settingsICloud() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .icloud
        let view = ScreenshotSettingsComposition(pane: .icloud)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "settings-icloud",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsWindow
    func test_settingsWindow() async {
        OrbitScreenshotFixtures.configure(env)
        SettingsRouter.shared.selectedPane = .general
        let view = ScreenshotSettingsComposition(pane: .general)
            .environment(env)
        await renderAndSave(
            view,
            name: "settings-window",
            size: CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        )
    }

    // Not a render of LibraryModeView: ScreenshotLibraryComposition works around the ScrollView limitation, sized as the Library is in the sidebar.

    private static let librarySize = CGSize(width: LibraryModeLayout.baseWidth, height: 720)
    private static let librarySpacesSize = CGSize(width: LibraryModeLayout.spacesWidth, height: 720)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryDownloads

    func test_libraryDownloads() async {
        OrbitScreenshotFixtures.configure(env)
        env.libraryRouter.selectedSection = .downloads
        env.libraryRouter.selection = nil
        let view = ScreenshotLibraryComposition(section: .downloads)
            .environment(env)
        await renderAndSave(view, name: "library-downloads", size: Self.librarySize)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_librarySpaces

    func test_librarySpaces() async {
        OrbitScreenshotFixtures.configure(env)
        env.libraryRouter.selectedSection = .spaces
        let view = ScreenshotLibraryComposition(section: .spaces)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(view, name: "library-spaces", size: Self.librarySpacesSize)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_librarySpacesWithFolders

    func test_librarySpacesWithFolders() async {
        OrbitScreenshotFixtures.configure(env)
        let spaceID = OrbitScreenshotFixtures.IDs.personalSpaceID

        let systemsFolderID = env.createFolder(name: "Systems", in: spaceID)
        let networkingFolderID = env.createFolder(name: "Networking", in: spaceID, parent: systemsFolderID)

        let routerTabID = env.openTab(url: URL(string: "https://example.com/router")!, in: spaceID, section: .today, activate: false)
        env.pinTab(routerTabID, toParent: networkingFolderID, atIndex: 0, in: spaceID)
        let switchTabID = env.openTab(url: URL(string: "https://example.com/switch")!, in: spaceID, section: .today, activate: false)
        env.pinTab(switchTabID, toParent: networkingFolderID, atIndex: 1, in: spaceID)

        let nasTabID = env.openTab(url: URL(string: "https://example.com/nas")!, in: spaceID, section: .today, activate: false)
        env.pinTab(nasTabID, toParent: systemsFolderID, atIndex: 0, in: spaceID)
        let hypervisorTabID = env.openTab(url: URL(string: "https://example.com/hypervisor")!, in: spaceID, section: .today, activate: false)
        env.pinTab(hypervisorTabID, toParent: systemsFolderID, atIndex: 1, in: spaceID)

        let looseTabID = env.openTab(url: URL(string: "https://example.com/homelab-dashboard")!, in: spaceID, section: .today, activate: false)
        env.pinTab(looseTabID, toParent: nil, atIndex: 0, in: spaceID)

        env.libraryRouter.selectedSection = .spaces
        let view = ScreenshotLibraryComposition(section: .spaces)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(view, name: "library-spaces-folders", size: Self.librarySpacesSize)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryArchivedTabsWithFolders

    func test_libraryArchivedTabsWithFolders() async {
        OrbitScreenshotFixtures.configure(env)
        let spaceID = OrbitScreenshotFixtures.IDs.personalSpaceID

        let parentFolderID = env.createFolder(name: "Reading", in: spaceID)
        let childFolderID = env.createFolder(name: "Long Reads", in: spaceID, parent: parentFolderID)

        let nestedTabID = env.openTab(url: URL(string: "https://example.com/nested-article")!, in: spaceID, section: .today, activate: false)
        env.pinTab(nestedTabID, toParent: childFolderID, atIndex: 0, in: spaceID)
        env.archiveTab(nestedTabID)

        let siblingTabID = env.openTab(url: URL(string: "https://example.com/top-level-folder-tab")!, in: spaceID, section: .today, activate: false)
        env.pinTab(siblingTabID, toParent: parentFolderID, atIndex: 0, in: spaceID)
        env.archiveTab(siblingTabID)

        let looseTabID = env.openTab(url: URL(string: "https://example.com/loose")!, in: spaceID, section: .today, activate: false)
        env.archiveTab(looseTabID)

        env.libraryRouter.selectedSection = .archivedTabs
        let view = ScreenshotLibraryComposition(section: .archivedTabs)
            .environment(env)
        await renderAndSave(view, name: "library-archived-tabs-folders", size: Self.librarySize)
    }

    // The detail's note body is not shown (LibraryNotePreviewView puts its Text in a ScrollView, which ImageRenderer does not rasterise off-screen), so this renders the section's list with the note in it.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryEaselsAndNotes
    func test_libraryEaselsAndNotes() async {
        OrbitScreenshotFixtures.configure(env)

        let note = env.noteStore.createNote(title: "Q4 launch notes")
        let body = NSMutableAttributedString()
        body.append(NSAttributedString(
            string: "Q4 launch notes\n",
            attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold)]
        ))
        body.append(NSAttributedString(
            string: "\nThe Library preview renders the note's real decoded body, "
                + "not a thumbnail of it — the same NSAttributedString the editor wrote, "
                + "with its own per-run attributes intact.\n\nHeadings, weights and colours "
                + "set in the editor survive into the preview.",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ))
        if let encoded = NotesEditorView.encode(body) {
            env.noteStore.setBody(encoded, forNote: note.id)
        }

        env.libraryRouter.selectedSection = .easelsAndNotes
        env.libraryRouter.selection = nil

        let view = ScreenshotLibraryComposition(section: .easelsAndNotes)
            .environment(env)
        await renderAndSave(view, name: "library-easels-notes", size: Self.librarySize)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryDownloadsAtTheUsersWidthWhenWider

    func test_libraryDownloadsAtTheUsersWidthWhenWider() async {
        OrbitScreenshotFixtures.configure(env)
        env.libraryRouter.selectedSection = .downloads
        env.libraryRouter.selection = nil
        let width = LibraryModeLayout.width(for: .downloads, userWidth: 420)
        let view = ScreenshotLibraryComposition(section: .downloads).environment(env)
        await renderAndSave(view, name: "library-downloads-wide", size: CGSize(width: width, height: 720))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryDownloads_listUsesTheFullColumnWidth
    func test_libraryDownloads_listUsesTheFullColumnWidth() {
        OrbitScreenshotFixtures.configure(env)
        env.libraryRouter.selectedSection = .downloads
        env.libraryRouter.selection = nil
        let item = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://example.com/running.zip")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("running-\(UUID().uuidString).zip"),
            suggestedFileName: "running.zip",
            totalBytes: 1_000
        )
        env.downloadStore.updateProgress(id: item.id, progress: DownloadProgress(receivedBytes: 400, totalBytes: 1_000, state: .inProgress))
        defer { env.downloadStore.remove(item.id) }

        let size = Self.librarySize
        let view = ScreenshotLibraryComposition(section: .downloads).environment(env)
        let rendered = render(view, size: size)

        let background = rendered.color(atX: Int(size.width) - 2, y: Int(size.height) - 4)
        let farRight = CGRect(x: size.width - 50, y: 80, width: 40, height: 200)
        if !rendered.containsNonBackgroundPixels(in: farRight, background: background) {
            rendered.writeDiagnosticPNG(named: "library-downloads-FAILED-listNotFullWidth")
        }
        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: farRight, background: background),
            "A running download's Cancel control should sit near the right edge of the \(Int(size.width))pt Library column; found nothing painted at \(farRight)."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryArchivedTabsWideNoSelection

    func test_libraryArchivedTabsWideNoSelection() async {
        OrbitScreenshotFixtures.configure(env)
        let spaceID = OrbitScreenshotFixtures.IDs.personalSpaceID

        let parentFolderID = env.createFolder(name: "Reading", in: spaceID)
        let childFolderID = env.createFolder(name: "Long Reads", in: spaceID, parent: parentFolderID)

        let nestedTabID = env.openTab(url: URL(string: "https://example.com/nested-article")!, in: spaceID, section: .today, activate: false)
        env.pinTab(nestedTabID, toParent: childFolderID, atIndex: 0, in: spaceID)
        env.archiveTab(nestedTabID)

        let siblingTabID = env.openTab(url: URL(string: "https://example.com/top-level-folder-tab")!, in: spaceID, section: .today, activate: false)
        env.pinTab(siblingTabID, toParent: parentFolderID, atIndex: 0, in: spaceID)
        env.archiveTab(siblingTabID)

        let looseTabID = env.openTab(url: URL(string: "https://example.com/loose")!, in: spaceID, section: .today, activate: false)
        env.archiveTab(looseTabID)

        env.libraryRouter.selectedSection = .archivedTabs
        env.libraryRouter.selection = nil
        let view = ScreenshotLibraryComposition(section: .archivedTabs).environment(env)
        await renderAndSave(view, name: "library-archived-tabs-wide", size: Self.librarySize)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryArchivedTabsNarrowMinWidth

    func test_libraryArchivedTabsNarrowMinWidth() async {
        OrbitScreenshotFixtures.configure(env)
        let spaceID = OrbitScreenshotFixtures.IDs.personalSpaceID
        let looseTabID = env.openTab(url: URL(string: "https://example.com/loose")!, in: spaceID, section: .today, activate: false)
        env.archiveTab(looseTabID)

        env.libraryRouter.selectedSection = .archivedTabs
        env.libraryRouter.selection = nil
        let view = ScreenshotLibraryComposition(section: .archivedTabs).environment(env)
        await renderAndSave(view, name: "library-archived-tabs-narrow", size: CGSize(width: LibraryModeLayout.baseWidth, height: 480))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryMediaWideNoSelection

    func test_libraryMediaWideNoSelection() async {
        OrbitScreenshotFixtures.configure(env)
        env.libraryRouter.selectedSection = .media
        env.libraryRouter.selection = nil
        let view = ScreenshotLibraryComposition(section: .media).environment(env)
        await renderAndSave(view, name: "library-media-wide", size: Self.librarySize)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryEaselsAndNotesWideNoSelection

    func test_libraryEaselsAndNotesWideNoSelection() async {
        OrbitScreenshotFixtures.configure(env)
        let note = env.noteStore.createNote(title: "Q4 launch notes")
        _ = env.easelStore.createEasel(title: "Sprint retro board")

        env.libraryRouter.selectedSection = .easelsAndNotes
        env.libraryRouter.selection = nil
        let view = ScreenshotLibraryComposition(section: .easelsAndNotes).environment(env)
        await renderAndSave(view, name: "library-easels-notes-wide", size: Self.librarySize)
        _ = note
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryBoostsWideNoSelection

    func test_libraryBoostsWideNoSelection() async {
        OrbitScreenshotFixtures.configure(env)
        _ = env.boostStore.createBoost(name: "Reader mode", host: "example.com")
        _ = env.boostStore.createBoost(name: "Dark theme", host: "news.ycombinator.com")

        env.libraryRouter.selectedSection = .boosts
        env.libraryRouter.selection = nil
        let view = ScreenshotLibraryComposition(section: .boosts).environment(env)
        await renderAndSave(view, name: "library-boosts-wide", size: Self.librarySize)
    }

    // No real engine starts in this target, so seedSiteControlPopover(_:) attaches a mock engine, session and webContents for the rows gated on env.engine.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_siteControlPopover
    func test_siteControlPopover() async {
        OrbitScreenshotFixtures.configure(env)
        OrbitScreenshotFixtures.seedSiteControlPopover(env)
        guard let tab = env.activeTab else {
            XCTFail("test_siteControlPopover: expected env.activeTab (seeded by seedSiteControlPopover) to be non-nil.")
            return
        }
        let view = SiteControlPopoverView(tab: tab)
            .environment(env)
            .background(Color(nsColor: .windowBackgroundColor))
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(view, name: "site-control-popover", size: CGSize(width: 300, height: 620))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_newSpacePanel

    func test_newSpacePanel() async {
        OrbitScreenshotFixtures.configure(env)
        await renderAndSave(
            NewSpaceFlowView()
                .environment(env)
                .orbitScreenshotModeDragDisabledForTests(),
            name: "new-space-panel",
            size: CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: Self.windowSize.height)
        )
    }


    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_spaceSwitcherMixedIcons
    func test_spaceSwitcherMixedIcons() async {
        guard let view = spaceSwitcherMixedIconsFixture() else { return }
        await renderAndSave(
            view,
            name: "space-switcher-mixed-icons",
            size: CGSize(width: env.sidebarWidth, height: OrbitMetrics.sidebarBottomBarHeight)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_spaceSwitcherMixedIconsLight
    func test_spaceSwitcherMixedIconsLight() async {
        guard let view = spaceSwitcherMixedIconsFixture() else { return }
        await renderAndSave(
            view,
            name: "space-switcher-mixed-icons-light",
            size: CGSize(width: env.sidebarWidth, height: OrbitMetrics.sidebarBottomBarHeight),
            appearance: .aqua
        )
    }

    private func spaceSwitcherMixedIconsFixture() -> AnyView? {
        OrbitScreenshotFixtures.configure(env)
        guard let fixtureSpace = env.space(OrbitScreenshotFixtures.IDs.workSpaceID) else {
            XCTFail("Expected OrbitScreenshotFixtures' Work space to exist.")
            return nil
        }
        let theme = fixtureSpace.theme
        let profileID = fixtureSpace.profileID

        var readingSpace = Space(name: "Reading", profileID: profileID)
        readingSpace.setIcon(emoji: "📚")
        readingSpace.theme = theme

        var workSpace = Space(name: "Work", profileID: profileID)
        workSpace.setIcon(symbol: "bolt.fill")
        workSpace.theme = theme

        var designSpace = Space(name: "Design", profileID: profileID)
        designSpace.setIcon(emoji: "🎨")
        designSpace.theme = theme

        var travelSpace = Space(name: "Travel", profileID: profileID)
        travelSpace.setIcon(symbol: "airplane")
        travelSpace.theme = theme

        var state = env.state
        state.spaces = [readingSpace, workSpace, designSpace, travelSpace]
        state.activeSpaceID = workSpace.id
        env.state = state

        return AnyView(
            SidebarBottomBar(theme: theme)
                .environment(env)
                .background { ThemeBackgroundView(theme: theme) }
                .orbitScreenshotModeDragDisabledForTests()
        )
    }

    // MARK: - Shared window view

    private static let windowSize = CGSize(width: 1320, height: 840)

    private func windowView() -> some View {
        BrowserWindowView(skipOnboarding: true)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
    }

    private func renderAndSave(
        _ view: some View,
        name: String,
        size: CGSize,
        appearance: NSAppearance.Name = .darkAqua,
        scale: CGFloat = 2.0
    ) async {
        let rendered = await renderForScreenshot(view, size: size, appearance: appearance, scale: scale)

        let expectedPixelWidth = Int((size.width * scale).rounded())
        let expectedPixelHeight = Int((size.height * scale).rounded())
        XCTAssertEqual(
            rendered.bitmap.pixelsWide, expectedPixelWidth,
            "\(name): rendered \(rendered.bitmap.pixelsWide)px wide, expected \(expectedPixelWidth)px (\(Int(size.width))pt @\(Int(scale))x) — the view did not lay out at its requested size."
        )
        XCTAssertEqual(
            rendered.bitmap.pixelsHigh, expectedPixelHeight,
            "\(name): rendered \(rendered.bitmap.pixelsHigh)px tall, expected \(expectedPixelHeight)px (\(Int(size.height))pt @\(Int(scale))x) — the view did not lay out at its requested size."
        )
        XCTAssertNotNil(
            rendered.boundingBoxOfContent(),
            "\(name): the rendered image is blank or a single uniform colour end to end — the view failed to draw anything distinguishable from its own corner pixel. This is exactly the class of defect (a broken layout that still produces a valid, wrong-looking PNG) a write-only check would miss."
        )

        let destination = Self.outputDirectory.appendingPathComponent("\(name).png")
        XCTAssertTrue(
            rendered.writePNG(to: destination),
            "\(name): failed to write \(destination.path)."
        )
    }


    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 8
        var x = 0
        while x < Int(size.width) {
            var y = 0
            while y < Int(size.height) {
                let lhs = a.color(atX: x, y: y)
                let rhs = b.color(atX: x, y: y)
                let dr = lhs.r - rhs.r, dg = lhs.g - rhs.g, db = lhs.b - rhs.b, da = lhs.a - rhs.a
                if (dr * dr + dg * dg + db * db + da * da).squareRoot() > 0.04 { return true }
                y += step
            }
            x += step
        }
        return false
    }
}

/// SidebarView.standardContent(for:)'s body, reproduced here with its ScrollView swapped for a plain VStack since ImageRenderer does not rasterise ScrollView content off-screen; kept local to this file, not a #if DEBUG flag on SidebarView itself, so it cannot mask a real scrolling regression elsewhere.
private struct ScreenshotSidebarComposition: View {
    @Environment(AppEnvironment.self) private var env
    var space: Space

    var body: some View {
        let hasPinnedNodes = !env.pinnedNodes(in: space.id).isEmpty

        VStack(alignment: .leading, spacing: 0) {
            SidebarTopRow(theme: space.theme)
            // Order must match SidebarView.standardContent(for:) exactly, or this stops being a screenshot of Orbit.
            SpaceTitleRow(space: space)
            FavoritesGridView(spaceID: space.id, theme: space.theme)

            VStack(alignment: .leading, spacing: OrbitMetrics.sidebarSectionSpacing) {
                if hasPinnedNodes {
                    PinnedSectionView(spaceID: space.id, theme: space.theme)
                }
                TodayDividerRow(spaceID: space.id, theme: space.theme)
                    .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
                TodaySectionView(spaceID: space.id, theme: space.theme)
            }
            .padding(.top, OrbitMetrics.sidebarSectionSpacing)
            .padding(.bottom, OrbitMetrics.sidebarSectionSpacing)

            Spacer(minLength: 0)

            // alwaysExpanded deviates from production: ImageRenderer has no pointer, so the hovered two-row card could not be captured.
            SidebarMiniPlayerTray(theme: space.theme, alwaysExpanded: true)

            SidebarBottomBar(theme: space.theme)
                .padding(.bottom, OrbitMetrics.sidebarInterSectionGap)
        }
        .background {
            ThemeBackgroundView(theme: space.theme, blur: SpaceVisualPrefsStore.shared.blur(for: space.id))
        }
    }
}

/// LibraryModeView's body, reproduced here with its ScrollView swapped for a plain VStack (see ScreenshotSidebarComposition); the detail's real content is always an NSViewRepresentable, which ImageRenderer cannot rasterise, so this renders the section's list only.
private struct ScreenshotLibraryComposition: View {
    @Environment(AppEnvironment.self) private var env
    var section: LibrarySection

    private var theme: SpaceTheme { env.activeSpace?.theme ?? SpaceTheme() }

    var body: some View {
        let style = LibraryStyle(theme: theme)
        HStack(alignment: .top, spacing: 0) {
            LibraryRailView(selection: .constant(section))

            Rectangle()
                .fill(style.divider)
                .frame(width: OrbitMetrics.cardBorderWidth)

            VStack(alignment: .leading, spacing: LibraryModeMetrics.sectionHeaderSpacing) {
                Text(section.rawValue)
                    .font(OrbitFont.spaceTitle)
                    .foregroundStyle(style.foreground)
                    .lineLimit(1)
                LibrarySearchField(text: .constant(""), placeholder: "Search \(section.rawValue)")

                if section.rendersItsOwnScrolling {
                    sectionList
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    sectionList
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, LibraryModeMetrics.contentPadding)
            .padding(.top, OrbitSpacing.xs)
            .padding(.bottom, OrbitSpacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.libraryStyle, style)
        .background(ThemeBackgroundView(theme: theme, blur: 0))
    }

    @ViewBuilder
    private var sectionList: some View {
        switch section {
        case .downloads: LibraryDownloadsView(searchQuery: "")
        case .easelsAndNotes: LibraryEaselsNotesView(searchQuery: "")
        case .media: LibraryMediaView(searchQuery: "")
        // ManageSpacesColumnsView directly: the host only adds a horizontal ScrollView, which ImageRenderer cannot rasterise.
        case .spaces:
            ManageSpacesColumnsView(searchQuery: "", onAddSpace: {})
        case .archivedTabs: LibraryArchivedTabsView(searchQuery: "")
        case .boosts: LibraryBoostsFallbackView(searchQuery: "")
        }
    }
}

/// SettingsRootView's body, reproduced here with its ScrollView swapped for a plain VStack (see ScreenshotSidebarComposition).
private struct ScreenshotSettingsComposition: View {
    var pane: SettingsPane

    var body: some View {
        // alignment: .top on both the HStack and the content column below is load-bearing: without it, the plain-VStack substitute reports its full content height, and HStack's default .center alignment centres the shorter rail inside the taller stack.
        HStack(alignment: .top, spacing: 0) {
            SettingsSidebarView(selection: .constant(pane))

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(width: 1)

            // GeometryReader keeps a pane far taller than the window top-anchored and cleanly clipped: without it, the plain VStack reports its own full, un-clipped content height, and RenderHarness's outer frame crops centred on that content rather than pinned to its top edge.
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    paneView
                        .padding(SettingsMetrics.contentHorizontalPadding)
                        .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
                        // Without this, a plain VStack shrinks each child's slot to its proposed height, but a .fixedSize(vertical: true) Text still paints at its full natural height, so two rows' content can visually overlap.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SettingsPalette.contentBackground)
        }
        .frame(minWidth: SettingsMetrics.windowMinWidth, minHeight: SettingsMetrics.windowMinHeight)
        .background(SettingsPalette.contentBackground)
    }

    @ViewBuilder
    private var paneView: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .data: DataSettingsPane()
        case .profiles: ProfilesSettingsPane()
        case .assist: AssistSettingsPane()
        case .links: LinksSettingsPane()
        case .shortcuts: ShortcutsSettingsPane()
        case .extensions: ExtensionsSettingsPane()
        case .icloud: SyncSettingsPane()
        case .adBlocker: AdBlockerSettingsPane()
        }
    }
}

private extension View {
    /// Also the shared flag that elides invisible NSViewRepresentable click-catchers, which rasterise as a solid block.
    func orbitScreenshotModeDragDisabledForTests() -> some View {
        #if DEBUG
        return self.environment(\.orbitScreenshotModeDragDisabled, true)
        #else
        return self
        #endif
    }
}
