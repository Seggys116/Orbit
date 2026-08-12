//  corpus: gppongmhjkpfnbhagpmjfkannfbllamg
//  Drives the REAL shipped Wappalyzer 6.12.5, pinned by SHA-256 in Chromium/extension-corpus.json,
//  not a fixture -- other suites build their own worker and pass while the real extension reports nothing.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class RealWappalyzerLiveTests: CorpusLiveTestCase {

    private static let corpusName = "Wappalyzer"

    private struct Subject {
        var directory: URL
        var id: String
    }

    /// Skips (naming the fetch command) when the corpus is not vendored on this machine,
    /// fails hard when the directory is present but unpacked from a different build.
    private func pinnedWappalyzer(file: StaticString = #filePath, line: UInt = #line) throws -> Subject {
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName, file: file, line: line)
        return Subject(directory: directory, id: entry.id)
    }

    // MARK: - Page fixtures

    // Signals taken straight from the extension's own technologies/*.json: WordPress
    // meta.generator, jQuery scriptSrc/js, Bootstrap dom style, PHP X-Powered-By header.
    private static let subjectHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="generator" content="WordPress 6.5">
    <title>Orbit Wappalyzer subject</title>
    <style>:root { --bs-gutter-x: 1.5rem; }</style>
    <script src="/jquery.js"></script>
    </head><body><h1>orbit-wappalyzer-subject</h1></body></html>
    """

    private static let decoyHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Orbit decoy</title></head>
    <body><h1>orbit-wappalyzer-decoy</h1></body></html>
    """

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html",
                body: Self.subjectHTML,
                extraHeaders: ["X-Powered-By": "PHP/8.2.10"]
            ),
            "/decoy": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.decoyHTML),
            "/jquery.js": LiveHTTPTestServer.Route(
                contentType: "application/javascript",
                body: "window.jQuery = { fn: { jquery: '3.7.1' } }; window.$ = window.jQuery;"
            ),
        ])
    }

    // MARK: - Harness

    private struct PopupDOM: Decodable {
        var emptyHidden: Bool
        var detectionsHidden: Bool
        var termsHidden: Bool
        var technologies: [String]
    }

    private struct QueriedTab: Decodable {
        var id: Int32?
        var windowId: Int32?
        var active: Bool?
        var url: String?
    }

    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(30),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("timed out waiting for \(waitingFor)")
    }

    /// A live engine, a registered window, the real extension loaded, and a subject tab
    /// whose badge Wappalyzer has already written (proof its analysis pipeline ran end to end).
    private struct Harness {
        var engine: ChromiumEngine
        var server: LiveHTTPTestServer
        var loaded: LoadedExtension
        var subjectTabID: TabID
        var subjectRegistryID: Int32
        var spaceID: SpaceID
    }

    private func startHarness(_ subject: Subject) async throws -> Harness {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        let env = self.env
        env._test_engineOverride = engine

        // The XCTest host has no OrbitWindowController, so nothing has registered this
        // environment as a chrome.windows window -- that's OrbitWindowController.configure's job.
        let bridge = OrbitChromiumTabsBridge.shared
        if !bridge.isWindowRegistered(env) {
            bridge.windowCreated(owner: env, focused: false)
        }
        bridge.windowFocusChanged(owner: env)

        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let server = try makeServer()
        let loaded = try await engine.loadExtension(at: subject.directory, session: engine.defaultSession)
        XCTAssertEqual(
            loaded.id, subject.id,
            "the vendored corpus directory produced a different extension than the pin, so nothing below is Wappalyzer"
        )
        XCTAssertTrue(loaded.hasToolbarAction)

        let subjectTabID = env.openTab(url: server.baseURL, in: spaceID)
        let contents = try XCTUnwrap(env.webContents[subjectTabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
        let subjectRegistryID = try XCTUnwrap(bridge.existingTabID(for: subjectTabID))

        try await Self.pollUntil("Wappalyzer to badge the subject tab") {
            !self.badgeText(engine: engine, extensionID: loaded.id, tabID: subjectRegistryID).isEmpty
        }
        // On first install Wappalyzer opens its own wappalyzer.com/installed tab; let it
        // land, then go back to the subject tab -- the state a user is in when opening the popup.
        try await Task.sleep(for: .seconds(3))
        env.activateTab(subjectTabID)

        return Harness(
            engine: engine, server: server, loaded: loaded, subjectTabID: subjectTabID,
            subjectRegistryID: subjectRegistryID, spaceID: spaceID
        )
    }

    private func badgeText(engine: ChromiumEngine, extensionID: String, tabID: Int32) -> String {
        engine.extensionActionStates.state(extensionID: extensionID, tabID: tabID).badgeText
    }

    /// The URL the toolbar itself would open, built through the production
    /// path rather than a hand-assembled chrome-extension:// string.
    private func actionEntry(
        engine: ChromiumEngine, subjectTabID: TabID, subjectRegistryID: Int32, extensionID: String
    ) throws -> SiteControlPopoverView.ExtensionActionEntry {
        let session = env.webContents[subjectTabID]?.session ?? engine.defaultSession
        let entries = SiteControlPopoverView.extensionActionEntries(
            engine: engine, session: session, tabID: subjectRegistryID
        )
        return try XCTUnwrap(
            entries.first { $0.extensionInfo.id == extensionID }, "Wappalyzer has no toolbar entry"
        )
    }

    private func openPopup(
        engine: ChromiumEngine, subjectTabID: TabID, subjectRegistryID: Int32, extensionID: String
    ) async throws -> (ExtensionActionPopupModel, ChromiumWebContents) {
        let entry = try actionEntry(
            engine: engine, subjectTabID: subjectTabID,
            subjectRegistryID: subjectRegistryID, extensionID: extensionID
        )
        let session = env.webContents[subjectTabID]?.session ?? engine.defaultSession
        let model = ExtensionActionPopupModel(engine: engine, session: session, url: entry.popupURL)
        model.start()
        let popup = try XCTUnwrap(model.contents as? ChromiumWebContents, model.loadFailure ?? "no popup contents")
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(popup)
        return (model, popup)
    }

    private func openPopup(for harness: Harness) async throws -> (ExtensionActionPopupModel, ChromiumWebContents) {
        try await openPopup(
            engine: harness.engine, subjectTabID: harness.subjectTabID,
            subjectRegistryID: harness.subjectRegistryID, extensionID: harness.loaded.id
        )
    }

    private static let popupDOMProbe = """
    (function () {
      function has(sel, cls) {
        var n = document.querySelector(sel);
        return !!n && n.classList.contains(cls);
      }
      return JSON.stringify({
        emptyHidden: has('.empty', 'empty--hidden'),
        detectionsHidden: has('.detections', 'detections--hidden'),
        termsHidden: has('.terms', 'terms--hidden'),
        technologies: Array.prototype.slice
          .call(document.querySelectorAll('.detections .technology__name'))
          .map(function (n) { return (n.textContent || '').trim(); })
          .filter(function (t) { return t.length > 0; })
      });
    })()
    """

    private func readPopupDOM(_ popup: ChromiumWebContents) async throws -> PopupDOM? {
        guard let raw = try await popup.evaluateJavaScript(Self.popupDOMProbe) as? String,
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(PopupDOM.self, from: data)
    }

    /// An extension popup is not a tab, so orbit::CurrentWindowIdFor falls through to
    /// GetLastFocusedWindowId -- the same resolution the worker's own Driver.getDetections takes.
    private func queryTabs(_ popup: ChromiumWebContents, queryInfo: String) async throws -> [QueriedTab] {
        let key = "__orbitQuery\(abs(queryInfo.hashValue))"
        _ = try await popup.evaluateJavaScript("""
        window.\(key) = null;
        chrome.tabs.query(\(queryInfo), function (tabs) {
          window.\(key) = JSON.stringify((tabs || []).map(function (t) {
            return { id: t.id, windowId: t.windowId, active: t.active, url: t.url };
          }));
        });
        """)
        var decoded: [QueriedTab] = []
        try await Self.pollUntil("chrome.tabs.query\(queryInfo) to answer") {
            guard let raw = try await popup.evaluateJavaScript("window.\(key)") as? String,
                  let data = raw.data(using: .utf8),
                  let tabs = try? JSONDecoder().decode([QueriedTab].self, from: data)
            else { return false }
            decoded = tabs
            return true
        }
        return decoded
    }

    /// Driver.onMessage answers a thrown method with a bare callback(), so "undefined" here
    /// means either a clean early return or a throw -- the caller watches the badge to tell them apart.
    private func callDriver(
        _ popup: ChromiumWebContents, key: String, method: String, args: String
    ) async throws -> String {
        _ = try await popup.evaluateJavaScript("""
        window.\(key) = null;
        chrome.runtime.sendMessage(
          { source: 'orbit-diag', func: '\(method)', args: \(args) },
          function (r) {
            var out;
            if (chrome.runtime.lastError) { out = { error: chrome.runtime.lastError.message }; }
            else if (r === undefined) { out = { value: 'undefined' }; }
            else if (r === null) { out = { value: 'null' }; }
            else if (Array.isArray(r)) {
              out = { count: r.length, names: r.slice(0, 12).map(function (d) { return d && d.name; }) };
            } else { out = { value: r }; }
            window.\(key) = JSON.stringify(out);
          }
        );
        """)
        var answer = ""
        try await Self.pollUntil("Driver.\(method) to answer") {
            guard let raw = try await popup.evaluateJavaScript("window.\(key)") as? String else {
                return false
            }
            answer = raw
            return true
        }
        return answer
    }

    private func dumpState(_ popup: ChromiumWebContents, _ label: String) async {
        let all = (try? await queryTabs(popup, queryInfo: "{}")) ?? []
        let active = (try? await queryTabs(popup, queryInfo: "{active: true, currentWindow: true}")) ?? []
        print("ORBIT-WAPP [\(label)] chrome.tabs.query({}) = \(all)")
        print("ORBIT-WAPP [\(label)] chrome.tabs.query({active,currentWindow}) = \(active)")
        if let dom = try? await readPopupDOM(popup) {
            print("ORBIT-WAPP [\(label)] popup DOM = \(String(describing: dom))")
        }
    }

    private func assertPopupListsTechnologies(
        _ popup: ChromiumWebContents, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> PopupDOM {
        var dom = PopupDOM(emptyHidden: false, detectionsHidden: true, termsHidden: false, technologies: [])
        try await Self.pollUntil("Wappalyzer's popup to render technologies (\(label))") {
            guard let read = try await self.readPopupDOM(popup) else { return false }
            dom = read
            return !read.technologies.isEmpty
        }
        if dom.technologies.isEmpty { await dumpState(popup, label) }
        XCTAssertTrue(dom.termsHidden, "[\(label)] terms gate should be auto-accepted on chrome", file: file, line: line)
        XCTAssertTrue(dom.emptyHidden, "[\(label)] popup still shows \"No technologies detected\"", file: file, line: line)
        XCTAssertFalse(dom.detectionsHidden, "[\(label)] popup's detections list is hidden", file: file, line: line)
        XCTAssertFalse(dom.technologies.isEmpty, "[\(label)] popup listed no technologies", file: file, line: line)
        return dom
    }

    // MARK: - Tests

    // Skippable only if the pinned corpus is not vendored: ExtensionCorpus never downloads
    // at test time, so a clone without `Scripts/extension-corpus fetch` has no Wappalyzer to drive.
    // ORBIT-LIVE-ENGINE: MAY-SKIP testRealWappalyzerPopupListsTheSameTechnologiesItsBadgeCounts
    func testRealWappalyzerPopupListsTheSameTechnologiesItsBadgeCounts() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subject = try pinnedWappalyzer()

        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let harness = try await self.startHarness(subject)
            defer { harness.server.stop() }
            defer { harness.engine.unloadExtension(id: harness.loaded.id, session: harness.engine.defaultSession) }

            let badge = self.badgeText(
                engine: harness.engine, extensionID: harness.loaded.id, tabID: harness.subjectRegistryID
            )
            let badgeCount = Int(badge) ?? 0
            print("ORBIT-WAPP badge = \(badge)")

            let (model, popup) = try await self.openPopup(for: harness)
            defer { model.teardown() }

            let dom = try await self.assertPopupListsTechnologies(popup, "happy path")
            print("ORBIT-WAPP popup technologies = \(dom.technologies)")

            XCTAssertGreaterThanOrEqual(badgeCount, 1, "badge should count Wappalyzer's own detections")
            XCTAssertLessThanOrEqual(
                dom.technologies.count, badgeCount,
                "the popup lists a confidence-filtered subset of what the badge counts, never more"
            )
            // WordPress's meta.generator match needs the content script's html analysis, which this
            // fixture does not reach, so only jQuery/Bootstrap are asserted here.
            XCTAssertTrue(dom.technologies.contains("jQuery"), "jQuery: \(dom.technologies)")
            XCTAssertTrue(dom.technologies.contains("Bootstrap"), "Bootstrap: \(dom.technologies)")

            let active = try await self.queryTabs(popup, queryInfo: "{active: true, currentWindow: true}")
            XCTAssertEqual(active.count, 1, "exactly one active tab per window: \(active)")
            XCTAssertEqual(active.first?.id, harness.subjectRegistryID, "\(active)")
        }
    }

    // ORBIT-LIVE-ENGINE: MAY-SKIP testRealWappalyzerPopupStillResolvesTheActiveTabAfterTheActiveTabIsClosed
    func testRealWappalyzerPopupStillResolvesTheActiveTabAfterTheActiveTabIsClosed() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subject = try pinnedWappalyzer()

        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let harness = try await self.startHarness(subject)
            defer { harness.server.stop() }
            defer { harness.engine.unloadExtension(id: harness.loaded.id, session: harness.engine.defaultSession) }
            let env = self.env

            // A second tab takes over active, then closes: BrowserStore reassigns activeTabBySpace,
            // but nothing tells OrbitTabRegistry, so chrome.tabs may believe otherwise.
            let decoyTabID = env.openTab(url: harness.server.baseURL.appendingPathComponent("decoy"), in: harness.spaceID)
            let decoyContents = try XCTUnwrap(env.webContents[decoyTabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(decoyContents)
            env.closeTab(decoyTabID)
            XCTAssertEqual(env.activeTabID, harness.subjectTabID, "Orbit itself shows the subject tab again")

            let (model, popup) = try await self.openPopup(for: harness)
            defer { model.teardown() }

            let active = try await self.queryTabs(popup, queryInfo: "{active: true, currentWindow: true}")
            if active.count != 1 || active.first?.id != harness.subjectRegistryID {
                await self.dumpState(popup, "after close")
            }
            XCTAssertEqual(active.count, 1, "exactly one active tab per window: \(active)")
            XCTAssertEqual(active.first?.id, harness.subjectRegistryID, "\(active)")

            _ = try await self.assertPopupListsTechnologies(popup, "after close")
        }
    }

    // ORBIT-LIVE-ENGINE: MAY-SKIP testRealWappalyzerPopupResolvesTheActiveTabAfterASpaceSwitch
    func testRealWappalyzerPopupResolvesTheActiveTabAfterASpaceSwitch() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subject = try pinnedWappalyzer()

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

            let firstSpaceID = try XCTUnwrap(env.activeSpace?.id)
            let server = try self.makeServer()
            defer { server.stop() }
            let loaded = try await engine.loadExtension(at: subject.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(
                loaded.id, subject.id,
                "the vendored corpus directory produced a different extension than the pin, so nothing below is Wappalyzer"
            )

            let decoyTabID = env.openTab(url: server.baseURL.appendingPathComponent("decoy"), in: firstSpaceID)
            let decoyContents = try XCTUnwrap(env.webContents[decoyTabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(decoyContents)

            let profileID = try XCTUnwrap(env.state.profiles.first?.id)
            let secondSpaceID = env.createSpace(
                name: "Wappalyzer", icon: "globe", iconIsEmoji: false, theme: .init(), profileID: profileID
            )
            env.selectSpace(secondSpaceID)

            let subjectTabID = env.openTab(url: server.baseURL, in: secondSpaceID)
            let subjectContents = try XCTUnwrap(env.webContents[subjectTabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(subjectContents)
            let subjectRegistryID = try XCTUnwrap(bridge.existingTabID(for: subjectTabID))

            try await Self.pollUntil("Wappalyzer to badge the subject tab") {
                !self.badgeText(engine: engine, extensionID: loaded.id, tabID: subjectRegistryID).isEmpty
            }
            try await Task.sleep(for: .seconds(3))
            env.selectSpace(secondSpaceID)

            let harness = Harness(
                engine: engine, server: server, loaded: loaded, subjectTabID: subjectTabID,
                subjectRegistryID: subjectRegistryID, spaceID: secondSpaceID
            )
            let (model, popup) = try await self.openPopup(for: harness)
            defer { model.teardown() }

            let active = try await self.queryTabs(popup, queryInfo: "{active: true, currentWindow: true}")
            if active.count != 1 || active.first?.id != subjectRegistryID {
                await self.dumpState(popup, "after space switch")
            }
            XCTAssertEqual(active.count, 1, "exactly one active tab per window: \(active)")
            XCTAssertEqual(active.first?.id, subjectRegistryID, "\(active)")

            _ = try await self.assertPopupListsTechnologies(popup, "after space switch")
        }
    }

    // Drives Wappalyzer's own Driver methods one at a time over the chrome.runtime.sendMessage
    // channel js/popup.js uses, walking "which tab does the worker resolve" to "what does it say".
    private static let workerDiagnosticProbe = """
    window.__orbitDiag = null;
    (function () {
      function call(func, args) {
        return new Promise(function (resolve) {
          chrome.runtime.sendMessage(
            { source: 'orbit-diag', func: func, args: args || [] },
            function (response) {
              resolve(
                chrome.runtime.lastError
                  ? { error: chrome.runtime.lastError.message }
                  : { value: response }
              );
            }
          );
        });
      }
      function summarise(r) {
        if (!r) { return null; }
        if (r.error) { return { error: r.error }; }
        var v = r.value;
        if (v === undefined) { return { value: 'undefined' }; }
        if (Array.isArray(v)) {
          return {
            count: v.length,
            names: v.slice(0, 12).map(function (d) {
              return (d && d.name) + '@' + (d && d.confidence);
            })
          };
        }
        if (v && typeof v === 'object') {
          return {
            url: v.url,
            transient: v.transient,
            detections: Array.isArray(v.detections) ? v.detections.length : null
          };
        }
        return { value: v };
      }
      // Wappalyzer reaches chrome.tabs.query through Utils.promisify, which
      // rejects on chrome.runtime.lastError. A raw callback that ignores
      // lastError would report a tab where Driver.getDetections throws, so
      // replicate both and record the difference.
      function promisifiedQuery() {
        return new Promise(function (resolve, reject) {
          chrome.tabs.query({ active: true, currentWindow: true }, function (tabs) {
            if (chrome.runtime.lastError) {
              reject(chrome.runtime.lastError.message || String(chrome.runtime.lastError));
              return;
            }
            resolve(tabs || []);
          });
        });
      }
      chrome.tabs.query({ active: true, currentWindow: true }, async function (tabs) {
        var tab = (tabs || [])[0] || {};
        var out = {
          resolvedTab: { id: tab.id, url: tab.url },
          queryLastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
        };
        try {
          out.promisifiedQuery = await promisifiedQuery().then(
            function (t) { return { count: t.length, firstId: t[0] && t[0].id }; },
            function (e) { return { rejected: String(e) }; }
          );
          out.getDetections = summarise(await call('getDetections'));
          out.getDetectionsForTab = summarise(
            await call('getDetectionsForTab', [{ id: tab.id, url: tab.url }])
          );
          out.getTabResult = summarise(await call('getTabResult', [tab.id, tab.url, true]));
          out.isTransientUrl = summarise(await call('isTransientUrl', [tab.url, tab.id, true]));
          out.isDisabledDomain = summarise(await call('isDisabledDomain', [tab.url]));
          var techs = await call('getTechnologies');
          out.technologyCount = techs.error
            ? techs
            : (Array.isArray(techs.value) ? techs.value.length : typeof techs.value);
          // Every detection Wappalyzer keeps lives in chrome.storage.session
          // (setCachedHostnames and persistTabResults both write there, and
          // getCachedHostnames deletes the chrome.storage.local copy once it
          // has migrated it). If that area does not work, an MV3 worker
          // restart loses the lot while the per-tab badge, which the browser
          // holds, survives -- so read both what it persisted and whether the
          // area functions at all.
          out.storageSession = typeof chrome.storage.session;
          if (chrome.storage.session) {
            await new Promise(function (r) {
              chrome.storage.session.set({ __orbitProbe: 'ok' }, function () {
                chrome.storage.session.get(
                  ['__orbitProbe', 'hostnames', 'tabResults'],
                  function (got) {
                    if (chrome.runtime.lastError) {
                      out.storageSessionError = chrome.runtime.lastError.message;
                    } else {
                      out.storageSessionRoundTrip = (got && got.__orbitProbe) || 'missing';
                      out.persistedHostnames = got && got.hostnames
                        ? Object.keys(got.hostnames)
                        : null;
                      out.persistedTabResults = got && got.tabResults
                        ? Object.keys(got.tabResults)
                        : null;
                    }
                    r();
                  }
                );
              });
            });
          }
        } catch (e) {
          out.threw = String(e);
        }
        window.__orbitDiag = JSON.stringify(out);
      });
    })();
    """

    // ORBIT-LIVE-ENGINE: MAY-SKIP testRealWappalyzerWorkerReportsDetectionsForTheTabItResolves
    func testRealWappalyzerWorkerReportsDetectionsForTheTabItResolves() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subject = try pinnedWappalyzer()

        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let harness = try await self.startHarness(subject)
            defer { harness.server.stop() }
            defer { harness.engine.unloadExtension(id: harness.loaded.id, session: harness.engine.defaultSession) }

            let badgeBefore = self.badgeText(
                engine: harness.engine, extensionID: harness.loaded.id, tabID: harness.subjectRegistryID
            )
            let subject = try XCTUnwrap(self.env.webContents[harness.subjectTabID] as? ChromiumWebContents)
            let pageURL = try await subject.evaluateJavaScript("location.href") as? String

            let (model, popup) = try await self.openPopup(for: harness)
            defer { model.teardown() }

            _ = try await popup.evaluateJavaScript(Self.workerDiagnosticProbe)
            var diagnostic = ""
            try await Self.pollUntil("Wappalyzer's worker to answer the diagnostic") {
                guard let raw = try await popup.evaluateJavaScript("window.__orbitDiag") as? String else {
                    return false
                }
                diagnostic = raw
                return true
            }

            let badgeAfter = self.badgeText(
                engine: harness.engine, extensionID: harness.loaded.id, tabID: harness.subjectRegistryID
            )
            print("ORBIT-WAPP subject registry id = \(harness.subjectRegistryID)")
            print("ORBIT-WAPP page location.href = \(String(describing: pageURL))")
            print("ORBIT-WAPP badge before popup = '\(badgeBefore)', after = '\(badgeAfter)'")
            print("ORBIT-WAPP worker diagnostic = \(diagnostic)")

            // getDetections reaches Driver.setIcon only if its own chrome.tabs.query resolved, so
            // clearing the badge first separates "the worker's query failed" from "something after it did".
            let subjectURL = harness.server.baseURL.absoluteString
            let cleared = try await self.callDriver(
                popup, key: "__orbitClear", method: "setIcon",
                args: "['\(subjectURL)', [], \(harness.subjectRegistryID)]"
            )
            try? await Self.pollUntil("Driver.setIcon to clear the badge", timeout: .seconds(10)) {
                self.badgeText(
                    engine: harness.engine, extensionID: harness.loaded.id, tabID: harness.subjectRegistryID
                ).isEmpty
            }
            let badgeAfterClear = self.badgeText(
                engine: harness.engine, extensionID: harness.loaded.id, tabID: harness.subjectRegistryID
            )
            let second = try await self.callDriver(
                popup, key: "__orbitSecond", method: "getDetections", args: "[]"
            )
            try? await Self.pollUntil("getDetections to restore the badge", timeout: .seconds(10)) {
                !self.badgeText(
                    engine: harness.engine, extensionID: harness.loaded.id, tabID: harness.subjectRegistryID
                ).isEmpty
            }
            let badgeAfterSecond = self.badgeText(
                engine: harness.engine, extensionID: harness.loaded.id, tabID: harness.subjectRegistryID
            )
            print("ORBIT-WAPP setIcon(url, [], tabId) = \(cleared), badge now '\(badgeAfterClear)'")
            print("ORBIT-WAPP second getDetections = \(second), badge now '\(badgeAfterSecond)'")

            XCTAssertFalse(badgeBefore.isEmpty, "Wappalyzer's own live detection never ran")
            XCTAssertTrue(
                badgeAfterClear.isEmpty,
                "Driver.setIcon could not even clear the badge, so the action API is the broken link"
            )
            XCTAssertFalse(
                badgeAfterSecond.isEmpty,
                "getDetections never reached Driver.setIcon, so its own chrome.tabs.query is the broken link"
            )
            XCTAssertFalse(
                diagnostic.contains("\"getDetections\":{\"value\":null}")
                    || diagnostic.contains("\"getDetections\":{\"value\":\"undefined\"}"),
                "the worker answered the popup with nothing for a tab it resolved: \(diagnostic)"
            )
        }
    }

    // Loopback is always transient to Wappalyzer (IP-literal host, and isPrivateIpAddress() calls
    // 127.x private); "transient" only moves where results cache, it never suppresses reporting.
    // ORBIT-LIVE-ENGINE: MAY-SKIP testWappalyzerTreatsLoopbackAsTransientAndStillReportsItsDetections
    func testWappalyzerTreatsLoopbackAsTransientAndStillReportsItsDetections() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subject = try pinnedWappalyzer()

        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let harness = try await self.startHarness(subject)
            defer { harness.server.stop() }
            defer { harness.engine.unloadExtension(id: harness.loaded.id, session: harness.engine.defaultSession) }

            let (model, popup) = try await self.openPopup(for: harness)
            defer { model.teardown() }

            let subjectURL = harness.server.baseURL.absoluteString
            let transient = try await self.callDriver(
                popup, key: "__orbitTransient", method: "isTransientUrl",
                args: "['\(subjectURL)', \(harness.subjectRegistryID), true]"
            )
            let forTab = try await self.callDriver(
                popup, key: "__orbitForTab", method: "getDetectionsForTab",
                args: "[{id: \(harness.subjectRegistryID), url: '\(subjectURL)'}]"
            )
            print("ORBIT-WAPP isTransientUrl = \(transient)")
            print("ORBIT-WAPP getDetectionsForTab = \(forTab)")

            XCTAssertTrue(
                transient.contains("\"value\":true"),
                "loopback should be transient to Wappalyzer, so the rule this suite pins still holds: \(transient)"
            )
            XCTAssertTrue(
                forTab.contains("\"count\":") && !forTab.contains("\"count\":0"),
                "transience must not suppress reporting -- it only moves the cache: \(forTab)"
            )
        }
    }

    // A rejected chrome.action.setIcon path throws out of Driver.getDetections, leaving the popup
    // showing "No technologies detected" while the badge still shows the count. Hermetic on purpose.
    // ORBIT-LIVE-ENGINE: MAY-SKIP testActionSetIconAcceptsTheAbsoluteURLsRuntimeGetURLReturns
    func testActionSetIconAcceptsTheAbsoluteURLsRuntimeGetURLReturns() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subject = try pinnedWappalyzer()

        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let harness = try await self.startHarness(subject)
            defer { harness.server.stop() }
            defer { harness.engine.unloadExtension(id: harness.loaded.id, session: harness.engine.defaultSession) }

            let (model, popup) = try await self.openPopup(for: harness)
            defer { model.teardown() }

            _ = try await popup.evaluateJavaScript("""
            window.__orbitIcon = null;
            (function () {
              var results = {};
              function record(name, done) {
                return function () {
                  results[name] = chrome.runtime.lastError ? chrome.runtime.lastError.message : 'ok';
                  done();
                };
              }
              var pending = 3;
              function done() { if (--pending === 0) { window.__orbitIcon = JSON.stringify(results); } }
              // Exactly the three shapes a real extension sends.
              chrome.action.setIcon(
                { tabId: \(harness.subjectRegistryID), path: chrome.runtime.getURL('images/icon_32.png') },
                record('absoluteString', done)
              );
              var manifest = chrome.runtime.getManifest();
              var dict = {};
              Object.keys(manifest.action.default_icon).forEach(function (size) {
                dict[size] = chrome.runtime.getURL(manifest.action.default_icon[size]);
              });
              chrome.action.setIcon(
                { tabId: \(harness.subjectRegistryID), path: dict }, record('absoluteDict', done)
              );
              chrome.action.setIcon(
                { tabId: \(harness.subjectRegistryID), path: 'images/icon_32.png' },
                record('relativeString', done)
              );
            })();
            """)
            var results = ""
            try await Self.pollUntil("chrome.action.setIcon to answer all three shapes") {
                guard let raw = try await popup.evaluateJavaScript("window.__orbitIcon") as? String else {
                    return false
                }
                results = raw
                return true
            }
            print("ORBIT-WAPP setIcon shapes = \(results)")

            XCTAssertFalse(
                results.contains("Icon invalid"),
                "chrome.action.setIcon rejected a path real extensions send: \(results)"
            )
            XCTAssertEqual(
                results.components(separatedBy: "\"ok\"").count - 1, 3,
                "all three path shapes must be accepted: \(results)"
            )
        }
    }

    // MARK: - The user's own site, over the real network

    // Wappalyzer has three channels: js/js.js's main-world postMessage (React, Next.js, Framer
    // Motion, Lucide), webRequest (Cloudflare, HTTP/3), and the content script's own DOM analysis.
    private static func mainWorldInjectionProbe(extensionID: String) -> String {
        """
        (function () {
          window.__orbitInject = null;
          var url = 'chrome-extension://\(extensionID)/js/js.js';
          var result = { url: url, fetch: null, scriptLoaded: null, error: null, replied: null };
          function finish() {
            if (!window.__orbitInject) { window.__orbitInject = JSON.stringify(result); }
          }
          // Separates "the resource is not web-accessible" from "the page CSP
          // refused the script element".
          fetch(url).then(
            function (r) { result.fetch = 'status:' + r.status; },
            function (e) { result.fetch = 'error:' + String(e); }
          );
          var s = document.createElement('script');
          s.onload = function () {
            result.scriptLoaded = true;
            var onMessage = function (e) {
              if (!e.data || !e.data.wappalyzer || !e.data.wappalyzer.js) { return; }
              window.removeEventListener('message', onMessage);
              result.replied = e.data.wappalyzer.js;
              finish();
            };
            window.addEventListener('message', onMessage);
            // Exactly the handshake content.js's getJs() performs.
            window.postMessage({ wappalyzer: { technologies: [
              { name: 'React', chains: ['React.version'] },
              { name: 'Next.js', chains: ['next.version', '__NEXT_DATA__'] },
              { name: 'Framer Motion', chains: ['Motion'] }
            ] } });
            setTimeout(function () { result.replied = result.replied || 'no-reply'; finish(); }, 4000);
          };
          s.onerror = function () {
            result.scriptLoaded = false;
            result.error = 'script onerror: the resource never executed in the main world';
            finish();
          };
          s.setAttribute('src', url);
          document.body.appendChild(s);
          setTimeout(function () {
            result.error = result.error || 'neither onload nor onerror fired';
            finish();
          }, 8000);
        })();
        """
    }

    private static func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        guard let (_, response) = try? await URLSession(configuration: configuration).data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse) != nil
    }

    // ORBIT-LIVE-ENGINE: MAY-SKIP testRealWappalyzerOnThePublicSiteReportsEachChannel
    // Also needs the real network: no local fixture carries Cloudflare's headers or a real Next.js bundle.
    func testRealWappalyzerOnThePublicSiteReportsEachChannel() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subject = try pinnedWappalyzer()
        let siteURL = URL(string: "https://zaknobleclarke.com")!

        try LiveChromiumEngineHost.runLive(timeout: 300) {
            guard await Self.isReachable(siteURL) else {
                throw XCTSkip("\(siteURL.absoluteString) is not reachable from this machine")
            }

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
            let loaded = try await engine.loadExtension(at: subject.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(
                loaded.id, subject.id,
                "the vendored corpus directory produced a different extension than the pin, so nothing below is Wappalyzer"
            )

            let tabID = env.openTab(url: siteURL, in: spaceID)
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            // Next.js hydrates after load; its globals and Wappalyzer's own
            // document_idle content script both need that to have happened.
            try await Task.sleep(for: .seconds(10))
            let registryID = try XCTUnwrap(bridge.existingTabID(for: tabID))
            env.activateTab(tabID)

            let pageURL = try await contents.evaluateJavaScript("location.href") as? String
            let globals = try await contents.evaluateJavaScript("""
            JSON.stringify({
              react: typeof window.React,
              nextData: typeof window.__NEXT_DATA__,
              next: typeof window.next,
              motion: typeof window.Motion,
              scripts: Array.prototype.slice.call(document.scripts)
                .map(function (s) { return s.src; })
                .filter(function (s) { return s; }).slice(0, 8)
            })
            """) as? String

            // Channel 2, measured directly, independent of whether
            // Wappalyzer's own content script got anywhere.
            _ = try await contents.evaluateJavaScript(Self.mainWorldInjectionProbe(extensionID: loaded.id))
            var injection = ""
            try await Self.pollUntil("the main-world injection probe to settle", timeout: .seconds(30)) {
                guard let raw = try await contents.evaluateJavaScript("window.__orbitInject") as? String else {
                    return false
                }
                injection = raw
                return true
            }

            let badge = self.badgeText(engine: engine, extensionID: loaded.id, tabID: registryID)

            let (model, popup) = try await self.openPopup(
                engine: engine, subjectTabID: tabID, subjectRegistryID: registryID, extensionID: loaded.id
            )
            defer { model.teardown() }

            let url = try XCTUnwrap(pageURL)
            let escaped = url.replacingOccurrences(of: "'", with: "\\'")
            let detections = try await self.callDriver(
                popup, key: "__orbitDet", method: "getDetections", args: "[]"
            )
            let forTab = try await self.callDriver(
                popup, key: "__orbitForTab", method: "getDetectionsForTab",
                args: "[{id: \(registryID), url: '\(escaped)'}]"
            )
            let tabResult = try await self.callDriver(
                popup, key: "__orbitTabRes", method: "getTabResult",
                args: "[\(registryID), '\(escaped)', true]"
            )
            // Channel 3: populated only by Driver.onResponseStarted, so null
            // here means the webRequest channel delivered nothing at all.
            let tabRequest = try await self.callDriver(
                popup, key: "__orbitTabReq", method: "getTabRequest",
                args: "[\(registryID), '\(escaped)', true]"
            )
            let transient = try await self.callDriver(
                popup, key: "__orbitTransient2", method: "isTransientUrl",
                args: "['\(escaped)', \(registryID), true]"
            )
            // Channel 3, measured directly: register the same listeners Wappalyzer does, then
            // reload the tab and see what arrives.
            _ = try await popup.evaluateJavaScript("""
            window.__orbitWebRequest = null;
            (function () {
              var events = [];
              var filter = { urls: ['http://*/*', 'https://*/*'], types: ['main_frame'] };
              try {
                chrome.webRequest.onResponseStarted.addListener(function (d) {
                  events.push({ event: 'onResponseStarted', tabId: d.tabId, url: d.url,
                                statusCode: d.statusCode, ip: d.ip || null });
                }, filter);
                chrome.webRequest.onCompleted.addListener(function (d) {
                  events.push({ event: 'onCompleted', tabId: d.tabId, url: d.url,
                                statusCode: d.statusCode, ip: d.ip || null,
                                headers: d.responseHeaders ? d.responseHeaders.length : null });
                }, filter, ['responseHeaders']);
              } catch (e) {
                window.__orbitWebRequest = JSON.stringify({ addListenerThrew: String(e) });
                return;
              }
              setTimeout(function () {
                window.__orbitWebRequest = JSON.stringify({ events: events });
              }, 15000);
              chrome.tabs.reload(\(registryID), { bypassCache: true });
            })();
            """)
            var webRequest = ""
            try await Self.pollUntil("the webRequest probe to settle", timeout: .seconds(45)) {
                guard let raw = try await popup.evaluateJavaScript("window.__orbitWebRequest") as? String else {
                    return false
                }
                webRequest = raw
                return true
            }

            let dom = try await self.readPopupDOM(popup)

            print("ORBIT-WAPP-SITE webRequest = \(webRequest)")
            print("ORBIT-WAPP-SITE url = \(url)")
            print("ORBIT-WAPP-SITE page globals = \(String(describing: globals))")
            print("ORBIT-WAPP-SITE main-world injection = \(injection)")
            print("ORBIT-WAPP-SITE badge = '\(badge)'")
            print("ORBIT-WAPP-SITE getDetections = \(detections)")
            print("ORBIT-WAPP-SITE getDetectionsForTab = \(forTab)")
            print("ORBIT-WAPP-SITE getTabResult = \(tabResult)")
            print("ORBIT-WAPP-SITE getTabRequest = \(tabRequest)")
            print("ORBIT-WAPP-SITE isTransientUrl = \(transient)")
            print("ORBIT-WAPP-SITE popup DOM = \(String(describing: dom))")

            XCTAssertTrue(
                injection.contains("\"scriptLoaded\":true"),
                "js/js.js never executed in the page's main world, so every JS-global technology is unreachable: \(injection)"
            )
            XCTAssertFalse(
                injection.contains("\"replied\":\"no-reply\""),
                "js/js.js loaded but never answered the postMessage handshake: \(injection)"
            )
            XCTAssertFalse(
                tabRequest.contains("\"value\":\"null\"") || tabRequest.contains("\"value\":null"),
                "Driver.onResponseStarted never recorded this request, so header-based technologies are unreachable: \(tabRequest)"
            )
            XCTAssertTrue(
                transient.contains("\"value\":false"),
                "a public https site must not be transient: \(transient)"
            )
            XCTAssertTrue(
                webRequest.contains("onResponseStarted"),
                "no webRequest onResponseStarted for a main-frame navigation, so Cloudflare and HTTP/3 are unreachable: \(webRequest)"
            )
            XCTAssertFalse(
                webRequest.contains("\"tabId\":-1"),
                "webRequest events carry tabId -1, which real extensions drop outright: \(webRequest)"
            )
            let rendered = dom?.technologies ?? []
            XCTAssertFalse(
                rendered.isEmpty,
                "the popup listed nothing on the user's own site; badge='\(badge)', getDetections=\(detections), forTab=\(forTab)"
            )
        }
    }

    // ORBIT-LIVE-ENGINE: MAY-SKIP testRealWappalyzerPopupReloadLinkReloadsTheActiveTab
    func testRealWappalyzerPopupReloadLinkReloadsTheActiveTab() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subject = try pinnedWappalyzer()

        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let harness = try await self.startHarness(subject)
            defer { harness.server.stop() }
            defer { harness.engine.unloadExtension(id: harness.loaded.id, session: harness.engine.defaultSession) }

            let (model, popup) = try await self.openPopup(for: harness)
            defer { model.teardown() }
            _ = try await self.assertPopupListsTechnologies(popup, "reload")

            // js/popup.js:557 binds this link to chrome.tabs.reload({bypassCache: true}).
            let kind = try await popup.evaluateJavaScript("typeof chrome.tabs.reload") as? String
            XCTAssertEqual(kind, "function", "chrome.tabs.reload is missing, so the popup's Reload link throws")

            let before = harness.server.requestLog.all.filter { $0.path == "/" }.count
            let clicked = try await popup.evaluateJavaScript(
                "var a = document.querySelector('.empty__reload'); a ? (a.click(), 'clicked') : 'missing'"
            ) as? String
            XCTAssertEqual(clicked, "clicked")

            try await Self.pollUntil("the subject page to be re-requested") {
                harness.server.requestLog.all.filter { $0.path == "/" }.count > before
            }
        }
    }
}
