//  chrome.commands end to end against a real engine: manifest parsing including
//  the suggested_key default/mac split, what getAll() actually returns, a real
//  key press reaching onCommand with a tab, and _execute_action triggering the
//  extension's action instead of firing onCommand.
//
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theManifestsCommandsAreRegisteredWithTheMacSuggestedKey
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_orbitsOwnShortcutBeatsTheExtensionsSuggestedKey
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_getAllReturnsWhatWasActuallyRegistered
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aRealKeyPressFiresOnCommandWithTheActiveTab
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_executeActionTriggersTheActionRatherThanOnCommand

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionCommandsLiveTests: LiveEnvironmentTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        env.pendingExtensionActionID = nil
        super.tearDown()
    }

    // MARK: - Fixture

    /// "mac" deliberately differs from "default": if the platform split were
    /// ignored, the registered accelerator would be ⇧⌘U and every assertion
    /// below on ⇧⌘Y would fail.
    private func writeFixture(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-Commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["tabs"],
          "host_permissions": ["<all_urls>"],
          "action": { "default_popup": "popup.html", "default_title": "\(name)" },
          "commands": {
            "toggle-feature": {
              "suggested_key": { "default": "Ctrl+Shift+U", "mac": "Command+Shift+Y" },
              "description": "Toggle the feature"
            },
            "unbound-feature": {
              "description": "Has no suggested key at all"
            },
            "steal-new-tab": {
              "suggested_key": { "default": "Ctrl+T" },
              "description": "Tries to take a key Orbit owns"
            },
            "_execute_action": {
              "suggested_key": { "default": "Ctrl+Shift+E" }
            }
          },
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var orbitCommands = [];
        chrome.commands.onCommand.addListener(function (command, tab) {
          orbitCommands.push({ command: command, tab: tab || null });
        });
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'orbit-commands-fired') {
            sendResponse(JSON.stringify(orbitCommands));
          } else if (message === 'orbit-commands-getall') {
            chrome.commands.getAll(function (commands) {
              sendResponse(JSON.stringify(commands));
            });
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let popup = "<!doctype html><html><body><div id=\"orbit-commands-popup\">popup</div></body></html>"
        try popup.write(to: directory.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Orbit Commands Probe</title></head>
        <body><div id="orbit-commands-probe">ready</div><script src="probe.js"></script></body></html>
        """
        try probeHTML.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let probeJS = """
        window.__orbitOut = null;
        window.orbitAsk = function (message) {
          window.__orbitOut = null;
          chrome.runtime.sendMessage(message, function (response) {
            window.__orbitOut = String(response);
          });
        };
        """
        try probeJS.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private struct Harness {
        var engine: ChromiumEngine
        var extensionID: String
        var probe: ChromiumWebContents
        var spaceID: SpaceID
    }

    private static func pollUntil(
        _ waitingFor: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "timed out waiting for \(waitingFor)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func ask(_ harness: Harness, _ message: String) async throws -> String {
        _ = try await harness.probe.evaluateJavaScript("window.orbitAsk('\(message)'); 'sent'")
        try await Self.pollUntil("the worker to answer \(message)") {
            try await harness.probe.evaluateJavaScript("window.__orbitOut !== null") as? Bool == true
        }
        return try await harness.probe.evaluateJavaScript("window.__orbitOut") as? String ?? ""
    }

    private func withLoadedFixture(_ body: (Harness) async throws -> Void) async throws {
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

        let directory = try writeFixture(named: "Orbit Commands")
        let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
        defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

        let probe = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { probe.close() }
        probe.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(probe)
        try await Self.pollUntil("the probe page to load") {
            try await probe.evaluateJavaScript("typeof window.orbitAsk === 'function'") as? Bool == true
        }

        try await body(Harness(engine: engine, extensionID: loaded.id, probe: probe, spaceID: spaceID))
    }

    // MARK: - Registration and getAll

    func test_theManifestsCommandsAreRegisteredWithTheMacSuggestedKey() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let registered = ExtensionCommandRegistry.shared.commands(forExtension: harness.extensionID)
            XCTAssertFalse(
                registered.isEmpty,
                "the manifest declared four commands and the embedder registered none; the commands manifest key was not parsed"
            )

            let toggle = try XCTUnwrap(
                registered.first { $0.name == "toggle-feature" },
                "the named command in the manifest was not registered at all"
            )
            XCTAssertEqual(
                toggle.accelerator, "Command+Shift+Y",
                "the \"mac\" suggested_key must win over \"default\"; ⇧⌘U here would mean the platform split was ignored"
            )
            XCTAssertTrue(toggle.isActive, "nothing in Orbit owns ⇧⌘Y, so this command must be active")

            let unbound = try XCTUnwrap(registered.first { $0.name == "unbound-feature" })
            XCTAssertEqual(unbound.accelerator, "", "a command with no suggested_key must register with no accelerator")
            XCTAssertFalse(unbound.isActive)

            let action = try XCTUnwrap(
                registered.first { $0.name == "_execute_action" },
                "_execute_action is a reserved name and must still be registered"
            )
            XCTAssertTrue(action.isAction)
            XCTAssertEqual(action.accelerator, "Command+Shift+E", "manifest Ctrl normalises to Command on macOS")
        }
    }

    func test_orbitsOwnShortcutBeatsTheExtensionsSuggestedKey() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let registered = ExtensionCommandRegistry.shared.commands(forExtension: harness.extensionID)
            let stolen = try XCTUnwrap(registered.first { $0.name == "steal-new-tab" })
            XCTAssertEqual(stolen.accelerator, "Command+T", "the manifest's own suggestion is still reported")
            XCTAssertFalse(
                stolen.isActive,
                "⌘T is Orbit's New Tab; an extension suggesting Ctrl+T must end up with no active shortcut"
            )
            XCTAssertEqual(
                stolen.shortcut, "",
                "getAll() must report a blank shortcut for a command that can never fire"
            )
        }
    }

    func test_getAllReturnsWhatWasActuallyRegistered() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let json = try await self.ask(harness, "orbit-commands-getall")
            let data = try XCTUnwrap(json.data(using: .utf8))
            let commands = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                "chrome.commands.getAll did not resolve with an array; it returned \(json)"
            )
            let byName = Dictionary(uniqueKeysWithValues: commands.compactMap { entry -> (String, [String: Any])? in
                guard let name = entry["name"] as? String else { return nil }
                return (name, entry)
            })

            XCTAssertNotNil(byName["_execute_action"], "getAll must include _execute_action")
            XCTAssertNotNil(byName["toggle-feature"])
            XCTAssertNotNil(byName["unbound-feature"])

            XCTAssertEqual(
                byName["toggle-feature"]?["description"] as? String, "Toggle the feature",
                "the manifest description must survive into getAll"
            )
            XCTAssertEqual(
                byName["toggle-feature"]?["shortcut"] as? String, "⇧⌘Y",
                "an active command must report its display shortcut"
            )
            XCTAssertEqual(
                byName["unbound-feature"]?["shortcut"] as? String, "",
                "a command with no key must report a blank shortcut, not be omitted"
            )
            XCTAssertEqual(
                byName["steal-new-tab"]?["shortcut"] as? String, "",
                "a command Orbit's own shortcut shadows must report blank, exactly as an unassigned one does"
            )
        }
    }

    // MARK: - A real key press

    func test_aRealKeyPressFiresOnCommandWithTheActiveTab() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let env = self.env
            let tabID = env.openTab(url: URL(string: "about:blank")!, in: harness.spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let event = ExtensionCommandKeyEvents.commandShiftY()
            XCTAssertNil(
                GlobalKeyEventMonitor.handle(event, in: env),
                "⇧⌘Y is the extension's own accelerator and nothing in Orbit owns it, so the monitor had to consume it"
            )
            try await Task.sleep(for: .milliseconds(800))

            let json = try await self.ask(harness, "orbit-commands-fired")
            let data = try XCTUnwrap(json.data(using: .utf8))
            let fired = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])

            XCTAssertEqual(
                fired.compactMap { $0["command"] as? String }, ["toggle-feature"],
                "a real ⇧⌘Y did not reach commands.onCommand; the listener registered and waited forever. Log was \(json)"
            )
            let tab = fired.first?["tab"] as? [String: Any]
            XCTAssertNotNil(
                tab?["id"] as? Int,
                "onCommand must carry the active tab as its second argument, as ExtensionKeybindingRegistry::CommandExecuted does"
            )
        }
    }

    func test_executeActionTriggersTheActionRatherThanOnCommand() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let env = self.env
            let tabID = env.openTab(url: URL(string: "about:blank")!, in: harness.spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            env.pendingExtensionActionID = nil

            let event = ExtensionCommandKeyEvents.keyDown(
                character: "e", keyCode: 14, modifiers: [.command, .shift])
            XCTAssertNil(
                GlobalKeyEventMonitor.handle(event, in: env),
                "⇧⌘E is the extension's _execute_action accelerator and had to be consumed"
            )
            try await Task.sleep(for: .milliseconds(800))

            XCTAssertEqual(
                env.pendingExtensionActionID, harness.extensionID,
                "_execute_action must ask Orbit to open that extension's own action popup"
            )
            XCTAssertEqual(
                env.siteControlPresentedTabID, env.activeTabID,
                "_execute_action must also open the surface the extension's icon lives on"
            )

            let json = try await self.ask(harness, "orbit-commands-fired")
            let data = try XCTUnwrap(json.data(using: .utf8))
            let fired = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            XCTAssertFalse(
                fired.contains { $0["command"] as? String == "_execute_action" },
                "_execute_action must trigger the action, never dispatch commands.onCommand. Log was \(json)"
            )
        }
    }
}
