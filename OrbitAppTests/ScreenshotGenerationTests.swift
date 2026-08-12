import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
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

    // MARK: - Window

    func test_windowFull() async {
        OrbitScreenshotFixtures.configure(env)
        await renderAndSave(
            windowView(),
            name: "window-full",
            size: Self.windowSize
        )
    }

    func test_windowFullLight() async {
        OrbitScreenshotFixtures.configure(env)
        await renderAndSave(
            windowView(),
            name: "window-full-light",
            size: Self.windowSize,
            appearance: .aqua
        )
    }

    // The fixture's Spaces use followsSystemAppearance, so the window background is genuinely
    // adaptive; Settings/Library paint from a fixed LibraryPalette and are not, so this stays scoped.
    func test_windowAppearance_lightAndDarkRenderDifferently() {
        OrbitScreenshotFixtures.configure(env)
        let dark = render(windowView(), size: Self.windowSize, appearance: .darkAqua)
        let light = render(windowView(), size: Self.windowSize, appearance: .aqua)
        XCTAssertTrue(
            Self.rendersDiffer(dark, light, size: Self.windowSize),
            "The main window rendered pixel-identical in light and dark appearance — the Space theme's own light/dark adaptation is not reaching the rendered window."
        )
    }

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

    // Real state comparisons, not three individually non-blank renders: each transition must
    // visibly change the rendered window, or the flags exist without layout reacting to them.
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

    // MARK: - Sidebar alone
    // NOT a direct render of SidebarView: ImageRenderer renders ScrollView content as entirely blank, so ScreenshotSidebarComposition swaps it for a plain VStack.

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

    // Goes further than "the sidebar is non-blank": proves the seeded now-playing card actually
    // reaches the bottom tray band, not just that seedNowPlayingCard()'s own env-level assertions
    // (nowPlayingTabs/canDrivePictureInPicture) passed while the tray itself stayed empty.
    func test_sidebar_nowPlayingCard_isVisibleInTheBottomTrayBand() {
        OrbitScreenshotFixtures.configure(env)
        guard let space = env.space(OrbitScreenshotFixtures.IDs.workSpaceID) else {
            XCTFail("Expected OrbitScreenshotFixtures' Work space to exist.")
            return
        }
        let size = CGSize(width: env.sidebarWidth, height: 900)
        // SidebarBottomBar sits below the tray, so this band (~90-140pt above the canvas floor) is
        // where SidebarMiniPlayerTray paints when, and only when, something is playing.
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

        // The tray shows a tab you are not looking at, so the fixture's
        // audible tab must not be the active one.
        if let spaceID = env.tab(tabID)?.spaceID, env.state.activeTabBySpace[spaceID] == tabID {
            env.state.activeTabBySpace[spaceID] = env.todayTabs(in: spaceID).first { $0.id != tabID }?.id
        }

        XCTAssertTrue(
            env.nowPlayingTabs.contains { $0.id == tabID },
            "The now-playing tray is empty, so refs/screenshots/sidebar.png would show no card at all."
        )
        XCTAssertTrue(
            env.canDrivePictureInPicture(for: tabID),
            "The picture-in-picture control would be hidden, so the captured card would be missing a control."
        )
    }

    // MARK: - Split view

    func test_splitTwoPanes() async {
        OrbitScreenshotFixtures.configure(env)
        OrbitScreenshotFixtures.seedSplitGroup(env)
        await renderAndSave(
            windowView(),
            name: "split-two-panes",
            size: Self.windowSize
        )
    }

    // MARK: - Command Bar

    func test_commandBar() async {
        OrbitScreenshotFixtures.configure(env)
        env.commandBarMode = .editURL(URL(string: "https://github.com")!)
        env.isCommandBarPresented = true
        let view = CommandBarView().environment(env).orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(view, name: "command-bar", size: CGSize(width: OrbitMetrics.commandBarWidth, height: 520))
    }

    // Scoped to the input row: TextField rasterises as a solid block, and ScrollView
    // content does not rasterise off-screen at all -- both ImageRenderer limitations.
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

    // Cropped to the view's declared width/row-height (not padded), with RGBA.clear as the
    // background reference, since a rounded-rect corner this tight can itself be anti-aliased.
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

    // MARK: - Settings

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

    // Captures the window on the Links pane, not the Air Traffic Control
    // sheet: a .sheet has no presented content to rasterise off-screen.
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

    // Real before/after comparison: turning Assist on must actually change what the pane draws,
    // not just what the two individual screenshot tests separately claim.
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
        AssistSettings.defaults = .standard
        AssistKeychain.inMemoryOverride = nil
    }

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

    // Kept as its own image, near-identical to settings-general.png, because
    // it documents the rail-plus-content-column structure rather than the
    // General pane's own content.
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

    // MARK: - Library
    // NOT a render of LibraryRootView: ScreenshotLibraryComposition works around the same ScrollView limitation as ScreenshotSidebarComposition.

    func test_libraryDownloads() async {
        OrbitScreenshotFixtures.configure(env)
        LibraryRouter.shared.selectedSection = .downloads
        LibraryRouter.shared.selection = env.downloads.first(where: { $0.state == .completed }).map { .download($0.id) }
        let view = ScreenshotLibraryComposition(section: .downloads)
            .environment(env)
        await renderAndSave(
            view,
            name: "library-downloads",
            size: CGSize(width: LibraryMetrics.windowDefaultWidth, height: LibraryMetrics.windowDefaultHeight)
        )
    }

    func test_librarySpaces() async {
        OrbitScreenshotFixtures.configure(env)
        LibraryRouter.shared.selectedSection = .spaces
        let view = ScreenshotLibraryComposition(section: .spaces)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
        await renderAndSave(
            view,
            name: "library-spaces",
            size: CGSize(width: LibraryMetrics.windowDefaultWidth, height: LibraryMetrics.windowDefaultHeight)
        )
    }

    // The note's body is not shown: LibraryNotePreviewView puts its Text in a ScrollView, which ImageRenderer does not rasterise off-screen; only the preview column's chrome is visible here.
    func test_libraryEaselsAndNotes() async {
        OrbitScreenshotFixtures.configure(env)

        let note = env.noteStore.createNote(title: "Q4 launch notes")
        let body = NSMutableAttributedString()
        body.append(NSAttributedString(
            string: "Q4 launch notes\n",
            attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold)]
        ))
        body.append(NSAttributedString(
            string: "\nThe Library preview column renders the note's real decoded body, "
                + "not a thumbnail of it — the same NSAttributedString the editor wrote, "
                + "with its own per-run attributes intact.\n\nHeadings, weights and colours "
                + "set in the editor survive into the preview.",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ))
        if let encoded = NotesEditorView.encode(body) {
            env.noteStore.setBody(encoded, forNote: note.id)
        }

        LibraryRouter.shared.selectedSection = .easelsAndNotes
        LibraryRouter.shared.selection = .note(note.id)

        let view = ScreenshotLibraryComposition(section: .easelsAndNotes)
            .environment(env)
        await renderAndSave(
            view,
            name: "library-easels-notes",
            size: CGSize(width: LibraryMetrics.windowDefaultWidth, height: LibraryMetrics.windowDefaultHeight)
        )
    }

    // MARK: - Site Control Center
    // No real engine ever starts in this target, so env.activeWebContents/env.engine are nil after a plain configure(env); seedSiteControlPopover(_:) attaches mock engine/session/webContents so the rows gated on env.engine actually draw.
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

    // MARK: - New Space

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

    // MARK: - Shared window view

    private static let windowSize = CGSize(width: 1320, height: 840)

    private func windowView() -> some View {
        BrowserWindowView(skipOnboarding: true)
            .environment(env)
            .orbitScreenshotModeDragDisabledForTests()
    }

    // MARK: - Render + write, genuinely asserting
    // renderAndSave used to only log whether the PNG write succeeded, so a broken layout still
    // produced a valid-looking PNG and the suite stayed green.
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

    // MARK: - Pixel-sampled comparison, for the "two states of the same surface must differ" checks above

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

// MARK: - Screenshot-only sidebar composition (works around the ScrollView limitation)

/// SidebarView.standardContent(for:)'s body, reproduced here with its ScrollView swapped for a plain VStack since ImageRenderer does not rasterise ScrollView content off-screen; kept local to this file, not a #if DEBUG flag on SidebarView itself, so it cannot mask a real scrolling regression elsewhere.
private struct ScreenshotSidebarComposition: View {
    @Environment(AppEnvironment.self) private var env
    var space: Space

    var body: some View {
        let hasPinnedNodes = !env.pinnedNodes(in: space.id).isEmpty

        VStack(alignment: .leading, spacing: 0) {
            SidebarTopRow(theme: space.theme)
            // Order must match SidebarView.standardContent(for:) exactly, or
            // this composition stops being a screenshot of Orbit.
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

            // alwaysExpanded deviates from production: ImageRenderer has no pointer, so the
            // card's hovered two-row form could never be captured otherwise.
            SidebarMiniPlayerTray(theme: space.theme, alwaysExpanded: true)

            SidebarBottomBar(theme: space.theme)
                .padding(.bottom, OrbitMetrics.sidebarInterSectionGap)
        }
        .background {
            ThemeBackgroundView(theme: space.theme, blur: SpaceVisualPrefsStore.shared.blur(for: space.id))
        }
    }
}

/// LibraryRootView's body, reproduced here with its ScrollView swapped for a plain VStack (see ScreenshotSidebarComposition); the preview column's real content is always an NSViewRepresentable, which ImageRenderer cannot rasterise, so this renders the column's real frame and background and draws nothing into it.
private struct ScreenshotLibraryComposition: View {
    @Environment(AppEnvironment.self) private var env
    @State private var router = LibraryRouter.shared
    var section: LibrarySection

    private var counts: [LibrarySection: Int] {
        [
            .media: env.mediaStates.values.filter { $0.isMediaActive }.count,
            .downloads: env.downloads.count,
            .easelsAndNotes: env.noteStore.index.count + env.easelStore.index.count,
            .spaces: env.spaces.count,
            .boosts: env.boostStore.boosts.count,
            .archivedTabs: env.archivedTabs().count,
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebarView(selection: .constant(section), counts: counts)

            Rectangle()
                .fill(LibraryPalette.divider)
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(section.rawValue)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LibraryPalette.textPrimary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    LibrarySearchField(text: .constant(""), placeholder: "Search \(section.rawValue)")
                        .frame(maxWidth: LibraryMetrics.searchFieldMaxWidth)
                }
                .padding(.horizontal, LibraryMetrics.contentHorizontalPadding)
                .padding(.top, LibraryMetrics.contentTopPadding)
                .padding(.bottom, 12)

                if section.rendersItsOwnScrolling {
                    sectionList
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    sectionList
                        .padding(.horizontal, LibraryMetrics.contentHorizontalPadding)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                }
            }
            .frame(width: section.supportsPreview ? LibraryMetrics.listColumnWidth : nil, alignment: .top)
            .frame(maxWidth: section.supportsPreview ? nil : .infinity, maxHeight: .infinity, alignment: .top)
            .background(LibraryPalette.contentBackground)

            if section.supportsPreview {
                LibraryPreviewPaneView(selection: router.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LibraryPalette.contentBackground)
    }

    @ViewBuilder
    private var sectionList: some View {
        switch section {
        case .downloads: LibraryDownloadsView(searchQuery: "")
        case .easelsAndNotes: LibraryEaselsNotesView(searchQuery: "")
        case .media: LibraryMediaView(searchQuery: "")
        // ManageSpacesColumnsView directly: the host's only addition is a horizontal
        // ScrollView, which ImageRenderer cannot rasterise.
        case .spaces:
            ManageSpacesColumnsView(searchQuery: "", onAddSpace: {})
                .padding(.horizontal, LibraryMetrics.contentHorizontalPadding)
                .padding(.bottom, LibraryMetrics.contentHorizontalPadding)
        case .archivedTabs: LibraryArchivedTabsView(searchQuery: "")
        case .boosts: EmptyView()
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
        }
    }
}

// MARK: - Screenshot-only drag suppression, applied at the call site

private extension View {
    /// Despite the name this is the shared "suppress the thing ImageRenderer cannot flatten" flag: it also elides OrbitNSMenuButton/OrbitPopupButton's invisible NSViewRepresentable click-catchers, which otherwise rasterise as a solid block.
    func orbitScreenshotModeDragDisabledForTests() -> some View {
        #if DEBUG
        return self.environment(\.orbitScreenshotModeDragDisabled, true)
        #else
        return self
        #endif
    }
}
