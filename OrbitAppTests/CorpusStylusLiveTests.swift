//  corpus: clngdbkpkpeebahjckkjfobafhncgmne
//  Drives real Stylus 2.4.9: a user style changes a computed style on the page.
//  Installs via chrome.runtime.sendMessage (same call as the editor's Save), driving offscreen.html.
//  Not popup.html: its first statement document.writes a <script src="data?..."> answered only by
//  its own service worker's fetch handler; offscreen.html shares its API access with no such dependency.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class CorpusStylusLiveTests: CorpusLiveTestCase {

    private static let corpusName = "Stylus"

    /// A colour no browser default and no fixture rule paints, so seeing it is
    /// unambiguous evidence the user style was applied.
    private static let styledBackground = "rgb(1, 2, 3)"

    private static let subjectHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Orbit Stylus subject</title>
    <style>html, body { background-color: #ffffff; margin: 0; height: 100%; }</style>
    </head><body><h1>orbit-stylus-subject</h1></body></html>
    """

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.subjectHTML),
        ])
    }

    @discardableResult
    private static func poll(
        timeout: Duration = .seconds(30), _ condition: () async throws -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func backgroundColour(of contents: ChromiumWebContents) async -> String {
        let raw = try? await contents.evaluateJavaScript(
            "String(window.getComputedStyle(document.body).backgroundColor)"
        )
        return (raw as? String) ?? ""
    }

    // Skips only when the corpus has not been vendored (`Scripts/extension-corpus fetch`).
    // ORBIT-LIVE-ENGINE: MAY-SKIP testAStylusUserStyleChangesAComputedStyleOnThePage
    func testAStylusUserStyleChangesAComputedStyleOnThePage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        let manifestVersion = try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName)
        XCTAssertEqual(manifestVersion, 3, "Stylus 2.4.9 is the MV3 build this expectation was written against")

        try LiveChromiumEngineHost.runLive(timeout: 300) {
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
            XCTAssertTrue(loaded.hasToolbarAction, "Stylus's manifest declares an action; Orbit draws no icon without one")

            let session = engine.defaultSession
            let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: session)
            let action = try XCTUnwrap(
                entries.first { $0.extensionInfo.id == loaded.id },
                """
                Stylus has no entry in the production toolbar path, so there is no addressable \
                extension origin to drive its API through. Entries offered: \(entries.map(\.extensionInfo.id))
                """
            )
            // Same origin, same API access, none of popup.html's dependency on
            // its worker answering a fetch for `data?...`.
            let driverURL = action.popupURL.deletingLastPathComponent().appendingPathComponent("offscreen.html")

            let model = ExtensionActionPopupModel(engine: engine, session: session, url: driverURL)
            model.start()
            defer { model.teardown() }
            let driver = try XCTUnwrap(
                model.contents as? ChromiumWebContents,
                model.loadFailure ?? "Stylus's own extension page could not be opened at \(driverURL)"
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(driver)

            // Exactly the message js/apply.js/common.js build, with the path
            // its editor's Save uses. A style with no id is a new one.
            let origin = server.baseURL.absoluteString
            _ = try await driver.evaluateJavaScript("""
            window.__orbitInstall = null;
            chrome.runtime.sendMessage({
              data: {
                method: 'invokeAPI',
                path: 'styles.editSave',
                args: [{
                  name: 'orbit-corpus-probe',
                  enabled: true,
                  sections: [{
                    code: 'body { background-color: \(Self.styledBackground) !important; }',
                    urlPrefixes: ['\(origin)'],
                    urls: ['\(origin)/']
                  }]
                }]
              },
              TDM: 1
            }, function (response) {
              window.__orbitInstall = JSON.stringify(
                chrome.runtime.lastError
                  ? { error: chrome.runtime.lastError.message }
                  : {
                      id: response && response.data && response.data.id,
                      enabled: response && response.data && response.data.enabled,
                      error: response && response.error && response.error.message
                    }
              );
            });
            """)

            var installReport = ""
            let installed = await Self.poll(timeout: .seconds(45)) {
                guard let raw = try await driver.evaluateJavaScript("window.__orbitInstall") as? String else {
                    return false
                }
                installReport = raw
                return true
            }
            print("ORBIT-STYLUS styles.editSave = \(installReport)")

            XCTAssertTrue(
                installed,
                """
                Stylus's service worker never answered styles.editSave at all. Its own content script \
                and every one of its pages reach it with exactly this \
                chrome.runtime.sendMessage({data:{method:'invokeAPI',...}}) shape, so nothing it does \
                works if this round trip does not.
                """
            )
            XCTAssertFalse(
                installReport.contains("\"error\""),
                "Stylus rejected the user style rather than saving it: \(installReport)"
            )
            XCTAssertTrue(
                installReport.contains("\"id\":"),
                """
                styles.editSave answered without an id, so no style was persisted and nothing below \
                could be applied: \(installReport)
                """
            )

            // Opened after the style exists, so the assertion does not depend
            // on Stylus's live styleAdded broadcast reaching an open tab.
            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            env.activateTab(tabID)

            var observed = ""
            await Self.poll(timeout: .seconds(45)) {
                observed = await self.backgroundColour(of: contents)
                return observed.replacingOccurrences(of: " ", with: "")
                    == Self.styledBackground.replacingOccurrences(of: " ", with: "")
            }
            print("ORBIT-STYLUS computed body background = \(observed)")

            XCTAssertEqual(
                observed.replacingOccurrences(of: " ", with: ""),
                Self.styledBackground.replacingOccurrences(of: " ", with: ""),
                """
                The user style Stylus saved never reached the page: body is still \(observed). The \
                style itself was persisted (\(installReport)), so the break is in delivery -- \
                js/apply.js runs at document_start, asks the worker for the sections matching this \
                URL and injects them, and one of those three steps produced nothing.
                """
            )
        }
    }
}
