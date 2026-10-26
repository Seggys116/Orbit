import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SiteControlPopoverVisualTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private static let canvasSize = CGSize(width: 420, height: 760)

    // MARK: - A minimal, mutable BrowserEngine stand-in (capabilities toggled after construction)

    private final class FakeEngine: BrowserEngine {
        static let kind: EngineKind = .webkit
        var capabilities: EngineCapabilities = [.extensions]
        var manageableContentSettings: Set<PermissionKind> = Set(PermissionKind.allCases)
        var extensionActivation: ExtensionActivation = .nextLaunch
        var versionDescription = "FakeEngine (SiteControlPopoverVisualTests — no real engine is running)"

        private let session: EngineSession
        init(session: EngineSession) { self.session = session }

        func start() throws {}
        func shutdown() -> Bool { true }
        func tick() {}

        func session(identifier: String, persistent: Bool) throws -> EngineSession { session }
        var defaultSession: EngineSession { session }

        func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
            throw EngineError(code: .engineUnavailable)
        }

        func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
        func addUserScript(_ script: UserScript, session: EngineSession) {}
        func removeUserScript(id: UUID, session: EngineSession) {}
        func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}

        func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
            throw EngineError(code: .engineUnavailable)
        }
        func unloadExtension(id: String, session: EngineSession) {}
        func loadedExtensions(session: EngineSession) -> [LoadedExtension] { [] }
    }

    // MARK: - Fixture: attaches a fake, extensions-capable engine and live web contents to the active tab

    @discardableResult
    private func seedPopover() -> (tab: Orbit.Tab, engine: FakeEngine, session: MockEngineSession)? {
        OrbitScreenshotFixtures.configure(env)
        guard let tab = env.activeTab, tab.url.host() != nil else {
            XCTFail("expected OrbitState.demo's active tab (env.activeTab) to carry a real, hosted URL")
            return nil
        }

        let session = MockEngineSession(identifier: "site-control-visual-fixture", isPersistent: true)
        session.setContentSetting(.block, for: .geolocation, url: tab.url)

        let webContents = MockWebContents(session: session)
        webContents.navigationState = NavigationState(
            url: tab.url, title: tab.title, canGoBack: true, canGoForward: false, isLoading: false, progress: 1, security: .secure
        )
        env._test_attachWebContents(webContents, for: tab.id)

        let engine = FakeEngine(session: session)
        env._test_engineOverride = engine
        return (tab, engine, session)
    }

    // MARK: - Declared width

    func test_popover_rendersAtItsDeclaredWidth() {
        guard let (tab, _, _) = seedPopover() else { return }

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                SiteControlPopoverView(tab: tab).environment(env).background(Color.red),
                size: Self.canvasSize,
                appearance: appearance
            )
            let box = rendered.boundingBoxOfContent()
            XCTAssertEqual(
                box?.width ?? -1, 300, accuracy: 1,
                "appearance \(appearance.rawValue): SiteControlPopoverView declares .frame(width: 300) but rendered at a different width — exactly the class of 'wrong scale' defect a PNG-only check would miss."
            )
        }
    }

    func test_popover_paintsNonBlankContent_inBothAppearances() {
        guard let (tab, _, _) = seedPopover() else { return }

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            // Without this the unflattenable representables paint placeholder blocks that satisfy any ink check on their own.
            let content = SiteControlPopoverView(tab: tab).environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true)
            let rendered = render(content, size: Self.canvasSize, appearance: appearance)
            let again = render(content, size: Self.canvasSize, appearance: appearance)

            XCTAssertFalse(
                Self.rendersDiffer(rendered, again, size: Self.canvasSize),
                "appearance \(appearance.rawValue): two renders of the same popover differ, so nothing measured here is a reliable signal."
            )

            var sliceTop = 0
            while sliceTop < Int(Self.popoverContentHeight) {
                let slice = CGRect(x: 0, y: sliceTop, width: Int(Self.canvasSize.width), height: Self.sliceHeight)
                XCTAssertGreaterThan(
                    Self.inkCount(rendered, in: slice), 200,
                    "appearance \(appearance.rawValue): only \(Self.inkCount(rendered, in: slice)) painted pixels between y=\(sliceTop) and y=\(sliceTop + Self.sliceHeight) -- a whole section of the popover is missing."
                )
                sliceTop += Self.sliceHeight
            }
        }
    }

    // MARK: - The extensions row appears only when the engine actually supports extensions

    func test_popover_withExtensionsCapableEngine_rendersDifferentlyThanWithout() {
        guard let (tab, engine, _) = seedPopover() else { return }

        engine.capabilities = [.extensions]
        let withExtensions = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        engine.capabilities = []
        let withoutExtensions = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(withExtensions, withoutExtensions, size: Self.canvasSize),
            "Removing the .extensions capability did not change anything rendered — SiteControlPopoverView.isExtensionsSectionVisible is not gating the real row."
        )
    }

    // MARK: - A stored permission decision actually adds a row

    func test_popover_withAStoredPermissionDecision_rendersDifferentlyThanWithNone() {
        guard let (tab, _, session) = seedPopover() else { return }

        let withDecision = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        session.setContentSetting(.ask, for: .geolocation, url: tab.url)
        let withoutDecision = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(withDecision, withoutDecision, size: Self.canvasSize),
            "Revoking the site's only stored permission decision (Location) did not change anything rendered — the permission row is not reading real content-setting state."
        )
    }

    // MARK: - The popover wears the Space theme

    private func renderThemedPopover(_ theme: SpaceTheme?, tab: Orbit.Tab) -> RenderedImage {
        var content = AnyView(
            SiteControlPopoverView(tab: tab)
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true)
        )
        if let theme { content = AnyView(content.environment(\.orbitSpaceTheme, theme)) }
        return render(content, size: Self.canvasSize, appearance: .darkAqua)
    }

    func test_popover_surfaceTextAndIconsFollowEachSpacesTheme_notAFixedColour() throws {
        guard let (tab, _, _) = seedPopover() else { return }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpaceThemedSiteControl-\(UUID().uuidString)", isDirectory: true)
        let untouched = renderThemedPopover(nil, tab: tab)
        XCTAssertLessThan(
            untouched.color(atX: 3, y: 3).a, 0.05,
            "With no Space theme the popover paints no surface of its own, so the themed renders below are the only thing that can account for a coloured surface."
        )

        for (name, theme, inkIsLight) in [
            ("dark", SpaceThemeChromeTests.darkTheme, true),
            ("light", SpaceThemeChromeTests.lightTheme, false),
        ] {
            let rendered = renderThemedPopover(theme, tab: tab)
            let url = directory.appendingPathComponent("\(name).png")
            rendered.writePNG(to: url)
            print("SpaceThemedSiteControl PNG (\(name)): \(url.path)")

            let expectedSurface = SpaceThemeChromeTests.renderedSurface(of: theme)
            XCTAssertTrue(
                rendered.color(atX: 3, y: 3).isApproximately(expectedSurface, tolerance: 0.01),
                "\(name): the popover surface (\(rendered.color(atX: 3, y: 3))) is not SpaceThemeChrome.surface as rasterised (\(expectedSurface))."
            )
            let otherTheme = inkIsLight ? SpaceThemeChromeTests.lightTheme : SpaceThemeChromeTests.darkTheme
            XCTAssertFalse(
                rendered.color(atX: 3, y: 3).isApproximately(SpaceThemeChromeTests.renderedSurface(of: otherTheme), tolerance: 0.05),
                "\(name): the surface matches the other theme's surface, so it is not following the theme."
            )

            for (band, rect) in [
                ("header", CGRect(x: 0, y: 0, width: 300, height: 56)),
                ("action icons", CGRect(x: 0, y: 66, width: 300, height: 40)),
            ] {
                let ink = SpaceThemeChromeTests.extremeInk(in: rendered, rect: rect, against: expectedSurface)
                let luminance = SpaceThemeChromeTests.luminance(ink)
                if inkIsLight {
                    XCTAssertGreaterThan(luminance, 0.75, "\(name) \(band): ink \(ink) is not the light readable foreground a dark Space calls for.")
                } else {
                    XCTAssertLessThan(luminance, 0.30, "\(name) \(band): ink \(ink) is not the dark readable foreground a light Space calls for -- a fixed colour would pass the dark case and fail this one.")
                }
            }
        }
    }

    func test_contextMenu_surfaceAndTextFollowTheSpaceTheme() {
        let entries: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: "Split Right", systemImage: "rectangle.righthalf.inset.filled", shortcut: "R")),
        ]
        let size = CGSize(width: OrbitMetrics.contextMenuWidth + 20, height: 110)

        for (name, theme, inkIsLight) in [
            ("dark", SpaceThemeChromeTests.darkTheme, true),
            ("light", SpaceThemeChromeTests.lightTheme, false),
        ] {
            let rendered = render(
                OrbitContextMenuView(entries: entries, onSelect: {})
                    .environment(\.orbitSpaceTheme, theme)
                    .environment(\.orbitScreenshotModeDragDisabled, true),
                size: size,
                appearance: .darkAqua
            )
            let expectedSurface = SpaceThemeChromeTests.renderedSurface(of: theme)
            XCTAssertTrue(
                rendered.color(atX: 4, y: 20).isApproximately(expectedSurface, tolerance: 0.01),
                "\(name): the menu surface (\(rendered.color(atX: 4, y: 20))) is not SpaceThemeChrome.surface as rasterised (\(expectedSurface))."
            )
            let otherTheme = inkIsLight ? SpaceThemeChromeTests.lightTheme : SpaceThemeChromeTests.darkTheme
            XCTAssertFalse(
                rendered.color(atX: 4, y: 20).isApproximately(SpaceThemeChromeTests.renderedSurface(of: otherTheme), tolerance: 0.05),
                "\(name): the menu surface matches the other theme's surface."
            )
            let ink = SpaceThemeChromeTests.extremeInk(
                in: rendered,
                rect: CGRect(x: 6, y: 4, width: OrbitMetrics.contextMenuWidth - 12, height: 40),
                against: expectedSurface
            )
            let luminance = SpaceThemeChromeTests.luminance(ink)
            if inkIsLight {
                XCTAssertGreaterThan(luminance, 0.75, "\(name): menu text \(ink) is not light on a dark Space.")
            } else {
                XCTAssertLessThan(luminance, 0.30, "\(name): menu text \(ink) is not dark on a light Space.")
            }
        }
    }

    // MARK: - Helpers

    private static let sliceHeight = 70
    private static let popoverContentHeight: CGFloat = 560

    private static func inkCount(_ image: RenderedImage, in rect: CGRect) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where image.color(atX: x, y: y).a > 0.04 {
                count += 1
            }
        }
        return count
    }

    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 6
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

// MARK: - SpaceThemeChrome: the colour resolver every themed toolbar surface draws from

@MainActor
final class SpaceThemeChromeTests: XCTestCase {

    static let darkTheme = SpaceTheme(
        style: .solid,
        colors: [ThemeColor(red: 0.10, green: 0.08, blue: 0.20)],
        followsSystemAppearance: false,
        prefersDarkContent: true
    )

    static let lightTheme = SpaceTheme(
        style: .solid,
        colors: [ThemeColor(red: 0.93, green: 0.90, blue: 0.82)],
        followsSystemAppearance: false
    )

    /// SpaceThemeChrome.surface through the same rasteriser as the views, which shifts raw sRGB values.
    static func renderedSurface(of theme: SpaceTheme) -> RGBA {
        let surface = SpaceThemeChrome(theme: theme, colorScheme: .dark).surface
        return render(Rectangle().fill(surface).frame(width: 40, height: 40), size: CGSize(width: 40, height: 40), appearance: .darkAqua)
            .averageColor(in: CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    static func luminance(_ c: RGBA) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    static func extremeInk(in image: RenderedImage, rect: CGRect, against background: RGBA) -> RGBA {
        var best = background
        var bestDistance = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let candidate = image.color(atX: x, y: y)
                let distance = abs(luminance(candidate) - luminance(background))
                if distance > bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        return best
    }

    private static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func assertSame(_ lhs: Color, _ rhs: Color, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let a = lhs.srgbComponents, b = rhs.srgbComponents
        XCTAssertEqual(a.red, b.red, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.alpha, b.alpha, accuracy: 0.01, message, file: file, line: line)
    }

    // MARK: Resolver output follows the theme

    func test_foregroundIsTheThemesReadableForeground_andDiffersBetweenThemes() {
        for scheme in [ColorScheme.dark, .light] {
            let dark = SpaceThemeChrome(theme: Self.darkTheme, colorScheme: scheme)
            let light = SpaceThemeChrome(theme: Self.lightTheme, colorScheme: scheme)

            assertSame(dark.foreground, Self.darkTheme.readableForeground, "dark theme foreground must be readableForeground (\(scheme))")
            assertSame(light.foreground, Self.lightTheme.readableForeground, "light theme foreground must be readableForeground (\(scheme))")
            assertSame(dark.secondaryForeground, Self.darkTheme.readableSecondaryForeground, "secondary foreground must be readableSecondaryForeground")
            XCTAssertGreaterThan(dark.foreground.approximateLuminance, 0.8)
            XCTAssertLessThan(light.foreground.approximateLuminance, 0.2)
        }
    }

    func test_fillRampsUseTheSidebarsOpacitiesAndAreOrdered() {
        let chrome = SpaceThemeChrome(theme: Self.darkTheme, colorScheme: .dark)
        let readableAlpha = Self.darkTheme.readableForeground.srgbComponents.alpha

        XCTAssertEqual(chrome.restFill.srgbComponents.alpha, readableAlpha * OrbitMetrics.sidebarActiveRowOpacity, accuracy: 0.002)
        XCTAssertEqual(chrome.hoverFill.srgbComponents.alpha, readableAlpha * OrbitMetrics.miniPlayerSurfaceOpacity, accuracy: 0.002)
        XCTAssertEqual(chrome.border.srgbComponents.alpha, readableAlpha * OrbitMetrics.cardBorderOpacity, accuracy: 0.002)
        XCTAssertEqual(chrome.divider.srgbComponents.alpha, readableAlpha * OrbitMetrics.sidebarDividerOpacity, accuracy: 0.002)
        XCTAssertLessThan(chrome.restFill.srgbComponents.alpha, chrome.hoverFill.srgbComponents.alpha)
        XCTAssertLessThan(chrome.hoverFill.srgbComponents.alpha, chrome.pressedFill.srgbComponents.alpha)
        XCTAssertEqual(chrome.disabledOpacity, OrbitMetrics.contextMenuDisabledOpacity)
    }

    func test_surfaceIsTheThemesOpaqueColour_andAccentContrastsWithIt() {
        for theme in [Self.darkTheme, Self.lightTheme] {
            let chrome = SpaceThemeChrome(theme: theme, colorScheme: .dark)
            let surface = chrome.surface.srgbComponents
            XCTAssertEqual(surface.alpha, 1, accuracy: 0.001, "a panel menu cannot be translucent")
            XCTAssertEqual(surface.red, theme.primary.red, accuracy: 0.01)
            XCTAssertEqual(surface.green, theme.primary.green, accuracy: 0.01)
            XCTAssertEqual(surface.blue, theme.primary.blue, accuracy: 0.01)
            XCTAssertGreaterThan(
                abs(chrome.accent.approximateLuminance - chrome.accentContrast.approximateLuminance), 0.5,
                "a badge drawn in the accent with accentContrast text must stay readable"
            )
        }
    }

    func test_chromeChangesWhenTheThemeChanges() {
        XCTAssertNotEqual(
            SpaceThemeChrome(theme: Self.darkTheme, colorScheme: .dark),
            SpaceThemeChrome(theme: Self.lightTheme, colorScheme: .dark)
        )
        XCTAssertEqual(
            SpaceThemeChrome(theme: Self.darkTheme, colorScheme: .dark),
            SpaceThemeChrome(theme: Self.darkTheme, colorScheme: .dark)
        )
    }

    func test_environmentDefaultsToNoTheme_andRoundTrips() {
        var values = EnvironmentValues()
        XCTAssertNil(values.orbitSpaceTheme)
        values.orbitSpaceTheme = Self.lightTheme
        XCTAssertEqual(values.orbitSpaceTheme, Self.lightTheme)
        XCTAssertFalse(values.orbitControlPressed)
    }

    func test_menuThemeSourceReadsItsProviderOnEveryAccess() {
        let source = OrbitMenuThemeSource.shared
        let saved = source.provider
        defer { source.provider = saved }

        source.provider = nil
        XCTAssertNil(source.theme)
        var current = Self.darkTheme
        source.provider = { current }
        XCTAssertEqual(source.theme, Self.darkTheme)
        current = Self.lightTheme
        XCTAssertEqual(source.theme, Self.lightTheme, "a cached theme would leave an open menu on the previous Space's colours")
    }

    // MARK: Animation

    private func stops() -> (current: SpaceSwipeBlend.Stop, previous: SpaceSwipeBlend.Stop, next: SpaceSwipeBlend.Stop) {
        (
            SpaceSwipeBlend.Stop(theme: Self.darkTheme, blur: 0.1),
            SpaceSwipeBlend.Stop(theme: Self.lightTheme, blur: 0.2),
            SpaceSwipeBlend.Stop(theme: SpaceThemePalette.presets[1], blur: 0.3)
        )
    }

    func test_swipeBlendFollowsTheFingerAndTheSettle() throws {
        let (current, previous, next) = stops()
        let width: CGFloat = 200

        for fraction in [0.1, 0.25, 0.5, 0.75, 1.0] {
            let towardsNext = try XCTUnwrap(SpaceSwipeBlend.make(
                translation: -width * fraction, width: width, isDragging: true, current: current, previous: previous, next: next
            ))
            XCTAssertEqual(towardsNext.incomingWeight, fraction, accuracy: 1e-9)
            XCTAssertEqual(towardsNext.incomingTheme, next.theme)
            XCTAssertEqual(towardsNext.incomingBlur, 0.3, accuracy: 1e-9)

            let towardsPrevious = try XCTUnwrap(SpaceSwipeBlend.make(
                translation: width * fraction, width: width, isDragging: true, current: current, previous: previous, next: next
            ))
            XCTAssertEqual(towardsPrevious.incomingWeight, fraction, accuracy: 1e-9)
            XCTAssertEqual(towardsPrevious.incomingTheme, previous.theme)
        }

        let overshoot = try XCTUnwrap(SpaceSwipeBlend.make(
            translation: -width * 1.4, width: width, isDragging: true, current: current, previous: previous, next: next
        ))
        XCTAssertEqual(overshoot.incomingWeight, 1, accuracy: 1e-9, "a spring overshoot must not push the weight past a full blend")

        let atRest = try XCTUnwrap(SpaceSwipeBlend.make(
            translation: 0, width: width, isDragging: true, current: current, previous: previous, next: next
        ))
        XCTAssertNil(atRest.incomingTheme)
        XCTAssertNil(SpaceSwipeBlend.make(translation: -50, width: width, isDragging: false, current: current, previous: previous, next: next))
        let noNeighbour = try XCTUnwrap(SpaceSwipeBlend.make(
            translation: -50, width: width, isDragging: true, current: current, previous: previous, next: nil
        ))
        XCTAssertNil(noNeighbour.incomingTheme)
    }

    func test_swipeBlendPublisherInterpolatesWithTheAnimatedTranslation() throws {
        let (current, previous, next) = stops()
        var publisher = SpaceSwipeBlendPublisher(
            translation: 0, width: 200, isDragging: true, current: current, previous: previous, next: next
        )

        var sampled: [Double] = []
        for translation in stride(from: CGFloat(0), through: -200, by: -40) {
            publisher.animatableData = translation
            sampled.append(try XCTUnwrap(publisher.blend).incomingWeight)
        }

        let expected = [0, 0.2, 0.4, 0.6, 0.8, 1.0]
        XCTAssertEqual(sampled.count, expected.count)
        for (actual, wanted) in zip(sampled, expected) {
            XCTAssertEqual(actual, wanted, accuracy: 1e-9, "the published weight must track animatableData frame by frame, not jump to the end state")
        }
        XCTAssertEqual(sampled, sampled.sorted(), "the weight must rise monotonically through a settle")
    }

    func test_themeAnimationIsDisabledByReduceMotion() {
        XCTAssertNil(OrbitThemeMotion.animation(reduceMotion: true))
        XCTAssertNil(OrbitThemeMotion.animation(reduceMotion: true, token: OrbitMotion.quick))
        XCTAssertEqual(OrbitThemeMotion.animation(reduceMotion: false), OrbitMotion.dramatic)
        XCTAssertEqual(OrbitThemeMotion.animation(reduceMotion: false, token: OrbitMotion.quick), OrbitMotion.quick)
    }

    func test_everyThemeDerivedSurfaceIsPairedWithAnimationKeyedToTheTheme() throws {
        let background = try Self.source("Orbit/UI/Theme/ThemeBackgroundView.swift")
        XCTAssertTrue(background.contains("@Environment(\\.accessibilityReduceMotion)"), "ThemeBackgroundView must read Reduce Motion")
        XCTAssertTrue(background.contains("OrbitThemeMotion.animation(reduceMotion: reduceMotion)"), "the crossfade must come from the Reduce-Motion-aware helper")
        XCTAssertTrue(background.contains("withAnimation(animation) { crossfadeProgress = 1 }"), "the crossfade must run on the helper's animation")
        XCTAssertFalse(
            background.contains("layer(for: previousTheme).opacity(1 - crossfadeProgress)"),
            "fading the outgoing layer out while the incoming fades in dips the combined coverage mid-crossfade"
        )

        for file in [
            "Orbit/UI/SiteControl/SiteControlPopoverView.swift",
            "Orbit/UI/SiteControl/ExtensionActionPopupHosting.swift",
            "Orbit/UI/Controls/OrbitContextMenuView.swift",
        ] {
            let text = try Self.source(file)
            XCTAssertTrue(text.contains("SpaceThemeChrome"), "\(file) no longer draws from SpaceThemeChrome")
            XCTAssertTrue(
                text.contains(".orbitThemeAnimation(value: chrome)"),
                "\(file) applies theme-derived colours with no crossfade keyed to the theme: a Space switch or theme edit would snap them"
            )
        }

        let toolbar = try Self.source("Orbit/UI/Toolbar/ToolbarView.swift")
        XCTAssertTrue(toolbar.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(toolbar.contains("OrbitThemeMotion.animation(reduceMotion: reduceMotion"))
        XCTAssertTrue(toolbar.contains("value: headerBackground"))
        XCTAssertFalse(
            toolbar.contains(".animation(.easeInOut(duration: OrbitToolbarMetrics.backgroundCrossFadeDuration), value: headerBackground)"),
            "the header crossfade must honour Reduce Motion"
        )
        XCTAssertTrue(toolbar.contains(".environment(\\.orbitSpaceTheme, spaceTheme)"), "the Site Control popover is no longer handed the Space theme")
        XCTAssertGreaterThanOrEqual(
            toolbar.components(separatedBy: "adoptMenuTheme()").count - 1, 3,
            "the split menu and the right-click menu must each point the panel menus at this window's theme when they open"
        )
        XCTAssertFalse(
            toolbar.contains(".onAppear { adoptMenuTheme() }"),
            "arming the process-wide menu theme at appear time leaks it into every later menu render in the same process"
        )

        let controls = try Self.source("Orbit/UI/Theme/SpaceThemedControls.swift")
        XCTAssertGreaterThanOrEqual(
            controls.components(separatedBy: "OrbitThemeMotion.animation(reduceMotion: reduceMotion, token: OrbitMotion.quick)").count - 1, 2,
            "hover and pressed fills must animate with the quick token and honour Reduce Motion"
        )
    }

    func test_everySpaceSwitchEntryPointGoesThroughTheSharedAnimationHelper() throws {
        let source = try Self.source("Orbit/Core/AppEnvironment.swift")

        func body(after marker: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: marker), "missing \(marker)")
            let rest = source[start.upperBound...]
            let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(marker)")
            return String(rest[..<end.lowerBound])
        }

        let helper = try body(after: "private func animatingSpaceSwitch(_ animated: Bool, _ change: () -> Void) {")
        XCTAssertTrue(helper.contains("OrbitThemeMotion.animation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"))
        XCTAssertTrue(helper.contains("withAnimation("))

        let select = try body(after: "func selectSpace(_ id: SpaceID, animated: Bool = true) {")
        XCTAssertTrue(select.contains("animatingSpaceSwitch(animated)"), "selectSpace changes the active Space outside the shared helper")
        XCTAssertFalse(select.contains("withAnimation"), "selectSpace must not wrap on its own: a second wrapper would fight the helper")

        let step = try body(after: "private func stepSpace(offset: Int) {")
        XCTAssertTrue(step.contains("animatingSpaceSwitch(true)"), "the document-scoped next/previous Space path bypasses the helper")
        XCTAssertTrue(step.contains("selectSpace("), "the window-scoped step must reach selectSpace")

        let jump = try body(after: "func jumpToSpace(index: Int) {")
        XCTAssertTrue(jump.contains("selectSpace("), "Ctrl+digit must reach selectSpace")
        XCTAssertFalse(source.contains("store.switchToSpace(") && source.components(separatedBy: "store.switchToSpace(").count > 2,
                       "a second direct store.switchToSpace call in AppEnvironment bypasses the helper")

        let container = try Self.source("Orbit/UI/Spaces/SpaceSwitchingSidebarContainer.swift")
        XCTAssertTrue(
            container.contains("env.selectSpace(destination.id, animated: false)"),
            "the swipe's settle completion must not add a second animation on top of the interpolated one"
        )
        let command = try Self.source("Orbit/UI/CommandBar/CommandBarActivation.swift")
        XCTAssertTrue(command.contains("env.selectSpace(targetSpaceID)"), "the command bar switch must go through selectSpace")
    }

    func test_swipeBackgroundIsPublishedThroughTheAnimatablePublisher() throws {
        let container = try Self.source("Orbit/UI/Spaces/SpaceSwitchingSidebarContainer.swift")
        XCTAssertTrue(container.contains("SpaceSwipeBlendPublisher("), "the swipe blend must be published through the animatable modifier")
        XCTAssertFalse(
            container.contains(".preference("),
            "publishing the blend with a bare .preference jumps the window background to its end state when the settle animation starts"
        )
        XCTAssertTrue(
            container.contains("withAnimation(OrbitMotion.interactive, completionCriteria: .logicallyComplete) {\n                translation = settleTarget"),
            "the settle must animate translation, which is what the publisher interpolates"
        )

        let blend = try Self.source("Orbit/UI/Spaces/SpaceGradientBlendView.swift")
        XCTAssertTrue(
            blend.contains("isDarkSurface: theme.isDarkSurface(for: colorScheme)"),
            "the swipe's grain must match the at-rest ThemeBackgroundView grain or it pops when the swipe ends"
        )
    }
}
