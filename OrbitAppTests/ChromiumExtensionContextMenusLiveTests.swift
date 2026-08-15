//  chrome.contextMenus end to end: a real MV3 worker creates items, a real
//  right-click on a real page matches them, Orbit's own menu renders them, and
//  selecting one fires onClicked with the payload Chrome would send. Registering
//  an item that is never rendered and never dispatched is the failure this
//  exists to catch.
//
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realRightClick_surfacesOnlyTheItemsWhoseContextsAndPatternsMatch
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_selectingAnItem_firesOnClickedWithTheRealInfoAndTabPayload
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_checkboxAndRadioStateIsOwnedByTheEngine
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_updateRemoveAndRemoveAllReachTheRenderedMenu
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_oneExtensionCannotRemoveAnothersItem

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionContextMenusLiveTests: LiveEnvironmentTestCase {

    private var temporaryDirectories: [URL] = []
    private var hostedWindow: NSWindow?

    override func tearDown() {
        hostedWindow?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        hostedWindow?.orderOut(nil)
        hostedWindow = nil
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    /// `removeAll` first because items created by a lazy context are persisted
    /// and restored on the next load, exactly as Chrome does it -- a bare
    /// create() would fail with a duplicate id on the second run.
    private static let defaultCreationScript = """
    chrome.contextMenus.removeAll(function () {
      chrome.contextMenus.create({ id: 'orbit-plain', title: 'Orbit Plain', contexts: ['all'] });
      chrome.contextMenus.create({ id: 'orbit-parent', title: 'Orbit Parent', contexts: ['all'] });
      chrome.contextMenus.create({ id: 'orbit-child', parentId: 'orbit-parent', title: 'Orbit Child', contexts: ['all'] });
      chrome.contextMenus.create({ id: 'orbit-check', type: 'checkbox', checked: false, title: 'Orbit Check', contexts: ['all'] });
      chrome.contextMenus.create({ id: 'orbit-radio-a', type: 'radio', checked: true, title: 'Orbit Radio A', contexts: ['all'] });
      chrome.contextMenus.create({ id: 'orbit-radio-b', type: 'radio', checked: false, title: 'Orbit Radio B', contexts: ['all'] });
      chrome.contextMenus.create({ id: 'orbit-link-only', title: 'Orbit Link Only', contexts: ['link'] });
      chrome.contextMenus.create({ id: 'orbit-selection-only', title: 'Orbit Says %s', contexts: ['selection'] });
      chrome.contextMenus.create({
        id: 'orbit-elsewhere', title: 'Orbit Elsewhere', contexts: ['all'],
        documentUrlPatterns: ['https://orbit-contextmenus-never.example/*']
      });
      chrome.contextMenus.create({ id: 'orbit-hidden', title: 'Orbit Hidden', contexts: ['all'], visible: false });
      chrome.contextMenus.create({ id: 'orbit-disabled', title: 'Orbit Disabled', contexts: ['all'], enabled: false });
    });
    """

    private func writeFixture(named name: String, creationScript: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-ContextMenus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["contextMenus", "tabs"],
          "host_permissions": ["<all_urls>"],
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var orbitClicks = [];
        var orbitLastError = null;
        chrome.contextMenus.onClicked.addListener(function (info, tab) {
          try {
            orbitClicks.push(JSON.parse(JSON.stringify([info, tab === undefined ? null : tab])));
          } catch (e) {
            orbitClicks.push(['__unserialisable__: ' + String(e)]);
          }
        });
        \(creationScript)
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'orbit-context-menu-report') {
            sendResponse(JSON.stringify({ clicks: orbitClicks, lastError: orbitLastError }));
            return true;
          }
          if (message && message.command === 'removeAll') {
            chrome.contextMenus.removeAll(function () {
              orbitLastError = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
              sendResponse('done');
            });
            return true;
          }
          if (message && message.command === 'remove') {
            chrome.contextMenus.remove(message.id, function () {
              orbitLastError = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
              sendResponse('done');
            });
            return true;
          }
          if (message && message.command === 'update') {
            chrome.contextMenus.update(message.id, message.properties, function () {
              orbitLastError = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
              sendResponse('done');
            });
            return true;
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>Orbit contextMenus probe</title></head>
        <body><div id="ready">ready</div><script src="probe.js"></script></body></html>
        """
        try probeHTML.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let probeJS = """
        window.__orbitReply = null;
        window.orbitSend = function (message) {
          window.__orbitReply = null;
          chrome.runtime.sendMessage(message, function (response) {
            window.__orbitReply = String(response);
          });
        };
        """
        try probeJS.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
    }

    // MARK: - Harness

    private struct Harness {
        var engine: ChromiumEngine
        var server: LiveHTTPTestServer
        var extensionID: String
        var probe: ChromiumWebContents
        var page: ChromiumWebContents
        var window: NSWindow
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html; charset=utf-8",
                body: """
                <!doctype html><html><head><meta charset="utf-8"><title>orbit context menus</title>
                <style>html,body{margin:0;padding:0;height:100%;background:#eeeeee}</style></head>
                <body><div style="height:100%">orbit-context-menus</div></body></html>
                """
            ),
        ])
    }

    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(20),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out waiting for \(waitingFor)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func loadProbe(extensionID: String, engine: ChromiumEngine) async throws -> ChromiumWebContents {
        let probe = try await LiveChromiumEngineHost.makeContents(engine: engine)
        probe.load(URL(string: "chrome-extension://\(extensionID)/probe.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(probe)
        try await Self.pollUntil("the probe page for \(extensionID)") {
            try await probe.evaluateJavaScript("typeof window.orbitSend === 'function'") as? Bool == true
        }
        return probe
    }

    @discardableResult
    private func send(_ probe: ChromiumWebContents, _ messageJS: String) async throws -> String {
        _ = try await probe.evaluateJavaScript("window.orbitSend(\(messageJS)); 'sent'")
        try await Self.pollUntil("the worker's reply to \(messageJS)") {
            try await probe.evaluateJavaScript("window.__orbitReply !== null") as? Bool == true
        }
        return try await probe.evaluateJavaScript("window.__orbitReply") as? String ?? ""
    }

    /// Each element is `[info, tab]`, exactly as onClicked was called.
    private func recordedClicks(_ probe: ChromiumWebContents) async throws -> [[Any]] {
        let raw = try await send(probe, "'orbit-context-menu-report'")
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clicks = parsed["clicks"] as? [[Any]]
        else { return [] }
        return clicks
    }

    private func makeHarness(creationScript: String) async throws -> Harness {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        env._test_engineOverride = engine
        let bridge = OrbitChromiumTabsBridge.shared
        if !bridge.isWindowRegistered(env) {
            bridge.windowCreated(owner: env, focused: false)
        }
        bridge.windowFocusChanged(owner: env)

        let server = try makeServer()
        let directory = try writeFixture(named: "Orbit Context Menus", creationScript: creationScript)
        let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
        let probe = try await loadProbe(extensionID: loaded.id, engine: engine)

        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let tabID = env.openTab(url: server.baseURL, in: spaceID)
        let page = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(page)

        let window = LiveContextMenuGesture.host(page)
        hostedWindow = window

        return Harness(
            engine: engine, server: server, extensionID: loaded.id,
            probe: probe, page: page, window: window
        )
    }

    private func teardown(_ harness: Harness) {
        harness.probe.close()
        harness.engine.unloadExtension(id: harness.extensionID, session: harness.engine.defaultSession)
        harness.server.stop()
    }

    private func titles(_ groups: [ExtensionContextMenuGroup]) -> [String] {
        func flatten(_ items: [ExtensionContextMenuItem]) -> [String] {
            items.flatMap { [$0.title] + flatten($0.children) }
        }
        return groups.flatMap { flatten($0.items) }
    }

    private func renderedEntries(_ harness: Harness) -> [OrbitContextMenuEntry] {
        env.buildContextMenuEntries(
            for: harness.page,
            context: ContextMenuContext(pageURL: harness.server.baseURL)
        )
    }

    // MARK: - Matching

    func test_realRightClick_surfacesOnlyTheItemsWhoseContextsAndPatternsMatch() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runMatchingChecks() }
    }

    private func runMatchingChecks() async throws {
        let harness = try await makeHarness(creationScript: Self.defaultCreationScript)
        defer { teardown(harness) }

        let groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        let names = titles(groups)

        XCTAssertEqual(
            groups.first?.extensionName, "Orbit Context Menus",
            "The group has to carry the extension's own name; it is what titles the submenu."
        )
        for expected in ["Orbit Plain", "Orbit Parent", "Orbit Child", "Orbit Check",
                         "Orbit Radio A", "Orbit Radio B", "Orbit Disabled"] {
            XCTAssertTrue(
                names.contains(expected),
                "\(expected) should match an \"all\" right-click on a plain page. Present: \(names)"
            )
        }
        XCTAssertFalse(
            names.contains("Orbit Link Only"),
            "A contexts:['link'] item must not appear on a right-click that was not on a link. Contexts filtering that never filters is not filtering."
        )
        XCTAssertNil(
            names.first { $0.hasPrefix("Orbit Says") },
            "A contexts:['selection'] item must not appear with nothing selected."
        )
        XCTAssertFalse(
            names.contains("Orbit Elsewhere"),
            "documentUrlPatterns pointing at another origin must exclude the item on this page."
        )
        XCTAssertFalse(
            names.contains("Orbit Hidden"),
            "visible:false must keep an item out of the menu entirely."
        )

        let parent = groups.first?.items.first { $0.title == "Orbit Parent" }
        XCTAssertEqual(
            parent?.children.map(\.title), ["Orbit Child"],
            "A parentId item must arrive nested under its parent, not flattened alongside it."
        )
        XCTAssertEqual(
            groups.first?.items.first { $0.title == "Orbit Disabled" }?.isEnabled, false,
            "enabled:false must travel with the item, so the row is drawn unusable rather than silently dead."
        )
        XCTAssertEqual(groups.first?.items.first { $0.title == "Orbit Radio A" }?.isChecked, true)
        XCTAssertEqual(
            groups.first?.items.first { $0.title == "Orbit Radio B" }?.isChecked, false,
            "Only one radio in a run may be checked; the engine owns that invariant."
        )

        // The API is worthless if the items never reach the menu the user sees.
        let entries = renderedEntries(harness)
        XCTAssertNotNil(
            entries.first(titled: "Orbit Context Menus"),
            "Orbit's own rendered context menu must contain the extension's submenu. Present: \(entries.flattenedItems.map(\.title))"
        )
        XCTAssertNotNil(entries.first(titled: "Orbit Plain"))
        XCTAssertNotNil(entries.first(titled: "Orbit Child"))
    }

    // MARK: - onClicked

    func test_selectingAnItem_firesOnClickedWithTheRealInfoAndTabPayload() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runOnClickedChecks() }
    }

    private func runOnClickedChecks() async throws {
        let harness = try await makeHarness(creationScript: Self.defaultCreationScript)
        defer { teardown(harness) }

        _ = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        let entries = renderedEntries(harness)
        let item = try XCTUnwrap(
            entries.first(titled: "Orbit Plain"),
            "no rendered row to select. Present: \(entries.flattenedItems.map(\.title))"
        )
        item.action?()
        try await Task.sleep(for: .seconds(2))

        let clicks = try await recordedClicks(harness.probe)
        XCTAssertEqual(
            clicks.count, 1,
            "Selecting the row must dispatch contextMenus.onClicked exactly once. A registered item that never fires is the whole failure mode this API has."
        )
        // baseURL is built with no path; Chromium canonicalises a bare origin to include the root.
        let committedPageURL = harness.server.baseURL.absoluteString + "/"
        let info = clicks.first?.first as? [String: Any]
        XCTAssertEqual(info?["menuItemId"] as? String, "orbit-plain")
        XCTAssertEqual(
            info?["pageUrl"] as? String, committedPageURL,
            "info.pageUrl must be the page the gesture happened on, not the extension's own URL."
        )
        XCTAssertEqual(info?["editable"] as? Bool, false)
        XCTAssertNil(
            info?["linkUrl"],
            "linkUrl is absent, not empty, when the click was not on a link."
        )

        let tab = clicks.first?.dropFirst().first as? [String: Any]
        XCTAssertNotNil(
            tab?["id"] as? Int,
            "onClicked's second argument is the tab the click happened in; without it an extension cannot act on the page it was invoked from. Raw: \(clicks)"
        )
        XCTAssertEqual(tab?["url"] as? String, committedPageURL)
    }

    // MARK: - Checkbox and radio state

    func test_checkboxAndRadioStateIsOwnedByTheEngine() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runCheckedStateChecks() }
    }

    private func runCheckedStateChecks() async throws {
        let harness = try await makeHarness(creationScript: Self.defaultCreationScript)
        defer { teardown(harness) }

        var groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        XCTAssertEqual(groups.first?.items.first { $0.title == "Orbit Check" }?.isChecked, false)

        try XCTUnwrap(renderedEntries(harness).first(titled: "Orbit Check")).action?()
        try await Task.sleep(for: .seconds(2))

        let info = try await recordedClicks(harness.probe).first?.first as? [String: Any]
        XCTAssertEqual(
            info?["wasChecked"] as? Bool, false,
            "A checkbox click reports the state BEFORE the click as wasChecked."
        )
        XCTAssertEqual(
            info?["checked"] as? Bool, true,
            "...and the state after it as checked. A checkbox that never toggles is a normal item with a tick drawn on it."
        )

        groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        XCTAssertEqual(
            groups.first?.items.first { $0.title == "Orbit Check" }?.isChecked, true,
            "The toggled state has to persist into the next menu, otherwise the tick is a lie."
        )
        XCTAssertEqual(
            renderedEntries(harness).first(titled: "Orbit Check")?.isChecked, true,
            "The rendered row must draw the checkmark the engine reports."
        )

        try XCTUnwrap(renderedEntries(harness).first(titled: "Orbit Radio B")).action?()
        try await Task.sleep(for: .seconds(2))
        groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        XCTAssertEqual(groups.first?.items.first { $0.title == "Orbit Radio B" }?.isChecked, true)
        XCTAssertEqual(
            groups.first?.items.first { $0.title == "Orbit Radio A" }?.isChecked, false,
            "Selecting one radio must clear the rest of its run; two checked radios is the bug."
        )
    }

    // MARK: - update / remove / removeAll

    func test_updateRemoveAndRemoveAllReachTheRenderedMenu() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runMutationChecks() }
    }

    private func runMutationChecks() async throws {
        let harness = try await makeHarness(creationScript: Self.defaultCreationScript)
        defer { teardown(harness) }

        _ = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )

        try await send(harness.probe, "{ command: 'update', id: 'orbit-plain', properties: { title: 'Orbit Renamed' } }")
        var groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        XCTAssertTrue(
            titles(groups).contains("Orbit Renamed"),
            "update() must change the title the menu draws. Present: \(titles(groups))"
        )
        XCTAssertFalse(titles(groups).contains("Orbit Plain"))

        try await send(harness.probe, "{ command: 'remove', id: 'orbit-parent' }")
        groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        XCTAssertFalse(titles(groups).contains("Orbit Parent"))
        XCTAssertFalse(
            titles(groups).contains("Orbit Child"),
            "Removing a parent removes its whole subtree; a child left behind is an unreachable orphan."
        )

        try await send(harness.probe, "{ command: 'removeAll' }")
        harness.window.contentView?.layoutSubtreeIfNeeded()
        LiveContextMenuGesture.rightClickCentre(of: harness.page, in: harness.window)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(
            harness.page.extensionContextMenuGroups().count, 0,
            "removeAll() must leave the extension contributing nothing at all."
        )
        XCTAssertEqual(
            renderedEntries(harness).flattenedItems.last?.title, "Inspect Element",
            "With every item removed the menu must be exactly Orbit's own again. Present: \(renderedEntries(harness).flattenedItems.map(\.title))"
        )
    }

    // MARK: - Per-extension isolation

    func test_oneExtensionCannotRemoveAnothersItem() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) { try await self.runIsolationChecks() }
    }

    private func runIsolationChecks() async throws {
        let harness = try await makeHarness(creationScript: Self.defaultCreationScript)
        defer { teardown(harness) }

        // A second extension using the SAME item id: if ids were global, its
        // removeAll() would take the first extension's items away too.
        let otherDirectory = try writeFixture(
            named: "Orbit Context Menus Two",
            creationScript: """
            chrome.contextMenus.removeAll(function () {
              chrome.contextMenus.create({ id: 'orbit-plain', title: 'Other Plain', contexts: ['all'] });
            });
            """
        )
        let other = try await harness.engine.loadExtension(at: otherDirectory, session: harness.engine.defaultSession)
        defer { harness.engine.unloadExtension(id: other.id, session: harness.engine.defaultSession) }
        let otherProbe = try await loadProbe(extensionID: other.id, engine: harness.engine)
        defer { otherProbe.close() }

        var groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        XCTAssertEqual(
            groups.count, 2,
            "Both extensions contribute their own group. Present: \(groups.map(\.extensionName))"
        )
        XCTAssertTrue(titles(groups).contains("Orbit Plain"))
        XCTAssertTrue(titles(groups).contains("Other Plain"))

        try await send(otherProbe, "{ command: 'removeAll' }")
        groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(
            harness.page, in: harness.window
        )
        XCTAssertTrue(
            titles(groups).contains("Orbit Plain"),
            """
            One extension's removeAll() wiped another's items. Menu item ids are scoped per \
            extension; sharing them across extensions is a cross-extension write. Present: \
            \(titles(groups))
            """
        )
        XCTAssertFalse(titles(groups).contains("Other Plain"))
    }
}
