//  Launch-time appearance push runs before Chromium is dlopen'd, so the first
//  document commits on blink's light default until something pushes for real.
// ORBIT-LIVE-ENGINE: OWN-PROCESS

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class FirstDocumentColorSchemeLiveTests: XCTestCase {

    // Painted by a media query and nothing else, served over a real socket so
    // this is an ordinary http:// navigation rather than a data:/loadHTML one.
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html, body { margin: 0; height: 100%; background: rgb(255, 255, 255); }
    @media (prefers-color-scheme: dark) { html, body { background: rgb(0, 0, 0); } }
    </style></head><body></body></html>
    """

    private var savedAppearance: AppearanceSettings?

    override func tearDown() {
        if let savedAppearance {
            AppearanceSettings.shared = savedAppearance
        }
        savedAppearance = nil
        EngineAppearance.apply()
        super.tearDown()
    }

    func testFirstDocumentAfterEngineStartHonoursOrbitsAppearance() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        // Engine start-up happens once per process and this test's subject is
        // engine start-up, so it has to be the test that causes it.
        XCTAssertFalse(
            LiveChromiumEngineHost.hasStartedEngine,
            "the engine was already started in this process, so nothing below is about engine start-up any more — this suite's whole-line '// ORBIT-LIVE-ENGINE: OWN-PROCESS' marker is what gets it a process of its own, and it is either gone or no longer understood by Scripts/live-engine-tests"
        )

        // Moved to the opposite of whatever the engine was last told, via the
        // one route that does not push (assigning `shared`, not `choose(_:)`).
        let expectedDark = !EngineAppearance.isDark
        savedAppearance = AppearanceSettings.shared
        let defaults = UserDefaults(suiteName: "FirstDocumentColorSchemeLiveTests.\(UUID().uuidString)")!
        let selection: AppearanceSettings.Appearance = expectedDark ? .dark : .light
        defaults.set(selection.rawValue, forKey: AppearanceSettings.defaultsKey)
        AppearanceSettings.shared = AppearanceSettings(defaults: defaults)

        let result = try LiveChromiumEngineHost.runLive(timeout: 90) {
            () -> (href: String?, matches: Bool, background: String?) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html", body: FirstDocumentColorSchemeLiveTests.page
                )
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)

            contents.load(server.baseURL)
            // Committed asynchronously, so waiting on isLoading alone can
            // settle on the about:blank makeContents left behind.
            let deadline = ContinuousClock.now + .seconds(15)
            while contents.navigationState.url?.host != "127.0.0.1" {
                guard ContinuousClock.now < deadline else {
                    throw EngineError(
                        code: .engineUnavailable,
                        underlyingDescription: "the fixture navigation never committed"
                    )
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let href = try await contents.evaluateJavaScript("document.location.href") as? String
            let matches = try await contents.evaluateJavaScript(
                "matchMedia('(prefers-color-scheme: dark)').matches"
            ) as? Bool
            let background = try await contents.evaluateJavaScript(
                "getComputedStyle(document.body).backgroundColor"
            ) as? String
            return (href, matches ?? !expectedDark, background)
        }

        XCTAssertEqual(
            result.href?.hasPrefix("http://127.0.0.1:"), true,
            "test precondition: the assertions below did not run against the fixture page (href \(String(describing: result.href)))"
        )
        XCTAssertEqual(
            result.matches, expectedDark,
            "the first page loaded after engine start resolved prefers-color-scheme against blink's default instead of Orbit's appearance — every dark site renders its light theme until something else pushes the scheme"
        )
        XCTAssertEqual(
            result.background, expectedDark ? "rgb(0, 0, 0)" : "rgb(255, 255, 255)",
            "the first document painted the wrong theme's background"
        )
    }
}
