//  "The listener registered" is not "the event works": checks payload shape,
//  not just invocation count. Keeps one page open, so not a test of idle wake-up.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionEventLivenessLiveTests: LiveEnvironmentTestCase {

    private typealias Schema = ExtensionAPISchemaSurface

    private var temporaryDirectories: [URL] = []
    private var previousProcessRoot: AppEnvironment?

    override func tearDown() {
        WebStoreInstallVerifyProbe.autoAnswerExtensionPermissionsConsent = nil
        if let previousProcessRoot {
            AppEnvironment.processRoot = previousProcessRoot
            // Re-arm, or both bridges keep observing this suite's scratch stores and
            // push its bookmarks and downloads into every later suite's engine.
            OrbitChromiumBookmarksBridge.shared.install()
            OrbitChromiumDownloadsBridge.shared.install()
        }
        previousProcessRoot = nil
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - The table

    private struct LivenessRow {
        var event: String
        var status: String
        var cause: String
        var payload: String?
    }

    private func readTable() throws -> [LivenessRow] {
        let object = try Schema.readObject(Schema.eventLivenessFile)
        guard let events = object["events"] as? [String: [String: Any]] else {
            throw Schema.SchemaError.malformed(Schema.eventLivenessFile, "missing \"events\" object")
        }
        return events.map { event, raw in
            LivenessRow(
                event: event,
                status: raw["status"] as? String ?? "",
                cause: raw["cause"] as? String ?? "",
                payload: raw["payload"] as? String
            )
        }.sorted { $0.event < $1.event }
    }

    /// Every cause this suite knows how to perform. A row naming anything
    /// else fails by name rather than being quietly skipped.
    private static let implementedCauses: Set<String> = [
        "openTab", "activateTab", "closeTab", "moveTab", "navigateTab",
        "navigateToFragment", "pushState", "navigateToUnresolvableHost", "setCookie",
        "windowCreated", "windowFocusChanged", "windowRemoved",
        "requestOptionalPermission", "removeOptionalPermission",
        "pressExtensionShortcut",
        "clickExtensionContextMenuItem",
        "createPinnedBookmark", "renamePinnedBookmark", "movePinnedBookmarkIntoFolder",
        "removePinnedBookmark",
        "beginDownload", "completeDownload", "eraseDownloadRecord",
        "recordVisit", "deleteHistoryURL",
    ]

    // MARK: - Fixture

    /// Kept as the raw JSON text; predicates evaluate against exactly those
    /// bytes in JavaScript, not a Swift round-trip of them.
    private struct Log {
        var json: String
        var registered: [String: Bool]
        var counts: [String: Int]
    }

    private func writeFixture(named name: String, observedEvents: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-EventLiveness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["tabs", "cookies", "webNavigation", "storage", "contextMenus", "bookmarks", "downloads", "history", "sessions"],
          "optional_permissions": ["privacy"],
          "host_permissions": ["<all_urls>"],
          "action": { "default_title": "\(name)" },
          "commands": {
            "orbit-liveness-command": {
              "suggested_key": { "default": "Ctrl+Shift+Y" },
              "description": "Orbit event liveness"
            }
          },
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // Registration is generated from the table, so a new row extends the
        // worker automatically rather than needing a matching edit here.
        let registrations = observedEvents.map { event -> String in
            let parts = event.split(separator: ".", maxSplits: 1).map(String.init)
            let namespace = parts[0]
            let member = parts.count > 1 ? parts[1] : ""
            return "orbitListen('\(event)', chrome.\(namespace) && chrome.\(namespace).\(member));"
        }.joined(separator: "\n")

        let background = """
        var orbitLog = {};
        function orbitListen(id, event) {
          if (!event || typeof event.addListener !== 'function') {
            orbitLog[id] = { registered: false, count: 0, payloads: [] };
            return;
          }
          orbitLog[id] = { registered: true, count: 0, payloads: [] };
          event.addListener(function () {
            var entry = orbitLog[id];
            entry.count++;
            if (entry.payloads.length < 8) {
              try {
                entry.payloads.push(JSON.parse(JSON.stringify(Array.prototype.slice.call(arguments))));
              } catch (e) {
                entry.payloads.push(['__unserialisable__: ' + String(e)]);
              }
            }
          });
        }
        \(registrations)
        // removeAll first: a lazy context's items are persisted and restored on
        // the next load, so a bare create() fails with a duplicate id.
        chrome.contextMenus.removeAll(function () {
          chrome.contextMenus.create({
            id: 'orbit-liveness-menu-item', title: 'Orbit Liveness Item', contexts: ['all']
          });
        });
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'orbit-liveness-report') {
            sendResponse(JSON.stringify(orbitLog));
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Orbit Event Liveness Probe</title></head>
        <body><div id="orbit-liveness-probe">ready</div><script src="probe.js"></script></body></html>
        """
        try probeHTML.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let probeJS = """
        window.__orbitLog = null;
        window.__orbitOut = null;
        window.orbitFetchLog = function () {
          window.__orbitLog = null;
          chrome.runtime.sendMessage('orbit-liveness-report', function (response) {
            window.__orbitLog = String(response);
          });
        };
        """
        try probeJS.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-event-liveness-one</body></html>"),
            "/second": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-event-liveness-two</body></html>"),
            "/third": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-event-liveness-three</body></html>"),
        ])
    }

    private static func pollUntil(_ waitingFor: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out waiting for \(waitingFor)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - The run

    func testEveryDeclaredEventTheLivenessTableMarksObservedIsActuallyDispatchedWithTheRightPayloadShape() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let table = try readTable()
        let observed = table.filter { $0.status == "observed" }
        XCTAssertGreaterThan(observed.count, 10, "the liveness table lists only \(observed.count) observed events")

        let unimplemented = observed.map(\.cause).filter { !Self.implementedCauses.contains($0) }
        XCTAssertEqual(
            Set(unimplemented).sorted(), [],
            "EventLiveness.json names causes this suite does not perform. An unimplemented cause would report every event depending on it as never firing, which is indistinguishable from the bug it is meant to catch."
        )

        continueAfterFailure = true
        let log = try LiveChromiumEngineHost.runLive(timeout: 240) { () -> Log in
            try await self.performEveryCauseAndCollect(observedEvents: observed.map(\.event))
        }

        for row in observed {
            guard let registered = log.registered[row.event] else {
                XCTFail("\(row.event): the worker never even recorded a slot for it, so the generated registration did not run")
                continue
            }
            XCTAssertTrue(
                registered,
                "\(row.event): the event object does not exist on the runtime chrome object, so no extension could register for it at all. That is a namespace or feature-resolution failure, not an event one — check the runtime reflection suite."
            )
            XCTAssertGreaterThan(
                log.counts[row.event] ?? 0, 0,
                "\(row.event): registered fine and never fired once, after performing its real cause (\(row.cause)). This is the exact shape of the action.onClicked, tabs.onReplaced and webNavigation.onTabReplaced bugs: a declared, registerable, permanently silent event."
            )
        }

        try LiveChromiumEngineHost.runLive(timeout: 120) {
            try await self.assertPayloadShapes(rows: observed, log: log)
        }
    }

    // MARK: - Causes

    private struct Harness {
        var engine: ChromiumEngine
        var server: LiveHTTPTestServer
        var extensionID: String
        var probe: ChromiumWebContents
        var spaceID: SpaceID
    }

    private var harness: Harness?

    private func performEveryCauseAndCollect(observedEvents: [String]) async throws -> Log {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        let env = self.env
        env._test_engineOverride = engine

        // Both bridges resolve processRoot per call; without this they would push the
        // real user's bookmarks and downloads instead of this environment's.
        previousProcessRoot = AppEnvironment.processRoot
        AppEnvironment.processRoot = env
        OrbitChromiumBookmarksBridge.shared.install()
        OrbitChromiumDownloadsBridge.shared.install()

        let bridge = OrbitChromiumTabsBridge.shared
        if !bridge.isWindowRegistered(env) {
            bridge.windowCreated(owner: env, focused: false)
        }
        bridge.windowFocusChanged(owner: env)
        let spaceID = try XCTUnwrap(env.activeSpace?.id)

        let server = try makeServer()
        defer { server.stop() }
        let directory = try writeFixture(named: "Orbit Event Liveness", observedEvents: observedEvents)
        let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
        defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

        let probe = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { probe.close() }
        probe.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(probe)
        try await Self.pollUntil("the probe page to load") {
            try await probe.evaluateJavaScript("typeof window.orbitFetchLog === 'function'") as? Bool == true
        }
        // Proves the worker finished evaluating its top-level script, so every
        // generated addListener call has run before any cause below fires.
        _ = try await fetchLog(probe)

        self.harness = Harness(engine: engine, server: server, extensionID: loaded.id, probe: probe, spaceID: spaceID)
        defer { self.harness = nil }

        try await causeTabAndNavigationEvents()
        try await causeCookieEvent()
        try await causeWindowEvents()
        try await causePermissionEvents()
        try await causeExtensionShortcut()
        try await causeContextMenuClick()
        try await causeBookmarkEvents()
        try await causeDownloadEvents()
        try await causeHistoryEvents()

        // Events cross a process boundary; give the last of them a moment to
        // land rather than racing the report.
        try await Task.sleep(for: .seconds(2))
        return try await fetchLog(probe)
    }

    private func causeTabAndNavigationEvents() async throws {
        let harness = try XCTUnwrap(self.harness)
        let env = self.env
        let bridge = OrbitChromiumTabsBridge.shared

        // openTab -> tabs.onCreated
        let firstTabID = env.openTab(url: harness.server.baseURL, in: harness.spaceID)
        let first = try XCTUnwrap(env.webContents[firstTabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(first)

        let secondTabID = env.openTab(url: harness.server.baseURL.appendingPathComponent("second"), in: harness.spaceID)
        let second = try XCTUnwrap(env.webContents[secondTabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(second)

        // activateTab -> tabs.onActivated
        env.activateTab(firstTabID)
        try await Task.sleep(for: .milliseconds(300))

        // moveTab -> tabs.onMoved. The registry is what dispatches the event,
        // and this is the seam the sidebar's own reorder calls into.
        bridge.tabMoved(tabUUID: secondTabID, windowOwner: env, fromIndex: 1, toIndex: 0)
        try await Task.sleep(for: .milliseconds(300))

        // navigateTab -> tabs.onUpdated and the four webNavigation events
        first.load(harness.server.baseURL.appendingPathComponent("third"))
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(first)

        // navigateToFragment -> webNavigation.onReferenceFragmentUpdated
        _ = try await first.evaluateJavaScript("location.hash = 'orbit-liveness'; 'ok'")
        try await Task.sleep(for: .milliseconds(500))

        // pushState -> webNavigation.onHistoryStateUpdated
        _ = try await first.evaluateJavaScript("history.pushState({}, '', '/pushed-by-orbit-liveness'); 'ok'")
        try await Task.sleep(for: .milliseconds(500))

        // navigateToUnresolvableHost -> webNavigation.onErrorOccurred
        first.load(URL(string: "http://orbit-conformance-no-such-host.invalid/")!)
        try? await LiveChromiumEngineHost.waitUntilStoppedLoading(first)
        try await Task.sleep(for: .milliseconds(500))

        // closeTab -> tabs.onRemoved, and sessions.onChanged: the closed tab joins
        // the recently-closed list, which is the list chrome.sessions reports.
        env.closeTab(secondTabID)
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Real sidebar mutations, not chrome.bookmarks calls: the registry diffs one
    /// pushed tree against the last, so only a store change can produce an event.
    private func causeBookmarkEvents() async throws {
        let harness = try XCTUnwrap(self.harness)
        let store = env.store

        let folderID = store.createFolder(name: "Orbit Liveness Folder", in: harness.spaceID)
        try await Task.sleep(for: .milliseconds(500))

        // createPinnedBookmark -> bookmarks.onCreated
        let bookmarkID = store.openTab(
            url: URL(string: "https://orbit-browser.app/liveness")!,
            in: harness.spaceID, section: .pinned, activate: false)
        try await Task.sleep(for: .milliseconds(500))
        try await waitForEvent("bookmarks.onCreated")

        // renamePinnedBookmark -> bookmarks.onChanged
        store.renameTab(bookmarkID, to: "Orbit Liveness Bookmark")
        try await Task.sleep(for: .milliseconds(500))
        try await waitForEvent("bookmarks.onChanged")

        // movePinnedBookmarkIntoFolder -> bookmarks.onMoved
        store.moveNode(bookmarkID, toParent: folderID, atIndex: 0, in: harness.spaceID)
        try await Task.sleep(for: .milliseconds(500))
        try await waitForEvent("bookmarks.onMoved")

        // removePinnedBookmark -> bookmarks.onRemoved
        store.removeBookmark(bookmarkID)
        try await Task.sleep(for: .milliseconds(500))
        try await waitForEvent("bookmarks.onRemoved")

        store.deleteFolder(folderID, in: harness.spaceID)
        try await Task.sleep(for: .milliseconds(500))
    }

    private func causeDownloadEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-EventLiveness-Downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let destination = directory.appendingPathComponent("orbit-liveness.bin")
        try Data(repeating: 0x4F, count: 1024).write(to: destination)

        let store = env.downloadStore
        // beginDownload -> downloads.onCreated
        let item = store.beginDownload(
            sourceURL: URL(string: "https://orbit-browser.app/files/orbit-liveness.bin")!,
            destinationURL: destination,
            suggestedFileName: "orbit-liveness.bin",
            mimeType: "application/octet-stream",
            totalBytes: 1024)
        try await Task.sleep(for: .milliseconds(500))
        try await waitForEvent("downloads.onCreated")

        // completeDownload -> downloads.onChanged
        store.updateProgress(
            id: item.id,
            progress: DownloadProgress(receivedBytes: 1024, totalBytes: 1024, state: .completed))
        try await Task.sleep(for: .milliseconds(500))
        try await waitForEvent("downloads.onChanged")

        // eraseDownloadRecord -> downloads.onErased. What the Downloads panel's own
        // remove does: the record goes, the file on disk stays.
        store.remove(item.id)
        try await Task.sleep(for: .milliseconds(500))
        try await waitForEvent("downloads.onErased")
    }

    private func causeHistoryEvents() async throws {
        let harness = try XCTUnwrap(self.harness)
        let space = try XCTUnwrap(env.activeSpace)
        let urlString = "https://orbit-liveness-\(UUID().uuidString.lowercased()).example/visited"
        let url = try XCTUnwrap(URL(string: urlString))

        // recordVisit -> history.onVisited, through the funnel every Orbit
        // navigation passes through rather than through chrome.history.addUrl.
        let row = await env.recordVisitReportingItem(
            url: url, title: "Orbit Liveness Visit", profileID: space.profileID,
            spaceID: space.id, wasTyped: true)
        XCTAssertNotNil(row, "Orbit recorded no visit, so history.onVisited could not have anything to report")
        try await waitForEvent("history.onVisited")

        // deleteHistoryURL -> history.onVisitRemoved
        _ = try await harness.probe.evaluateJavaScript(
            "chrome.history.deleteUrl({ url: '\(urlString)' }); 'asked'"
        )
        try await waitForEvent("history.onVisitRemoved", upTo: .seconds(15))
    }

    /// Gives up quietly: a miss has to fail as that event's own "registered and
    /// never fired" assertion, which names the cause, not as a timeout here.
    private func waitForEvent(_ event: String, upTo timeout: Duration = .seconds(10)) async throws {
        guard let probe = harness?.probe else { return }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let log = try await fetchLog(probe)
            if (log.counts[event] ?? 0) > 0 { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func causeCookieEvent() async throws {
        let harness = try XCTUnwrap(self.harness)
        let env = self.env
        let tabID = env.openTab(url: harness.server.baseURL, in: harness.spaceID)
        let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
        _ = try await contents.evaluateJavaScript(
            "document.cookie = 'orbit-liveness=1; path=/; max-age=600'; 'ok'"
        )
        try await Task.sleep(for: .milliseconds(700))
        env.closeTab(tabID)
    }

    private func causeWindowEvents() async throws {
        let bridge = OrbitChromiumTabsBridge.shared
        // Any object identity the bridge has not seen registers as a new
        // chrome.windows window, as OrbitWindowController.configure does.
        let secondWindowOwner = NSObject()
        bridge.windowCreated(owner: secondWindowOwner, focused: false)
        try await Task.sleep(for: .milliseconds(300))
        bridge.windowFocusChanged(owner: secondWindowOwner)
        try await Task.sleep(for: .milliseconds(300))
        bridge.windowRemoved(owner: secondWindowOwner)
        try await Task.sleep(for: .milliseconds(300))
        bridge.windowFocusChanged(owner: env)
    }

    /// Drives GlobalKeyEventMonitor.handle, which is the exact entry point
    /// NSEvent's local monitor calls, so nothing about the dispatch is stubbed.
    private func causeExtensionShortcut() async throws {
        let env = self.env
        ExtensionCommandRegistry.shared.publishOrbitReservedShortcuts()
        let event = ExtensionCommandKeyEvents.commandShiftY()
        XCTAssertNil(
            GlobalKeyEventMonitor.handle(event, in: env),
            "the extension declared Ctrl+Shift+Y and nothing in Orbit owns ⇧⌘Y, so the monitor had to swallow it"
        )
        try await Task.sleep(for: .milliseconds(700))
    }

    // A real right-click is the only way a contextMenus item can exist to be
    // clicked: an untrusted `contextmenu` event never leaves the renderer.
    private func causeContextMenuClick() async throws {
        let harness = try XCTUnwrap(self.harness)
        let env = self.env
        let tabID = env.openTab(url: harness.server.baseURL, in: harness.spaceID)
        let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

        let window = LiveContextMenuGesture.host(contents)
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
            env.closeTab(tabID)
        }

        let groups = try await LiveContextMenuGesture.rightClickUntilExtensionItemsAppear(contents, in: window)
        let item = try XCTUnwrap(
            groups.first?.items.first,
            "the fixture's own menu item never matched a real right-click"
        )
        contents.performExtensionContextMenuItem(item.id)
        try await Task.sleep(for: .seconds(1))
    }

    private func causePermissionEvents() async throws {
        let harness = try XCTUnwrap(self.harness)
        WebStoreInstallVerifyProbe.autoAnswerExtensionPermissionsConsent = true
        defer { WebStoreInstallVerifyProbe.autoAnswerExtensionPermissionsConsent = nil }

        _ = try await harness.probe.evaluateJavaScript(
            """
            (function () {
              chrome.permissions.request({ permissions: ['privacy'] });
              return 'requested';
            })()
            """,
            userGesture: true
        )
        try await Task.sleep(for: .seconds(2))

        _ = try await harness.probe.evaluateJavaScript(
            """
            (function () {
              chrome.permissions.remove({ permissions: ['privacy'] });
              return 'removed';
            })()
            """
        )
        try await Task.sleep(for: .seconds(2))
    }

    // MARK: - Reading and asserting

    private func fetchLog(_ probe: ChromiumWebContents) async throws -> Log {
        _ = try await probe.evaluateJavaScript("window.orbitFetchLog(); 'asked'")
        try await Self.pollUntil("the service worker's liveness log") {
            try await probe.evaluateJavaScript("window.__orbitLog !== null") as? Bool == true
        }
        let reported = try await probe.evaluateJavaScript("window.__orbitLog") as? String
        let raw = try XCTUnwrap(reported, "the worker never answered the report request")
        guard raw != "undefined", raw != "null", let data = raw.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else {
            XCTFail("the worker's liveness report came back as \(raw)")
            return Log(json: "{}", registered: [:], counts: [:])
        }
        return Log(
            json: raw,
            registered: parsed.mapValues { $0["registered"] as? Bool ?? false },
            counts: parsed.mapValues { $0["count"] as? Int ?? 0 }
        )
    }

    /// A row passes if any recorded firing satisfies its predicate -- the
    /// question is whether the shape is ever right, not whether every one is.
    private func assertPayloadShapes(rows: [LivenessRow], log: Log) async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        let evaluator = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { evaluator.close() }

        for row in rows {
            guard let payload = row.payload, !payload.isEmpty else { continue }
            let count = log.counts[row.event] ?? 0
            guard count > 0 else { continue }

            let script = """
            (function () {
              var report = \(log.json);
              var entry = report[\(Self.jsStringLiteral(row.event))];
              if (!entry || !entry.payloads) { return JSON.stringify({ matched: false, payloads: [] }); }
              for (var i = 0; i < entry.payloads.length; i++) {
                var args = entry.payloads[i];
                try { if (\(payload)) { return JSON.stringify({ matched: true, payloads: entry.payloads }); } }
                catch (e) {}
              }
              return JSON.stringify({ matched: false, payloads: entry.payloads });
            })()
            """
            let raw = try await evaluator.evaluateJavaScript(script) as? String ?? ""
            let outcome = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            let matched = outcome?["matched"] as? Bool ?? false
            let payloads = outcome?["payloads"] ?? "unreadable"
            XCTAssertTrue(
                matched,
                "\(row.event) fired \(count) time(s) and not one payload matched its shape assertion. Arrival is not correctness: tabs.onCreated was dispatched with an entirely wrong argument list while every count-based test passed. Recorded arguments: \(payloads)"
            )
        }
    }

    private static func jsStringLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let list = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(list.dropFirst().dropLast())
    }
}
