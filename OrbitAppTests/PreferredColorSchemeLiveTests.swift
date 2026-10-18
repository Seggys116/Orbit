//  Live coverage that a real page's `prefers-color-scheme` media query answers with Orbit's
//  own appearance: an embedder that never assigns preferred_color_scheme serves light forever.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class PreferredColorSchemeLiveTests: XCTestCase {

    // Painted by a media query and nothing else, so the sampled pixel is
    // evidence about the query rather than about any script.
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html, body { margin: 0; height: 100%; background: #ffffff; }
    @media (prefers-color-scheme: dark) { html, body { background: #000000; } }
    </style></head><body></body></html>
    """

    private var savedAppearance: AppearanceSettings?

    override func setUp() {
        super.setUp()
        savedAppearance = AppearanceSettings.shared
        // A scratch suite: `selection`'s didSet persists, and a test must not
        // rewrite the real user's appearance preference.
        let defaults = UserDefaults(suiteName: "PreferredColorSchemeLiveTests.\(UUID().uuidString)")!
        AppearanceSettings.shared = AppearanceSettings(defaults: defaults)
    }

    override func tearDown() {
        if let savedAppearance {
            AppearanceSettings.shared = savedAppearance
        }
        savedAppearance = nil
        EngineAppearance.apply()
        super.tearDown()
    }

    func testEngineExposesTheColorSchemeEntryPoint() throws {
        try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.setPreferredColorScheme(.dark)
            contents.loadHTML("<!doctype html><html><body>scheme</body></html>", baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            contents.setPreferredColorScheme(.dark)
            let matches = try await contents.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
            XCTAssertEqual(
                matches, true,
                "setPreferredColorScheme(.dark) left prefers-color-scheme light"
            )
        }
    }

    func testDarkAppearanceMakesPagesResolvePrefersColorSchemeToDark() throws {
        let result = try WebKitLiveEngineHost.runLive(timeout: 60) { () -> (matches: Bool, pixel: (Int, Int, Int)?) in
            AppearanceSettings.shared.selection = .dark
            EngineAppearance.apply()

            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            contents.loadHTML(PreferredColorSchemeLiveTests.page, baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            let matches = try await PreferredColorSchemeLiveTests.prefersDark(contents)
            return (matches, await PreferredColorSchemeLiveTests.centrePixel(of: contents))
        }

        XCTAssertTrue(
            result.matches,
            "with Orbit set to Dark, matchMedia('(prefers-color-scheme: dark)') was still false in a real page — every dark site on the web renders its light theme"
        )
        let pixel = try XCTUnwrap(result.pixel, "capturePreview returned nothing")
        XCTAssertLessThan(pixel.0, 40, "page painted its light background under a dark appearance (red channel)")
        XCTAssertLessThan(pixel.1, 40, "page painted its light background under a dark appearance (green channel)")
        XCTAssertLessThan(pixel.2, 40, "page painted its light background under a dark appearance (blue channel)")
    }

    func testAppearanceChangeRethemesAPageThatIsAlreadyLoaded() throws {
        let result = try WebKitLiveEngineHost.runLive(timeout: 60) { () -> (dark: Bool, light: Bool, pixel: (Int, Int, Int)?) in
            AppearanceSettings.shared.selection = .dark
            EngineAppearance.apply()

            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            contents.loadHTML(PreferredColorSchemeLiveTests.page, baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            let dark = try await PreferredColorSchemeLiveTests.prefersDark(contents)

            // No reload: the point is that changing the preference re-pushes to
            // documents already open, rather than only to the next one.
            AppearanceSettings.shared.selection = .light
            EngineAppearance.apply()

            var light = true
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                light = try await PreferredColorSchemeLiveTests.prefersDark(contents)
                if !light { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            return (dark, light, await PreferredColorSchemeLiveTests.centrePixel(of: contents))
        }

        XCTAssertTrue(result.dark, "test precondition: page did not start out dark")
        XCTAssertFalse(
            result.light,
            "switching Orbit to Light left an already-loaded page still reporting prefers-color-scheme: dark — the preference change never reached the renderer"
        )
        let pixel = try XCTUnwrap(result.pixel, "capturePreview returned nothing")
        XCTAssertGreaterThan(pixel.0, 200, "page did not repaint its light background (red channel)")
        XCTAssertGreaterThan(pixel.1, 200, "page did not repaint its light background (green channel)")
        XCTAssertGreaterThan(pixel.2, 200, "page did not repaint its light background (blue channel)")
    }

    // MARK: - Helpers

    private static func prefersDark(_ contents: WebKitWebContents) async throws -> Bool {
        let raw = try await contents.evaluateJavaScript(
            "matchMedia('(prefers-color-scheme: dark)').matches"
        )
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        throw EngineError(
            code: .engineUnavailable,
            underlyingDescription: "matchMedia returned \(String(describing: raw)) rather than a boolean"
        )
    }

    private static func centrePixel(of contents: WebKitWebContents) async -> (Int, Int, Int)? {
        try? await Task.sleep(for: .milliseconds(400))
        guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: 320, height: 240)),
              let sample = ImagePixelSampler.sample(image)
        else { return nil }
        return (sample.pixel.red, sample.pixel.green, sample.pixel.blue)
    }
}
