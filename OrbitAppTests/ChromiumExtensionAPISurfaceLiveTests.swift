//  Regression: iCloud Passwords/PayPal Honey threw on missing
//  chrome.webNavigation.onTabReplaced/chrome.tabs.onReplaced; pins the surface those extensions actually touch.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionAPISurfaceLiveTests: XCTestCase {

    private static let reportAttribute = "data-orbit-api-surface-report"
    private static let pollMessage = "orbit-api-surface-report"

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    /// `probeBody` runs at the top level of the worker, unguarded, where the
    /// real extensions' own init runs. Error collectors install first, so a throw is recorded, not just timed out.
    private func writeFixture(
        named name: String,
        permissions: [String],
        hostPermissions: [String] = ["http://127.0.0.1/*"],
        probeBody: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-APISurface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let permissionsJSON = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let hostPermissionsJSON = hostPermissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": [\(permissionsJSON)],
          "host_permissions": [\(hostPermissionsJSON)],
          "action": { "default_title": "\(name)" },
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var orbitErrors = [];
        var orbitReport = null;
        var orbitReportReady = null;
        self.addEventListener('error', function(event) {
          orbitErrors.push('error: ' + (event.message || String(event)));
        });
        self.addEventListener('unhandledrejection', function(event) {
          var reason = event.reason;
          orbitErrors.push('unhandledrejection: ' + ((reason && reason.message) || String(reason)));
        });
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message !== '\(Self.pollMessage)') { return false; }
          Promise.resolve(orbitReportReady).then(function() {
            sendResponse(JSON.stringify({ errors: orbitErrors, report: orbitReport }));
          }, function(error) {
            orbitErrors.push('report: ' + ((error && error.message) || String(error)));
            sendResponse(JSON.stringify({ errors: orbitErrors, report: orbitReport }));
          });
          return true;
        });

        \(probeBody)
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        function orbitPollAPISurface() {
          chrome.runtime.sendMessage('\(Self.pollMessage)', function(response) {
            if (response) {
              document.documentElement.setAttribute('\(Self.reportAttribute)', response);
            }
          });
        }
        orbitPollAPISurface();
        setInterval(orbitPollAPISurface, 200);
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html",
                body: "<html><body>orbit-api-surface-test</body></html>"
            ),
        ])
    }

    private static func pollUntil(timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "pollUntil timed out after \(timeout)"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private struct WorkerReport {
        let errors: [String]
        let report: [String: Any]
    }

    /// A nil return means the worker never answered at all, which is itself
    /// the failure mode this file exists for.
    private func runFixture(_ directory: URL, timeout: Duration = .seconds(20)) throws -> WorkerReport? {
        try LiveChromiumEngineHost.runLive { () -> WorkerReport? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let read = "document.documentElement.getAttribute('\(Self.reportAttribute)')"
            do {
                try await Self.pollUntil(timeout: timeout) {
                    try await contents.evaluateJavaScript(read) as? String != nil
                }
            } catch {
                return nil
            }
            guard let raw = try await contents.evaluateJavaScript(read) as? String,
                  let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            return WorkerReport(
                errors: parsed["errors"] as? [String] ?? [],
                report: parsed["report"] as? [String: Any] ?? [:]
            )
        }
    }

    // MARK: - The events the two real extensions crashed on

    func testTabsOnReplacedAndWebNavigationOnTabReplacedExistInAServiceWorkerAndAcceptListeners() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        // Mirrors the real call shapes: iCloud Passwords calls
        // webNavigation.onTabReplaced.addListener at top level, Honey calls tabs.onReplaced.addListener.
        let directory = try writeFixture(
            named: "Orbit API Surface Replaced Events",
            permissions: ["webNavigation"],
            probeBody: """
            var orbitTabsListener = function() {};
            var orbitWebNavListener = function() {};
            chrome.tabs.onReplaced.addListener(orbitTabsListener);
            chrome.webNavigation.onTabReplaced.addListener(orbitWebNavListener);
            orbitReport = {
              tabsOnReplacedType: typeof chrome.tabs.onReplaced,
              tabsAddListenerType: typeof chrome.tabs.onReplaced.addListener,
              tabsHasListener: chrome.tabs.onReplaced.hasListener(orbitTabsListener),
              webNavigationOnTabReplacedType: typeof chrome.webNavigation.onTabReplaced,
              webNavigationAddListenerType: typeof chrome.webNavigation.onTabReplaced.addListener,
              webNavigationHasListener: chrome.webNavigation.onTabReplaced.hasListener(orbitWebNavListener)
            };
            """
        )

        let result = try XCTUnwrap(
            try runFixture(directory),
            "the background service worker never answered: chrome.tabs.onReplaced / "
            + "chrome.webNavigation.onTabReplaced threw during initial script evaluation, which is "
            + "exactly the reported defect (service worker registration status 15, "
            + "kErrorScriptEvaluateFailed)"
        )

        XCTAssertEqual(result.errors, [], "the worker recorded uncaught errors while registering the replaced-tab events")
        XCTAssertEqual(result.report["tabsOnReplacedType"] as? String, "object", "chrome.tabs.onReplaced is not an event object")
        XCTAssertEqual(result.report["tabsAddListenerType"] as? String, "function")
        XCTAssertEqual(result.report["tabsHasListener"] as? Bool, true, "chrome.tabs.onReplaced.addListener did not actually register the listener")
        XCTAssertEqual(result.report["webNavigationOnTabReplacedType"] as? String, "object", "chrome.webNavigation.onTabReplaced is not an event object")
        XCTAssertEqual(result.report["webNavigationAddListenerType"] as? String, "function")
        XCTAssertEqual(result.report["webNavigationHasListener"] as? Bool, true, "chrome.webNavigation.onTabReplaced.addListener did not actually register the listener")
    }

    // MARK: - Regression guard: real-world-shaped initialisation, zero errors

    func testRealWorldShapedBackgroundWorkerInitialisationRaisesNoUncaughtErrors() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        // Every top-level chrome.* touch the two real extensions make, in
        // one worker, unguarded. Any one being undefined throws here exactly as for them.
        let directory = try writeFixture(
            named: "Orbit API Surface Real World Shape",
            permissions: ["webNavigation", "storage", "scripting", "alarms"],
            probeBody: """
            chrome.webNavigation.onBeforeNavigate.addListener(function() {});
            chrome.webNavigation.onCommitted.addListener(function() {});
            chrome.webNavigation.onDOMContentLoaded.addListener(function() {});
            chrome.webNavigation.onCompleted.addListener(function() {});
            chrome.webNavigation.onErrorOccurred.addListener(function() {});
            chrome.webNavigation.onReferenceFragmentUpdated.addListener(function() {});
            chrome.webNavigation.onHistoryStateUpdated.addListener(function() {});
            chrome.webNavigation.onTabReplaced.addListener(function() {});
            chrome.tabs.onCreated.addListener(function() {});
            chrome.tabs.onUpdated.addListener(function() {});
            chrome.tabs.onMoved.addListener(function() {});
            chrome.tabs.onActivated.addListener(function() {});
            chrome.tabs.onRemoved.addListener(function() {});
            chrome.tabs.onReplaced.addListener(function() {});
            chrome.windows.onCreated.addListener(function() {});
            chrome.windows.onRemoved.addListener(function() {});
            chrome.windows.onFocusChanged.addListener(function() {});
            chrome.action.onClicked.addListener(function() {});
            chrome.runtime.onInstalled.addListener(function() {});
            chrome.runtime.onSuspend.addListener(function() {});
            chrome.runtime.onSuspendCanceled.addListener(function() {});
            chrome.runtime.onUpdateAvailable.addListener(function() {});
            chrome.runtime.onConnect.addListener(function() {});
            chrome.alarms.onAlarm.addListener(function() {});
            orbitReportReady = (async function() {
              await chrome.action.setBadgeText({ text: '' });
              var tabs = await chrome.tabs.query({});
              var windows = await chrome.windows.getAll({});
              orbitReport = { initialised: true, tabCount: tabs.length, windowCount: windows.length };
            })();
            """
        )

        let result = try XCTUnwrap(
            try runFixture(directory),
            "the background service worker never answered: its top-level initialisation threw, which "
            + "is the reported defect (uncaught TypeError plus service worker registration status 15)"
        )

        XCTAssertEqual(
            result.errors, [],
            "a real-world-shaped MV3 background worker raised uncaught errors during initialisation"
        )
        XCTAssertEqual(result.report["initialised"] as? Bool, true)
    }

    // MARK: - chrome.privacy

    func testPrivacyServicesExposesSearchSuggestEnabledAndNothingOrbitDoesNotHonour() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        // The absences matter as much as the presence: a ChromeSetting for a
        // feature Orbit does not have would accept a value and change nothing.
        let directory = try writeFixture(
            named: "Orbit API Surface Privacy Shape",
            permissions: ["privacy"],
            probeBody: """
            orbitReportReady = (async function() {
              var got = await chrome.privacy.services.searchSuggestEnabled.get({});
              orbitReport = {
                servicesType: typeof chrome.privacy.services,
                settingType: typeof chrome.privacy.services.searchSuggestEnabled,
                onChangeAddListenerType:
                  typeof chrome.privacy.services.searchSuggestEnabled.onChange.addListener,
                value: got.value,
                levelOfControl: got.levelOfControl,
                passwordSavingEnabled: typeof chrome.privacy.services.passwordSavingEnabled,
                autofillAddressEnabled: typeof chrome.privacy.services.autofillAddressEnabled,
                autofillCreditCardEnabled: typeof chrome.privacy.services.autofillCreditCardEnabled,
                network: typeof chrome.privacy.network,
                websites: typeof chrome.privacy.websites
              };
            })();
            """
        )

        let result = try XCTUnwrap(try runFixture(directory), "the background service worker never answered")

        XCTAssertEqual(result.errors, [], "chrome.privacy raised uncaught errors")
        XCTAssertEqual(result.report["servicesType"] as? String, "object")
        XCTAssertEqual(result.report["settingType"] as? String, "object")
        XCTAssertEqual(result.report["onChangeAddListenerType"] as? String, "function")
        XCTAssertEqual(result.report["value"] as? Bool, true, "search suggestions default to on")
        XCTAssertEqual(
            result.report["levelOfControl"] as? String, "controllable_by_this_extension",
            "an extension holding the privacy permission and controlling nothing yet must be told it can"
        )
        for absent in ["passwordSavingEnabled", "autofillAddressEnabled", "autofillCreditCardEnabled", "network", "websites"] {
            XCTAssertEqual(
                result.report[absent] as? String, "undefined",
                "\(absent) names a feature Orbit does not have; exposing it would accept a value and change nothing"
            )
        }
    }

    func testPrivacySearchSuggestEnabledSetIsReadBackAndFiresOnChange() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        // The listener must fire for a real state change, not merely
        // register: the pref really moves through ExtensionPrefStore.
        let directory = try writeFixture(
            named: "Orbit API Surface Privacy Round Trip",
            permissions: ["privacy"],
            probeBody: """
            var orbitPrefChanges = [];
            chrome.privacy.services.searchSuggestEnabled.onChange.addListener(function(details) {
              orbitPrefChanges.push({ value: details.value, levelOfControl: details.levelOfControl });
            });
            orbitReportReady = (async function() {
              var before = await chrome.privacy.services.searchSuggestEnabled.get({});
              await chrome.privacy.services.searchSuggestEnabled.set({ value: false });
              for (var i = 0; i < 100 && orbitPrefChanges.length === 0; i++) {
                await new Promise(function(resolve) { setTimeout(resolve, 50); });
              }
              var afterSet = await chrome.privacy.services.searchSuggestEnabled.get({});
              await chrome.privacy.services.searchSuggestEnabled.clear({});
              for (var j = 0; j < 100 && orbitPrefChanges.length < 2; j++) {
                await new Promise(function(resolve) { setTimeout(resolve, 50); });
              }
              var afterClear = await chrome.privacy.services.searchSuggestEnabled.get({});
              orbitReport = {
                before: before.value,
                afterSet: afterSet.value,
                afterSetLevel: afterSet.levelOfControl,
                afterClear: afterClear.value,
                changes: orbitPrefChanges
              };
            })();
            """
        )

        let result = try XCTUnwrap(try runFixture(directory, timeout: .seconds(30)), "the background service worker never answered")

        XCTAssertEqual(result.errors, [], "chrome.privacy round trip raised uncaught errors")
        XCTAssertEqual(result.report["before"] as? Bool, true)
        XCTAssertEqual(result.report["afterSet"] as? Bool, false, "types.ChromeSetting.set did not change the effective value")
        XCTAssertEqual(
            result.report["afterSetLevel"] as? String, "controlled_by_this_extension",
            "an extension that has set the pref must be told it controls it"
        )
        XCTAssertEqual(result.report["afterClear"] as? Bool, true, "types.ChromeSetting.clear did not release the override")

        let changes = result.report["changes"] as? [[String: Any]] ?? []
        XCTAssertFalse(
            changes.isEmpty,
            "onChange never fired for a pref this very worker had just set — the event is registered but not wired to a real source"
        )
        XCTAssertEqual(changes.first?["value"] as? Bool, false)
        XCTAssertEqual(changes.first?["levelOfControl"] as? String, "controlled_by_this_extension")
    }

    func testICloudPasswordsShapedPrivacyProbeDoesNotThrow() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        // The shape iCloud Passwords' ExtensionSettings constructor runs at
        // top level; its guards only work if absent settings read as undefined rather than throwing.
        let directory = try writeFixture(
            named: "Orbit API Surface iCloud Shape",
            permissions: ["privacy", "storage"],
            probeBody: """
            chrome.privacy.services.passwordSavingEnabled &&
              chrome.privacy.services.passwordSavingEnabled.onChange.addListener(function() {});
            chrome.privacy.services.autofillCreditCardEnabled &&
              chrome.privacy.services.autofillCreditCardEnabled.onChange.addListener(function() {});
            chrome.privacy.services.autofillAddressEnabled &&
              chrome.privacy.services.autofillAddressEnabled.onChange.addListener(function() {});
            orbitReportReady = (async function() {
              async function control(setting, wanted) {
                var current;
                try { current = await setting.get({}); } catch (error) { return 'threw-on-get'; }
                if (!current) { return 'no-value'; }
                if (current.value === wanted) { return 'already'; }
                await setting.set({ value: wanted });
                return 'set';
              }
              var outcomes = await Promise.allSettled([
                control(chrome.privacy.services.passwordSavingEnabled, false),
                control(chrome.privacy.services.autofillCreditCardEnabled, false),
                control(chrome.privacy.services.autofillAddressEnabled, false)
              ]);
              orbitReport = { settled: outcomes.length, reachedEnd: true };
            })();
            """
        )

        let result = try XCTUnwrap(
            try runFixture(directory),
            "the background service worker never answered — this is the reported iCloud Passwords defect: "
            + "a top-level throw during initial script evaluation, reported as service worker registration status 15"
        )

        XCTAssertEqual(
            result.errors, [],
            "the iCloud-Passwords-shaped privacy probe raised uncaught errors"
        )
        XCTAssertEqual(result.report["reachedEnd"] as? Bool, true)
        XCTAssertEqual(result.report["settled"] as? Int, 3)
    }

    // MARK: - chrome.cookies

    func testCookiesAPIRoundTripsARealCookieThroughTheNetworkStack() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let directory = try writeFixture(
            named: "Orbit API Surface Cookies",
            permissions: ["cookies"],
            probeBody: """
            orbitReportReady = (async function() {
              var url = 'http://127.0.0.1/';
              var stores = await chrome.cookies.getAllCookieStores();
              var set = await chrome.cookies.set({ url: url, name: 'orbit_live_test', value: 'v1' });
              var got = await chrome.cookies.get({ url: url, name: 'orbit_live_test' });
              var all = await chrome.cookies.getAll({ url: url });
              var removed = await chrome.cookies.remove({ url: url, name: 'orbit_live_test' });
              var after = await chrome.cookies.get({ url: url, name: 'orbit_live_test' });
              orbitReport = {
                storeCount: stores.length,
                setValue: set ? set.value : null,
                getValue: got ? got.value : null,
                getAllContainsIt: all.some(function(c) { return c.name === 'orbit_live_test'; }),
                removedName: removed ? removed.name : null,
                afterRemoval: after
              };
            })();
            """
        )

        let result = try XCTUnwrap(try runFixture(directory), "the background service worker never answered — chrome.cookies threw")

        XCTAssertEqual(result.errors, [], "chrome.cookies raised uncaught errors")
        XCTAssertEqual(result.report["setValue"] as? String, "v1", "chrome.cookies.set did not report the cookie it stored")
        XCTAssertEqual(result.report["getValue"] as? String, "v1", "chrome.cookies.get did not read back the cookie chrome.cookies.set wrote")
        XCTAssertEqual(result.report["getAllContainsIt"] as? Bool, true)
        XCTAssertEqual(result.report["removedName"] as? String, "orbit_live_test")
        XCTAssertTrue(result.report["afterRemoval"] is NSNull, "the cookie survived chrome.cookies.remove")
        XCTAssertGreaterThanOrEqual(result.report["storeCount"] as? Int ?? 0, 1, "chrome.cookies.getAllCookieStores reported no store")
    }

    func testCookiesOnChangedFiresForARealCookieChange() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        // Not that addListener returns without throwing, but that it is
        // genuinely wired to the network stack's cookie change notifications.
        let directory = try writeFixture(
            named: "Orbit API Surface Cookies OnChanged",
            permissions: ["cookies"],
            probeBody: """
            var orbitCookieChanges = [];
            chrome.cookies.onChanged.addListener(function(changeInfo) {
              if (changeInfo && changeInfo.cookie && changeInfo.cookie.name === 'orbit_live_test_change') {
                orbitCookieChanges.push({ removed: changeInfo.removed, cause: changeInfo.cause, value: changeInfo.cookie.value });
              }
            });
            orbitReportReady = (async function() {
              var url = 'http://127.0.0.1/';
              await chrome.cookies.set({ url: url, name: 'orbit_live_test_change', value: 'fired' });
              for (var i = 0; i < 100 && orbitCookieChanges.length === 0; i++) {
                await new Promise(function(resolve) { setTimeout(resolve, 50); });
              }
              await chrome.cookies.remove({ url: url, name: 'orbit_live_test_change' });
              orbitReport = { changes: orbitCookieChanges };
            })();
            """
        )

        let result = try XCTUnwrap(try runFixture(directory, timeout: .seconds(30)), "the background service worker never answered")

        XCTAssertEqual(result.errors, [], "chrome.cookies.onChanged raised uncaught errors")
        let changes = result.report["changes"] as? [[String: Any]] ?? []
        XCTAssertFalse(
            changes.isEmpty,
            "chrome.cookies.onChanged never fired for a cookie this very worker had just written — "
            + "the event is registered but not wired to a real source"
        )
        XCTAssertEqual(changes.first?["value"] as? String, "fired")
        XCTAssertEqual(changes.first?["removed"] as? Bool, false)
    }
}
