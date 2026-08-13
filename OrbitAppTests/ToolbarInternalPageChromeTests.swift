import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class ToolbarInternalPageChromeTests: XCTestCase {

    // MARK: - Harness

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var scratchSpaceID: SpaceID!

    // ToolbarView reads ToolbarSettings.shared directly, so a render test only means
    // anything against a scratch instance, never the real user's persisted preference.
    private var suiteName: String!
    private var writingStore: UserDefaults!
    private var settings: ToolbarSettings!
    private var originalSharedSettings: ToolbarSettings!

    // Same isolation for DeveloperModeSettings.shared.isEnabled, which
    // ToolbarView.addressText also reads.
    private var developerModeSuiteName: String!
    private var developerModeWritingStore: UserDefaults!

    // A real, never-key NSWindow used only by the pane identity test, which needs a live
    // view hierarchy to carry @State across two env.activateTab(_:) calls.
    private var window: NSWindow?

    override func setUp() {
        super.setUp()

        suiteName = "OrbitAppTests-ToolbarInternalPageChrome-\(UUID().uuidString)"
        writingStore = UserDefaults(suiteName: suiteName)
        settings = ToolbarSettings(defaults: writingStore)
        originalSharedSettings = ToolbarSettings.shared
        ToolbarSettings.shared = settings

        developerModeSuiteName = "OrbitAppTests-ToolbarInternalPageChrome-DevMode-\(UUID().uuidString)"
        developerModeWritingStore = UserDefaults(suiteName: developerModeSuiteName)
        DeveloperModeSettings.defaults = developerModeWritingStore

        let profileID = env.createDefaultProfileIfNeeded()
        scratchSpaceID = env.createSpace(
            name: "Toolbar Internal Page Chrome Scratch",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: profileID
        )
        env.selectSpace(scratchSpaceID)
    }

    override func tearDown() {
        // window.close() alone can leave a live NSHostingView (and, through
        // it, env) attached to a window AppKit has only deferred releasing.
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil

        ToolbarSettings.shared = originalSharedSettings
        writingStore?.removePersistentDomain(forName: suiteName)
        settings = nil
        writingStore = nil

        DeveloperModeSettings.defaults = .standard
        developerModeWritingStore?.removePersistentDomain(forName: developerModeSuiteName)
        developerModeWritingStore = nil
        developerModeSuiteName = nil

        if let scratchSpaceID { env.deleteSpace(scratchSpaceID) }
        scratchSpaceID = nil

        super.tearDown()
    }

    // Module-qualified: SwiftUI declares its own Tab since macOS 15, so a
    // bare Tab here is genuinely ambiguous.
    private func makeTab(url: String) -> Orbit.Tab {
        let tab = Orbit.Tab(spaceID: scratchSpaceID, section: .today, url: URL(string: url)!)
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func cleanup(_ ids: [TabID]) {
        for id in ids { env.state.tabs.removeValue(forKey: id) }
    }

    // MARK: - Live-window capture

    private func hostLiveWindow<V: View>(_ content: V, size: CGSize) -> NSHostingView<V> {
        tearDownHostedWindow()
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        return host
    }

    private func tearDownHostedWindow() {
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
    }

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // Must sample through a live NSHostingView, not RenderHarness.render(_:size:): ImageRenderer cannot flatten .addressField's NSViewRepresentable click-catcher.
    private func captureBitmap(of host: NSView) -> NSBitmapImageRep? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func rgba(in rep: NSBitmapImageRep, atX x: Double, y: Double, viewSize: CGSize) -> RGBA? {
        let scaleX = Double(rep.pixelsWide) / Double(viewSize.width)
        let scaleY = Double(rep.pixelsHigh) / Double(viewSize.height)
        guard let raw = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.sRGB) else { return nil }
        return RGBA(
            r: Double(raw.redComponent),
            g: Double(raw.greenComponent),
            b: Double(raw.blueComponent),
            a: Double(raw.alphaComponent)
        )
    }

    private func capturedColor(of host: NSView, at point: NSPoint, viewSize: CGSize) -> NSColor? {
        guard let rep = captureBitmap(of: host) else { return nil }
        let scaleX = Double(rep.pixelsWide) / Double(viewSize.width)
        let scaleY = Double(rep.pixelsHigh) / Double(viewSize.height)
        guard let raw = rep.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY)) else { return nil }
        return raw.usingColorSpace(.sRGB)
    }

    private func colorsApproximatelyEqual(_ a: NSColor?, _ b: NSColor?, tolerance: Double = 0.06) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
        return abs(Double(a.redComponent) - Double(b.redComponent)) <= tolerance
            && abs(Double(a.greenComponent) - Double(b.greenComponent)) <= tolerance
            && abs(Double(a.blueComponent) - Double(b.blueComponent)) <= tolerance
    }

    // Measures the single darkest/brightest pixel, not an averaged region, to stay insensitive to how many characters the rendered string has.
    private func peakInkDeviation(_ rep: NSBitmapImageRep, viewSize: CGSize, in rect: CGRect, background: RGBA) -> Double {
        let minX = max(0, rect.minX)
        let maxX = min(viewSize.width, rect.maxX)
        let minY = max(0, rect.minY)
        let maxY = min(viewSize.height, rect.maxY)
        guard minX < maxX, minY < maxY else { return 0 }
        var peak = 0.0
        var y = minY
        while y < maxY {
            var x = minX
            while x < maxX {
                if let sample = rgba(in: rep, atX: x, y: y, viewSize: viewSize) {
                    let deviation = max(
                        abs(sample.r - background.r),
                        abs(sample.g - background.g),
                        abs(sample.b - background.b)
                    )
                    peak = max(peak, deviation)
                }
                x += 0.5
            }
            y += 0.5
        }
        return peak
    }

    private func addressBand(size: CGSize) -> CGRect {
        CGRect(
            x: OrbitToolbarMetrics.addressSideReserve + OrbitToolbarMetrics.leadingPadding,
            y: OrbitToolbarMetrics.topPadding,
            width: size.width - 2 * (OrbitToolbarMetrics.addressSideReserve + OrbitToolbarMetrics.leadingPadding),
            height: OrbitToolbarMetrics.height
        )
    }

    // MARK: - 0. `isDocumentPage` itself

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_isDocumentPage_acceptsARealUUIDUnderNoteOrEasel

    func test_isDocumentPage_acceptsARealUUIDUnderNoteOrEasel() {
        let realID = UUID().uuidString
        XCTAssertTrue(OrbitInternalPageChrome.isDocumentPage(URL(string: "orbit://note/\(realID)")!))
        XCTAssertTrue(OrbitInternalPageChrome.isDocumentPage(URL(string: "orbit://easel/\(realID)")!))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_isDocumentPage_rejectsMalformedOrUnrelatedInput

    func test_isDocumentPage_rejectsMalformedOrUnrelatedInput() {
        let cases = [
            "orbit://note/not-a-uuid",
            "orbit://easel/not-a-uuid",
            "orbit://note",
            "orbit://easel",
            "orbit://",
            "orbit://new-tab",
            "https://example.com",
            "view-source:https://example.com"
        ]
        for raw in cases {
            let url = URL(string: raw)!
            XCTAssertFalse(
                OrbitInternalPageChrome.isDocumentPage(url),
                "\(raw) must not resolve as a document page — either its last path component isn't a real UUID, or it names no note/easel host at all. Every downstream behaviour in this file (address text, header colour, pane identity) is gated on this predicate answering correctly."
            )
        }
    }

    // MARK: - 1a. Address text — the pure function

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_addressText_isUntitledForNoteAndEaselDocuments_inBothFullURLModes

    func test_addressText_isUntitledForNoteAndEaselDocuments_inBothFullURLModes() {
        let noteURL = URL(string: "orbit://note/\(UUID().uuidString)")!
        let easelURL = URL(string: "orbit://easel/\(UUID().uuidString)")!
        for url in [noteURL, easelURL] {
            for showsFullURL in [false, true] {
                XCTAssertEqual(
                    ToolbarAddressText.text(for: url, showsFullURL: showsFullURL),
                    "untitled",
                    "\(url.absoluteString) at showsFullURL=\(showsFullURL) must read \"untitled\" — user, verbatim: \"The URL should just say 'untitled'.\" Independent of the full-URL setting: there is no full/domain distinction for a document with no URL."
                )
            }
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_addressText_newTabAndViewSource_areUnchanged

    func test_addressText_newTabAndViewSource_areUnchanged() {
        for raw in ["orbit://new-tab", "view-source:https://example.com"] {
            let url = URL(string: raw)!
            for showsFullURL in [false, true] {
                XCTAssertNil(
                    ToolbarAddressText.text(for: url, showsFullURL: showsFullURL),
                    "\(raw) at showsFullURL=\(showsFullURL) is not a document page and must keep falling back to nil (the dim placeholder) — the document-page carve-out must not widen to cover every internal surface."
                )
            }
        }
    }

    // MARK: - 1b. Address text — rendered at real content opacity

    // Both tabs are forced to the same header background, so any difference
    // measured below is attributable only to the two strings' foreground
    // opacity, never to the two tabs painting different backgrounds.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noteAndEaselAddressText_rendersAtContentOpacity_notThePlaceholderDim
    func test_noteAndEaselAddressText_rendersAtContentOpacity_notThePlaceholderDim() {
        let forcedBackground = ThemeColor(red: 0.9, green: 0.9, blue: 0.92)
        let noteTab = makeTab(url: "orbit://note/\(UUID().uuidString)")
        let easelTab = makeTab(url: "orbit://easel/\(UUID().uuidString)")
        let blankTab = makeTab(url: "orbit://new-tab")
        defer { cleanup([noteTab.id, easelTab.id, blankTab.id]) }

        for tab in [noteTab, easelTab, blankTab] {
            env.themeColors[tab.id] = forcedBackground
        }
        defer {
            for tab in [noteTab, easelTab, blankTab] { env.themeColors.removeValue(forKey: tab.id) }
        }

        let size = CGSize(width: 460, height: OrbitToolbarMetrics.totalHeight)
        let band = addressBand(size: size)

        for showsFullURL in [false, true] {
            settings.showsFullURL = showsFullURL

            let blankHost = hostLiveWindow(ToolbarView(tab: blankTab).environment(env), size: size)
            guard let blankRep = captureBitmap(of: blankHost),
                  let background = rgba(in: blankRep, atX: 2, y: 2, viewSize: size) else {
                XCTFail("Could not capture the blank tab's header — the harness itself is broken.")
                tearDownHostedWindow()
                continue
            }
            let blankPeak = peakInkDeviation(blankRep, viewSize: size, in: band, background: background)
            tearDownHostedWindow()

            for (label, documentTab) in [("Note", noteTab), ("Easel", easelTab)] {
                let documentHost = hostLiveWindow(ToolbarView(tab: documentTab).environment(env), size: size)
                guard let documentRep = captureBitmap(of: documentHost) else {
                    XCTFail("Could not capture \(label)'s header — the harness itself is broken.")
                    tearDownHostedWindow()
                    continue
                }
                let documentPeak = peakInkDeviation(documentRep, viewSize: size, in: band, background: background)
                tearDownHostedWindow()

                XCTAssertGreaterThan(
                    documentPeak, 0.2,
                    "showsFullURL=\(showsFullURL): \(label)'s \"untitled\" text produced almost no ink against the header background (peak deviation \(documentPeak)) — the address field is not rendering real content at all."
                )
                XCTAssertGreaterThan(
                    documentPeak, blankPeak * 1.3,
                    """
                    showsFullURL=\(showsFullURL): \(label)'s "untitled" address text (peak ink deviation \
                    \(documentPeak)) should be noticeably more opaque than the dim "Search or Enter URL..." \
                    placeholder it used to fall back to (\(blankPeak)) — 0.85 vs 0.45 foreground opacity, both \
                    over the identical forced background. If these are close, the field is still drawing the \
                    dim placeholder treatment instead of real content.
                    """
                )
            }
        }
    }

    // MARK: - 1c. Address leading control (F7) — must never mount over a document page

    // Walks real NSView.subviews, not pixels: F7's regression is about the click catcher's mere presence in the tree, which no bitmap comparison can prove.
    private func findAddressCopyClickCatcher(in view: NSView) -> ToolbarAddressCopyClickCatchingNSView? {
        if let match = view as? ToolbarAddressCopyClickCatchingNSView { return match }
        for subview in view.subviews {
            if let match = findAddressCopyClickCatcher(in: subview) { return match }
        }
        return nil
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_addressLeadingControl_neverMountsOverADocumentPage_evenIfSecurityResolves

    func test_addressLeadingControl_neverMountsOverADocumentPage_evenIfSecurityResolves() {
        let noteTab = makeTab(url: "orbit://note/\(UUID().uuidString)")
        let easelTab = makeTab(url: "orbit://easel/\(UUID().uuidString)")
        defer { cleanup([noteTab.id, easelTab.id]) }

        // Forces a security classification a document tab does not resolve to today, so this
        // gate must hold even if something later makes it possible.
        env.navigationStates[noteTab.id] = NavigationState(security: .secure)
        env.navigationStates[easelTab.id] = NavigationState(security: .secure)
        defer {
            env.navigationStates.removeValue(forKey: noteTab.id)
            env.navigationStates.removeValue(forKey: easelTab.id)
        }

        let size = CGSize(width: 460, height: OrbitToolbarMetrics.totalHeight)

        for (label, tab) in [("Note", noteTab), ("Easel", easelTab)] {
            let host = hostLiveWindow(ToolbarView(tab: tab).environment(env), size: size)
            // layoutSubtreeIfNeeded/displayIfNeeded alone is not enough to let an
            // NSViewRepresentable's makeNSView run before this inspects the tree.
            pump(seconds: 0.3)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            XCTAssertNil(
                findAddressCopyClickCatcher(in: host),
                """
                \(label)'s header mounted ToolbarAddressCopyControl's own AppKit click catcher over \
                \(tab.url.absoluteString) even with security forced to .secure. ToolbarAddressText
                .text(for:showsFullURL:)'s own doc comment (Orbit/UI/Toolbar/ToolbarSettings.swift) states the \
                internal orbit:// literal "must never reach this field at all" — a mounted catcher here means it \
                is one accidental future change to SecurityLevel resolution or ToolbarSecurityGlyph.symbol(for:) \
                away from being copied to the pasteboard by ToolbarAddressCopyControl.handleClick().
                """
            )
            tearDownHostedWindow()
        }
    }

    // Positive control for the test above, proving the walker finds a real catcher rather than always returning nil; security must be .secure, since .unknown never mounts a real, walkable NSView.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_addressLeadingControl_mountsOverAnOrdinaryLoadedPage
    func test_addressLeadingControl_mountsOverAnOrdinaryLoadedPage() {
        let webTab = makeTab(url: "https://example.com")
        defer { cleanup([webTab.id]) }
        env.navigationStates[webTab.id] = NavigationState(security: .secure)
        defer { env.navigationStates.removeValue(forKey: webTab.id) }

        let size = CGSize(width: 460, height: OrbitToolbarMetrics.totalHeight)
        let host = hostLiveWindow(ToolbarView(tab: webTab).environment(env), size: size)
        pump(seconds: 0.3)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertNotNil(
            findAddressCopyClickCatcher(in: host),
            "An ordinary loaded, secure https:// tab must still mount ToolbarAddressCopyControl's own click catcher — the positive control proving the walker above genuinely finds a real one when present, rather than unconditionally returning nil."
        )
        tearDownHostedWindow()
    }

    // MARK: - 2a. Header background matches the document surface colour

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_headerBackground_forNoteOrEaselTab_equalsTheInternalSurfaceColour_inBothAppearances

    func test_headerBackground_forNoteOrEaselTab_equalsTheInternalSurfaceColour_inBothAppearances() {
        let noteTab = makeTab(url: "orbit://note/\(UUID().uuidString)")
        let easelTab = makeTab(url: "orbit://easel/\(UUID().uuidString)")
        let blankTab = makeTab(url: "orbit://new-tab")
        defer { cleanup([noteTab.id, easelTab.id, blankTab.id]) }

        let size = CGSize(width: 400, height: OrbitToolbarMetrics.totalHeight)

        for (appearance, colorScheme): (NSAppearance.Name, ColorScheme) in [(.aqua, .light), (.darkAqua, .dark)] {
            let expected = OrbitInternalPageChrome.surfaceColor(for: colorScheme)
            let expectedRGBA = RGBA(r: expected.red, g: expected.green, b: expected.blue, a: expected.alpha)

            let blankRender = render(ToolbarView(tab: blankTab).environment(env), size: size, appearance: appearance)
            let neutralBackground = blankRender.color(atX: 2, y: 2)

            for (label, documentTab) in [("Note", noteTab), ("Easel", easelTab)] {
                let documentRender = render(ToolbarView(tab: documentTab).environment(env), size: size, appearance: appearance)
                let documentBackground = documentRender.color(atX: 2, y: 2)

                XCTAssertTrue(
                    documentBackground.isApproximately(expectedRGBA, tolerance: 0.05),
                    "\(appearance): \(label)'s header background (\(documentBackground)) should equal OrbitInternalPageChrome.surfaceColor(for:) (\(expectedRGBA)) — the exact colour the surface itself paints behind its content."
                )
                XCTAssertFalse(
                    documentBackground.isApproximately(neutralBackground, tolerance: 0.02),
                    "\(appearance): \(label)'s header (\(documentBackground)) rendered the same as a blank orbit://new-tab pane's hardcoded neutral fallback (\(neutralBackground)) — the header is not distinguishing a real document from an empty tab, which is the exact 'top bar doesn't match the page' report this fixes."
                )
            }
        }
    }

    // F8's own regression guard: reproduces the same Tab.id showing a web page (with a pushed theme colour) first, then being sent to a Note, with nothing ever clearing the stale entry.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_headerBackground_forDocumentPage_winsOverAStaleThemeColorLeftFromThatSameTabsPriorPage
    func test_headerBackground_forDocumentPage_winsOverAStaleThemeColorLeftFromThatSameTabsPriorPage() {
        let tab = makeTab(url: "https://example.com")
        defer { cleanup([tab.id]) }

        let staleColor = ThemeColor(red: 0.05, green: 0.05, blue: 0.05)
        env.themeColors[tab.id] = staleColor
        defer { env.themeColors.removeValue(forKey: tab.id) }

        var documentTab = tab
        documentTab.url = URL(string: "orbit://note/\(UUID().uuidString)")!
        env.state.tabs[documentTab.id] = documentTab
        defer { cleanup([documentTab.id]) }

        let size = CGSize(width: 400, height: OrbitToolbarMetrics.totalHeight)
        let staleRGBA = RGBA(r: staleColor.red, g: staleColor.green, b: staleColor.blue, a: staleColor.alpha)

        for (appearance, colorScheme): (NSAppearance.Name, ColorScheme) in [(.aqua, .light), (.darkAqua, .dark)] {
            let expected = OrbitInternalPageChrome.surfaceColor(for: colorScheme)
            let expectedRGBA = RGBA(r: expected.red, g: expected.green, b: expected.blue, a: expected.alpha)

            let documentRender = render(ToolbarView(tab: documentTab).environment(env), size: size, appearance: appearance)
            let documentBackground = documentRender.color(atX: 2, y: 2)

            XCTAssertTrue(
                documentBackground.isApproximately(expectedRGBA, tolerance: 0.05),
                """
                \(appearance): a tab carrying a stale env.themeColors entry (\(staleRGBA)) from before it navigated \
                to a Note rendered \(documentBackground), not the document surface colour \(expectedRGBA) — the \
                stale, pushed colour from the tab's prior web page is outranking the document branch of \
                ToolbarView.rawPageColor again. This is the exact F8 regression: the header must match the note it \
                is showing, not whatever page this tab happened to load before it became one.
                """
            )
            XCTAssertFalse(
                documentBackground.isApproximately(staleRGBA, tolerance: 0.05),
                "\(appearance): the header painted the stale web-page theme colour \(staleRGBA) instead of the Note's own surface colour \(expectedRGBA)."
            )
        }
    }

    // MARK: - 2b. Glyph/text contrast is readable against that background

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_addressTextContrast_isReadableAgainstTheDocumentSurfaceColour_inBothAppearances

    func test_addressTextContrast_isReadableAgainstTheDocumentSurfaceColour_inBothAppearances() {
        let noteTab = makeTab(url: "orbit://note/\(UUID().uuidString)")
        defer { cleanup([noteTab.id]) }

        let size = CGSize(width: 460, height: OrbitToolbarMetrics.totalHeight)
        let band = addressBand(size: size)

        for colorScheme: ColorScheme in [.light, .dark] {
            // Must set \.colorScheme directly on the hosted content, never NSApp.appearance, or another window's real appearance gets disturbed.
            let host = hostLiveWindow(
                ToolbarView(tab: noteTab).environment(env).environment(\.colorScheme, colorScheme),
                size: size
            )
            guard let rep = captureBitmap(of: host), let background = rgba(in: rep, atX: 2, y: 2, viewSize: size) else {
                XCTFail("\(colorScheme): could not capture the hosted header — the harness itself is broken.")
                tearDownHostedWindow()
                continue
            }
            let peak = peakInkDeviation(rep, viewSize: size, in: band, background: background)
            tearDownHostedWindow()

            XCTAssertGreaterThan(
                peak, 0.3,
                """
                \(colorScheme): "untitled" failed to read with legible contrast against the resolved header \
                background \(background) — peak ink deviation was only \(peak). ToolbarView.headerForeground/
                headerForegroundDimmed are derived from headerBackground automatically, so this must hold — \
                but that is a claim about real pixels, not something this suite may merely assume.
                """
            )
        }
    }

    // MARK: - 3. Pane identity — the regression guard for "completely erased"

    // A stateless Rectangle().fill(color(for: id)) would prove nothing, since SwiftUI re-evaluates body regardless of remount; only @State captured in .onAppear can tell genuine remount from in-place update.
    private struct PaneIdentityProbeView: View {
        let id: UUID
        @State private var capturedColor: NSColor = .clear

        var body: some View {
            Rectangle()
                .fill(Color(nsColor: capturedColor))
                .onAppear {
                    capturedColor = Self.color(for: id)
                }
        }

        static func color(for id: UUID) -> NSColor {
            let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
            let combined = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let hue = Double(combined % 360) / 360.0
            return NSColor(hue: hue, saturation: 0.85, brightness: 0.85, alpha: 1)
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_paneIdentity_switchingActiveTabBetweenTwoNoteDocuments_producesAGenuinelyDifferentRenderedPane

    func test_paneIdentity_switchingActiveTabBetweenTwoNoteDocuments_producesAGenuinelyDifferentRenderedPane() {
        let idA = UUID()
        let idB = UUID()

        let previousHook = env.extensionPoints.notesEditor
        env.extensionPoints.notesEditor = { id in AnyView(PaneIdentityProbeView(id: id)) }
        defer { env.extensionPoints.notesEditor = previousHook }

        let tabAID = env.openTab(
            url: URL(string: "orbit://note/\(idA.uuidString)")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )
        let tabBID = env.openTab(
            url: URL(string: "orbit://note/\(idB.uuidString)")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )
        defer { cleanup([tabAID, tabBID]) }

        env.activateTab(tabAID)

        let size = CGSize(width: 500, height: 400)
        let host = hostLiveWindow(ContentCardView().environment(env), size: size)
        pump(seconds: 0.3)

        let probePoint = NSPoint(x: 150, y: Double(OrbitToolbarMetrics.totalHeight) + 40)

        // Must compare only against other captures from this same cacheDisplay pipeline, never PaneIdentityProbeView's raw NSColor(hue:...) value, since the two can differ past tolerance despite reading identically.
        func capture(_ label: String) -> NSColor? {
            guard let color = capturedColor(of: host, at: probePoint, viewSize: size) else {
                XCTFail("Could not capture the hosted pane's pixels while showing \(label) — the harness itself is broken.")
                return nil
            }
            return color
        }

        guard let colorA1 = capture("Note A (first activation)") else { return }

        env.activateTab(tabBID)
        pump(seconds: 0.3)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let colorB = capture("Note B") else { return }

        env.activateTab(tabAID)
        pump(seconds: 0.3)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let colorA2 = capture("Note A (second activation)") else { return }

        XCTAssertFalse(
            colorsApproximatelyEqual(colorB, colorA1),
            """
            Switching the active tab to Note B still rendered Note A's probe colour (A: \(colorA1), B: \(colorB)). \
            SingleTabContentView.paneContent (Orbit/UI/Content/ContentCardView.swift) treated the switch as an update \
            to the same view identity rather than a teardown-and-remount — the exact "click off and click back on, the \
            notes get completely erased" mechanism this file documents. The fix is the \
            `.id(documentSurfaceIdentity(kind:id:))` on the note/easel branch of that switch's ZStack.
            """
        )
        XCTAssertTrue(
            colorsApproximatelyEqual(colorA2, colorA1),
            """
            Switching back to Note A's own tab rendered a third, different colour (first visit: \(colorA1), \
            second visit: \(colorA2)) instead of Note A's own, consistent identity. A colour that merely *changes* \
            on every switch would already satisfy "genuinely different" without proving *whose* document is showing —
            this is the check that it is really Note A's own remounted pane both times, not drift or noise.
            """
        )
    }
}
