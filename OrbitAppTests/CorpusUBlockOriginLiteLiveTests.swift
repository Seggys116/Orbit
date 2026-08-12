//  corpus: ddkjiahejlhfcafbddmgiahcphecmpfh
//  Drives real uBlock Origin Lite against a server-side oracle: the blocked request
//  (easylist.json rule 2810) must never reach LiveHTTPTestServer, with Orbit's own blocker off.
//  Rule 2810 is a valid oracle: no initiatorDomains/requestDomains/exclusions (a loopback origin matches),
//  it's the only default-enabled rule matching the URL, and uBOL's default optimal mode adds no allowAllRequests for the host.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class CorpusUBlockOriginLiteLiveTests: CorpusLiveTestCase {

    private static let corpusName = "uBlock Origin Lite"

    private static let blockedPath = "/pagead/conversion.js"
    private static let controlPath = "/orbit-control.js"

    // Blocked script requested first so a pass can't come from the parser
    // never reaching it; both scripts also record arrival in the page.
    private static let subjectHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <title>Orbit uBOL subject</title>
    <script src="\(blockedPath)"></script>
    <script src="\(controlPath)"></script>
    </head><body><h1>orbit-ubol-subject</h1></body></html>
    """

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.subjectHTML),
            Self.blockedPath: LiveHTTPTestServer.Route(
                contentType: "application/javascript", body: "window.__orbitBlockedRan = true;"
            ),
            Self.controlPath: LiveHTTPTestServer.Route(
                contentType: "application/javascript", body: "window.__orbitControlRan = true;"
            ),
        ])
    }

    /// Polls without asserting: used for readiness gates whose failure is
    /// reported by the behavioural assertion that follows, not by a timeout.
    @discardableResult
    private static func poll(
        timeout: Duration = .seconds(30), _ condition: () async throws -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private struct Visit {
        var blockedRequests: Int
        var controlRequests: Int
        var blockedScriptRan: Bool
        var controlScriptRan: Bool
        var orbitOwnBlockerVerdict: ContentBlockingDecision

        // preventedOriginalResponse, not isBlocked: a redirect decision keeps
        // the request off the socket just as completely as a block.
        var orbitOwnBlockerWouldHaveBlocked: Bool { orbitOwnBlockerVerdict.preventedOriginalResponse }

        var description: String {
            """
            server saw \(blockedRequests) request(s) for \(CorpusUBlockOriginLiteLiveTests.blockedPath) \
            and \(controlRequests) for \(CorpusUBlockOriginLiteLiveTests.controlPath); \
            page reports blockedScriptRan=\(blockedScriptRan) controlScriptRan=\(controlScriptRan); \
            Orbit's own content blocker said \(orbitOwnBlockerVerdict) about the same URL
            """
        }
    }

    /// Opens the subject page in a real tab on its own server and reports what
    /// the socket and the document each saw.
    /// Own server, own ephemeral port per phase: phase two can never be answered out of a cache phase one warmed.
    private func visitSubject(spaceID: SpaceID, settle: Duration) async throws -> Visit {
        let server = try makeServer()
        defer { server.stop() }

        let tabID = env.openTab(url: server.baseURL, in: spaceID)
        defer { env.closeTab(tabID) }
        let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

        // Only once the control request arrives is "the other one never
        // arrived" a statement about blocking rather than timing.
        await Self.poll(timeout: .seconds(20)) {
            server.requestLog.all.contains { $0.path == Self.controlPath }
        }
        try await Task.sleep(for: settle)

        let raw = try await contents.evaluateJavaScript(
            "JSON.stringify({b: window.__orbitBlockedRan === true, c: window.__orbitControlRan === true})"
        )
        let flags = (raw as? String) ?? ""

        return Visit(
            blockedRequests: server.requestLog.all.filter { $0.path == Self.blockedPath }.count,
            controlRequests: server.requestLog.all.filter { $0.path == Self.controlPath }.count,
            blockedScriptRan: flags.contains("\"b\":true"),
            controlScriptRan: flags.contains("\"c\":true"),
            orbitOwnBlockerVerdict: Self.orbitOwnBlockerVerdict(server: server)
        )
    }

    /// Orbit's EasyList carries the same rule uBOL compiles into id 2810, so
    /// if Orbit's own blocker is armed both stop the request and neither leg means anything.
    private static func orbitOwnBlockerVerdict(server: LiveHTTPTestServer) -> ContentBlockingDecision {
        let blockedURL = URL(string: blockedPath, relativeTo: server.baseURL)?.absoluteString
            ?? server.baseURL.absoluteString + blockedPath
        return ContentBlockingRuntime.shared.controller.blocker.decision(
            forURL: blockedURL,
            documentURL: server.baseURL.absoluteString,
            resourceType: .script
        )
    }

    private func assertNothingButTheSubjectCanBlock(
        _ visit: Visit, expectedExtensions: [String], engine: ChromiumEngine, phase: String
    ) {
        XCTAssertFalse(
            visit.orbitOwnBlockerWouldHaveBlocked,
            """
            \(phase): Orbit's own content blocker is armed and stops \(Self.blockedPath) itself, so this \
            measurement cannot tell uBlock Origin Lite apart from Orbit. CorpusLiveTestCase holds it off \
            for the length of every corpus test; something re-armed it. \(visit.description)
            """
        )
        let loaded = engine.loadedExtensions(session: engine.defaultSession).map(\.id).sorted()
        XCTAssertEqual(
            loaded, expectedExtensions.sorted(),
            """
            \(phase): the shared engine has extensions loaded that this test does not account for, and a \
            blocker among them would be credited to uBlock Origin Lite. Expected \
            \(expectedExtensions.sorted()), engine reports \(loaded).
            """
        )
    }

    // Skips only when the corpus has not been vendored (`Scripts/extension-corpus fetch`).
    // ORBIT-LIVE-ENGINE: MAY-SKIP testUBlockOriginLiteStopsARuleMatchedRequestFromEverReachingTheServer
    func testUBlockOriginLiteStopsARuleMatchedRequestFromEverReachingTheServer() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        let manifestVersion = try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName)
        XCTAssertEqual(manifestVersion, 3, "uBlock Origin Lite is the MV3 declarativeNetRequest entry in this corpus")

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

            // Negative control, run first with nothing loaded: separates
            // "uBOL blocked it" from "this fixture never asked for it".
            let unprotected = try await self.visitSubject(spaceID: spaceID, settle: .seconds(2))
            self.assertNothingButTheSubjectCanBlock(
                unprotected, expectedExtensions: [], engine: engine, phase: "negative control"
            )
            XCTAssertGreaterThan(
                unprotected.blockedRequests, 0,
                "with no blocker loaded the subject page must still request \(Self.blockedPath) -- \(unprotected.description)"
            )
            XCTAssertTrue(
                unprotected.blockedScriptRan,
                "with no blocker loaded the subject page must execute \(Self.blockedPath) -- \(unprotected.description)"
            )
            XCTAssertGreaterThan(
                unprotected.controlRequests, 0,
                "the control request never reached the server even unprotected -- \(unprotected.description)"
            )

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(
                loaded.id, entry.id,
                "the vendored corpus directory produced a different extension than the pin"
            )

            // Rulesets are live only once the MV3 worker boots and reconciles
            // them; gate on getEnabledRulesets or a race measures start-up, not filtering.
            let rulesets = await self.readEnabledRulesets(engine: engine, extensionID: loaded.id)
            print("ORBIT-UBOL enabled rulesets = \(rulesets)")

            let protected = try await self.visitSubject(spaceID: spaceID, settle: .seconds(3))
            print("ORBIT-UBOL protected visit: \(protected.description)")

            // Same preconditions again: uBOL is the only thing that changed
            // between legs, so it is the only thing the missing request can be attributed to.
            self.assertNothingButTheSubjectCanBlock(
                protected, expectedExtensions: [loaded.id], engine: engine, phase: "protected visit"
            )
            XCTAssertGreaterThan(
                protected.controlRequests, 0,
                """
                the control request did not reach the server either, so this run measured a broken \
                page rather than blocking -- \(protected.description)
                """
            )
            XCTAssertTrue(
                protected.controlScriptRan,
                "the control script never executed, so nothing here distinguishes blocking from a dead page -- \(protected.description)"
            )
            XCTAssertEqual(
                protected.blockedRequests, 0,
                """
                \(Self.blockedPath) still reached the socket with uBlock Origin Lite loaded. Its own \
                rulesets/main/easylist.json ships rule id 2810 -- block, resourceTypes ["script"], \
                urlFilter "/pagead/conversion.js" -- in a ruleset its manifest enables by default, and \
                nothing in any enabled ruleset allows it back. Enabled rulesets the extension itself \
                reports: \(rulesets). \(protected.description)
                """
            )
            XCTAssertFalse(
                protected.blockedScriptRan,
                "the blocked script executed in the page, so the request was not merely unlogged -- \(protected.description)"
            )
        }
    }

    // Separates "declarativeNetRequest blocks nothing" from "the ruleset was
    // never enabled" -- two different bugs with the same symptom above.
    // ORBIT-LIVE-ENGINE: MAY-SKIP testUBlockOriginLiteReportsItsDefaultRulesetsEnabled
    func testUBlockOriginLiteReportsItsDefaultRulesetsEnabled() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName)

        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(loaded.id, entry.id, "the vendored corpus directory produced a different extension than the pin")
            XCTAssertTrue(loaded.hasToolbarAction, "uBlock Origin Lite's entire UI hangs off its toolbar action")

            let rulesets = await self.readEnabledRulesets(engine: engine, extensionID: loaded.id)
            XCTAssertTrue(
                rulesets.contains("easylist"),
                """
                uBlock Origin Lite does not report its own `easylist` static ruleset enabled. Its \
                manifest ships that ruleset with "enabled": true, and it carries the rule the blocking \
                test drives, so nothing below it can block. Reported: \(rulesets)
                """
            )
            XCTAssertTrue(
                rulesets.contains("ublock-filters"),
                "uBlock Origin Lite's own default filter list is not enabled either: \(rulesets)"
            )
        }
    }

    // MARK: - Reading the extension's own view of its rulesets

    /// Hosts uBOL's popup via the production ExtensionActionPopupModel and asks
    /// which rulesets are enabled. Empty on no answer, so the caller's assertion decides.
    private func readEnabledRulesets(engine: ChromiumEngine, extensionID: String) async -> [String] {
        let session = engine.defaultSession
        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: session)
        guard let action = entries.first(where: { $0.extensionInfo.id == extensionID }) else { return [] }

        let model = ExtensionActionPopupModel(engine: engine, session: session, url: action.popupURL)
        model.start()
        defer { model.teardown() }
        guard let popup = model.contents as? ChromiumWebContents else { return [] }
        try? await LiveChromiumEngineHost.waitUntilStoppedLoading(popup)

        _ = try? await popup.evaluateJavaScript("""
        window.__orbitRulesets = null;
        (function () {
          if (!chrome.declarativeNetRequest || !chrome.declarativeNetRequest.getEnabledRulesets) {
            window.__orbitRulesets = JSON.stringify([]);
            return;
          }
          chrome.declarativeNetRequest.getEnabledRulesets(function (ids) {
            window.__orbitRulesets = JSON.stringify(
              chrome.runtime.lastError ? [] : (ids || [])
            );
          });
        })();
        """)

        var reported: [String] = []
        await Self.poll(timeout: .seconds(30)) {
            guard let raw = try await popup.evaluateJavaScript("window.__orbitRulesets") as? String,
                  let data = raw.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data),
                  !ids.isEmpty
            else { return false }
            reported = ids
            return true
        }
        return reported
    }
}
