//  chrome.scripting/tabs.sendMessage were once absent worker->page only.
//  Reflection tests assert DEFINED; effect tests read real DOM/style, so inert bindings fail.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumScriptingAndTabMessagingLiveTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Shared fixture plumbing

    private static let reportAttribute = "data-orbit-scripting-report"

    private func makeDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func writeManifest(
        in directory: URL,
        named name: String,
        permissions: [String],
        hostPermissions: [String] = ["http://127.0.0.1/*"]
    ) throws {
        let permissionsJSON = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let hostPermissionsJSON = hostPermissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": [\(permissionsJSON)],
          "host_permissions": [\(hostPermissionsJSON)],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }

    private static func pollUntil(
        timeout: Duration = .seconds(20),
        _ condition: () async throws -> Bool
    ) async throws {
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

    private func decodeReport(_ raw: Any?) -> [String: Any]? {
        guard let text = raw as? String,
              let data = text.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Layer 1: the surface is DEFINED at runtime

    /// Reflects over `chrome` itself rather than calling anything, so a
    /// namespace compiled-in but unreachable fails here rather than passing silently.
    private func writeReflectionFixture(named name: String, permissions: [String]) throws -> URL {
        let directory = try makeDirectory("ScriptingReflection")
        try writeManifest(in: directory, named: name, permissions: permissions)

        let background = """
        var orbitErrors = [];
        self.addEventListener('error', function(event) {
          orbitErrors.push('error: ' + (event.message || String(event)));
        });
        self.addEventListener('unhandledrejection', function(event) {
          var reason = event.reason;
          orbitErrors.push('unhandledrejection: ' + ((reason && reason.message) || String(reason)));
        });

        function orbitFunctionNames(namespace) {
          if (!namespace) { return null; }
          var names = [];
          for (var key in namespace) {
            if (typeof namespace[key] === 'function') { names.push(key); }
          }
          return names.sort();
        }

        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message !== 'orbit-reflect') { return false; }
          sendResponse(JSON.stringify({
            errors: orbitErrors,
            namespaces: Object.keys(chrome).sort(),
            scriptingType: typeof chrome.scripting,
            scriptingFunctions: orbitFunctionNames(chrome.scripting),
            managementType: typeof chrome.management,
            managementFunctions: orbitFunctionNames(chrome.management),
            tabsSendMessageType: typeof chrome.tabs.sendMessage,
            tabsConnectType: typeof chrome.tabs.connect,
            tabsExecuteScriptType: typeof chrome.tabs.executeScript
          }));
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        function orbitPollReflection() {
          chrome.runtime.sendMessage('orbit-reflect', function(response) {
            if (response) {
              document.documentElement.setAttribute('\(Self.reportAttribute)', response);
            }
          });
        }
        orbitPollReflection();
        setInterval(orbitPollReflection, 200);
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeReflectionServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html",
                body: "<html><body>orbit-scripting-reflection</body></html>"
            ),
        ])
    }

    private func runReflectionFixture(_ directory: URL) throws -> [String: Any]? {
        try LiveChromiumEngineHost.runLive { () -> [String: Any]? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let server = try self.makeReflectionServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let read = "document.documentElement.getAttribute('\(Self.reportAttribute)')"
            do {
                try await Self.pollUntil {
                    try await contents.evaluateJavaScript(read) as? String != nil
                }
            } catch {
                return nil
            }
            return self.decodeReport(try await contents.evaluateJavaScript(read))
        }
    }

    func testChromeScriptingNamespaceAndEveryMemberAreDefinedInARealServiceWorkerWhenTheExtensionDeclaresTheScriptingPermission() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let directory = try writeReflectionFixture(
            named: "Orbit Scripting Reflection Test",
            permissions: ["scripting", "tabs", "management"]
        )
        let report = try XCTUnwrap(
            try runReflectionFixture(directory),
            "the background service worker never answered"
        )

        XCTAssertEqual(
            report["scriptingType"] as? String, "object",
            "chrome.scripting is undefined — the \"scripting\" permission is registered only in chrome/common/extensions/permissions/chrome_api_permissions.cc, so an unregistered permission name is dropped from the manifest and permission:scripting can never resolve"
        )
        let scriptingFunctions = Set(report["scriptingFunctions"] as? [String] ?? [])
        for expected in [
            "executeScript", "insertCSS", "removeCSS",
            "registerContentScripts", "unregisterContentScripts",
            "updateContentScripts", "getRegisteredContentScripts",
        ] {
            XCTAssertTrue(
                scriptingFunctions.contains(expected),
                "chrome.scripting.\(expected) is missing; the namespace exposes \(scriptingFunctions.sorted())"
            )
        }
        XCTAssertEqual(report["errors"] as? [String] ?? [], [], "the worker recorded uncaught errors")
    }

    func testChromeManagementExposesItsPermissionGatedMembersWhenTheExtensionDeclaresTheManagementPermission() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let directory = try writeReflectionFixture(
            named: "Orbit Management Reflection Test",
            permissions: ["management"]
        )
        let report = try XCTUnwrap(
            try runReflectionFixture(directory),
            "the background service worker never answered"
        )

        let managementFunctions = Set(report["managementFunctions"] as? [String] ?? [])
        // getSelf/uninstallSelf/getPermissionWarningsByManifest declare no
        // dependency upstream, so they worked even unregistered.
        for expected in ["getAll", "get", "setEnabled", "uninstall", "getPermissionWarningsById"] {
            XCTAssertTrue(
                managementFunctions.contains(expected),
                "chrome.management.\(expected) is missing; the namespace exposes \(managementFunctions.sorted())"
            )
        }
        XCTAssertTrue(managementFunctions.contains("getSelf"), "the no-permission members must not have regressed")
    }

    func testChromeTabsSendMessageAndConnectAreDefinedAndTheMV2ExecuteScriptStaysAbsent() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let directory = try writeReflectionFixture(
            named: "Orbit Tab Messaging Reflection Test",
            permissions: ["tabs"]
        )
        let report = try XCTUnwrap(
            try runReflectionFixture(directory),
            "the background service worker never answered"
        )

        XCTAssertEqual(
            report["tabsSendMessageType"] as? String, "function",
            "chrome.tabs.sendMessage is undefined — a background worker has no way to reach a content script"
        )
        XCTAssertEqual(
            report["tabsConnectType"] as? String, "function",
            "chrome.tabs.connect is undefined"
        )
        XCTAssertEqual(
            report["tabsExecuteScriptType"] as? String, "undefined",
            "chrome.tabs.executeScript is MV2-only and must stay absent; MV3 extensions use chrome.scripting.executeScript"
        )
    }

    /// The negative control the reflection tests need to mean anything: with
    /// no permissions declared, the permission-gated surface must be gone.
    func testAnExtensionDeclaringNoPermissionsSeesNoScriptingNamespaceAndOnlyManagementsNoPermissionMembers() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let directory = try writeReflectionFixture(
            named: "Orbit Scripting Negative Control Test",
            permissions: []
        )
        let report = try XCTUnwrap(
            try runReflectionFixture(directory),
            "the background service worker never answered"
        )

        XCTAssertEqual(
            report["scriptingType"] as? String, "undefined",
            "chrome.scripting must be gated on the \"scripting\" permission"
        )
        let managementFunctions = Set(report["managementFunctions"] as? [String] ?? [])
        XCTAssertFalse(
            managementFunctions.contains("getAll"),
            "chrome.management.getAll must be gated on the \"management\" permission"
        )
        XCTAssertTrue(
            managementFunctions.contains("getSelf"),
            "chrome.management.getSelf declares no dependency upstream and must stay available"
        )
        // chrome.tabs itself needs no permission in Chrome either; only the
        // url/title fields it returns are scrubbed. So this is expected.
        XCTAssertEqual(report["tabsSendMessageType"] as? String, "function")
    }

    // MARK: - Layer 2: the calls have a real effect on a real page

    private struct EffectFixture {
        let directory: URL
        let contentScriptRan = "data-orbit-effect-content-script-ran"
        let sendMessageReceived = "data-orbit-effect-sendmessage-received"
        let connectReceived = "data-orbit-effect-connect-received"
        let connectMessage = "data-orbit-effect-connect-message"
        let scriptingExecuted = "data-orbit-effect-scripting-executed"
        let report = "data-orbit-effect-report"
    }

    private func writeEffectFixture(named name: String) throws -> EffectFixture {
        let directory = try makeDirectory("ScriptingEffect")
        let fixture = EffectFixture(directory: directory)
        try writeManifest(
            in: directory, named: name,
            permissions: ["scripting", "tabs", "management"]
        )

        let background = """
        var orbitState = {
          tabId: null,
          probesStarted: false,
          sendMessageReply: null,
          sendMessageError: null,
          portReply: null,
          portError: null,
          executeScriptReturn: null,
          executeScriptError: null,
          insertCSSDone: false,
          insertCSSError: null,
          managementNames: null,
          managementError: null,
          errors: []
        };

        self.addEventListener('error', function(event) {
          orbitState.errors.push('error: ' + (event.message || String(event)));
        });
        self.addEventListener('unhandledrejection', function(event) {
          var reason = event.reason;
          orbitState.errors.push('unhandledrejection: ' + ((reason && reason.message) || String(reason)));
        });

        function orbitRunProbes(tabId) {
          if (orbitState.probesStarted) { return; }
          orbitState.probesStarted = true;
          orbitState.tabId = tabId;

          try {
            chrome.tabs.sendMessage(tabId, 'orbit-tab-ping', function(response) {
              if (chrome.runtime.lastError) {
                orbitState.sendMessageError = chrome.runtime.lastError.message;
                return;
              }
              orbitState.sendMessageReply = response;
            });
          } catch (e) {
            orbitState.sendMessageError = 'threw: ' + ((e && e.message) || String(e));
          }

          try {
            var port = chrome.tabs.connect(tabId, { name: 'orbit-tab-port' });
            port.onMessage.addListener(function(message) {
              orbitState.portReply = message;
            });
            port.onDisconnect.addListener(function() {
              if (orbitState.portReply === null) {
                orbitState.portError = 'disconnected with no message' +
                  (chrome.runtime.lastError ? (': ' + chrome.runtime.lastError.message) : '');
              }
            });
            port.postMessage('orbit-port-ping');
          } catch (e) {
            orbitState.portError = 'threw: ' + ((e && e.message) || String(e));
          }

          try {
            chrome.scripting.executeScript({
              target: { tabId: tabId },
              func: function() {
                document.documentElement.setAttribute('\(fixture.scriptingExecuted)', 'true');
                return 'orbit-scripting-return';
              }
            }).then(function(results) {
              orbitState.executeScriptReturn = (results && results[0]) ? results[0].result : null;
            }, function(error) {
              orbitState.executeScriptError = (error && error.message) || String(error);
            });
          } catch (e) {
            orbitState.executeScriptError = 'threw: ' + ((e && e.message) || String(e));
          }

          try {
            chrome.scripting.insertCSS({
              target: { tabId: tabId },
              css: 'body { background-color: rgb(1, 2, 3) !important; }'
            }).then(function() {
              orbitState.insertCSSDone = true;
            }, function(error) {
              orbitState.insertCSSError = (error && error.message) || String(error);
            });
          } catch (e) {
            orbitState.insertCSSError = 'threw: ' + ((e && e.message) || String(e));
          }

          try {
            chrome.management.getAll().then(function(list) {
              orbitState.managementNames = list.map(function(item) { return item.name; });
            }, function(error) {
              orbitState.managementError = (error && error.message) || String(error);
            });
          } catch (e) {
            orbitState.managementError = 'threw: ' + ((e && e.message) || String(e));
          }
        }

        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message === 'orbit-register') {
            if (sender && sender.tab && typeof sender.tab.id === 'number') {
              orbitRunProbes(sender.tab.id);
            } else {
              orbitState.errors.push('register: sender.tab.id missing');
            }
            sendResponse('ok');
            return true;
          }
          if (message === 'orbit-report') {
            sendResponse(JSON.stringify(orbitState));
            return true;
          }
          return false;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        document.documentElement.setAttribute('\(fixture.contentScriptRan)', 'true');

        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message === 'orbit-tab-ping') {
            document.documentElement.setAttribute('\(fixture.sendMessageReceived)', 'true');
            sendResponse('orbit-tab-pong');
            return true;
          }
          return false;
        });

        chrome.runtime.onConnect.addListener(function(port) {
          if (port.name !== 'orbit-tab-port') { return; }
          document.documentElement.setAttribute('\(fixture.connectReceived)', 'true');
          port.onMessage.addListener(function(message) {
            document.documentElement.setAttribute('\(fixture.connectMessage)', String(message));
            port.postMessage('orbit-port-pong');
          });
        });

        function orbitPollEffectReport() {
          chrome.runtime.sendMessage('orbit-report', function(response) {
            if (response) {
              document.documentElement.setAttribute('\(fixture.report)', response);
            }
          });
        }
        chrome.runtime.sendMessage('orbit-register', function() { orbitPollEffectReport(); });
        setInterval(orbitPollEffectReport, 200);
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return fixture
    }

    private struct EffectOutcome {
        let report: [String: Any]
        let sendMessageReceived: Bool
        let connectReceived: Bool
        let connectMessage: String?
        let scriptingExecuted: Bool
        let bodyBackgroundColor: String?
        let extensionName: String
    }

    /// Runs against a real Orbit tab (`env.openTab`), not a bare WebContents:
    /// sendMessage/connect and scripting's target both key on an OrbitTabRegistry tab id.
    private func runEffectFixture() throws -> EffectOutcome {
        try LiveChromiumEngineHost.runLive { () -> EffectOutcome in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let extensionName = "Orbit Scripting Effect Test"
            let fixture = try self.writeEffectFixture(named: extensionName)
            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let server = try LiveHTTPTestServer(routes: [
                "/subject": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body>orbit-scripting-effect-subject</body></html>"
                ),
            ])
            defer { server.stop() }

            let tabID = env.openTab(url: server.baseURL.appendingPathComponent("subject"), in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            // openTab defers navigation until content blocking compiles, so
            // there's no main frame to evaluate script in until this settles.
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let readReport = "document.documentElement.getAttribute('\(fixture.report)')"
            // Waits for every probe to have settled (landed or failed), not
            // succeeded, so a failure is asserted with its own message, not a bare timeout.
            try await Self.pollUntil(timeout: .seconds(30)) {
                guard let parsed = self.decodeReport(try await contents.evaluateJavaScript(readReport)) else {
                    return false
                }
                func settled(_ value: String, _ error: String) -> Bool {
                    let landed = parsed[value] != nil && !(parsed[value] is NSNull)
                    return landed || (parsed[error] is String)
                }
                return settled("sendMessageReply", "sendMessageError")
                    && settled("portReply", "portError")
                    && settled("executeScriptReturn", "executeScriptError")
                    && (parsed["insertCSSDone"] as? Bool == true || parsed["insertCSSError"] is String)
                    && settled("managementNames", "managementError")
            }

            let rawReport = try await contents.evaluateJavaScript(readReport)
            let report = try XCTUnwrap(
                self.decodeReport(rawReport),
                "the worker never produced a report"
            )

            func attribute(_ name: String) async throws -> String? {
                try await contents.evaluateJavaScript(
                    "document.documentElement.getAttribute('\(name)')"
                ) as? String
            }

            let background = try await contents.evaluateJavaScript(
                "getComputedStyle(document.body).backgroundColor"
            ) as? String

            return EffectOutcome(
                report: report,
                sendMessageReceived: try await attribute(fixture.sendMessageReceived) == "true",
                connectReceived: try await attribute(fixture.connectReceived) == "true",
                connectMessage: try await attribute(fixture.connectMessage),
                scriptingExecuted: try await attribute(fixture.scriptingExecuted) == "true",
                bodyBackgroundColor: background,
                extensionName: extensionName
            )
        }
    }

    func testWorkerToContentScriptMessagingAndScriptInjectionAllTakeRealEffectOnARealPage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let outcome = try runEffectFixture()
        let report = outcome.report

        XCTAssertEqual(report["errors"] as? [String] ?? [], [], "the worker recorded uncaught errors")

        // chrome.tabs.sendMessage: the content script really received it, and
        // its reply really reached the worker. Either half alone is too weak.
        XCTAssertNil(report["sendMessageError"] as? String, "chrome.tabs.sendMessage failed")
        XCTAssertTrue(
            outcome.sendMessageReceived,
            "the content script's chrome.runtime.onMessage never fired for chrome.tabs.sendMessage — the worker cannot reach a content script"
        )
        XCTAssertEqual(
            report["sendMessageReply"] as? String, "orbit-tab-pong",
            "the content script's reply never reached the worker"
        )

        // chrome.tabs.connect: a real long-lived port, both directions.
        XCTAssertNil(report["portError"] as? String, "chrome.tabs.connect failed")
        XCTAssertTrue(outcome.connectReceived, "the content script's chrome.runtime.onConnect never fired")
        XCTAssertEqual(outcome.connectMessage, "orbit-port-ping", "the worker's port message never arrived in the page")
        XCTAssertEqual(report["portReply"] as? String, "orbit-port-pong", "the page's port reply never reached the worker")

        // chrome.scripting.executeScript: read through the page's own DOM,
        // not through the extension, so an inert binding cannot fake it.
        XCTAssertNil(report["executeScriptError"] as? String, "chrome.scripting.executeScript failed")
        XCTAssertTrue(
            outcome.scriptingExecuted,
            "chrome.scripting.executeScript never mutated the real page served by LiveHTTPTestServer"
        )
        XCTAssertEqual(
            report["executeScriptReturn"] as? String, "orbit-scripting-return",
            "the injected function's return value never came back through InjectionResult"
        )

        // chrome.scripting.insertCSS: the computed style of a real page.
        XCTAssertNil(report["insertCSSError"] as? String, "chrome.scripting.insertCSS failed")
        XCTAssertEqual(
            outcome.bodyBackgroundColor, "rgb(1, 2, 3)",
            "chrome.scripting.insertCSS did not change the real page's computed background colour"
        )

        // chrome.management's permission-gated half, which the same
        // permission registration unblocked.
        XCTAssertNil(report["managementError"] as? String, "chrome.management.getAll failed")
        let names = try XCTUnwrap(
            report["managementNames"] as? [String],
            "chrome.management.getAll never resolved — its members are gated on the \"management\" permission"
        )
        XCTAssertTrue(
            names.contains(outcome.extensionName),
            "chrome.management.getAll did not list the extension making the call; it reported \(names)"
        )
    }
}
