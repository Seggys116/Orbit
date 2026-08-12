//  Reproduces the live crash: removing an extension while genuinely active,
//  not a moment after an inert loadExtension() call.
//  ORBIT-LIVE-ENGINE: DESTRUCTIVE
//  The bug is the engine's process dying, so this gets its own process; a real crash takes down only this suite.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionRemovalCrashLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture: a genuinely active extension, not an inert one

    private func writeActiveFixture(named name: String, matchHost: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-RemovalCrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": [],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://\(matchHost)/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message === 'orbit-removal-crash-ping') { sendResponse('orbit-removal-crash-pong'); }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        document.documentElement.setAttribute('data-orbit-removal-crash-content-ran', 'true');
        chrome.runtime.sendMessage('orbit-removal-crash-ping', function(response) {
          if (response === 'orbit-removal-crash-pong') {
            document.documentElement.setAttribute('data-orbit-removal-crash-worker-responded', 'true');
          }
        });
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-removal-crash-page</body></html>"),
        ])
    }

    private static func pollUntil(timeout: Duration = .seconds(15), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "pollUntil timed out after \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // Runs on the same still-open contents the extension was active in, and
    // a brand-new one -- either could be what a use-after-free during removal corrupts.
    private func assertEngineIsStillAlive(_ engine: ChromiumEngine, survivingContents: ChromiumWebContents, server: LiveHTTPTestServer) async throws {
        let arithmetic = try await survivingContents.evaluateJavaScript("1 + 1") as? Int
        XCTAssertEqual(arithmetic, 2, "the tab that was hosting the just-removed extension's content script no longer evaluates JavaScript -- the renderer or its host did not survive removal")

        let freshContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { freshContents.close() }
        freshContents.load(server.baseURL)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(freshContents)
        let freshBody = try await freshContents.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertEqual(freshBody, "orbit-removal-crash-page", "the browser process could not serve a brand-new navigation right after the extension was removed")
    }

    // MARK: - Unpacked path: engine.unloadExtension while the tab is still open and the worker has already answered

    func testRemovingAnActivelyRunningUnpackedExtensionDoesNotCrashTheEngineAndUnloadsItWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeActiveFixture(named: "Orbit Removal Crash Unpacked Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            // Both signals, not just the content script: the worker must
            // have handled a real message, so removal contends with a live worker, not an idle one.
            try await Self.pollUntil {
                try await contents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-removal-crash-worker-responded')") as? String == "true"
            }

            // The tab stays open, unlike every other removal test in this
            // file's sibling suite, which close (or never open) one before unloading.
            engine.unloadExtension(id: loaded.id, session: engine.defaultSession)

            XCTAssertFalse(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == loaded.id },
                "unloadExtension must remove the extension from the running engine's registry even when it was actively running in an open tab"
            )

            try await self.assertEngineIsStillAlive(engine, survivingContents: contents, server: server)
        }
    }

    // MARK: - Tracked path: the exact call ExtensionsSettingsPane's "Remove" button makes, while a tab is open

    func testRemovingAnActivelyRunningTrackedExtensionThroughExtensionStoreWhileATabIsOpenDoesNotCrashTheEngineWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrbitAppTests-RemovalCrashStore-\(UUID().uuidString)", isDirectory: true)
            self.tempDirectories.append(root)
            let store = ExtensionStore(root: root)
            let runtime = ExtensionRuntime(store: store)
            runtime.bind(to: engine)
            defer { runtime.unbind() }

            let directory = try self.writeActiveFixture(named: "Orbit Removal Crash Tracked Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let installed = try store.install(unpackedAt: directory, publicKey: nil)
            try await Self.pollUntil {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Self.pollUntil {
                try await contents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-removal-crash-worker-responded')") as? String == "true"
            }

            // Exactly ExtensionsSettingsPane.remove(_:)'s branch for a tracked extension.
            try store.remove(id: installed.id)

            XCTAssertFalse(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id },
                "ExtensionStore.remove must unload an actively running extension from the engine, with the tab that was hosting it still open"
            )

            try await self.assertEngineIsStillAlive(engine, survivingContents: contents, server: server)
        }
    }
}
