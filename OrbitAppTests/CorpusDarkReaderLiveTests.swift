//  corpus: eimadpbcbfnmbkopoojfekhnkhdbieeh
//  Drives real Dark Reader: a white page must end up dark with nothing toggled
//  on (shipped defaults are enabled/dark). Ignores inject/fallback.js (OS-dark-mode-only).

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class CorpusDarkReaderLiveTests: CorpusLiveTestCase {

    private static let corpusName = "Dark Reader"

    private static let subjectHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Orbit Dark Reader subject</title>
    <style>html, body { background-color: #ffffff; color: #000000; margin: 0; height: 100%; }</style>
    </head><body><h1>orbit-dark-reader-subject</h1><p>white on black is the whole test</p></body></html>
    """

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.subjectHTML),
        ])
    }

    // MARK: - Reading the page's own computed colour

    private struct PageColours: Decodable {
        var html: String
        var body: String
        var darkReaderNodes: Int
    }

    private static let colourProbe = """
    JSON.stringify({
      html: String(window.getComputedStyle(document.documentElement).backgroundColor),
      body: String(window.getComputedStyle(document.body).backgroundColor),
      darkReaderNodes: document.querySelectorAll('[class*="darkreader"], [data-darkreader-inline-bgcolor]').length
    })
    """

    /// Relative luminance of an `rgb()`/`rgba()` triple, or nil for anything
    /// that names no colour at all (`transparent`, an empty string).
    private static func luminance(of colour: String) -> Double? {
        let digits = colour.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .filter { !$0.isEmpty }
        guard digits.count >= 3,
              let red = Double(digits[0]), let green = Double(digits[1]), let blue = Double(digits[2])
        else { return nil }
        if digits.count >= 4, let alpha = Double(digits[3]), alpha == 0 { return nil }
        return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
    }

    /// The darkest colour the page actually paints: which element ends up
    /// carrying the dark background depends on the page, so both are read and the darker wins.
    private static func darkestLuminance(_ colours: PageColours) -> Double? {
        [luminance(of: colours.html), luminance(of: colours.body)].compactMap { $0 }.min()
    }

    private func readColours(_ contents: ChromiumWebContents) async throws -> PageColours? {
        guard let raw = try await contents.evaluateJavaScript(Self.colourProbe) as? String,
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(PageColours.self, from: data)
    }

    // Skips only when the corpus has not been vendored (`Scripts/extension-corpus fetch`).
    // ORBIT-LIVE-ENGINE: MAY-SKIP testDarkReaderTurnsAWhitePageDarkWithoutBeingSwitchedOn
    func testDarkReaderTurnsAWhitePageDarkWithoutBeingSwitchedOn() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName)

        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine

            let bridge = OrbitChromiumTabsBridge.shared
            if !bridge.isWindowRegistered(env) {
                bridge.windowCreated(owner: env, focused: false)
            }
            bridge.windowFocusChanged(owner: env)
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let server = try self.makeServer()
            defer { server.stop() }

            // Control run, with nothing loaded: the fixture has to be white
            // before "it went dark" means anything.
            let controlTabID = env.openTab(url: server.baseURL, in: spaceID)
            let controlContents = try XCTUnwrap(env.webContents[controlTabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(controlContents)
            let controlReading = try await self.readColours(controlContents)
            let control = try XCTUnwrap(controlReading, "the control page reported no computed colours at all")
            let controlLuminance = try XCTUnwrap(
                Self.darkestLuminance(control), "the control page painted no opaque background: \(control)"
            )
            env.closeTab(controlTabID)
            XCTAssertGreaterThan(
                controlLuminance, 0.8,
                """
                the subject page is not white before Dark Reader is loaded (html=\(control.html), \
                body=\(control.body)), so nothing below measures Dark Reader
                """
            )

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(
                loaded.id, entry.id,
                "the vendored corpus directory produced a different extension than the pin"
            )

            let subjectTabID = env.openTab(url: server.baseURL, in: spaceID)
            let subject = try XCTUnwrap(env.webContents[subjectTabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(subject)
            env.activateTab(subjectTabID)

            // The content script reaches its worker and rebuilds stylesheets,
            // so the dark result arrives some frames after load, not at load.
            var observed = PageColours(html: "", body: "", darkReaderNodes: 0)
            let deadline = ContinuousClock.now + .seconds(45)
            while ContinuousClock.now < deadline {
                if let colours = try await self.readColours(subject) {
                    observed = colours
                    if let luminance = Self.darkestLuminance(colours), luminance < 0.3 { break }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            print("ORBIT-DARKREADER computed colours = \(observed)")

            let darkened = try XCTUnwrap(
                Self.darkestLuminance(observed),
                "the subject page painted no opaque background with Dark Reader loaded: \(observed)"
            )
            XCTAssertLessThan(
                darkened, 0.3,
                """
                Dark Reader left the page light (html=\(observed.html), body=\(observed.body), \
                darkreader-marked nodes=\(observed.darkReaderNodes)); the same page measured \
                \(controlLuminance) unprotected. Its shipped defaults are enabled/dark with no \
                automation, so nothing was waiting on a user: either its document_start content \
                script never ran, or its round trip to its own service worker never answered.
                """
            )
            XCTAssertLessThan(
                darkened, controlLuminance,
                "Dark Reader did not darken anything relative to the unprotected control run: \(observed)"
            )
            XCTAssertGreaterThan(
                observed.darkReaderNodes, 0,
                """
                the page is dark but carries nothing Dark Reader marked, so something other than the \
                extension coloured it and this assertion would be measuring the wrong thing: \(observed)
                """
            )
        }
    }
}
