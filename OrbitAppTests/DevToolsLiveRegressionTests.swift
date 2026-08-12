//  Asserts on the real inspector's CDP counters and frontend document, not just
//  a window existing -- the regression was an inspector that opened to a loading wheel forever.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class DevToolsLiveRegressionTests: XCTestCase {

    private static let pageHTML = "<html><body>orbit-devtools-test</body></html>"

    // MARK: - Fixtures

    private struct Inspector {
        var inspected: ChromiumWebContents
        var frontend: ChromiumWebContents
    }

    private static func decodeState(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Opens the inspector and waits for the CDP pipe to actually carry
    /// traffic, not merely for a frontend handle to exist.
    private static func openInspector(
        on inspected: ChromiumWebContents,
        timeout: Duration = .seconds(20)
    ) async throws -> Inspector {
        inspected.showDeveloperTools(inspectAt: nil)

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let state = decodeState(inspected.devToolsStateJSON())
            let attached = state["attached"] as? Bool ?? false
            let responses = state["responsesToFrontend"] as? Int ?? 0
            if attached, responses > 0, let frontend = inspected.developerToolsFrontend {
                return Inspector(inspected: inspected, frontend: frontend)
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        let final = inspected.devToolsStateJSON()
        XCTFail("the inspector never attached and answered a CDP command; final state \(final)")
        throw XCTSkip("inspector never attached")
    }

    /// Every field is read from the live frontend, so an empty/stuck frontend
    /// is distinguishable from a rendered one. Walks every shadow root, since
    /// DevTools builds its chrome inside them and light-DOM-only querySelectorAll under-reports.
    private static let frontendProbe = """
    (function () {
      var root = document.documentElement;
      function countDeep(selector) {
        var total = 0;
        var queue = [document];
        var seen = 0;
        while (queue.length && seen < 20000) {
          var node = queue.shift();
          seen++;
          try { total += node.querySelectorAll(selector).length; } catch (e) {}
          var all = node.querySelectorAll('*');
          for (var i = 0; i < all.length; i++) {
            if (all[i].shadowRoot) { queue.push(all[i].shadowRoot); }
          }
        }
        return total;
      }
      var stylesheets = [];
      var links = document.querySelectorAll('link[rel="stylesheet"]');
      for (var i = 0; i < links.length; i++) { stylesheets.push(links[i].getAttribute('href')); }
      var styles = window.getComputedStyle(root);
      return JSON.stringify({
        readyState: document.readyState,
        rootClass: root ? String(root.className) : '',
        prefersDark: !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches),
        tabs: countDeep('.tabbed-pane-header-tab'),
        toolbars: countDeep('devtools-toolbar'),
        panels: countDeep('.panel'),
        splitWidgets: countDeep('devtools-split-view, .split-widget'),
        baseContainer: String(styles.getPropertyValue('--sys-color-cdt-base-container') || '').trim(),
        onSurface: String(styles.getPropertyValue('--sys-color-on-surface') || '').trim(),
        bodyBackground: document.body ? String(window.getComputedStyle(document.body).backgroundColor) : '',
        bodyChildren: document.body ? document.body.children.length : -1,
        stylesheets: stylesheets
      });
    })()
    """

    private static func probeFrontend(_ frontend: ChromiumWebContents) async throws -> [String: Any] {
        let raw = try await frontend.evaluateJavaScript(frontendProbe)
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("the frontend probe returned \(String(describing: raw)) rather than a JSON object")
            return [:]
        }
        return object
    }

    /// Polls until the frontend has built its panel UI, so a slow boot fails
    /// as a timeout with the real document state attached rather than flaking.
    @discardableResult
    private static func waitForRenderedFrontend(
        _ frontend: ChromiumWebContents,
        timeout: Duration = .seconds(20)
    ) async throws -> [String: Any] {
        var last: [String: Any] = [:]
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            last = try await probeFrontend(frontend)
            if (last["tabs"] as? Int ?? 0) > 0 { return last }
            try await Task.sleep(for: .milliseconds(250))
        }
        return last
    }

    // MARK: - The CDP pipe

    // Inspect Element passes a real click point (routes through
    // InspectElementAt), and GetFocusedFrame() is null right after load -- InspectElement dereferenced it, crashing the process.
    func test_inspectElementAtAPoint_doesNotCrashWhenNothingHasFocus() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let inspected = try await LiveChromiumEngineHost.makeContents(engine: engine)
            inspected.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(inspected)

            // Exactly what OrbitContextMenu's Inspect Element item does.
            inspected.showDeveloperTools(inspectAt: CGPoint(x: 40, y: 40))

            let deadline = ContinuousClock.now + .seconds(20)
            var attached = false
            while ContinuousClock.now < deadline {
                let state = Self.decodeState(inspected.devToolsStateJSON())
                if state["attached"] as? Bool == true,
                   (state["responsesToFrontend"] as? Int ?? 0) > 0 {
                    attached = true
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }

            XCTAssertTrue(
                attached,
                "inspecting at a point never attached; state \(inspected.devToolsStateJSON())"
            )

            // The engine surviving is the assertion: a null focused frame used to
            // take the whole browser process down before this could run.
            let alive = try await inspected.evaluateJavaScript("document.body.textContent")
            XCTAssertEqual(alive as? String, "orbit-devtools-test", "the engine did not survive Inspect Element")
        }
    }

    func test_openDevTools_attachesAndCarriesRealCDPTraffic() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let inspected = try await LiveChromiumEngineHost.makeContents(engine: engine)
            inspected.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(inspected)

            XCTAssertTrue(
                inspected.devToolsStateJSON().contains("\"open\":false"),
                "precondition: no inspector open yet"
            )

            let inspector = try await Self.openInspector(on: inspected)
            let state = Self.decodeState(inspected.devToolsStateJSON())

            XCTAssertEqual(state["open"] as? Bool, true, "state \(state)")
            XCTAssertEqual(state["attached"] as? Bool, true, "the frontend never attached to a DevToolsAgentHost; state \(state)")
            XCTAssertGreaterThan(
                state["commandsFromFrontend"] as? Int ?? 0, 0,
                "the frontend sent no CDP commands at all; state \(state)"
            )
            XCTAssertGreaterThan(
                state["responsesToFrontend"] as? Int ?? 0, 0,
                "no CDP command was ever answered, so the pipe is one-way; state \(state)"
            )
            XCTAssertTrue(
                (state["frontendURL"] as? String ?? "").hasPrefix("devtools://devtools/bundled/devtools_app.html"),
                "the inspector is not on the bundled frontend; state \(state)"
            )

            _ = inspector
            inspected.closeDeveloperTools()
        }
    }

    // MARK: - The frontend actually renders

    // The "I see nothing except a loading wheel" report, asserted: a
    // frontend that boots but never builds panels reports zero tabs/toolbars with an attached pipe.
    func test_devToolsFrontend_buildsItsPanelUI() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let inspected = try await LiveChromiumEngineHost.makeContents(engine: engine)
            inspected.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(inspected)

            let inspector = try await Self.openInspector(on: inspected)
            let probe = try await Self.waitForRenderedFrontend(inspector.frontend)

            XCTAssertEqual(probe["readyState"] as? String, "complete", "frontend document \(probe)")
            XCTAssertGreaterThan(
                probe["tabs"] as? Int ?? 0, 0,
                "the frontend never built a single panel tab -- this is the loading-wheel state; document \(probe)"
            )
            XCTAssertGreaterThan(
                probe["toolbars"] as? Int ?? 0, 0,
                "the frontend built no toolbar; document \(probe)"
            )

            inspected.closeDeveloperTools()
        }
    }

    // MARK: - Appearance

    // The frontend resolves "systemPreferred" from prefers-color-scheme and
    // toggles `theme-with-dark-background` on <html>; that class is the whole observable outcome.

    private static func openInspector(
        appearance: AppearanceSettings.Appearance,
        on inspected: ChromiumWebContents
    ) async throws -> Inspector {
        AppearanceSettings.shared.selection = appearance
        EngineAppearance.apply()
        return try await openInspector(on: inspected)
    }

    private static func waitForThemeClass(
        _ frontend: ChromiumWebContents,
        dark: Bool,
        timeout: Duration = .seconds(15)
    ) async throws -> [String: Any] {
        var last: [String: Any] = [:]
        let deadline = ContinuousClock.now + timeout
        while true {
            last = try await probeFrontend(frontend)
            let classes = (last["rootClass"] as? String ?? "")
                .split(separator: " ").map(String.init)
            if classes.contains("theme-with-dark-background") == dark { return last }
            guard ContinuousClock.now < deadline else { return last }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func runInspectorThemeCase(
        appearance: AppearanceSettings.Appearance,
        expectDark: Bool
    ) throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let previous = AppearanceSettings.shared.selection
            defer {
                AppearanceSettings.shared.selection = previous
                EngineAppearance.apply()
            }

            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let inspected = try await LiveChromiumEngineHost.makeContents(engine: engine)
            inspected.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(inspected)

            let inspector = try await Self.openInspector(appearance: appearance, on: inspected)
            let probe = try await Self.waitForThemeClass(inspector.frontend, dark: expectDark)

            XCTAssertEqual(
                probe["prefersDark"] as? Bool, expectDark,
                "the frontend's own prefers-color-scheme did not follow Orbit's \(appearance.rawValue) appearance; document \(probe)"
            )
            XCTAssertEqual(
                (probe["rootClass"] as? String ?? "").contains("theme-with-dark-background"), expectDark,
                "the inspector did not resolve to \(expectDark ? "dark" : "light"); document \(probe)"
            )
            // Without this the theme never applies: the frontend waits on a
            // devtools://theme/colors.css load Orbit cannot answer.
            XCTAssertTrue(
                (probe["rootClass"] as? String ?? "").contains("baseline-"),
                "the frontend never applied a palette, so its design tokens are unset; document \(probe)"
            )
            XCTAssertFalse(
                (probe["baseContainer"] as? String ?? "").isEmpty,
                "--sys-color-cdt-base-container resolved to nothing, so the inspector has no surface colour; document \(probe)"
            )

            inspected.closeDeveloperTools()
        }
    }

    func test_devToolsTheme_isDarkWhenOrbitIsDark() throws {
        try runInspectorThemeCase(appearance: .dark, expectDark: true)
    }

    func test_devToolsTheme_isLightWhenOrbitIsLight() throws {
        try runInspectorThemeCase(appearance: .light, expectDark: false)
    }

    // The "follows" half of the request: an inspector already on screen must
    // re-theme, not stay stale until it is reopened.
    func test_devToolsTheme_tracksAnAppearanceChangeWhileOpen() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let previous = AppearanceSettings.shared.selection
            defer {
                AppearanceSettings.shared.selection = previous
                EngineAppearance.apply()
            }

            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let inspected = try await LiveChromiumEngineHost.makeContents(engine: engine)
            inspected.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(inspected)

            let inspector = try await Self.openInspector(appearance: .light, on: inspected)
            let opened = try await Self.waitForThemeClass(inspector.frontend, dark: false)
            XCTAssertFalse(
                (opened["rootClass"] as? String ?? "").contains("theme-with-dark-background"),
                "precondition: the inspector should have opened light; document \(opened)"
            )

            AppearanceSettings.shared.selection = .dark
            EngineAppearance.apply()

            let switched = try await Self.waitForThemeClass(inspector.frontend, dark: true)
            XCTAssertTrue(
                (switched["rootClass"] as? String ?? "").contains("theme-with-dark-background"),
                "the open inspector stayed light after Orbit went dark; document \(switched)"
            )
            XCTAssertEqual(switched["prefersDark"] as? Bool, true, "document \(switched)")

            AppearanceSettings.shared.selection = .light
            EngineAppearance.apply()

            let back = try await Self.waitForThemeClass(inspector.frontend, dark: false)
            XCTAssertFalse(
                (back["rootClass"] as? String ?? "").contains("theme-with-dark-background"),
                "the open inspector stayed dark after Orbit went back to light; document \(back)"
            )

            inspected.closeDeveloperTools()
        }
    }
}
