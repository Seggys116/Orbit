//  corpus: fmkadmapgofadopljbjfkapdkoienihi
//  A KNOWN-UNSUPPORTED CANARY, pinned to fail loudly the day DevTools extensions
//  start working. If either assertion fails, update the corpus JSON and make this positive -- don't loosen it.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class CorpusReactDeveloperToolsLiveTests: CorpusLiveTestCase {

    private static let corpusName = "React Developer Tools"

    private static let subjectHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Orbit React DevTools subject</title></head>
    <body><div id="root">orbit-react-devtools-subject</div></body></html>
    """

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.subjectHTML),
        ])
    }

    private struct FrontendExtensionState: Decodable {
        var frameSources: [String]
        var panelTabs: [String]
        var devToolsAPIHasAddExtensions: Bool
    }

    /// Tab titles are collected by walking every shadow root, since DevTools
    /// builds nearly all of its chrome inside them.
    private static let frontendProbe = """
    (function () {
      var frames = [];
      var all = document.querySelectorAll('iframe');
      for (var i = 0; i < all.length; i++) {
        frames.push(String(all[i].getAttribute('src') || all[i].src || ''));
      }
      var titles = [];
      var queue = [document];
      var seen = 0;
      while (queue.length && seen < 20000) {
        var node = queue.shift();
        seen++;
        var tabs = [];
        try { tabs = node.querySelectorAll('.tabbed-pane-header-tab'); } catch (e) {}
        for (var t = 0; t < tabs.length; t++) {
          titles.push(String(tabs[t].textContent || '').trim());
        }
        var children = [];
        try { children = node.querySelectorAll('*'); } catch (e) {}
        for (var c = 0; c < children.length; c++) {
          if (children[c].shadowRoot) { queue.push(children[c].shadowRoot); }
          if (children[c].tagName === 'IFRAME') {
            frames.push(String(children[c].getAttribute('src') || children[c].src || ''));
          }
        }
      }
      return JSON.stringify({
        frameSources: frames,
        panelTabs: titles,
        devToolsAPIHasAddExtensions: !!(window.DevToolsAPI && typeof window.DevToolsAPI.addExtensions === 'function')
      });
    })()
    """

    private static func decodeState(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    // Skips only when the corpus has not been vendored (`Scripts/extension-corpus fetch`).
    // ORBIT-LIVE-ENGINE: MAY-SKIP testReactDeveloperToolsDevToolsPageIsStillNeverCreated
    func testReactDeveloperToolsDevToolsPageIsStillNeverCreated() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName)

        // The canary only works while the pinned build still declares a
        // devtools page; dropping it would make every assertion below true for the wrong reason.
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        ) as? [String: Any]
        XCTAssertEqual(
            manifest?["devtools_page"] as? String, "main.html",
            "the pinned React Developer Tools no longer declares a devtools_page, so this canary no longer measures anything"
        )

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

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(
                loaded.id, entry.id,
                "the vendored corpus directory produced a different extension than the pin"
            )

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            env.activateTab(tabID)

            contents.showDeveloperTools(inspectAt: nil)
            defer { contents.closeDeveloperTools() }

            var frontend: ChromiumWebContents?
            let attachDeadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < attachDeadline {
                let state = Self.decodeState(contents.devToolsStateJSON())
                if state["attached"] as? Bool == true,
                   (state["responsesToFrontend"] as? Int ?? 0) > 0,
                   let open = contents.developerToolsFrontend {
                    frontend = open
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            let inspector = try XCTUnwrap(
                frontend,
                """
                the inspector never attached, so this canary measured nothing; final state \
                \(contents.devToolsStateJSON())
                """
            )

            // Let the frontend finish building its panel bar before reading
            // it, or an empty tab list would pass for the wrong reason.
            var observed = FrontendExtensionState(frameSources: [], panelTabs: [], devToolsAPIHasAddExtensions: false)
            let renderDeadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < renderDeadline {
                if let raw = try await inspector.evaluateJavaScript(Self.frontendProbe) as? String,
                   let data = raw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(FrontendExtensionState.self, from: data) {
                    observed = decoded
                    if !decoded.panelTabs.isEmpty { break }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            print("ORBIT-REACTDEVTOOLS frontend state = \(observed)")

            XCTAssertFalse(
                observed.panelTabs.isEmpty,
                "the frontend never built its panel bar, so the absence of a React panel below proves nothing"
            )

            let extensionFrames = observed.frameSources.filter { $0.contains(loaded.id) }
            XCTAssertTrue(
                extensionFrames.isEmpty,
                """
                A DevTools frontend frame now addresses \(loaded.id) (\(extensionFrames)). DevTools \
                extensions may now work in Orbit: nothing used to send `addExtensions` to the \
                frontend, so the devtools page iframe was never created. Update this corpus entry's \
                expectation in Chromium/extension-corpus.json and turn this canary into a positive \
                test -- do not relax the assertion.
                """
            )

            // "Components" only: DevTools ships its own Performance and Memory
            // panels, so a broader name match would fail for a native tab.
            let reactPanels = observed.panelTabs.filter { $0.localizedCaseInsensitiveContains("Components") }
            XCTAssertTrue(
                reactPanels.isEmpty,
                """
                The inspector now shows a React Developer Tools panel (\(reactPanels)) out of \
                \(observed.panelTabs). Its devtools page must therefore be running and calling \
                chrome.devtools.panels.create. That is the day this canary exists to catch: update \
                the expectation on this corpus entry rather than the assertion.
                """
            )
        }
    }
}
