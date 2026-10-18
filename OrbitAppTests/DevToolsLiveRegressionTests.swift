//  Asserts on the real Web Inspector's frontend document and its protocol connection to the inspected page, not just
//  a window existing -- the regression was an inspector that opened to a loading wheel forever.

import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class DevToolsLiveRegressionTests: XCTestCase {

    private static let pageHTML = "<html><body>orbit-devtools-test</body></html>"

    override func tearDown() {
        for window in NSApp.windows where window.title.hasPrefix("Web Inspector") {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct Inspector {
        var inspected: WebKitWebContents
        var window: NSWindow
    }

    private static func decodeState(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// A bare window holding the page itself: the inspector has no pane to share, so it opens in WebKit's own window.
    @discardableResult
    private static func host(_ contents: WebKitWebContents) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "page"
        window.isRestorable = false
        window.contentView = contents.view
        contents.view.frame = window.contentView?.bounds ?? .zero
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private static func inspectorWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("Web Inspector") }
    }

    private static func openInspector(
        on inspected: WebKitWebContents,
        timeout: Duration = .seconds(8)
    ) async throws -> Inspector {
        _ = host(inspected)
        inspected.showDeveloperTools(inspectAt: nil)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let window = inspectorWindow() {
                return Inspector(inspected: inspected, window: window)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Web Inspector did not open")
        throw EngineError(code: .engineUnavailable, underlyingDescription: "Web Inspector did not open")
    }

    /// Every field is read from the live frontend, so an empty/stuck frontend
    /// is distinguishable from a rendered one. `WI` is the Web Inspector's own global: a connected frontend has a main
    /// target and a built tab bar.
    private static let frontendProbe = """
    (function () {
      var wi = typeof WI !== 'undefined' ? WI : null;
      var stylesheets = [];
      var links = document.querySelectorAll('link[rel="stylesheet"]');
      for (var i = 0; i < links.length; i++) { stylesheets.push(links[i].getAttribute('href')); }
      return JSON.stringify({
        readyState: document.readyState,
        hasWI: !!wi,
        hasMainTarget: !!(wi && wi.mainTarget),
        tabs: wi && wi.tabBar && wi.tabBar.tabBarItems ? wi.tabBar.tabBarItems.length : -1,
        elementCount: document.querySelectorAll('*').length,
        bodyChildren: document.body ? document.body.children.length : -1,
        prefersDark: !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches),
        stylesheets: stylesheets
      });
    })()
    """

    private static func probeFrontend(_ frontend: WebKitInspectorFrontend) async throws -> [String: Any] {
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
        _ inspected: WebKitWebContents,
        timeout: Duration = .seconds(25)
    ) async throws -> (frontend: WebKitInspectorFrontend, probe: [String: Any]) {
        var last: [String: Any] = [:]
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let frontend = inspected.developerToolsFrontend {
                last = (try? await probeFrontend(frontend)) ?? [:]
                if (last["tabs"] as? Int ?? 0) > 0, last["hasMainTarget"] as? Bool == true { return (frontend, last) }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("the inspector frontend never finished building; last probe \(last)")
        throw EngineError(code: .engineUnavailable, underlyingDescription: "frontend never rendered: \(last)")
    }

    /// One real round trip over the inspector protocol: the frontend asks the inspected page's runtime to evaluate.
    /// `callAsyncJavaScript` on the inspector frontend fails with `removedFromContainer` after WebKit
    /// shows that page; `evaluateJavaScript` is the call that actually runs there.
    private static func evaluateThroughProtocol(_ frontend: WebKitInspectorFrontend, _ expression: String) async throws -> String? {
        let token = UUID().uuidString
        let body = """
        (function() {
          var token = \(JavaScriptLiteral.string(token));
          if (window.__orbitProtocolToken === token) return;
          window.__orbitProtocolToken = token;
          var expression = \(JavaScriptLiteral.string(expression));
          var tries = 0;
          var timer = setInterval(function() {
            tries += 1;
            var target = (typeof WI !== 'undefined') ? WI.mainTarget : null;
            if (!target || !target.RuntimeAgent || !target.RuntimeAgent.evaluate) {
              if (tries > 50) clearInterval(timer);
              return;
            }
            clearInterval(timer);
            target.RuntimeAgent.evaluate.invoke({expression: expression, returnByValue: true}).then(function(r) {
              document.documentElement.setAttribute('data-orbit-protocol', token + ':' + String(r && r.result ? r.result.value : ''));
            }, function() {
              document.documentElement.setAttribute('data-orbit-protocol', token + ':');
            });
          }, 100);
        })()
        """
        _ = try await frontend.evaluateJavaScript(body)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let raw = try await frontend.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-protocol')")
            if let text = raw as? String, text.hasPrefix(token + ":") {
                return String(text.dropFirst(token.count + 1))
            }
            // The inspector page reloads after show. A timer started in the previous document is gone.
            _ = try? await frontend.evaluateJavaScript(body)
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // MARK: - The inspector protocol

    // Inspect Element passes a real click point (routes through
    // InspectElementAt), and GetFocusedFrame() is null right after load -- InspectElement dereferenced it, crashing the process.
    func test_inspectElementAtAPoint_doesNotCrashWhenNothingHasFocus() throws {
        try WebKitLiveEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            let inspected = try await WebKitLiveEngineHost.makeContents(engine: engine)
            inspected.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(inspected)
            _ = Self.host(inspected)

            inspected.showDeveloperTools(inspectAt: CGPoint(x: 40, y: 40))

            let deadline = ContinuousClock.now + .seconds(8)
            var opened = false
            while ContinuousClock.now < deadline {
                if Self.inspectorWindow() != nil {
                    opened = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(opened, "Inspect Element did not open Web Inspector")
            let inspector = try XCTUnwrap(inspected.webInspector(), "Inspect Element left no inspector object")
            let nativeSelection = WebKitWebContents.boolMessage(inspector, "isElementSelectionActive")
            var frontendSelection = false
            if !nativeSelection, let frontend = inspected.inspectorFrontendWebView {
                let deadline = ContinuousClock.now + .seconds(4)
                while ContinuousClock.now < deadline {
                    let raw = try? await frontend.evaluateJavaScript(
                        "(function(){ return !!(window.WI && WI.domManager && WI.domManager.inspectModeEnabled); })()"
                    )
                    if raw as? Bool == true {
                        frontendSelection = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            XCTAssertTrue(
                nativeSelection || frontendSelection,
                "Inspect Element opened the inspector without arming element selection"
            )

            // The engine surviving is the assertion: a null focused frame used to
            // take the whole browser process down before this could run.
            let alive = try await inspected.evaluateJavaScript("document.body.textContent")
            XCTAssertEqual(alive as? String, "orbit-devtools-test", "the engine did not survive Inspect Element")
            inspected.closeDeveloperTools()
            inspected.close()
        }
    }

    func test_openDevTools_connectsAndCarriesRealProtocolTraffic() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            let inspected = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { inspected.close() }
            inspected.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(inspected)

            XCTAssertNil(Self.inspectorWindow(), "precondition: no inspector open yet")
            XCTAssertFalse(inspected.developerToolsAreOpen())
            XCTAssertNil(inspected.developerToolsFrontend)
            XCTAssertEqual(Self.decodeState(inspected.devToolsStateJSON())["open"] as? Bool, false)

            let inspector = try await Self.openInspector(on: inspected)
            XCTAssertTrue(inspector.window.isVisible)
            XCTAssertTrue(inspector.window.title.hasPrefix("Web Inspector"))
            XCTAssertTrue(inspected.developerToolsAreOpen())
            XCTAssertFalse(inspected.isDeveloperToolsDocked, "a page with no pane cannot dock")

            let rendered = try await Self.waitForRenderedFrontend(inspected)
            let state = Self.decodeState(inspected.devToolsStateJSON())
            XCTAssertEqual(state["open"] as? Bool, true, "state \(state)")
            XCTAssertEqual(state["attached"] as? Bool, true, "the inspector never connected to the page; state \(state)")
            XCTAssertEqual(state["docked"] as? Bool, false, "state \(state)")
            XCTAssertEqual(state["dockSide"] as? String, "undocked", "state \(state)")
            XCTAssertGreaterThan(state["responsesToFrontend"] as? Int ?? 0, 0, "the frontend never loaded; state \(state)")

            // A real round trip over the inspector protocol, from the frontend into the inspected page.
            let echoed = try await Self.evaluateThroughProtocol(rendered.frontend, "document.body.textContent")
            XCTAssertEqual(echoed, "orbit-devtools-test", "the frontend could not evaluate in the page it inspects")

            let alive = try await inspected.evaluateJavaScript("document.body.textContent")
            XCTAssertEqual(alive as? String, "orbit-devtools-test")
            inspected.closeDeveloperTools()
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertNil(Self.inspectorWindow(), "closing developer tools left Web Inspector visible")
            XCTAssertFalse(inspected.developerToolsAreOpen())
            XCTAssertEqual(Self.decodeState(inspected.devToolsStateJSON())["open"] as? Bool, false)
        }
    }

    func test_devTools_reopensAfterCloseAndCarriesTrafficAgain() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let inspected = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { inspected.close() }
            inspected.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(inspected)

            for round in 1...2 {
                let inspector = try await Self.openInspector(on: inspected)
                XCTAssertTrue(inspector.window.isVisible, "round \(round): the inspector did not open")
                let rendered = try await Self.waitForRenderedFrontend(inspected)
                let echoed = try await Self.evaluateThroughProtocol(rendered.frontend, "1 + 1")
                XCTAssertEqual(echoed, "2", "round \(round): the reopened inspector is not connected to the page")
                inspected.closeDeveloperTools()
                try await Task.sleep(nanoseconds: 400_000_000)
                XCTAssertNil(Self.inspectorWindow(), "round \(round): closing left the inspector open")
            }
        }
    }

    // MARK: - The frontend actually renders

    // The "I see nothing except a loading wheel" report, asserted: a
    // frontend that boots but never builds panels reports zero tabs/toolbars with an attached pipe.
    func test_devToolsFrontend_buildsItsPanelUI() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            let inspected = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { inspected.close() }
            inspected.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(inspected)

            let inspector = try await Self.openInspector(on: inspected)
            XCTAssertNotNil(inspector.window.contentView)
            XCTAssertFalse(inspector.window.contentView?.subviews.isEmpty ?? true, "Web Inspector opened with no content")

            let rendered = try await Self.waitForRenderedFrontend(inspected)
            let probe = rendered.probe
            XCTAssertEqual(probe["readyState"] as? String, "complete", "probe \(probe)")
            XCTAssertEqual(probe["hasWI"] as? Bool, true, "the frontend page is not the Web Inspector: \(probe)")
            XCTAssertEqual(probe["hasMainTarget"] as? Bool, true, "the frontend never connected to the inspected page: \(probe)")
            XCTAssertGreaterThan(probe["tabs"] as? Int ?? 0, 0, "the tab bar was never built: \(probe)")
            XCTAssertGreaterThan(probe["bodyChildren"] as? Int ?? 0, 0, "the frontend body is empty: \(probe)")
            XCTAssertGreaterThan(probe["elementCount"] as? Int ?? 0, 200, "the frontend built almost no UI: \(probe)")
            XCTAssertFalse((probe["stylesheets"] as? [String] ?? []).isEmpty, "the frontend loaded no stylesheet: \(probe)")
            XCTAssertTrue(rendered.frontend.view.isDescendant(of: inspector.window.contentView!), "the frontend page is not what the window shows")

            let alive = try await inspected.evaluateJavaScript("document.body.textContent")
            XCTAssertEqual(alive as? String, "orbit-devtools-test")
            inspected.closeDeveloperTools()
        }
    }

    // MARK: - Appearance

    // The inspector's stylesheets switch on prefers-color-scheme, so both the window's appearance and the
    // frontend page's own media query are asserted.

    private static func openInspector(
        appearance: AppearanceSettings.Appearance,
        on inspected: WebKitWebContents
    ) async throws -> Inspector {
        AppearanceSettings.shared.selection = appearance
        EngineAppearance.apply()
        return try await openInspector(on: inspected)
    }

    /// The frontend's own prefers-color-scheme, which is what its stylesheets switch on.
    private static func waitForFrontendScheme(
        _ inspected: WebKitWebContents,
        dark: Bool,
        timeout: Duration = .seconds(15)
    ) async throws -> [String: Any] {
        var last: [String: Any] = [:]
        let deadline = ContinuousClock.now + timeout
        while true {
            if let frontend = inspected.developerToolsFrontend {
                last = (try? await probeFrontend(frontend)) ?? [:]
                if last["prefersDark"] as? Bool == dark { return last }
            }
            guard ContinuousClock.now < deadline else { return last }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func runInspectorThemeCase(
        appearance: AppearanceSettings.Appearance,
        expectDark: Bool
    ) throws {
        try WebKitLiveEngineHost.runLive {
            let previous = AppearanceSettings.shared.selection
            defer {
                AppearanceSettings.shared.selection = previous
                EngineAppearance.apply()
            }

            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            let inspected = try await WebKitLiveEngineHost.makeContents(engine: engine)
            inspected.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(inspected)

            let inspector = try await Self.openInspector(appearance: appearance, on: inspected)
            let match = inspector.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            XCTAssertEqual(match == .darkAqua, expectDark, "Web Inspector appearance did not follow \(appearance.rawValue)")
            let scheme = try await Self.waitForFrontendScheme(inspected, dark: expectDark)
            XCTAssertEqual(scheme["prefersDark"] as? Bool, expectDark, "the frontend page's prefers-color-scheme did not follow \(appearance.rawValue): \(scheme)")
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
        try WebKitLiveEngineHost.runLive {
            let previous = AppearanceSettings.shared.selection
            defer {
                AppearanceSettings.shared.selection = previous
                EngineAppearance.apply()
            }

            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            let inspected = try await WebKitLiveEngineHost.makeContents(engine: engine)
            inspected.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(inspected)

            let inspector = try await Self.openInspector(appearance: .light, on: inspected)
            XCTAssertEqual(inspector.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
            let light = try await Self.waitForFrontendScheme(inspected, dark: false)
            XCTAssertEqual(light["prefersDark"] as? Bool, false, "the frontend opened dark under a light Orbit: \(light)")

            AppearanceSettings.shared.selection = .dark
            EngineAppearance.apply()
            XCTAssertEqual(inspector.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
            let dark = try await Self.waitForFrontendScheme(inspected, dark: true)
            XCTAssertEqual(dark["prefersDark"] as? Bool, true, "the open frontend stayed light after Orbit went dark: \(dark)")

            AppearanceSettings.shared.selection = .light
            EngineAppearance.apply()
            XCTAssertEqual(inspector.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
            let backToLight = try await Self.waitForFrontendScheme(inspected, dark: false)
            XCTAssertEqual(backToLight["prefersDark"] as? Bool, false, "the open frontend stayed dark after Orbit went light: \(backToLight)")

            inspected.closeDeveloperTools()
        }
    }
}
