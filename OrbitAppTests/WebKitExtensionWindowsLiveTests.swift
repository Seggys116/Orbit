//  chrome.windows and the tab verbs a real worker reaches through WKWebExtension: each Orbit window is its
//  own extension window with its own tabs, focus follows the window, windows.create opens a real window,
//  and tabs.remove / tabs.update act on the sidebar's own tabs rather than only on the web view.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitExtensionWindowsLiveTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private func writeProbeExtension() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-ExtensionWindows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Orbit Windows Test",
          "version": "1.0",
          "permissions": ["tabs"],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var lastFocusWindowId = 'never';
        chrome.windows.onFocusChanged.addListener(function (windowId) { lastFocusWindowId = windowId; });

        function fail(sendResponse, error) {
          sendResponse(JSON.stringify({ error: String((error && error.message) || error) }));
        }

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (!message || !message.kind) { return; }
          try {
            if (message.kind === 'windows') {
              chrome.windows.getAll({ populate: true }, function (windows) {
                sendResponse(JSON.stringify({
                  windows: (windows || []).map(function (w) {
                    return {
                      id: w.id, focused: !!w.focused, incognito: !!w.incognito, state: w.state, type: w.type,
                      tabs: (w.tabs || []).map(function (t) {
                        return { id: t.id, url: t.url || null, index: t.index, active: !!t.active, pinned: !!t.pinned };
                      })
                    };
                  })
                }));
              });
            } else if (message.kind === 'focus') {
              sendResponse(JSON.stringify({ lastFocusWindowId: lastFocusWindowId }));
            } else if (message.kind === 'create') {
              chrome.windows.create({ url: message.url }, function (created) {
                sendResponse(JSON.stringify({
                  id: created ? created.id : null,
                  error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
                }));
              });
            } else if (message.kind === 'remove') {
              chrome.tabs.remove(message.tabId, function () {
                sendResponse(JSON.stringify({ error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null }));
              });
            } else if (message.kind === 'update') {
              chrome.tabs.update(message.tabId, message.properties, function (tab) {
                sendResponse(JSON.stringify({
                  pinned: tab ? !!tab.pinned : null,
                  error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
                }));
              });
            }
          } catch (e) { fail(sendResponse, e); }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        if (location.pathname === '/observer') {
          let handled = null;
          setInterval(function () {
            const raw = document.documentElement.getAttribute('data-orbit-probe-request');
            if (!raw || raw === handled) { return; }
            handled = raw;
            const request = JSON.parse(raw);
            chrome.runtime.sendMessage(request.message, function (response) {
              document.documentElement.setAttribute('data-orbit-probe-response', JSON.stringify({
                id: request.id,
                response: response || null,
                error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
              }));
            });
          }, 50);
        }
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/observer": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>observer</title><body>observer</body></html>"),
            "/b": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>b</title><body>b</body></html>"),
            "/d": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>d</title><body>d</body></html>"),
            "/created": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>created</title><body>created</body></html>"),
            "/private": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><title>private</title><body>private</body></html>"),
        ])
    }

    // MARK: - Probe plumbing

    private struct Harness {
        let engine: WebKitEngine
        let extensionID: String
        let server: LiveHTTPTestServer
        let observer: WebKitWebContents
        let spaceID: SpaceID

        @MainActor
        func teardown() {
            server.stop()
            engine.unloadExtension(id: extensionID, session: engine.defaultSession)
        }
    }

    private struct TabInfo {
        let id: Int
        let url: String?
        let index: Int
        let active: Bool
        let pinned: Bool
    }

    private struct WindowInfo {
        let id: Int
        let focused: Bool
        let incognito: Bool
        let tabs: [TabInfo]

        func lists(path: String) -> Bool { tabs.contains { $0.url?.hasSuffix(path) == true } }
    }

    private static func pollUntil(
        timeout: Duration = .seconds(15),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "pollUntil timed out after \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A closed today tab is archived, not deleted, so it can be reopened. It has left the sidebar
    /// once its renderer is gone and it is no longer in Today or pinned.
    private func removedTabLeftTheSidebar(_ id: TabID, in env: AppEnvironment) -> Bool {
        guard env.webContents[id] == nil else { return false }
        guard let tab = env.state.tabs[id] else { return true }
        return tab.section == .archived
    }

    private static func replyTornDownByWebKit(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("InvalidTransition") || text.contains("CancellationError")
    }

    private func jsStringLiteral(for object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        let wrapped = try JSONSerialization.data(withJSONObject: [String(decoding: data, as: UTF8.self)])
        return String(decoding: wrapped, as: UTF8.self) + "[0]"
    }

    private func probe(_ message: [String: Any], on contents: WebKitWebContents) async throws -> [String: Any] {
        let id = UUID().uuidString
        let literal = try jsStringLiteral(for: ["id": id, "message": message])
        _ = try await contents.evaluateJavaScript(
            "document.documentElement.setAttribute('data-orbit-probe-request', \(literal)); true"
        )
        var payload: [String: Any]?
        try await Self.pollUntil {
            let raw = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('data-orbit-probe-response')"
            )
            guard let text = raw as? String, let data = text.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["id"] as? String == id
            else { return false }
            if let error = envelope["error"] as? String {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "probe failed: \(error)")
            }
            guard let inner = envelope["response"] as? String, let innerData = inner.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any]
            else { return false }
            payload = decoded
            return true
        }
        return try XCTUnwrap(payload)
    }

    private func windows(on contents: WebKitWebContents) async throws -> [WindowInfo] {
        let payload = try await probe(["kind": "windows"], on: contents)
        return (payload["windows"] as? [[String: Any]] ?? []).map { dict in
            WindowInfo(
                id: dict["id"] as? Int ?? -1,
                focused: dict["focused"] as? Bool ?? false,
                incognito: dict["incognito"] as? Bool ?? false,
                tabs: (dict["tabs"] as? [[String: Any]] ?? []).map { tab in
                    TabInfo(
                        id: tab["id"] as? Int ?? -1,
                        url: tab["url"] as? String,
                        index: tab["index"] as? Int ?? -1,
                        active: tab["active"] as? Bool ?? false,
                        pinned: tab["pinned"] as? Bool ?? false
                    )
                }
            )
        }
    }

    private func makeHarness() async throws -> Harness {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        env._test_engineOverride = engine
        let spaceID = try XCTUnwrap(env.activeSpace?.id)
        let directory = try writeProbeExtension()
        let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
        let server = try makeServer()
        let observerTabID = env.openTab(url: server.baseURL.appendingPathComponent("observer"), in: spaceID)
        let observer = try XCTUnwrap(env.webContents[observerTabID] as? WebKitWebContents)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(observer)
        engine.noteWindowFocused(environment: env)
        try await Self.pollUntil(timeout: .seconds(30)) {
            let reported = try? await self.windows(on: observer)
            return reported?.contains { $0.lists(path: "/observer") } == true
        }
        return Harness(engine: engine, extensionID: loaded.id, server: server, observer: observer, spaceID: spaceID)
    }

    private func openLoadedTab(path: String, server: LiveHTTPTestServer, in environment: AppEnvironment, space: SpaceID) async throws -> TabID {
        let tabID = environment.openTab(url: server.baseURL.appendingPathComponent(path), in: space)
        let contents = try XCTUnwrap(environment.webContents[tabID] as? WebKitWebContents)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        return tabID
    }

    private func tabID(forPath path: String, on observer: WebKitWebContents) async throws -> Int {
        var found: Int?
        try await Self.pollUntil {
            let all = try await self.windows(on: observer)
            found = all.flatMap(\.tabs).first { $0.url?.hasSuffix(path) == true }?.id
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    // MARK: - One extension window per Orbit window

    func testEachOrbitWindowListsOnlyItsOwnTabs() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness()
            defer { harness.teardown() }
            let env = self.env

            let tabB = try await self.openLoadedTab(path: "b", server: harness.server, in: env, space: harness.spaceID)
            defer { if env.state.tabs[tabB] != nil { env.closeTab(tabB) } }

            let otherSpaceID = env.store.createSpace(
                name: "Extension Windows Other", icon: "square.on.square", iconIsEmoji: false,
                theme: WindowSession.incognitoTheme, profileID: env.state.profiles[0].id, activate: false
            )
            let otherEnv = AppEnvironment.makeWindowScoped(sharing: env, activeSpaceID: otherSpaceID, isTornOff: true)
            let tabD = try await self.openLoadedTab(path: "d", server: harness.server, in: env, space: harness.spaceID)
            env.store.moveTab(tabD, toSpace: otherSpaceID, section: .today)
            otherEnv.adoptWebContents(for: tabD, from: env)
            defer {
                otherEnv.closeTab(tabD)
                otherEnv.disposeWindowSession()
                harness.engine.noteWindowClosed(environment: otherEnv)
                env.store.deleteSpace(otherSpaceID)
            }

            var reported: [WindowInfo] = []
            try await Self.pollUntil {
                reported = try await self.windows(on: harness.observer)
                return reported.contains { $0.lists(path: "/d") }
            }
            let first = try XCTUnwrap(reported.first { $0.lists(path: "/observer") })
            let second = try XCTUnwrap(reported.first { $0.lists(path: "/d") })

            XCTAssertNotEqual(first.id, second.id, "two Orbit windows must be two extension windows")
            XCTAssertTrue(first.lists(path: "/b"), "the first window owns tab B too")
            XCTAssertFalse(first.lists(path: "/d"), "tab D lives in the other window and must not be listed in this one")
            XCTAssertEqual(second.tabs.count, 1, "the second window lists exactly its own tab")
            XCTAssertEqual(second.tabs.first?.index, 0, "indices count within a window")
            XCTAssertEqual(first.tabs.map(\.index), Array(0..<first.tabs.count), "tabs are indexed in sidebar order, window by window")
        }
    }

    func testFocusChangeReachesWindowsOnFocusChanged() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness()
            defer { harness.teardown() }
            let env = self.env

            let otherSpaceID = env.store.createSpace(
                name: "Extension Windows Focus", icon: "square.on.square", iconIsEmoji: false,
                theme: WindowSession.incognitoTheme, profileID: env.state.profiles[0].id, activate: false
            )
            let otherEnv = AppEnvironment.makeWindowScoped(sharing: env, activeSpaceID: otherSpaceID, isTornOff: true)
            let tabD = try await self.openLoadedTab(path: "d", server: harness.server, in: env, space: harness.spaceID)
            env.store.moveTab(tabD, toSpace: otherSpaceID, section: .today)
            otherEnv.adoptWebContents(for: tabD, from: env)
            defer {
                otherEnv.closeTab(tabD)
                otherEnv.disposeWindowSession()
                harness.engine.noteWindowClosed(environment: otherEnv)
                env.store.deleteSpace(otherSpaceID)
            }

            var reported: [WindowInfo] = []
            try await Self.pollUntil {
                reported = try await self.windows(on: harness.observer)
                return reported.contains { $0.lists(path: "/d") }
            }
            let observerWindow = try XCTUnwrap(reported.first { $0.lists(path: "/observer") }).id
            let otherWindow = try XCTUnwrap(reported.first { $0.lists(path: "/d") }).id

            harness.engine.noteWindowFocused(environment: otherEnv)
            try await Self.pollUntil {
                try await self.probe(["kind": "focus"], on: harness.observer)["lastFocusWindowId"] as? Int == otherWindow
            }

            harness.engine.noteWindowFocused(environment: env)
            try await Self.pollUntil {
                try await self.probe(["kind": "focus"], on: harness.observer)["lastFocusWindowId"] as? Int == observerWindow
            }

            harness.engine.noteWindowFocused(environment: nil)
            try await Self.pollUntil {
                try await self.probe(["kind": "focus"], on: harness.observer)["lastFocusWindowId"] as? Int == -1
            }
        }
    }

    func testWindowsCreateOpensARealOrbitWindow() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness()
            defer { harness.teardown() }
            let env = self.env
            let previousProcessRoot = AppEnvironment.processRoot
            AppEnvironment.processRoot = env
            // Opening a real window starts the engine that window owns; keep dispatching through this one.
            let previousDispatch = ExtensionCommandRegistry.shared.dispatch
            defer {
                ExtensionCommandRegistry.shared.dispatch = previousDispatch
                AppEnvironment.processRoot = previousProcessRoot
            }

            let windowsBefore = OrbitWindowController.openEnvironments.count
            let url = harness.server.baseURL.appendingPathComponent("created")
            let created = try await self.probe(["kind": "create", "url": url.absoluteString], on: harness.observer)
            XCTAssertNil(created["error"] as? String, "windows.create failed: \(created)")

            let newEnvironment = try XCTUnwrap(
                OrbitWindowController.openEnvironments.last { $0 !== env },
                "windows.create must open a real Orbit window"
            )
            let controller = try XCTUnwrap(OrbitWindowController.controller(for: newEnvironment))
            defer {
                controller.close()
            }
            XCTAssertEqual(OrbitWindowController.openEnvironments.count, windowsBefore + 1)
            XCTAssertTrue(controller.window?.isVisible == true, "the window has to be on screen")

            var listing: [WindowInfo] = []
            try await Self.pollUntil {
                listing = try await self.windows(on: harness.observer)
                return listing.contains { $0.lists(path: "/created") }
            }
            let createdWindow = try XCTUnwrap(listing.first { $0.lists(path: "/created") })
            XCTAssertEqual(createdWindow.id, created["id"] as? Int, "windows.create must answer with the window it made")
            XCTAssertEqual(createdWindow.tabs.count, 1)
            XCTAssertFalse(listing.first { $0.lists(path: "/observer") }?.lists(path: "/created") ?? true)
        }
    }

    // MARK: - Tab verbs reach the sidebar

    func testTabsRemoveClosesTheSidebarTab() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness()
            defer { harness.teardown() }
            let env = self.env

            let tabB = try await self.openLoadedTab(path: "b", server: harness.server, in: env, space: harness.spaceID)
            defer { if env.state.tabs[tabB] != nil { env.closeTab(tabB) } }
            let extensionTabID = try await self.tabID(forPath: "/b", on: harness.observer)

            // A today tab closes into the archive, so the record stays and can be reopened.
            // The row has to leave the sidebar, and chrome.tabs has to drop it. WebKit can
            // fault the content-script reply while the removed view is leaving the window;
            // that transport error still fails the test when the tab did not actually close.
            var transportError: Error?
            var apiError: String?
            do {
                let result = try await self.probe(["kind": "remove", "tabId": extensionTabID], on: harness.observer)
                apiError = result["error"] as? String
            } catch {
                transportError = error
            }

            try await Self.pollUntil {
                self.removedTabLeftTheSidebar(tabB, in: env)
            }
            let remaining = try await self.windows(on: harness.observer).flatMap(\.tabs)
            XCTAssertFalse(remaining.contains { $0.url?.hasSuffix("/b") == true }, "a removed tab must leave chrome.tabs too")
            XCTAssertNil(apiError, "tabs.remove failed: \(apiError ?? "")")
            if let transportError, !Self.replyTornDownByWebKit(transportError) {
                throw transportError
            }
        }
    }

    func testTabsUpdatePinnedPinsAndUnpinsTheSidebarTab() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness()
            defer { harness.teardown() }
            let env = self.env

            let tabB = try await self.openLoadedTab(path: "b", server: harness.server, in: env, space: harness.spaceID)
            defer { if env.state.tabs[tabB] != nil { env.closeTab(tabB) } }
            let extensionTabID = try await self.tabID(forPath: "/b", on: harness.observer)
            XCTAssertEqual(env.state.tabs[tabB]?.section, .today)

            let pin = try await self.probe(
                ["kind": "update", "tabId": extensionTabID, "properties": ["pinned": true]], on: harness.observer
            )
            XCTAssertNil(pin["error"] as? String, "tabs.update {pinned: true} failed: \(pin)")
            try await Self.pollUntil { env.state.tabs[tabB]?.section == .pinned }

            let listed = try await self.windows(on: harness.observer).flatMap(\.tabs).first { $0.url?.hasSuffix("/b") == true }
            XCTAssertEqual(listed?.pinned, true, "chrome.tabs must report what the sidebar now shows")

            let unpin = try await self.probe(
                ["kind": "update", "tabId": extensionTabID, "properties": ["pinned": false]], on: harness.observer
            )
            XCTAssertNil(unpin["error"] as? String, "tabs.update {pinned: false} failed: \(unpin)")
            try await Self.pollUntil { env.state.tabs[tabB]?.section == .today }
        }
    }

    // MARK: - Incognito

    func testAnIncognitoWindowIsOnlyVisibleToAnExtensionAllowedInIncognito() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            let harness = try await self.makeHarness()
            defer {
                harness.engine.setExtensionAllowedInIncognito(id: harness.extensionID, allowed: true)
                harness.teardown()
            }
            let env = self.env

            let session = WindowSession.incognito(on: env)
            let privateEnv = session.environment
            let privateSpaceID = try XCTUnwrap(privateEnv.activeSpace?.id)
            let privateTab = try await self.openLoadedTab(path: "private", server: harness.server, in: privateEnv, space: privateSpaceID)
            defer {
                privateEnv.closeTab(privateTab)
                session.dispose()
            }

            harness.engine.setExtensionAllowedInIncognito(id: harness.extensionID, allowed: false)
            let hidden = try await self.windows(on: harness.observer)
            XCTAssertFalse(
                hidden.contains { $0.lists(path: "/private") },
                "an extension not allowed in Incognito must not see the private window's tabs"
            )

            harness.engine.setExtensionAllowedInIncognito(id: harness.extensionID, allowed: true)
            try await Self.pollUntil {
                let listing = try await self.windows(on: harness.observer)
                return listing.first { $0.lists(path: "/private") }?.incognito == true
            }
        }
    }
}
