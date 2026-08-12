import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class PaneChromeTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
    }

    // MARK: - Fixtures

    // `Tab` alone is ambiguous here: this file also imports SwiftUI, which
    // declares its own `SwiftUI.Tab` — always qualify as `Orbit.Tab`.
    private func makeTab(url: String = "https://example.com") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
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

    // MARK: - 1. Header background equals the tab's theme colour

    func test_headerBackground_equalsTabsThemeColorWhenSet() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }
        let color = ThemeColor(red: 0.5, green: 0.28, blue: 0.74)
        env.themeColors[tab.id] = color

        let size = CGSize(width: 400, height: OrbitToolbarMetrics.totalHeight)
        let rendered = render(ToolbarView(tab: tab).environment(env), size: size)

        let sampled = rendered.color(atX: 2, y: 2)

        // The harness' ImageRenderer pipeline runs colours through its own colour-management round trip, so compare against the same render/sample path, not the raw ThemeColor components.
        let referenceSwatch = render(
            Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha),
            size: size
        )
        let expected = referenceSwatch.color(atX: 2, y: 2)

        if !sampled.isApproximately(expected, tolerance: 0.03) {
            rendered.writeDiagnosticPNG(named: "headerBackground-equalsThemeColor-FAILED")
        }
        XCTAssertTrue(
            sampled.isApproximately(expected, tolerance: 0.03),
            "refs/ARC_PANE_CHROME.md: expected the pane header's background to equal the tab's resolved theme colour (rendered reference: \(expected)), found \(sampled)."
        )
    }

    // MARK: - 2. Glyph colour flips at the luminance threshold

    func test_glyphColor_flipsAtLuminanceThreshold_forLightAndDarkPages() {
        let darkTab = makeTab(url: "https://dark.example.com")
        let lightTab = makeTab(url: "https://light.example.com")
        defer { cleanup([darkTab.id, lightTab.id]) }

        let darkColor = ThemeColor(red: 0.05, green: 0.05, blue: 0.08)
        let lightColor = ThemeColor(red: 0.95, green: 0.95, blue: 0.97)
        XCTAssertLessThan(darkColor.luminance, 0.5, "Test precondition: darkColor must sit below ThemeColor.luminance's 0.5 threshold.")
        XCTAssertGreaterThan(lightColor.luminance, 0.5, "Test precondition: lightColor must sit above ThemeColor.luminance's 0.5 threshold.")

        env.themeColors[darkTab.id] = darkColor
        env.themeColors[lightTab.id] = lightColor

        let size = CGSize(width: 400, height: OrbitToolbarMetrics.totalHeight)
        let darkRendered = render(ToolbarView(tab: darkTab).environment(env), size: size)
        let lightRendered = render(ToolbarView(tab: lightTab).environment(env), size: size)

        let refreshCenterX = OrbitToolbarMetrics.leadingPadding
            + OrbitToolbarMetrics.navIconSize * 2.5
            + OrbitToolbarMetrics.navIconSpacing * 2
        let iconRect = CGRect(x: refreshCenterX - 6, y: OrbitToolbarMetrics.topPadding + OrbitToolbarMetrics.height / 2 - 6, width: 12, height: 12)
        let backgroundRect = CGRect(x: 260, y: OrbitToolbarMetrics.topPadding + 4, width: 24, height: OrbitToolbarMetrics.height - 8)

        func luminance(_ c: RGBA) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

        let darkIconLuminance = luminance(darkRendered.averageColor(in: iconRect))
        let darkBackgroundLuminance = luminance(darkRendered.averageColor(in: backgroundRect))
        let lightIconLuminance = luminance(lightRendered.averageColor(in: iconRect))
        let lightBackgroundLuminance = luminance(lightRendered.averageColor(in: backgroundRect))

        if darkIconLuminance <= darkBackgroundLuminance + 0.03 {
            darkRendered.writeDiagnosticPNG(named: "glyphColor-darkPage-FAILED")
        }
        XCTAssertGreaterThan(
            darkIconLuminance, darkBackgroundLuminance + 0.03,
            "refs/ARC_PANE_CHROME.md: over a dark header (luminance \(darkColor.luminance)), the refresh glyph should read as light/white — expected the icon rect's luminance (\(darkIconLuminance)) to be noticeably brighter than the surrounding background's (\(darkBackgroundLuminance))."
        )

        if lightIconLuminance >= lightBackgroundLuminance - 0.03 {
            lightRendered.writeDiagnosticPNG(named: "glyphColor-lightPage-FAILED")
        }
        XCTAssertLessThan(
            lightIconLuminance, lightBackgroundLuminance - 0.03,
            "refs/ARC_PANE_CHROME.md: over a light header (luminance \(lightColor.luminance)), the refresh glyph should read as dark/black — expected the icon rect's luminance (\(lightIconLuminance)) to be noticeably darker than the surrounding background's (\(lightBackgroundLuminance))."
        )
    }

    // MARK: - 2b. A colour that resolves *after* the first render still lands

    func test_aColourResolvedAfterTheFirstRender_repaintsTheHeaderAndItsGlyphsTogether() async {
        let tab = makeTab(url: "https://resolves-late.example.com")
        defer { cleanup([tab.id]) }

        let page = MockWebContents()
        var reads = 0
        page.evaluateJavaScriptHandler = { _ in
            reads += 1
            if reads < 4 { return ["color": NSNull(), "ready": false] }
            return ["color": "#ffffff", "ready": true]
        }
        env._test_attachWebContents(page, for: tab.id)
        defer { env._test_detachWebContents(for: tab.id) }

        let size = CGSize(width: 400, height: OrbitToolbarMetrics.totalHeight)
        let host = NSHostingView(rootView: ToolbarView(tab: tab).environment(env))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        try? await Task.sleep(for: .milliseconds(150))
        env.navigationStates[tab.id] = NavigationState(url: tab.url, canGoBack: true)

        try? await Task.sleep(for: .milliseconds(1600))
        XCTAssertNotNil(
            PaneHeaderColorResolver.shared.cachedColor(for: tab.url),
            "Test precondition: the header's own .task must have sampled the stubbed page by now."
        )

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Could not create a bitmap to capture the hosted header into.")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let scale = Double(rep.pixelsWide) / Double(size.width)
        func luminance(atX x: Double, y: Double) -> Double? {
            guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return nil }
            return 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
        }

        guard let backgroundLuminance = luminance(atX: 270, y: Double(OrbitToolbarMetrics.topPadding) + 4) else {
            XCTFail("Could not sample the header's background.")
            return
        }

        XCTAssertGreaterThan(
            backgroundLuminance, 0.5,
            """
            The page resolved to white, so the header must be painting white. \
            Found luminance \(backgroundLuminance) — the header is still on its \
            neutral fallback, i.e. the resolved colour reached the view's glyph \
            colours without ever reaching its background fill. That is the \
            reported defect: a header 'hidden' against the window chrome while \
            its text is coloured as though it were not.
            """
        )

        let refreshCenterX = Double(OrbitToolbarMetrics.leadingPadding)
            + Double(OrbitToolbarMetrics.navIconSize) * 2.5
            + Double(OrbitToolbarMetrics.navIconSpacing) * 2
        let glyphY = Double(OrbitToolbarMetrics.topPadding) + Double(OrbitToolbarMetrics.height) / 2
        var darkestGlyphLuminance = 1.0
        for offset in stride(from: -5.0, through: 5.0, by: 0.5) {
            for dy in stride(from: -5.0, through: 5.0, by: 0.5) {
                if let l = luminance(atX: refreshCenterX + offset, y: glyphY + dy) {
                    darkestGlyphLuminance = min(darkestGlyphLuminance, l)
                }
            }
        }

        XCTAssertLessThan(
            darkestGlyphLuminance, backgroundLuminance - 0.1,
            "refs/ARC_PANE_CHROME.md point 4: over the light colour the header actually painted (\(backgroundLuminance)), the glyphs must read dark — found \(darkestGlyphLuminance)."
        )
    }

    // MARK: - 2c. The header keeps following the page for the document's life

    func test_aPageThatChangesColourWithoutNavigating_repaintsTheHeaderAndItsGlyphsEveryTime() async {
        let tab = makeTab(url: "https://changes-colour-in-place.example.com")
        defer { cleanup([tab.id]) }

        let size = CGSize(width: 400, height: OrbitToolbarMetrics.totalHeight)
        let host = NSHostingView(rootView: ToolbarView(tab: tab).environment(env))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let refreshCenterX = Double(OrbitToolbarMetrics.leadingPadding)
            + Double(OrbitToolbarMetrics.navIconSize) * 2.5
            + Double(OrbitToolbarMetrics.navIconSpacing) * 2
        let glyphY = Double(OrbitToolbarMetrics.topPadding) + Double(OrbitToolbarMetrics.height) / 2

        func settleAndSample(_ color: ThemeColor) async -> (background: Double, darkestGlyph: Double)? {
            env.themeColors[tab.id] = color
            try? await Task.sleep(for: .milliseconds(900))

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = Double(rep.pixelsWide) / Double(size.width)
            func luminance(atX x: Double, y: Double) -> Double? {
                guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return nil }
                return 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
            }
            guard let background = luminance(atX: 270, y: Double(OrbitToolbarMetrics.topPadding) + 4) else { return nil }
            var darkest = 1.0
            var brightest = 0.0
            for dx in stride(from: -5.0, through: 5.0, by: 0.5) {
                for dy in stride(from: -5.0, through: 5.0, by: 0.5) {
                    if let l = luminance(atX: refreshCenterX + dx, y: glyphY + dy) {
                        darkest = min(darkest, l)
                        brightest = max(brightest, l)
                    }
                }
            }
            let glyph = abs(darkest - background) > abs(brightest - background) ? darkest : brightest
            return (background, glyph)
        }

        guard let light = await settleAndSample(ThemeColor(red: 1, green: 1, blue: 1)) else {
            XCTFail("Could not sample the header after the page's first colour.")
            return
        }
        XCTAssertGreaterThan(light.background, 0.5, "The page is white, so the header must paint light. Found \(light.background).")
        XCTAssertLessThan(
            light.darkestGlyph, light.background - 0.1,
            "Over a light header the glyphs must read dark — found glyph \(light.darkestGlyph) against background \(light.background)."
        )

        guard let dark = await settleAndSample(ThemeColor(red: 0x0D / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0)) else {
            XCTFail("Could not sample the header after the page changed colour.")
            return
        }
        XCTAssertLessThan(
            dark.background, 0.5,
            """
            The page went dark without navigating and the header did not follow. \
            Found luminance \(dark.background), still on the light colour it \
            resolved first. This is the reported defect: the colour "should be \
            adaptive and not just focus purely on the first result".
            """
        )
        XCTAssertGreaterThan(
            dark.darkestGlyph, dark.background + 0.1,
            "Over the dark colour the header now paints (\(dark.background)), the glyphs must have flipped to light — found \(dark.darkestGlyph). A background that followed while the glyphs did not is the exact 'hidden header' defect 2b exists for."
        )

        guard let lightAgain = await settleAndSample(ThemeColor(red: 0.95, green: 0.95, blue: 0.97)) else {
            XCTFail("Could not sample the header after the page changed colour a second time.")
            return
        }
        XCTAssertGreaterThan(
            lightAgain.background, 0.5,
            "The header must keep following the page for the document's whole life, not only across its first change. Found \(lightAgain.background)."
        )
        XCTAssertLessThan(
            lightAgain.darkestGlyph, lightAgain.background - 0.1,
            "And the glyphs must flip back with it — found \(lightAgain.darkestGlyph) against \(lightAgain.background)."
        )
    }

    func test_aPageThatChangesColour_movesTheScrollerAndTheHeaderTogether() {
        let sequence: [ThemeColor] = [
            ThemeColor(red: 1, green: 1, blue: 1),
            ThemeColor(red: 0x0D / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0),
            ThemeColor(red: 0.95, green: 0.95, blue: 0.97),
        ]
        let expectedSchemes: [PageColorSchemeScript.Scheme] = [.light, .dark, .light]

        for (color, expected) in zip(sequence, expectedSchemes) {
            XCTAssertEqual(
                PageColorSchemeScript.scheme(for: color), expected,
                "At page colour \(color) the scroller must declare \(expected)."
            )
            let headerSaysLight = PaneHeaderColorResolver.foreground(for: color) == .dark
            XCTAssertEqual(
                headerSaysLight, expected == .light,
                "The header and the scroller disagreed about whether \(color) is a light page — they must come out of the same luminance rule at every step of a live sequence, not only at first paint."
            )
        }
    }

    // MARK: - 3. Each pane in a split reflects its own tab's navigation state

    func test_twoPaneSplit_eachHeaderReflectsItsOwnTabsNavigationState() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }

        env.isSidebarVisible = true
        defer { env.isSidebarVisible = true }

        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group between tabA and tabB.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        env.navigationStates[tabA.id] = NavigationState(url: tabA.url, canGoBack: true)
        env.navigationStates[tabB.id] = NavigationState(url: tabB.url, canGoBack: false)
        defer {
            env.navigationStates.removeValue(forKey: tabA.id)
            env.navigationStates.removeValue(forKey: tabB.id)
        }

        let totalWidth: CGFloat = 400
        let rendered = render(
            SplitViewContainer(rootTabID: tabA.id).environment(env).environment(\.orbitScreenshotModeDragDisabled, true),
            size: CGSize(width: totalWidth, height: 200)
        )

        let dividerCount = 1
        let available = totalWidth - CGFloat(dividerCount) * OrbitMetrics.splitDividerThickness
        let paneWidth = available / 2
        let paneBSlotStartX = paneWidth + OrbitMetrics.splitDividerThickness
        let paneBContentStartX = paneBSlotStartX + OrbitSplitPaneMetrics.paneGap

        let iconY = OrbitToolbarMetrics.topPadding + (OrbitToolbarMetrics.height - OrbitToolbarMetrics.navIconSize) / 2
        func backIconRect(contentStartX: CGFloat) -> CGRect {
            CGRect(x: contentStartX + OrbitToolbarMetrics.leadingPadding, y: iconY, width: OrbitToolbarMetrics.navIconSize, height: OrbitToolbarMetrics.navIconSize)
        }
        let paneARect = backIconRect(contentStartX: 0)
        let paneBRect = backIconRect(contentStartX: paneBContentStartX)

        func luminance(_ c: RGBA) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

        let barRect = CGRect(
            x: OrbitToolbarMetrics.leadingPadding / 4,
            y: iconY,
            width: OrbitToolbarMetrics.leadingPadding / 2,
            height: OrbitToolbarMetrics.navIconSize
        )
        let barLuminance = luminance(rendered.averageColor(in: barRect))
        let paneAIconLuminance = luminance(rendered.averageColor(in: paneARect))
        let paneBIconLuminance = luminance(rendered.averageColor(in: paneBRect))
        let paneAContrast = abs(paneAIconLuminance - barLuminance)
        let paneBContrast = abs(paneBIconLuminance - barLuminance)

        if paneAContrast <= paneBContrast {
            rendered.writeDiagnosticPNG(named: "splitPanes-perPaneNavigationState-FAILED")
        }
        XCTAssertGreaterThan(
            paneAContrast, paneBContrast,
            "refs/ARC_PANE_CHROME.md point 2: pane A (canGoBack == true) should render its back icon with more contrast against the shared header bar than pane B's dimmed one (canGoBack == false) — got bar luminance \(barLuminance), pane A \(paneAIconLuminance) (contrast \(paneAContrast)), pane B \(paneBIconLuminance) (contrast \(paneBContrast)). If both panes render identically, the header is reading a single shared/active tab's state instead of each pane's own."
        )
    }

    // MARK: - 4. The focused pane's border differs from the unfocused pane's

    func test_splitPane_focusedBorderDiffersFromUnfocused() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }

        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group between tabA and tabB.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        let size = CGSize(width: 600, height: 200)
        let dividerCount = 1
        let available = size.width - CGFloat(dividerCount) * OrbitMetrics.splitDividerThickness
        let paneAWidth = available / 2
        let paneARightEdge = paneAWidth - OrbitSplitPaneMetrics.paneGap
        let borderRect = CGRect(x: paneARightEdge - 6, y: 90, width: 5, height: 20)

        func renderPane() -> RenderedImage {
            var view = AnyView(SplitViewContainer(rootTabID: tabA.id).environment(env))
            #if DEBUG
            view = AnyView(view.environment(\.orbitScreenshotModeDragDisabled, true))
            #endif
            return render(view, size: size)
        }

        env.focusedSplitPaneIndex = 0
        let paneAFocused = renderPane()
        let focusedBorderColor = paneAFocused.averageColor(in: borderRect)

        env.focusedSplitPaneIndex = 1
        let paneAUnfocused = renderPane()
        let unfocusedBorderColor = paneAUnfocused.averageColor(in: borderRect)
        env.focusedSplitPaneIndex = 0

        if focusedBorderColor.isApproximately(unfocusedBorderColor, tolerance: 0.03) {
            paneAFocused.writeDiagnosticPNG(named: "splitPane-focusedBorder-FAILED-focused")
            paneAUnfocused.writeDiagnosticPNG(named: "splitPane-focusedBorder-FAILED-unfocused")
        }
        XCTAssertFalse(
            focusedBorderColor.isApproximately(unfocusedBorderColor, tolerance: 0.03),
            "refs/ARC_PANE_CHROME.md point 5: pane A's own border should visibly differ between env.focusedSplitPaneIndex == 0 (focused: \(focusedBorderColor)) and == 1 (unfocused: \(unfocusedBorderColor)) — they rendered as the same colour."
        )
    }

    // MARK: - 5. The pane header renders in every sidebar state (reverted regression)

    func test_paneHeader_rendersInBothSidebarStates() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }
        let headerColor = ThemeColor(red: 0.92, green: 0.08, blue: 0.55)
        env.themeColors[tab.id] = headerColor

        let size = CGSize(width: 400, height: 200)
        let headerBandRect = CGRect(x: 4, y: 2, width: size.width - 8, height: 16)

        env.isSidebarVisible = false
        let sidebarHidden = render(SingleTabContentView(tab: tab, isFocusedPane: true).environment(env).environment(\.orbitScreenshotModeDragDisabled, true), size: size)
        let sidebarHiddenColor = sidebarHidden.averageColor(in: headerBandRect)

        env.isSidebarVisible = true
        let sidebarVisible = render(SingleTabContentView(tab: tab, isFocusedPane: true).environment(env).environment(\.orbitScreenshotModeDragDisabled, true), size: size)
        let sidebarVisibleColor = sidebarVisible.averageColor(in: headerBandRect)

        if !sidebarHiddenColor.isApproximately(sidebarVisibleColor, tolerance: 0.06) {
            sidebarHidden.writeDiagnosticPNG(named: "paneHeader-sidebarHidden-FAILED")
            sidebarVisible.writeDiagnosticPNG(named: "paneHeader-sidebarVisible-FAILED")
        }
        XCTAssertTrue(
            sidebarHiddenColor.isApproximately(sidebarVisibleColor, tolerance: 0.06),
            "refs/ARC_PANE_CHROME.md: expected the pane's top band to render the same header regardless of env.isSidebarVisible (hidden: \(sidebarHiddenColor), visible: \(sidebarVisibleColor)) — they rendered as different colours, meaning the header is being suppressed in one sidebar state."
        )

        let referenceSwatch = render(
            Color(.sRGB, red: headerColor.red, green: headerColor.green, blue: headerColor.blue, opacity: headerColor.alpha),
            size: size
        )
        let expectedHeaderColor = referenceSwatch.averageColor(in: headerBandRect)
        XCTAssertTrue(
            sidebarHiddenColor.isApproximately(expectedHeaderColor, tolerance: 0.06),
            "Expected the sidebar-hidden pane's header band (\(sidebarHiddenColor)) to match the tab's own theme colour (\(expectedHeaderColor))."
        )
        XCTAssertTrue(
            sidebarVisibleColor.isApproximately(expectedHeaderColor, tolerance: 0.06),
            "Expected the sidebar-visible pane's header band (\(sidebarVisibleColor)) to match the tab's own theme colour (\(expectedHeaderColor)) — the header must not disappear or change colour when the sidebar is shown."
        )
    }

    // MARK: - 6. Content card inset is uniform on all four edges, both sidebar states

    func test_contentCard_insetIsUniformOnAllFourEdges_bothSidebarStates() {
        PeekState.shared.dismiss()

        let spaceColor = ThemeColor(red: 0.93, green: 0.16, blue: 0.55)
        let theme = SpaceTheme(style: .solid, colors: [spaceColor], grain: 0)
        let profileID = env.createDefaultProfileIfNeeded()
        let spaceID = env.createSpace(name: "Inset Test Space", icon: "circle", iconIsEmoji: false, theme: theme, profileID: profileID)
        let originalActiveSpaceID = env.state.activeSpaceID
        defer {
            env.state.activeSpaceID = originalActiveSpaceID
            env.deleteSpace(spaceID)
        }
        env.state.activeSpaceID = spaceID

        let backgroundReference = RGBA(r: spaceColor.red, g: spaceColor.green, b: spaceColor.blue, a: 1)
        let size = CGSize(width: 900, height: 600)
        let tolerance = 0.12

        for sidebarVisible in [true, false] {
            env.isSidebarVisible = sidebarVisible
            var windowView = AnyView(BrowserWindowView(skipOnboarding: true).environment(env))
            #if DEBUG
            windowView = AnyView(windowView.environment(\.orbitScreenshotModeDragDisabled, true))
            #endif
            let rendered = render(windowView, size: size)

            let contentColumnLeadingX = sidebarVisible ? Int((env.sidebarWidth + OrbitMetrics.sidebarResizeHandleWidth).rounded()) : 0
            let verticalScanX = (contentColumnLeadingX + Int(size.width)) / 2
            let horizontalScanY = Int(size.height) / 2

            func firstNonBackground(from: Int, to: Int, fixed: Int, horizontal: Bool) -> Int? {
                let steps = from <= to ? Array(stride(from: from, through: to, by: 1)) : Array(stride(from: from, through: to, by: -1))
                for value in steps {
                    let sample = horizontal ? rendered.color(atX: value, y: fixed) : rendered.color(atX: fixed, y: value)
                    if !sample.isApproximately(backgroundReference, tolerance: tolerance) {
                        return value
                    }
                }
                return nil
            }

            guard
                let cardTopY = firstNonBackground(from: 0, to: Int(size.height) - 1, fixed: verticalScanX, horizontal: false),
                let cardBottomYFromEnd = firstNonBackground(from: Int(size.height) - 1, to: 0, fixed: verticalScanX, horizontal: false),
                let cardLeadingX = firstNonBackground(from: contentColumnLeadingX, to: Int(size.width) - 1, fixed: horizontalScanY, horizontal: true),
                let cardTrailingXFromEnd = firstNonBackground(from: Int(size.width) - 1, to: contentColumnLeadingX, fixed: horizontalScanY, horizontal: true)
            else {
                rendered.writeDiagnosticPNG(named: "cardInset-uniform-FAILED-noCardFound-sidebarVisible-\(sidebarVisible)")
                XCTFail("Could not find the content card's edges against the Space background (sidebarVisible: \(sidebarVisible)) — the whole scanned region matched the background colour.")
                continue
            }

            let topInset = CGFloat(cardTopY)
            let bottomInset = size.height - CGFloat(cardBottomYFromEnd) - 1
            let leadingInset = CGFloat(cardLeadingX - contentColumnLeadingX)
            let trailingInset = size.width - CGFloat(cardTrailingXFromEnd) - 1

            let insets = [topInset, bottomInset, leadingInset, trailingInset]
            let maxDelta = (insets.max() ?? 0) - (insets.min() ?? 0)

            if maxDelta > 2 {
                rendered.writeDiagnosticPNG(named: "cardInset-uniform-FAILED-sidebarVisible-\(sidebarVisible)")
            }
            XCTAssertLessThanOrEqual(
                maxDelta, 2,
                "refs/ARC_PANE_CHROME.md: expected the content card's inset to be uniform on all four edges (sidebarVisible: \(sidebarVisible)) — measured top=\(topInset) bottom=\(bottomInset) leading=\(leadingInset) trailing=\(trailingInset), a spread of \(maxDelta)pt. The old defect was specifically a zero-inset leading edge while docked; any one edge drifting from the other three should fail here."
            )
        }
    }

    // MARK: - 7. The seam between two split panes is one gap, not two

    func test_splitPanes_interPaneGapMatchesTheOuterCardInset() {
        PeekState.shared.dismiss()

        let spaceColor = ThemeColor(red: 0.93, green: 0.16, blue: 0.55)
        let theme = SpaceTheme(style: .solid, colors: [spaceColor], grain: 0)
        let profileID = env.createDefaultProfileIfNeeded()
        let spaceID = env.createSpace(name: "Split Gap Test Space", icon: "circle", iconIsEmoji: false, theme: theme, profileID: profileID)
        let originalActiveSpaceID = env.state.activeSpaceID
        env.state.activeSpaceID = spaceID

        let tabA = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://a.example.com")!, title: "")
        let tabB = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://b.example.com")!, title: "")
        env.state.tabs[tabA.id] = tabA
        env.state.tabs[tabB.id] = tabB
        env.themeColors[tabA.id] = ThemeColor(red: 0.05, green: 0.55, blue: 0.20)
        env.themeColors[tabB.id] = ThemeColor(red: 0.05, green: 0.55, blue: 0.20)

        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            env.state.activeSpaceID = originalActiveSpaceID
            env.deleteSpace(spaceID)
            cleanup([tabA.id, tabB.id])
            XCTFail("Failed to create a split group between tabA and tabB.")
            return
        }
        env.activeTabID = tabA.id
        defer {
            env.store.dissolveSplit(groupID)
            env.state.activeSpaceID = originalActiveSpaceID
            env.deleteSpace(spaceID)
            cleanup([tabA.id, tabB.id])
        }

        let size = CGSize(width: 1000, height: 600)
        let tolerance = 0.12

        env.isSidebarVisible = true
        var windowView = AnyView(BrowserWindowView(skipOnboarding: true).environment(env))
        #if DEBUG
        windowView = AnyView(windowView.environment(\.orbitScreenshotModeDragDisabled, true))
        #endif
        let rendered = render(windowView, size: size)

        let contentColumnLeadingX = Int((env.sidebarWidth + OrbitMetrics.sidebarResizeHandleWidth).rounded())
        let scanY = Int(size.height) / 2

        let backgroundProbeY = Int(size.height) - 3
        let backgroundReference = rendered.color(atX: (contentColumnLeadingX + Int(size.width)) / 2, y: backgroundProbeY)

        func isBackground(_ x: Int) -> Bool {
            rendered.color(atX: x, y: scanY).isApproximately(backgroundReference, tolerance: tolerance)
        }

        var runs: [(isBackground: Bool, start: Int, end: Int)] = []
        for x in contentColumnLeadingX..<Int(size.width) {
            let background = isBackground(x)
            if var last = runs.last, last.isBackground == background {
                last.end = x
                runs[runs.count - 1] = last
            } else {
                runs.append((background, x, x))
            }
        }

        let backgroundRuns = runs.filter(\.isBackground)
        guard backgroundRuns.count == 3, runs.count == 5, runs.first?.isBackground == true else {
            rendered.writeDiagnosticPNG(named: "splitPaneGap-FAILED-unexpectedRuns")
            XCTFail("Expected the scan line across a two-pane split to read as exactly margin/paneA/seam/paneB/margin — found \(runs.count) runs (\(backgroundRuns.count) of them background): \(runs.map { "\($0.isBackground ? "bg" : "pane") \($0.start)...\($0.end)" }).")
            return
        }

        let leadingMargin = CGFloat(backgroundRuns[0].end - backgroundRuns[0].start + 1)
        let seam = CGFloat(backgroundRuns[1].end - backgroundRuns[1].start + 1)
        let trailingMargin = CGFloat(backgroundRuns[2].end - backgroundRuns[2].start + 1)

        let outerMargin = (leadingMargin + trailingMargin) / 2
        if abs(seam - outerMargin) > 2 {
            rendered.writeDiagnosticPNG(named: "splitPaneGap-FAILED-doubled")
        }
        XCTAssertEqual(
            seam, outerMargin, accuracy: 2,
            "The seam between two split panes measured \(seam)pt against an outer margin of \(outerMargin)pt (leading \(leadingMargin), trailing \(trailingMargin)). The reported defect was exactly this: each pane applying a full gap on its facing edge, so the two add up (plus OrbitMetrics.splitDividerThickness) to about twice the border every other edge in the window gets. OrbitSplitPaneMetrics.paneGap must stay derived from a single total (interPaneGap), split across the two facing edges."
        )

        XCTAssertEqual(
            seam, OrbitSplitPaneMetrics.interPaneGap, accuracy: 2,
            "Expected the measured seam (\(seam)pt) to equal OrbitSplitPaneMetrics.interPaneGap (\(OrbitSplitPaneMetrics.interPaneGap)pt) — the constant and what actually renders have drifted apart."
        )
    }
}
