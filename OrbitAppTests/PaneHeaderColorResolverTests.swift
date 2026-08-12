import AppKit
import XCTest
@testable import Orbit

@MainActor
final class PaneHeaderColorResolverTests: XCTestCase {

    private let tabID: TabID = UUID()

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
    }

    private func solidImage(_ color: NSColor) -> NSImage {
        let size = CGSize(width: 4, height: 4)
        let image = NSImage(size: size)
        image.lockFocus()
        color.usingColorSpace(.sRGB)?.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func page(returning serialized: String?, ready: Bool = true) -> MockWebContents {
        let mock = MockWebContents()
        mock.evaluateJavaScriptHandler = { _ in
            ["color": serialized.map { $0 as Any } ?? NSNull(), "ready": ready]
        }
        return mock
    }

    // MARK: - The screen is never captured

    func test_sample_neverCapturesTheScreen() async {
        let url = URL(string: "https://no-screen-capture.example.com")!
        let mock = page(returning: "#336699")

        let sampled = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)

        XCTAssertNotNil(sampled, "Test precondition: the stubbed page does declare a colour.")
        XCTAssertEqual(
            mock.capturePreviewCallCount, 0,
            "Resolving a pane header colour must never capture the page's pixels: that path reaches ScreenCaptureKit on the shipping engine and makes macOS ask the user for Screen Recording permission."
        )
    }

    func test_sample_evaluatesThePageThemeColorProbe() async {
        let url = URL(string: "https://probe.example.com")!
        let mock = page(returning: "#336699")

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)

        XCTAssertEqual(mock.evaluateJavaScriptCallCount, 1)
        XCTAssertEqual(
            mock.lastEvaluatedScript, PageThemeColorScript.source,
            "The resolver must evaluate the shared probe (Orbit/Engine/PageThemeColorScript.swift), not a re-typed copy of it."
        )
    }

    // MARK: - Declared theme colour -> glyph colour

    func test_sample_darkThemeColorResolvesToLightGlyphs() async {
        let url = URL(string: "https://dark-site.example.com")!
        let mock = page(returning: "#0d1117")

        guard let sampled = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock) else {
            XCTFail("Expected the declared theme colour to resolve.")
            return
        }

        XCTAssertEqual(sampled.red, 0x0D / 255.0, accuracy: 0.01)
        XCTAssertEqual(sampled.green, 0x11 / 255.0, accuracy: 0.01)
        XCTAssertEqual(sampled.blue, 0x17 / 255.0, accuracy: 0.01)
        XCTAssertEqual(
            PaneHeaderColorResolver.foreground(for: sampled), .light,
            "A near-black page header must take light glyphs, whatever the system appearance is."
        )
    }

    func test_sample_lightThemeColorResolvesToDarkGlyphs() async {
        let url = URL(string: "https://light-site.example.com")!
        let mock = page(returning: "#f5f5f7")

        guard let sampled = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock) else {
            XCTFail("Expected the declared theme colour to resolve.")
            return
        }

        XCTAssertEqual(sampled.red, 0xF5 / 255.0, accuracy: 0.01)
        XCTAssertEqual(
            PaneHeaderColorResolver.foreground(for: sampled), .dark,
            "A near-white page header must take dark glyphs, whatever the system appearance is."
        )
    }

    func test_sample_glyphColourFlipsWithThePage() async {
        let darkURL = URL(string: "https://flip-dark.example.com")!
        let lightURL = URL(string: "https://flip-light.example.com")!

        let dark = await PaneHeaderColorResolver.shared.sample(tab: UUID(), url: darkURL, contents: page(returning: "rgba(17, 17, 17, 1)"))
        let light = await PaneHeaderColorResolver.shared.sample(tab: UUID(), url: lightURL, contents: page(returning: "rgba(250, 250, 250, 1)"))

        guard let dark, let light else {
            XCTFail("Expected both stubbed pages to resolve a colour.")
            return
        }
        XCTAssertEqual(PaneHeaderColorResolver.foreground(for: dark), .light)
        XCTAssertEqual(PaneHeaderColorResolver.foreground(for: light), .dark)
        XCTAssertNotEqual(
            PaneHeaderColorResolver.foreground(for: dark),
            PaneHeaderColorResolver.foreground(for: light),
            "The glyph colour must be derived from the page's own colour — two pages at opposite ends of the luminance range cannot land on the same answer."
        )
    }

    // MARK: - foreground(for:)

    func test_foreground_thresholdIsTheResolvedBackgroundsLuminance() {
        // Mid-grey either side of the L > 0.5 threshold.
        XCTAssertEqual(PaneHeaderColorResolver.foreground(for: ThemeColor(red: 0.60, green: 0.60, blue: 0.60)), .dark)
        XCTAssertEqual(PaneHeaderColorResolver.foreground(for: ThemeColor(red: 0.40, green: 0.40, blue: 0.40)), .light)
        // Luminance is weighted, not a plain average: saturated blue is dark,
        // saturated green is light despite no red and no blue.
        XCTAssertEqual(PaneHeaderColorResolver.foreground(for: ThemeColor(red: 0, green: 0, blue: 1)), .light)
        XCTAssertEqual(PaneHeaderColorResolver.foreground(for: ThemeColor(red: 0, green: 1, blue: 0)), .dark)
    }

    // MARK: - Readiness polling

    func test_sample_reReadsAPageThatIsStillLoading() async {
        let url = URL(string: "https://slow-head.example.com")!
        let mock = MockWebContents()
        var reads = 0
        mock.evaluateJavaScriptHandler = { _ in
            reads += 1
            if reads < 3 { return ["color": NSNull(), "ready": false] }
            return ["color": "#123456", "ready": true]
        }

        let sampled = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)

        XCTAssertEqual(reads, 3, "The resolver must keep asking while the document reports itself loading.")
        XCTAssertEqual(sampled?.blue ?? -1, 0x56 / 255.0, accuracy: 0.01)
    }

    func test_sample_stopsAskingOnceAFinishedPageHasNoColour() async {
        let url = URL(string: "https://colourless.example.com")!
        let mock = page(returning: nil, ready: true)

        let sampled = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)

        XCTAssertNil(sampled, "A finished page with no declared colour and no painted background resolves to nothing — the header falls back to its neutral.")
        XCTAssertEqual(mock.evaluateJavaScriptCallCount, 1, "A page that says it has finished loading must be asked exactly once.")
        XCTAssertNil(PaneHeaderColorResolver.shared.cachedColor(for: url), "A miss must not be cached as a colour.")
    }

    // MARK: - Live per-tab readings, and the URL hint behind them

    func test_sample_recordsTheResultAsThisTabsLiveReadingAndAsAURLHint() async {
        let url = URL(string: "https://cache-test.example.com")!
        let mock = page(returning: "rgba(26, 26, 230, 1)")

        XCTAssertNil(PaneHeaderColorResolver.shared.cachedColor(for: url), "Test precondition: nothing resolved yet.")

        let sampled = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)
        XCTAssertNotNil(sampled, "Expected sample(tab:url:contents:) to resolve a colour from the stubbed page.")
        XCTAssertEqual(sampled?.blue ?? 0, 230.0 / 255.0, accuracy: 0.01)

        XCTAssertEqual(
            PaneHeaderColorResolver.shared.color(forTab: tabID, url: url), sampled,
            "The resolved colour must be readable back as this tab's live reading — that is what ToolbarView and PageScrollerColorScheme both read out of their bodies."
        )
        XCTAssertEqual(
            PaneHeaderColorResolver.shared.cachedColor(for: url), sampled,
            "It must also land as the URL's first-paint hint, so re-opening this address paints its header immediately instead of flashing the neutral fallback."
        )
    }

    func test_sample_reReadsAPageItAlreadyResolvedOnce_becauseColourIsNotAPropertyOfTheURL() async {
        let url = URL(string: "https://re-reads.example.com")!
        let mock = MockWebContents()
        var answer = "rgba(128, 128, 128, 1)"
        mock.evaluateJavaScriptHandler = { _ in ["color": answer, "ready": true] }

        let first = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)
        XCTAssertEqual(mock.evaluateJavaScriptCallCount, 1, "Test precondition: the first sample reads the page exactly once.")
        XCTAssertEqual(first?.blue ?? -1, 128.0 / 255.0, accuracy: 0.01)

        // Repaints itself black without navigating — a theme toggle.
        answer = "rgba(0, 0, 0, 1)"
        let second = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)

        XCTAssertEqual(mock.evaluateJavaScriptCallCount, 2, "The same URL must be re-readable: a page can change colour without navigating.")
        XCTAssertEqual(second?.blue ?? -1, 0.0, accuracy: 0.01, "The re-read must return what the page says now, not what it said the first time.")
        XCTAssertEqual(
            PaneHeaderColorResolver.shared.color(forTab: tabID, url: url)?.blue ?? -1, 0.0, accuracy: 0.01,
            "And the tab's live reading must have moved with it — this is the value the header actually paints."
        )
    }

    func test_sample_aPageThatLosesItsColour_isNotRepaintedFromItsOwnStaleHint() async {
        let url = URL(string: "https://loses-colour.example.com")!
        let mock = MockWebContents()
        var answer: String? = "#ff0000"
        mock.evaluateJavaScriptHandler = { _ in
            ["color": answer.map { $0 as Any } ?? NSNull(), "ready": true]
        }

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)
        XCTAssertNotNil(PaneHeaderColorResolver.shared.cachedColor(for: url), "Test precondition: the first read left a URL hint.")

        answer = nil
        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)

        XCTAssertNil(
            PaneHeaderColorResolver.shared.color(forTab: tabID, url: url),
            "A page read to completion with no colour is an answer. Returning the stale hint here would leave the header painted with a colour the page no longer has."
        )
    }

    func test_color_aReadingTakenAtAnotherURLIsNeverHandedBackForThisOne() async {
        let oldURL = URL(string: "https://before.example.com")!
        let newURL = URL(string: "https://after.example.com")!

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: oldURL, contents: page(returning: "#ff0000"))

        XCTAssertNotNil(PaneHeaderColorResolver.shared.color(forTab: tabID, url: oldURL), "Test precondition: the reading exists for the URL it was taken from.")
        XCTAssertNil(
            PaneHeaderColorResolver.shared.color(forTab: tabID, url: newURL),
            "The same tab at a different URL is a different page; its previous reading must not tint it."
        )
    }

    func test_sample_twoTabsAtTheSameURLKeepIndependentLiveReadings() async {
        let url = URL(string: "https://shared-address.example.com")!
        let tabA: TabID = UUID()
        let tabB: TabID = UUID()

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabA, url: url, contents: page(returning: "#ffffff"))
        _ = await PaneHeaderColorResolver.shared.sample(tab: tabB, url: url, contents: page(returning: "#0d1117"))

        XCTAssertEqual(PaneHeaderColorResolver.shared.color(forTab: tabA, url: url)?.red ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(PaneHeaderColorResolver.shared.color(forTab: tabB, url: url)?.red ?? -1, 0x0D / 255.0, accuracy: 0.01)
        XCTAssertEqual(
            PaneHeaderColorResolver.foreground(for: PaneHeaderColorResolver.shared.color(forTab: tabA, url: url)!), .dark
        )
        XCTAssertEqual(
            PaneHeaderColorResolver.foreground(for: PaneHeaderColorResolver.shared.color(forTab: tabB, url: url)!), .light,
            "Two panes on the same address resolved different colours; each must keep its own, including its own glyph colour."
        )
    }

    func test_color_fallsBackToTheURLHintForATabWithNoReadingOfItsOwn() async {
        let url = URL(string: "https://hinted.example.com")!
        _ = await PaneHeaderColorResolver.shared.sample(tab: UUID(), url: url, contents: page(returning: "#123456"))

        let freshTab: TabID = UUID()
        XCTAssertEqual(
            PaneHeaderColorResolver.shared.color(forTab: freshTab, url: url)?.blue ?? -1, 0x56 / 255.0, accuracy: 0.01,
            "A tab with no reading of its own paints from the address's first-paint hint."
        )
    }

    func test_forget_dropsTheTabsLiveReadingAndKeepsTheURLHint() async {
        let url = URL(string: "https://closed-tab.example.com")!
        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: page(returning: "#abcdef"))

        PaneHeaderColorResolver.shared.forget(tab: tabID)

        XCTAssertNotNil(
            PaneHeaderColorResolver.shared.cachedColor(for: url),
            "Closing a tab must not throw away what Orbit learned about the address — that hint is what paints the header instantly if the page is reopened."
        )
    }

    func test_sample_differentURLsResolveIndependently() async {
        let urlA = URL(string: "https://site-a.example.com")!
        let urlB = URL(string: "https://site-b.example.com")!

        _ = await PaneHeaderColorResolver.shared.sample(tab: UUID(), url: urlA, contents: page(returning: "#ff0000"))
        _ = await PaneHeaderColorResolver.shared.sample(tab: UUID(), url: urlB, contents: page(returning: "#0000ff"))

        XCTAssertEqual(PaneHeaderColorResolver.shared.cachedColor(for: urlA)?.red ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(PaneHeaderColorResolver.shared.cachedColor(for: urlB)?.blue ?? 0, 1.0, accuracy: 0.01)
    }

    // MARK: - Observation

    func test_sample_notifiesObserversOfTheCacheWhenAColourResolves() async {
        let url = URL(string: "https://observable.example.com")!
        let notified = expectation(description: "an observer of cachedColor(for:) is invalidated when the colour lands")

        withObservationTracking {
            _ = PaneHeaderColorResolver.shared.cachedColor(for: url)
        } onChange: {
            notified.fulfill()
        }

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: page(returning: "#ffffff"))

        await fulfillment(of: [notified], timeout: 1)
        XCTAssertNotNil(
            PaneHeaderColorResolver.shared.cachedColor(for: url),
            "Test precondition: the stubbed page does resolve a colour."
        )
    }

    func test_sample_doesNotNotifyHintObserversWhenThePageHasNoColour() async {
        let url = URL(string: "https://observable-miss.example.com")!
        var notifications = 0

        withObservationTracking {
            _ = PaneHeaderColorResolver.shared.cachedColor(for: url)
        } onChange: {
            notifications += 1
        }

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: page(returning: nil, ready: true))

        XCTAssertEqual(notifications, 0, "A colourless page writes no hint, so it must invalidate no observer of one.")
    }

    func test_sample_notifiesObserversOfTheLiveReadingWhenAColourResolves() async {
        let url = URL(string: "https://observable-live.example.com")!
        let notified = expectation(description: "an observer of color(forTab:url:) is invalidated when the colour lands")

        withObservationTracking {
            _ = PaneHeaderColorResolver.shared.color(forTab: tabID, url: url)
        } onChange: {
            notified.fulfill()
        }

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: page(returning: "#0d1117"))

        await fulfillment(of: [notified], timeout: 1)
    }

    // Guards a loop: ToolbarView's .task(id:) calls sample and a write invalidates every
    // observer, so an unchanged answer that still counted as a change would loop forever.
    func test_sample_reResolvingTheSameColourInvalidatesNobody() async {
        let url = URL(string: "https://stable-colour.example.com")!
        let mock = page(returning: "#336699")

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)

        var notifications = 0
        withObservationTracking {
            _ = PaneHeaderColorResolver.shared.color(forTab: tabID, url: url)
        } onChange: {
            notifications += 1
        }

        _ = await PaneHeaderColorResolver.shared.sample(tab: tabID, url: url, contents: mock)

        XCTAssertEqual(
            notifications, 0,
            "A re-read that finds the page unchanged must write nothing: it is called from a task that a write would re-trigger."
        )
    }

    // MARK: - The painted colour is the colour the glyphs are picked for

    func test_composited_leavesAnOpaqueColourExactlyAsItIs() {
        let neutral = ThemeColor(red: 0.16, green: 0.155, blue: 0.18)
        let opaque = ThemeColor(red: 0.95, green: 0.95, blue: 0.97)

        let painted = opaque.composited(over: neutral)

        XCTAssertEqual(painted.red, opaque.red, accuracy: 0.0001)
        XCTAssertEqual(painted.green, opaque.green, accuracy: 0.0001)
        XCTAssertEqual(painted.blue, opaque.blue, accuracy: 0.0001)
        XCTAssertEqual(painted.alpha, 1.0, accuracy: 0.0001)
    }

    func test_composited_flattensATranslucentColourOntoWhatIsBehindIt() {
        let neutral = ThemeColor(red: 0.2, green: 0.2, blue: 0.2)
        let halfWhite = ThemeColor(red: 1, green: 1, blue: 1, alpha: 0.5)

        let painted = halfWhite.composited(over: neutral)

        XCTAssertEqual(painted.red, 0.6, accuracy: 0.0001)
        XCTAssertEqual(painted.green, 0.6, accuracy: 0.0001)
        XCTAssertEqual(painted.blue, 0.6, accuracy: 0.0001)
        XCTAssertEqual(painted.alpha, 1.0, accuracy: 0.0001, "A composited colour is opaque — that is the point of compositing it.")
    }

    func test_foreground_followsThePaintedColourNotTheDeclaredOne() {
        let neutral = ThemeColor(red: 0.16, green: 0.155, blue: 0.18)
        let declared = ThemeColor(red: 1, green: 1, blue: 1, alpha: 0.08)

        XCTAssertGreaterThan(declared.luminance, 0.5, "Test precondition: the declared colour reads as light on its own.")
        XCTAssertEqual(
            PaneHeaderColorResolver.foreground(for: declared), .dark,
            "Test precondition: taken raw, this colour would ask for dark glyphs."
        )

        let painted = declared.composited(over: neutral)

        XCTAssertLessThan(painted.luminance, 0.5, "Barely-there white over a dark neutral paints dark.")
        XCTAssertEqual(
            PaneHeaderColorResolver.foreground(for: painted), .light,
            "refs/ARC_PANE_CHROME.md point 4: glyphs are picked from the resolved background that is actually painted, so a translucent page colour cannot leave dark glyphs on a dark bar."
        )
    }

    // MARK: - orbitAverageColor()

    func test_orbitAverageColor_recoversASolidColor() {
        let source = NSColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 1.0)
        guard let averaged = solidImage(source).orbitAverageColor() else {
            XCTFail("Expected orbitAverageColor() to resolve a colour for a solid-fill image.")
            return
        }
        let resolved = averaged.usingColorSpace(.sRGB) ?? averaged
        XCTAssertEqual(Double(resolved.redComponent), 0.2, accuracy: 0.05)
        XCTAssertEqual(Double(resolved.greenComponent), 0.7, accuracy: 0.05)
        XCTAssertEqual(Double(resolved.blueComponent), 0.4, accuracy: 0.05)
    }
}

final class PageThemeColorScriptTests: XCTestCase {

    func test_decode_readsAnOpaqueHexColour() {
        let reading = PageThemeColorScript.decode(["color": "#0d1117", "ready": true])
        guard let color = reading?.color?.usingColorSpace(.sRGB) else {
            XCTFail("Expected #0d1117 to decode.")
            return
        }
        XCTAssertEqual(Double(color.redComponent), 0x0D / 255.0, accuracy: 0.01)
        XCTAssertEqual(Double(color.greenComponent), 0x11 / 255.0, accuracy: 0.01)
        XCTAssertEqual(Double(color.blueComponent), 0x17 / 255.0, accuracy: 0.01)
        XCTAssertEqual(Double(color.alphaComponent), 1.0, accuracy: 0.01)
        XCTAssertEqual(reading?.isReady, true)
    }

    func test_decode_readsAnRGBAColourWithItsAlpha() {
        let reading = PageThemeColorScript.decode(["color": "rgba(255, 128, 0, 0.5)", "ready": true])
        guard let color = reading?.color?.usingColorSpace(.sRGB) else {
            XCTFail("Expected rgba(...) to decode.")
            return
        }
        XCTAssertEqual(Double(color.redComponent), 1.0, accuracy: 0.01)
        XCTAssertEqual(Double(color.greenComponent), 128.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(Double(color.blueComponent), 0.0, accuracy: 0.01)
        XCTAssertEqual(Double(color.alphaComponent), 0.5, accuracy: 0.01)
    }

    func test_decode_reportsNoColourRatherThanGuessingAtSomethingUnrecognised() {
        XCTAssertNil(PageThemeColorScript.decode(["color": "cornflowerblue", "ready": true])?.color)
        XCTAssertNil(PageThemeColorScript.decode(["color": "#abc", "ready": true])?.color)
        XCTAssertNil(PageThemeColorScript.decode(["color": "rgb(1, 2, 3)", "ready": true])?.color)
        XCTAssertNil(PageThemeColorScript.decode(["color": NSNull(), "ready": true])?.color)
    }

    func test_decode_treatsAMissingReadyFlagAsNotReady() {
        XCTAssertEqual(PageThemeColorScript.decode(["color": NSNull()])?.isReady, false)
        XCTAssertNil(PageThemeColorScript.decode("not a payload at all"))
        XCTAssertNil(PageThemeColorScript.decode(nil))
    }

    func test_source_readsTheStandardMechanismsAndMutatesNothing() {
        let source = PageThemeColorScript.source
        XCTAssertTrue(source.contains("meta[name=\"theme-color\"]"), "The declared theme colour is the standard input and must be read first.")
        XCTAssertTrue(source.contains("getComputedStyle"), "The computed background of body/html is the documented fallback.")
        XCTAssertTrue(source.contains("document.readyState"), "The payload must report readiness so the resolver can tell 'no colour' from 'not yet'.")
        XCTAssertFalse(source.contains("appendChild"), "The probe must not insert anything into the page it is measuring.")
        XCTAssertFalse(source.contains("document.write"), "The probe must not write to the page it is measuring.")
    }
}

/// Regression cover: the scrollbar used to draw from the app's NSAppearance instead of
/// the page's colour, putting dark chrome down a white page under a dark-appearance window.
@MainActor
final class PageColorSchemeScriptTests: XCTestCase {

    // MARK: - Which scheme a page gets

    func test_scheme_aLightPageDeclaresLight() {
        XCTAssertEqual(PageColorSchemeScript.scheme(for: ThemeColor(red: 1, green: 1, blue: 1)), .light)
        XCTAssertEqual(PageColorSchemeScript.scheme(for: ThemeColor(red: 0.973, green: 0.976, blue: 0.980)), .light)
    }

    func test_scheme_aDarkPageDeclaresDark() {
        XCTAssertEqual(PageColorSchemeScript.scheme(for: ThemeColor(red: 0x0D / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0)), .dark)
    }

    func test_scheme_ignoresTheSystemAppearanceEntirely() {
        let white = ThemeColor(red: 1, green: 1, blue: 1)
        let nearBlack = ThemeColor(red: 0.05, green: 0.07, blue: 0.09)
        let original = NSApp.appearance
        defer { NSApp.appearance = original }

        NSApp.appearance = NSAppearance(named: .darkAqua)
        let lightUnderDarkApp = PageColorSchemeScript.scheme(for: white)
        let darkUnderDarkApp = PageColorSchemeScript.scheme(for: nearBlack)

        NSApp.appearance = NSAppearance(named: .aqua)
        let lightUnderLightApp = PageColorSchemeScript.scheme(for: white)
        let darkUnderLightApp = PageColorSchemeScript.scheme(for: nearBlack)

        XCTAssertEqual(lightUnderDarkApp, .light, "A white page under a dark-appearance app is what the user reported: it must still be treated as light.")
        XCTAssertEqual(lightUnderDarkApp, lightUnderLightApp, "The scheme a page declares must follow the page, never the app's appearance.")
        XCTAssertEqual(darkUnderDarkApp, .dark)
        XCTAssertEqual(darkUnderDarkApp, darkUnderLightApp, "The scheme a page declares must follow the page, never the app's appearance.")
    }

    func test_scheme_neverDisagreesWithThePaneHeadersOwnRule() {
        for step in 0...20 {
            let level = Double(step) / 20.0
            let color = ThemeColor(red: level, green: level, blue: level)
            let expected: PageColorSchemeScript.Scheme =
                PaneHeaderColorResolver.foreground(for: color) == .dark ? .light : .dark
            XCTAssertEqual(
                PageColorSchemeScript.scheme(for: color), expected,
                "At luminance \(color.luminance) the scroller and the pane header disagreed about whether the page is light or dark."
            )
        }
    }

    func test_scheme_followsThePaintedColourNotTheDeclaredOne() {
        XCTAssertEqual(PageColorSchemeScript.undeclaredDocumentCanvas, ThemeColor(red: 1, green: 1, blue: 1))

        let barelyThereBlack = ThemeColor(red: 0, green: 0, blue: 0, alpha: 0.05)
        XCTAssertLessThan(barelyThereBlack.luminance, 0.5, "Test precondition: taken raw, this colour reads as dark.")
        XCTAssertEqual(
            PageColorSchemeScript.scheme(for: barelyThereBlack), .light,
            "A 5%-black page background paints as near-white over the engine's canvas, so it is a light page and must declare light."
        )
    }

    // MARK: - The script text, which is what both backends run

    func test_source_declaresOnlyAColourSchemeAndTouchesNothingElse() {
        for scheme in [PageColorSchemeScript.Scheme.light, .dark] {
            let source = PageColorSchemeScript.source(applying: scheme)

            XCTAssertTrue(source.contains("root.style.setProperty('color-scheme', value)"), "The declaration is an inline `color-scheme` on the root element — the standard, engine-agnostic lever (CSS Color Adjust Level 1).")
            XCTAssertTrue(source.contains("var value = '\(scheme.rawValue)';"), "The script must declare the scheme it was asked for.")
            XCTAssertTrue(source.contains("getComputedStyle"), "The author's own declaration has to be read from the *computed* value, so a scheme set from a stylesheet or a <meta name=\"color-scheme\"> counts.")
            XCTAssertTrue(source.contains("'normal'"), "'normal' is the initial value, and the only state Orbit is allowed to write over.")

            XCTAssertFalse(source.contains("appendChild"), "Nothing may be inserted into the page.")
            XCTAssertFalse(source.contains("document.write"), "Nothing may be written to the page.")
            XCTAssertFalse(source.contains("innerHTML"), "The page's markup must not be rewritten.")
            XCTAssertFalse(source.contains("dataset"), "The marker must stay off the DOM — a data- attribute is visible to the page's own selectors and serialises into outerHTML.")
            XCTAssertFalse(source.contains("classList"), "No class may be added to the page.")
            XCTAssertFalse(source.contains("prefers-color-scheme"), "The page must keep seeing the user's real system appearance; this feature must never touch the media query.")
            XCTAssertFalse(source.contains(":root"), "A `:root` rule of Orbit's own (specificity 0,1,0) would silently outrank the `html { ... }` (0,0,1) pages actually use — the declaration has to be inline and only ever on a page that declared nothing.")
        }
    }

    func test_scheme_onlyEverDeclaresLightOrDark() {
        XCTAssertEqual(PageColorSchemeScript.Scheme.light.rawValue, "light")
        XCTAssertEqual(PageColorSchemeScript.Scheme.dark.rawValue, "dark")
        XCTAssertNil(PageColorSchemeScript.Scheme(rawValue: "normal"))
        XCTAssertNil(PageColorSchemeScript.decode(["applied": "normal", "authorDeclared": false])?.applied)
    }

    // MARK: - apply(_:to:)

    func test_apply_evaluatesTheSharedScriptRatherThanARetypedCopy() async {
        let mock = MockWebContents()
        mock.evaluateJavaScriptHandler = { _ in ["applied": "light", "authorDeclared": false] }

        let outcome = await PageColorSchemeScript.apply(.light, to: mock)

        XCTAssertEqual(mock.evaluateJavaScriptCallCount, 1)
        XCTAssertEqual(
            mock.lastEvaluatedScript, PageColorSchemeScript.source(applying: .light),
            "The declaration must go through the shared script (Orbit/Engine/PageColorSchemeScript.swift) so both engine backends run identical text."
        )
        XCTAssertEqual(outcome, PageColorSchemeScript.Outcome(applied: .light, authorDeclared: false))
    }

    func test_apply_reportsWhenThePageDeclaresItsOwnSchemeAndOrbitWroteNothing() async {
        let mock = MockWebContents()
        mock.evaluateJavaScriptHandler = { _ in ["applied": NSNull(), "authorDeclared": true] }

        let outcome = await PageColorSchemeScript.apply(.dark, to: mock)

        XCTAssertEqual(outcome?.authorDeclared, true)
        XCTAssertNil(outcome?.applied, "Nothing may be written over a page's own declaration.")
    }

    func test_decode_treatsAnUnrecognisedPayloadAsNoReading() {
        XCTAssertNil(PageColorSchemeScript.decode(nil))
        XCTAssertNil(PageColorSchemeScript.decode("not a payload at all"))
        XCTAssertEqual(PageColorSchemeScript.decode([:]), PageColorSchemeScript.Outcome(applied: nil, authorDeclared: false))
        // A JS boolean arrives as an NSNumber through both backends' bridges.
        XCTAssertEqual(PageColorSchemeScript.decode(["applied": NSNull(), "authorDeclared": NSNumber(value: 1)])?.authorDeclared, true)
    }
}

final class PageColorObserverScriptTests: XCTestCase {

    private var observerSource: String {
        PageColorObserverScript.source(postExpression: PageColorObserverScript.chromiumPostExpression)
    }

    /// Strips `//` comments, or a "must NOT appear" assertion below would false-positive on the script's own commentary about what it avoids.
    private var observerCodeOnly: String {
        observerSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - One rule, shared with the pull

    func test_source_embedsTheSharedResolutionRuleRatherThanACopyOfIt() {
        XCTAssertTrue(
            observerSource.contains(PageThemeColorScript.resolverSource),
            "The observer must embed PageThemeColorScript.resolverSource verbatim — the same fragment PaneHeaderColorResolver's one-shot probe runs."
        )
        XCTAssertTrue(
            PageThemeColorScript.source.contains(PageThemeColorScript.resolverSource),
            "...and so must the probe, or 'shared' means nothing."
        )
    }

    func test_resolverSource_carriesTheSwiftOpacityThreshold() {
        XCTAssertTrue(
            PageThemeColorScript.resolverSource.contains("> \(PageThemeColorScript.minimumOpaqueAlpha)"),
            "The page-side alpha rule must be interpolated from PageThemeColorScript.minimumOpaqueAlpha, not hardcoded beside it."
        )
    }

    // MARK: - Every input is subscribed to

    func test_source_followsTheViewportAndEveryDeclaredMediaQuery() {
        XCTAssertTrue(observerSource.contains("window.matchMedia(queries[j])"), "Each declared `media` attribute must get its own matchMedia listener.")
        XCTAssertTrue(observerSource.contains("__orbitDeclaredMediaQueries()"), "The query list must come from the same code that chooses between the metas.")
        XCTAssertTrue(observerSource.contains("addEventListener('resize', schedule)"), "A responsive page can change what it paints at a breakpoint without declaring any theme-color.")
    }

    func test_source_reReadsWhenTheScrollPositionSettles() {
        XCTAssertTrue(
            observerSource.contains("document.addEventListener('scroll', scheduleAfterScrollSettles, { passive: true, capture: true })"),
            "Scroll must be watched, with capture:true (scroll does not bubble, so a page whose top region is its own scrolling container would otherwise never report) and passive:true (it must never be able to delay a scroll)."
        )
    }

    func test_source_debouncesScrollRatherThanThrottlingIt() {
        XCTAssertFalse(
            observerCodeOnly.contains("addEventListener('scroll', schedule,"),
            "Scroll must not go through the shared trailing throttle: that runs a 1.68ms synchronous band read four times a second in the middle of a fling."
        )
        XCTAssertTrue(observerSource.contains("if (scrollTimer !== null) { clearTimeout(scrollTimer); }"), "Each scroll event must reset the quiet timer — that is what makes it a debounce.")

        let quietMS = Int(PageColorObserverScript.scrollQuietInterval.components.attoseconds / 1_000_000_000_000_000)
        XCTAssertTrue(
            observerSource.contains("SCROLL_QUIET_MS = \(quietMS)"),
            "The quiet period must come from PageColorObserverScript.scrollQuietInterval, not a literal in the script."
        )
        XCTAssertLessThan(
            PageColorObserverScript.scrollQuietInterval, PageColorObserverScript.minimumPostInterval,
            "The scroll debounce must be shorter than the post throttle, or settling a scroll would wait out both in series before the chrome moved."
        )
    }

    func test_source_alwaysSubscribesToPrefersColorScheme() {
        XCTAssertTrue(
            observerSource.contains("'(prefers-color-scheme: dark)'"),
            "Subscribed unconditionally, not only when a meta declares it: a page whose <body> background comes from its own prefers-color-scheme rules declares no theme-color at all."
        )
    }

    func test_source_watchesSinglePageAppNavigation() {
        XCTAssertFalse(
            observerSource.contains("history[name] = function"),
            "history.pushState/.replaceState must not be wrapped — that is a native-function-integrity tell (Function.prototype.toString on it no longer reads '[native code]'), exactly the kind of check commercial anti-bot scripts run. SPA navigation without a popstate must instead be caught by the idle safety-net interval."
        )
        XCTAssertTrue(observerSource.contains("addEventListener('popstate', schedule)"))
        XCTAssertTrue(observerSource.contains("addEventListener('hashchange', schedule)"))
        let idleMS = Int(PageColorObserverScript.idleReReadInterval.components.seconds * 1000)
        XCTAssertTrue(
            observerSource.contains("IDLE_RE_READ_MS = \(idleMS)"),
            "A pushState-driven SPA route change with no matching popstate must be caught by the same idle safety-net interval that already covers CSSOM-only restyles."
        )
    }

    func test_source_watchesTheHeadDeeplyAndTheTwoPaintedRootsShallowly() {
        XCTAssertTrue(observerSource.contains("headObserver.observe(document.head"), "The <head> is where theme-color metas live.")
        XCTAssertTrue(observerSource.contains("attributeFilter: ['content', 'media', 'name']"), "A meta can change by any of those three.")
        XCTAssertTrue(observerSource.contains("rootObserver.observe(document.documentElement, { attributes: true })"))
        XCTAssertTrue(observerSource.contains("rootObserver.observe(document.body, { attributes: true })"))
        XCTAssertFalse(
            observerSource.contains("rootObserver.observe(document.body, { attributes: true, subtree: true"),
            "A subtree observer on <body> would fire on every DOM write the page makes — that is the version of this that burns CPU."
        )
    }

    // MARK: - Idle cost

    func test_source_doesNotPollAtFrameRate() {
        XCTAssertFalse(
            observerCodeOnly.contains("requestAnimationFrame"),
            "A rAF loop would re-read the computed background ~60 times a second on a completely static page. (Checked against the code only — the script's commentary explains this decision and must stay free to name it.)"
        )
        let idleMS = Int(PageColorObserverScript.idleReReadInterval.components.seconds * 1000)
        XCTAssertTrue(
            observerSource.contains("IDLE_RE_READ_MS = \(idleMS)"),
            "The safety-net cadence must come from PageColorObserverScript.idleReReadInterval, not a literal in the script."
        )
        XCTAssertTrue(
            observerSource.contains("if (document.hidden) { return; }"),
            "A tab the user cannot see must cost nothing; visibilitychange re-reads when it comes back."
        )
    }

    func test_source_coalescesBurstsAndNeverPostsTheSameColourTwice() {
        let intervalMS = Int(PageColorObserverScript.minimumPostInterval.components.attoseconds / 1_000_000_000_000_000)
        XCTAssertTrue(
            observerSource.contains("MINIMUM_POST_INTERVAL_MS = \(intervalMS)"),
            "The throttle floor must come from PageColorObserverScript.minimumPostInterval."
        )
        XCTAssertTrue(
            observerSource.contains("if (pendingTimer !== null) { return; }"),
            "Every trigger must schedule rather than evaluate, so a burst inside one task costs one read."
        )
        XCTAssertTrue(
            observerSource.contains("if (reading.color === lastPostedColor && reading.document === lastPostedDocument) { return; }"),
            "The same reading must never be posted twice in a row — and a reading is both colours, not just the chrome one."
        )
        XCTAssertTrue(
            observerSource.contains("post({ color: reading.color, document: reading.document, ready: reading.ready })"),
            "Both colours must reach the host in one payload, so the header and the page's scrollbar can never describe two different moments of the same page."
        )
    }

    func test_source_neverPostsNoColourWhileTheDocumentIsStillParsing() {
        XCTAssertTrue(
            observerSource.contains("if (reading.color === null && !reading.ready) { return; }"),
            "'No colour yet' is not an answer until the document has finished parsing — the same distinction PaneHeaderColorResolver's poll makes."
        )
    }

    // MARK: - It runs inside somebody else's page

    func test_source_touchesNothingAboutTheDocumentItWatches() {
        for expression in [PageColorObserverScript.chromiumPostExpression, "someOtherTransport(payload)"] {
            let source = PageColorObserverScript.source(postExpression: expression)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(source.contains("appendChild"), "Nothing may be inserted into the page.")
            XCTAssertFalse(source.contains("document.write"), "Nothing may be written to the page.")
            XCTAssertFalse(source.contains("innerHTML"), "The page's markup must not be rewritten.")
            XCTAssertFalse(source.contains("setProperty"), "The observer reads styles; it must never write one. (PageColorSchemeScript is the only thing allowed to, and only on a page that declared nothing.)")
            XCTAssertFalse(source.contains("classList"), "No class may be added to the page.")
        }
    }

    func test_source_installsAtMostOncePerDocument() {
        XCTAssertTrue(observerSource.contains("Symbol.for('__orbitPageColorObserverInstalled')"))
        XCTAssertFalse(
            observerSource.contains("window.__orbitPageColorObserverInstalled"),
            "The guard must not be a plain string property on window — that is the exact shape a fingerprinting script's Object.getOwnPropertyNames(window) enumeration flags as an unknown global."
        )
    }

    // MARK: - Transport

    func test_source_postsThroughTheTransportItIsGiven() {
        let chromium = PageColorObserverScript.source(postExpression: PageColorObserverScript.chromiumPostExpression)
        XCTAssertTrue(chromium.contains("__orbitPost('\(PageColorObserverScript.channelName)', JSON.stringify(payload))"))
        // The captured local, not the global a second time: window.__orbitPostMessage
        // is deleted by the engine before any page script runs.
        XCTAssertTrue(chromium.contains("var __orbitPost = window.__orbitPostMessage;"))

        let placeholder = "someOtherTransport(payload)"
        XCTAssertTrue(
            PageColorObserverScript.source(postExpression: placeholder).contains(placeholder),
            "postExpression is not substituted verbatim, so what a test generates is not what a page runs."
        )

        XCTAssertNotEqual(
            PageColorObserverScript.channelName, MediaSessionObserverScript.channelName,
            "Two observers sharing a channel name would have their payloads routed to each other's decoder."
        )
    }

    func test_chromiumUserScript_runsAtDocumentStartOnEveryPageAndOnlyTheMainFrame() {
        let script = PageColorObserverScript.chromiumUserScript
        XCTAssertEqual(script.injectionTime, .documentStart, "It has to be watching before the page's own scripts run.")
        XCTAssertEqual(script.matchPatterns, ["<all_urls>"])
        XCTAssertFalse(script.allFrames, "A pane's chrome follows the page; an iframe's background is not the page's colour.")
        XCTAssertEqual(script.id, PageColorObserverScript.scriptID, "A stable id is what stops a session accumulating duplicate registrations.")
    }

    // MARK: - Decoding

    func test_decode_readsTheSamePayloadShapeTheProbeProduces() {
        let reading = PageColorObserverScript.decode(["color": "#0d1117", "ready": true])
        XCTAssertEqual(reading?.color?.usingColorSpace(.sRGB)?.redComponent ?? -1, 0x0D / 255.0, accuracy: 0.01)
        XCTAssertEqual(reading?.isReady, true)
        XCTAssertNil(PageColorObserverScript.decode("not a payload at all"))
        XCTAssertNil(PageColorObserverScript.decode(nil))
    }

    // The bridge's script-message arguments are strings, so this backend's payload arrives as JSON text.
    func test_decode_readsTheChromiumBackendsJSONPayload() {
        let reading = PageColorObserverScript.decode(payloadJSON: "{\"color\":\"#ffffff\",\"ready\":true}")
        XCTAssertEqual(reading?.color?.usingColorSpace(.sRGB)?.redComponent ?? -1, 1.0, accuracy: 0.01)
        XCTAssertEqual(reading?.isReady, true)

        XCTAssertEqual(
            PageColorObserverScript.decode(payloadJSON: "{\"color\":null,\"ready\":true}")?.color, nil,
            "A finished page with no colour is a real answer and must decode as one."
        )
        XCTAssertNil(PageColorObserverScript.decode(payloadJSON: "{ not json"), "Malformed JSON is no reading, never a colour.")
    }

    // MARK: - The opacity gate

    func test_isEffectivelyOpaque_agreesWithThePageSideRule() {
        XCTAssertTrue(PageThemeColorScript.isEffectivelyOpaque(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
        XCTAssertTrue(
            PageThemeColorScript.isEffectivelyOpaque(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)),
            "Half-opaque is a real answer — the consumer composites it. Only barely-there is rejected."
        )
        XCTAssertFalse(PageThemeColorScript.isEffectivelyOpaque(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)))
        XCTAssertFalse(PageThemeColorScript.isEffectivelyOpaque(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)))
        XCTAssertFalse(PageThemeColorScript.isEffectivelyOpaque(nil), "No colour is not a colour.")
    }
}
