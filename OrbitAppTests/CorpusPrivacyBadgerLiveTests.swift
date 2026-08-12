//  corpus: pkehgijcmpdhfbdbbnkijodmdjhbjlgp
//  Drives real Privacy Badger: its popup renders nothing until getPopupData
//  answers. No three-visit tracker assertion -- 127.0.0.1-only server makes every page the same site.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class CorpusPrivacyBadgerLiveTests: CorpusLiveTestCase {

    private static let corpusName = "Privacy Badger"

    private static let subjectHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Orbit Privacy Badger subject</title></head>
    <body><h1>orbit-privacy-badger-subject</h1><img src="/beacon.gif" alt=""></body></html>
    """

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.subjectHTML),
            "/beacon.gif": LiveHTTPTestServer.Route(contentType: "image/gif", body: "GIF89a"),
        ])
    }

    private static func pollUntil(
        _ waitingFor: String, timeout: Duration = .seconds(30), _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for \(waitingFor)")
    }

    private struct PopupState: Decodable {
        var slidersDone: Bool
        var noTrackersVisible: Bool
        var trackerHeaderVisible: Bool
        var disabledSiteVisible: Bool
        var trackerRows: Int
    }

    private static let popupProbe = """
    (function () {
      function visible(id) {
        var n = document.getElementById(id);
        if (!n) { return false; }
        var style = window.getComputedStyle(n);
        return style.display !== 'none' && style.visibility !== 'hidden';
      }
      return JSON.stringify({
        slidersDone: window.SLIDERS_DONE === true,
        noTrackersVisible: visible('instructions-no-trackers'),
        trackerHeaderVisible: visible('tracker-list-header'),
        disabledSiteVisible: visible('disabled-site-message'),
        trackerRows: document.querySelectorAll('#blockedResourcesInner .clicker').length
      });
    })()
    """

    // Skips only when the corpus has not been vendored (`Scripts/extension-corpus fetch`).
    // ORBIT-LIVE-ENGINE: MAY-SKIP testRealPrivacyBadgersPopupRendersItsOwnStateFromItsOwnServiceWorker
    func testRealPrivacyBadgersPopupRendersItsOwnStateFromItsOwnServiceWorker() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName)

        try LiveChromiumEngineHost.runLive(timeout: 180) {
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
            XCTAssertEqual(loaded.id, entry.id, "the vendored corpus directory produced a different extension than the pin")
            XCTAssertTrue(
                loaded.hasToolbarAction,
                "Privacy Badger's whole UI is its toolbar button; without an action there is nothing for a user to open"
            )

            let subjectTabID = env.openTab(url: server.baseURL, in: spaceID)
            let contents = try XCTUnwrap(env.webContents[subjectTabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let registryID = try XCTUnwrap(bridge.existingTabID(for: subjectTabID))
            env.activateTab(subjectTabID)

            let session = env.webContents[subjectTabID]?.session ?? engine.defaultSession
            let entries = SiteControlPopoverView.extensionActionEntries(
                engine: engine, session: session, tabID: registryID
            )
            let action = try XCTUnwrap(
                entries.first { $0.extensionInfo.id == loaded.id },
                "Privacy Badger has no toolbar entry, so the production toolbar path never offers its popup at all"
            )

            let model = ExtensionActionPopupModel(engine: engine, session: session, url: action.popupURL)
            model.start()
            let popup = try XCTUnwrap(model.contents as? ChromiumWebContents, model.loadFailure ?? "no popup contents")
            defer { model.teardown() }
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(popup)

            var state = PopupState(
                slidersDone: false, noTrackersVisible: false, trackerHeaderVisible: false,
                disabledSiteVisible: false, trackerRows: 0
            )
            try await Self.pollUntil("Privacy Badger's popup to render a terminal state") {
                guard let raw = try await popup.evaluateJavaScript(Self.popupProbe) as? String,
                      let data = raw.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(PopupState.self, from: data)
                else { return false }
                state = decoded
                return decoded.noTrackersVisible || decoded.trackerHeaderVisible || decoded.disabledSiteVisible
            }

            XCTAssertFalse(
                state.disabledSiteVisible,
                "Privacy Badger reports itself disabled for the subject page, so its blocking path never ran and nothing below measures protection"
            )
            XCTAssertTrue(
                state.noTrackersVisible || state.trackerHeaderVisible,
                "Privacy Badger's popup is frozen in its initial markup: neither the \"no trackers\" message nor the tracker-list header was ever revealed. Its popup renders nothing until its own service worker answers getPopupData with data it read from chrome.tabs and chrome.storage, so this is a broken round trip, not an empty result."
            )
        }
    }
}
