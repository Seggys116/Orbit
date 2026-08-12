//  Writes PNGs to a scratch directory outside the repository, for human review --
//  not part of the refs/screenshots/ set Scripts/screenshots regenerates.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class TearOffAndLittleWindowAppearanceTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private static let outputDirectory = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-zaknoble-clarke-Projects-XCode-Orbit/07ecceb8-e922-481a-9eb4-887b7efcb973/scratchpad",
        isDirectory: true
    )

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
        PeekState.shared.dismiss()
    }

    // MARK: - 1. The little window's chrome, at the window's own default size

    func test_littleWindowChrome_darkPageThemeColour() async throws {
        let tab = try makeLittleOrbitTab()
        env.themeColors[tab.id] = ThemeColor(red: 0.05, green: 0.07, blue: 0.09)

        let rendered = await renderAndSave(
            LittleWindowChromeReplica(tab: tab)
                .environment(env)
                .orbitScreenshotModeSuppressedForTests(),
            name: "little-window-dark-theme-colour",
            size: LittleOrbitWindowController.defaultSize
        )

        assertHeaderIsTinted(rendered, expected: ThemeColor(red: 0.05, green: 0.07, blue: 0.09))
    }

    func test_littleWindowChrome_lightPageThemeColour() async throws {
        let tab = try makeLittleOrbitTab()
        env.themeColors[tab.id] = ThemeColor(red: 0.86, green: 0.88, blue: 0.98)

        let rendered = await renderAndSave(
            LittleWindowChromeReplica(tab: tab)
                .environment(env)
                .orbitScreenshotModeSuppressedForTests(),
            name: "little-window-light-theme-colour",
            size: LittleOrbitWindowController.defaultSize
        )

        assertHeaderIsTinted(rendered, expected: ThemeColor(red: 0.86, green: 0.88, blue: 0.98))
    }

    private func makeLittleOrbitTab() throws -> Orbit.Tab {
        let spaceID = try XCTUnwrap(env.state.spaces.first?.id, "AppEnvironment.demo seeds at least one Space")
        var tab = Orbit.Tab(
            spaceID: spaceID,
            section: .today,
            url: try XCTUnwrap(URL(string: "https://developer.apple.com/documentation/swiftui/imagerenderer")),
            title: "ImageRenderer | Apple Developer Documentation"
        )
        tab.splitIndex = 0
        env.state.tabs[tab.id] = tab
        env.navigationStates[tab.id] = NavigationState(
            url: tab.url,
            title: tab.title,
            canGoBack: true,
            canGoForward: true,
            security: .secure
        )
        return tab
    }

    private func assertHeaderIsTinted(_ rendered: RenderedImage, expected: ThemeColor) {
        let headerTop = OrbitMetrics.cardInset
        let probe = CGRect(
            x: OrbitMetrics.cardInset
                + OrbitToolbarMetrics.leadingPadding
                + ToolbarPaneCapabilities.littleOrbitWindow.leadingInset
                + OrbitToolbarMetrics.navClusterWidth
                + 8,
            y: headerTop + 2,
            width: 40,
            height: OrbitToolbarMetrics.topPadding + 2
        )
        let sampled = rendered.averageColor(in: probe)
        let want = RGBA(r: expected.red, g: expected.green, b: expected.blue, a: 1)
        XCTAssertTrue(
            sampled.isApproximately(want, tolerance: 0.06),
            "The little window's pane header did not take the page's own theme colour: sampled \(sampled) in \(probe), expected ~\(want). The header is ToolbarView's, tinted from env.themeColors[tab.id] — LittleOrbitWindowController.swift's header states this window's chrome must colour itself from the page exactly as the main window's pane does."
        )
    }

    // MARK: - 2. The torn-off window's sidebar (`TornOffWindowBar` present)

    func test_tornOffWindowSidebar_showsTheTemporaryBar() async throws {
        let host = env
        let originTabID = try seedOriginTab(in: host)
        let session = try XCTUnwrap(
            WindowSession.tornOff(on: host, adopting: originTabID),
            "WindowSession.tornOff must produce a session for a real tab — this render has nothing to show otherwise."
        )
        defer { session.dispose() }

        let tornOffEnv = session.environment
        let space = try XCTUnwrap(tornOffEnv.activeSpace, "a torn-off session owns exactly one Space")
        XCTAssertTrue(
            tornOffEnv.isTornOffWindow(for: space),
            "precondition: this environment must report itself torn-off, or the bar under test is correctly absent and this image proves nothing."
        )

        let rendered = await renderAndSave(
            sidebar(for: space, in: tornOffEnv),
            name: "torn-off-sidebar",
            size: CGSize(width: tornOffEnv.sidebarWidth, height: 900)
        )

        let band = tornOffBarBand
        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: band, background: rendered.averageColor(in: band.offsetBy(dx: 0, dy: -band.height)), tolerance: 0.02),
            "Nothing is painted where TornOffWindowBar should be (\(band)) — a torn-off window would give the user no indication its tabs close with it."
        )
    }

    func test_ordinarySidebar_hasNoTemporaryBar() async throws {
        let space = try XCTUnwrap(env.activeSpace, "AppEnvironment.demo seeds an active Space")
        XCTAssertFalse(env.isTornOffWindow(for: space), "precondition: this is an ordinary window's environment")

        _ = await renderAndSave(
            sidebar(for: space, in: env),
            name: "ordinary-sidebar",
            size: CGSize(width: env.sidebarWidth, height: 900)
        )
    }

    func test_theTemporaryBarAppearsOnlyInTheTornOffCase() async throws {
        let host = env
        let originTabID = try seedOriginTab(in: host)
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        defer { session.dispose() }
        let tornOffEnv = session.environment
        let tornOffSpace = try XCTUnwrap(tornOffEnv.activeSpace)
        let ordinarySpace = try XCTUnwrap(host.activeSpace)

        let size = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: 900)
        let tornOff = await renderForScreenshot(sidebar(for: tornOffSpace, in: tornOffEnv), size: size)
        let ordinary = await renderForScreenshot(sidebar(for: ordinarySpace, in: host), size: size)

        func luminance(_ c: RGBA) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        let band = tornOffBarBand
        let tornOffLuminance = luminance(tornOff.averageColor(in: band))
        let ordinaryLuminance = luminance(ordinary.averageColor(in: band))

        XCTAssertGreaterThan(
            abs(tornOffLuminance - ordinaryLuminance), 0.01,
            """
            The band directly under SpaceTitleRow renders identically (luminance \(tornOffLuminance) vs \(ordinaryLuminance)) \
            in a torn-off window and an ordinary one. Either TornOffWindowBar is not being drawn at all, or it is being \
            drawn in both — SidebarView gates it on env.isTornOffWindow(for: space) precisely so it appears in one and not \
            the other.
            """
        )
    }

    private var tornOffBarBand: CGRect {
        let y = OrbitMetrics.sidebarTopRowHeight + OrbitMetrics.sidebarRowHeight
        return CGRect(
            x: OrbitMetrics.sidebarHorizontalPadding + 2,
            y: y + 2,
            width: OrbitMetrics.sidebarDefaultWidth - (OrbitMetrics.sidebarHorizontalPadding + 2) * 2,
            height: 22
        )
    }

    private func sidebar(for space: Space, in environment: AppEnvironment) -> some View {
        SidebarView(space: space)
            .environment(environment)
            .background {
                ThemeBackgroundView(theme: space.theme, blur: SpaceVisualPrefsStore.shared.blur(for: space.id))
            }
            .orbitScreenshotModeSuppressedForTests()
    }

    private func seedOriginTab(in host: AppEnvironment) throws -> TabID {
        let spaceID = try XCTUnwrap(host.state.spaces.first?.id)
        host.state.activeSpaceID = spaceID
        return host.openTab(url: try XCTUnwrap(URL(string: "https://origin.example.com/logged-in")), in: spaceID)
    }

    // MARK: - 3. Source-level guards: the replica still matches what ships

    func test_littleWindowReplica_stillMatchesTheShippingComposition() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Orbit/UI/Window/LittleOrbitWindowController.swift"),
            encoding: .utf8
        )

        let required: [(String, String)] = [
            ("ToolbarView(tab: tab, paneCapabilities: .littleOrbitWindow)",
             "the pane header must be the real, shared ToolbarView with the little-window preset — traffic-light gutter and Open in Orbit both real"),
            (".paneCardChrome(isFocused: false)",
             "the pane must carry the same rounded/bordered card chrome every main-window pane does, unfocused"),
            (".padding(OrbitMetrics.cardInset)",
             "the pane card must be inset by cardInset on every side, exactly as SingleTabContentView insets a lone pane"),
            ("WindowControlsView()",
             "the window's own traffic lights must be the real, shared WindowControlsView — never a reproduction"),
            (".padding(.leading, OrbitMetrics.cardInset + OrbitWindowControlMetrics.leadingInset)",
             "the traffic lights' leading placement must be cardInset (the pane card's own inset) plus the same leading inset PositionedWindowControls uses for the main window, not a re-guessed literal"),
            (".padding(.top, OrbitMetrics.cardInset + windowControlsTopInset)",
             "the traffic lights must be vertically centred against ToolbarView's own totalHeight band, offset by the pane card's own cardInset — not the sidebar's unrelated band"),
            (".background(Color(nsColor: .windowBackgroundColor))",
             "the window's own surround behind the pane card"),
            ("window.standardWindowButton(.closeButton)?.isHidden = true",
             "the real AppKit close button must be hidden, never removed, so Cmd+W and Mission Control still work"),
            ("window.standardWindowButton(.miniaturizeButton)?.isHidden = true",
             "the real AppKit miniaturize button must be hidden"),
            ("window.standardWindowButton(.zoomButton)?.isHidden = true",
             "the real AppKit zoom button must be hidden"),
        ]
        for (needle, why) in required {
            XCTAssertTrue(
                source.contains(needle),
                "LittleOrbitWindowController.swift no longer contains `\(needle)` — \(why). LittleWindowChromeReplica in this file reproduces that exact composition, so the PNGs this suite writes no longer show what the little window actually looks like."
            )
        }

        XCTAssertFalse(
            source.contains("private var controlStrip: some View"),
            "LittleOrbitWindowController.swift still declares `controlStrip` — the two-row composition this suite's PNGs are supposed to prove was replaced by a single header row is still present."
        )

        let overlay = try XCTUnwrap(
            source.range(of: "            paneCard\n                .overlay(alignment: .topLeading) { windowControlsOverlay }"),
            "LittleOrbitView.body no longer overlays windowControlsOverlay directly on paneCard — the single-row composition this suite's PNGs are evidence for no longer matches what ships."
        )
        XCTAssertFalse(overlay.isEmpty)
    }

    func test_aTornOffWindowRendersNoSpaceIdentity_noTitleRow_andNoSpaceDot() throws {
        let sidebar = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Orbit/UI/Sidebar/SidebarView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            sidebar.contains("if !env.isTornOffWindow(for: space) {\n                SpaceTitleRow(space: space)"),
            "SidebarView must gate SpaceTitleRow out of a torn-off window. Without that gate the ephemeral Space's name — which is the torn tab's title, not anything the user named — renders as a Space identity, which is exactly what the user asked to remove."
        )

        let gate = try XCTUnwrap(
            sidebar.range(of: "if env.isTornOffWindow(for: space) {"),
            "SidebarView no longer gates anything on env.isTornOffWindow(for:) — the torn-off sidebar render in this file is measuring an unconditional row, or nothing at all."
        )
        let bar = try XCTUnwrap(
            sidebar.range(of: "TornOffWindowBar(theme: space.theme)"),
            "SidebarView no longer mounts TornOffWindowBar, so a torn-off window says nothing about being temporary."
        )
        let favourites = try XCTUnwrap(
            sidebar.range(of: "FavoritesGridView(spaceID: space.id, theme: space.theme)"),
            "SidebarView no longer renders FavoritesGridView"
        )

        XCTAssertTrue(
            gate.upperBound < bar.lowerBound && bar.upperBound < favourites.lowerBound,
            "TornOffWindowBar must still sit above Favourites — with the Space title row gone it is now the torn-off window's leading row, and `tornOffBarBand` in this file probes exactly that band."
        )

        let bottomBar = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Orbit/UI/Sidebar/SidebarBottomBar.swift"),
            encoding: .utf8
        )
        let dotGate = try XCTUnwrap(
            bottomBar.range(of: "if env.isTornOffWindow {"),
            "SidebarBottomBar no longer suppresses the Space pager in a torn-off window, so the Space dot the user asked to remove is back."
        )
        let pager = try XCTUnwrap(bottomBar.range(of: "pagerRegion"), "SidebarBottomBar no longer references pagerRegion at all")
        XCTAssertTrue(
            dotGate.lowerBound < pager.lowerBound,
            "The torn-off suppression must gate pagerRegion, not follow it."
        )
        XCTAssertTrue(
            bottomBar.contains("Spacer(minLength: OrbitMetrics.sidebarBottomBarSpacing)"),
            "Removing the greedy GeometryReader without a Spacer in its place collapses libraryButton and newItemMenu together — see pagerRegion's own doc comment on why it is what centres this row."
        )
    }

    // MARK: - Render + write

    @discardableResult
    private func renderAndSave(
        _ view: some View,
        name: String,
        size: CGSize,
        appearance: NSAppearance.Name = .darkAqua
    ) async -> RenderedImage {
        let rendered = await renderForScreenshot(view, size: size, appearance: appearance)
        let destination = Self.outputDirectory.appendingPathComponent("\(name).png")
        if rendered.writePNG(to: destination) {
            print("TearOffAndLittleWindowAppearanceTests: wrote \(name).png (\(Int(size.width))x\(Int(size.height))pt @2x) to \(destination.path)")
        } else {
            XCTFail("TearOffAndLittleWindowAppearanceTests: could not write \(name).png to \(destination.path) — there is no image to review.")
        }
        return rendered
    }
}

// MARK: - The little window's composition, reproduced

/// Reproduces `LittleOrbitView`'s body, which is `private` to its own file; kept
/// in sync by `test_littleWindowReplica_stillMatchesTheShippingComposition`.
private struct LittleWindowChromeReplica: View {
    @Environment(AppEnvironment.self) private var env
    var tab: Orbit.Tab

    var body: some View {
        ZStack {
            paneCard
                .overlay(alignment: .topLeading) { windowControlsOverlay }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: LittleOrbitWindowController.minimumSize.width,
            minHeight: LittleOrbitWindowController.minimumSize.height
        )
    }

    private var windowControlsOverlay: some View {
        WindowControlsView()
            .padding(.leading, OrbitMetrics.cardInset + OrbitWindowControlMetrics.leadingInset)
            .padding(.top, OrbitMetrics.cardInset + (OrbitToolbarMetrics.totalHeight - OrbitWindowControlMetrics.diameter) / 2)
    }

    private var paneCard: some View {
        VStack(spacing: 0) {
            ToolbarView(tab: tab, paneCapabilities: .littleOrbitWindow)
            paneContent
        }
        .paneCardChrome(isFocused: false)
        .padding(OrbitMetrics.cardInset)
    }

    @ViewBuilder
    private var paneContent: some View {
        if env.crashedTabs.contains(tab.id) {
            CrashedTabView { }
        } else if let problem = env.certificateProblems[tab.id] {
            CertificateInterstitialView(tabID: tab.id, problem: problem)
        } else if let error = env.tabErrors[tab.id] {
            ErrorPageView(error: error) { }
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }
}

// MARK: - Screenshot-only representable suppression

private extension View {
    func orbitScreenshotModeSuppressedForTests() -> some View {
        #if DEBUG
        return self.environment(\.orbitScreenshotModeDragDisabled, true)
        #else
        return self
        #endif
    }
}
