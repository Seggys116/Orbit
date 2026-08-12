//  Live coverage for the full extension flow (install, running worker,
//  removal, reinstall, enable/disable), all in the SAME already-running engine process, no restart.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionLifecycleLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeFixture(named name: String) throws -> LiveExtensionFixture.Built {
        let built = try LiveExtensionFixture.write(named: name, matchHost: "127.0.0.1")
        tempDirectories.append(built.directory)
        return built
    }

    private func makeTrackedStore() -> ExtensionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-ExtensionLifecycleStore-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(root)
        return ExtensionStore(root: root)
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-live-extension-test-page</body></html>"),
        ])
    }

    // Version-tagged variant of LiveExtensionFixture.write, with a
    // per-version marker file to prove an update replaced files, not just its version string.
    private func writeVersionedActiveFixture(
        name: String, version: String, matchHost: String, uniqueFileName: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-VersionedActiveFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "\(version)",
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
          if (message === 'orbit-update-soak-ping') { sendResponse('orbit-update-soak-pong-\(version)'); }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        document.documentElement.setAttribute('data-orbit-update-soak-content-ran', 'true');
        chrome.runtime.sendMessage('orbit-update-soak-ping', function(response) {
          document.documentElement.setAttribute('data-orbit-update-soak-response', response);
        });
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        try "orbit-update-soak-marker-\(version)".write(
            to: directory.appendingPathComponent(uniqueFileName), atomically: true, encoding: .utf8
        )

        return directory
    }

    // MARK: - Polling

    private static func pollUntil(
        timeout: Duration = .seconds(10),
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

    // MARK: - Load Unpacked Extension path (direct engine.loadExtension, matches ExtensionsSettingsPane.load(directory:))

    func testLoadUnpackedExtensionActivatesInTheRunningEngineWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.makeFixture(named: "Orbit Unpacked Lifecycle Test")

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            XCTAssertTrue(loaded.isActivated, "loadExtension must report immediate activation for a .immediate engine")
            XCTAssertTrue(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == loaded.id && $0.isEnabled },
                "the real Chromium extension registry must list the extension as loaded right after loadExtension(at:) returns -- same process, no restart"
            )
        }
    }

    func testUnloadingAnUnpackedExtensionRemovesItFromTheRunningEngineWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.makeFixture(named: "Orbit Unpacked Unload Test")

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            engine.unloadExtension(id: loaded.id, session: engine.defaultSession)

            XCTAssertFalse(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == loaded.id },
                "unloadExtension must remove the extension from the running engine immediately, with no restart"
            )
        }
    }

    func testReinstallingAnUnpackedExtensionAfterUnloadReactivatesItWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.makeFixture(named: "Orbit Unpacked Reinstall Test")

            let first = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            engine.unloadExtension(id: first.id, session: engine.defaultSession)
            XCTAssertFalse(engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == first.id })

            let second = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: second.id, session: engine.defaultSession) }

            XCTAssertEqual(second.id, first.id, "the same unpacked directory must derive the same extension id on reinstall")
            XCTAssertTrue(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == second.id && $0.isEnabled },
                "re-loading after an unload must reactivate it in the running engine, with no restart"
            )
        }
    }

    // MARK: - The extension actually running: content script + MV3 background service worker

    func testUnpackedExtensionContentScriptInjectsAndBackgroundServiceWorkerRespondsWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (contentScriptRan, backgroundResponded) = try LiveChromiumEngineHost.runLive { () -> (Bool, Bool) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.makeFixture(named: "Orbit Content Script + Background Worker Test")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.pollUntil(timeout: .seconds(15)) {
                try await contents.evaluateJavaScript(
                    "document.documentElement.getAttribute('\(fixture.backgroundResponseMarkerAttribute)')"
                ) as? String == "true"
            }

            let contentScriptRan = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.contentScriptMarkerAttribute)')"
            ) as? String == "true"
            let backgroundResponded = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.backgroundResponseMarkerAttribute)')"
            ) as? String == "true"
            return (contentScriptRan, backgroundResponded)
        }

        XCTAssertTrue(contentScriptRan, "the extension's real content script never injected into a real navigated page")
        XCTAssertTrue(backgroundResponded, "the content script's chrome.runtime.sendMessage never got a reply from the real MV3 background service worker")
    }

    func testUnloadingAnUnpackedExtensionStopsItsContentScriptFromInjectingIntoNewPagesWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let markerAfterUnload = try LiveChromiumEngineHost.runLive { () -> String? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.makeFixture(named: "Orbit Unload Stops Content Script Test")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)

            let firstContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { firstContents.close() }
            firstContents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(firstContents)
            try await Self.pollUntil(timeout: .seconds(15)) {
                try await firstContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('\(fixture.contentScriptMarkerAttribute)')"
                ) as? String == "true"
            }
            firstContents.close()

            engine.unloadExtension(id: loaded.id, session: engine.defaultSession)

            let secondContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { secondContents.close() }
            secondContents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(secondContents)
            // No signal to poll for (the content script must NOT run), so this
            // is a fixed settle wait rather than a pollUntil.
            try await Task.sleep(for: .milliseconds(500))
            return try await secondContents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.contentScriptMarkerAttribute)')"
            ) as? String
        }

        XCTAssertNil(markerAfterUnload, "a freshly navigated page must not run an unloaded extension's content script")
    }

    // MARK: - Options page: a real chrome-extension:// URL, served for real

    func testExtensionOptionsPageLoadsAsARealExtensionURLWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let title = try LiveChromiumEngineHost.runLive { () -> Any? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.makeFixture(named: "Orbit Options Page Test")

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(URL(string: "chrome-extension://\(loaded.id)/options.html")!)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            return try await contents.evaluateJavaScript("document.title")
        }

        XCTAssertEqual(title as? String, "Orbit Live Test Options", "the extension's own options.html was not served through the real chrome-extension:// scheme handler")
    }

    // MARK: - Tracked (Web-Store-equivalent) install path: ExtensionStore + ExtensionRuntime

    func testInstallingThroughExtensionStoreActivatesInTheRunningEngineWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let store = self.makeTrackedStore()
            let runtime = ExtensionRuntime(store: store)
            runtime.bind(to: engine)
            defer {
                for record in store.installed() { try? store.remove(id: record.id) }
                runtime.unbind()
            }

            let fixture = try self.makeFixture(named: "Orbit Tracked Install Test")
            let installed = try store.install(unpackedAt: fixture.directory, publicKey: nil)

            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }

            XCTAssertTrue(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id && $0.isEnabled },
                "ExtensionStore.install must reach the real running Chromium engine through ExtensionRuntime -- this is the same tail end webstorePrivate.completeInstall's ExtensionInstaller calls -- with no restart"
            )
        }
    }

    func testRemovingATrackedExtensionUnloadsItFromTheRunningEngineWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let store = self.makeTrackedStore()
            let runtime = ExtensionRuntime(store: store)
            runtime.bind(to: engine)
            defer { runtime.unbind() }

            let fixture = try self.makeFixture(named: "Orbit Tracked Remove Test")
            let installed = try store.install(unpackedAt: fixture.directory, publicKey: nil)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }

            try store.remove(id: installed.id)

            XCTAssertFalse(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id },
                "ExtensionStore.remove must unload the extension from the running engine immediately, with no restart"
            )
        }
    }

    func testReinstallingATrackedExtensionAfterRemovalReactivatesItWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let store = self.makeTrackedStore()
            let runtime = ExtensionRuntime(store: store)
            runtime.bind(to: engine)
            defer {
                for record in store.installed() { try? store.remove(id: record.id) }
                runtime.unbind()
            }

            let fixture = try self.makeFixture(named: "Orbit Tracked Reinstall Test")
            let installed = try store.install(unpackedAt: fixture.directory, publicKey: nil)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }
            try store.remove(id: installed.id)
            try await Self.pollUntil(timeout: .seconds(15)) {
                !engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }

            let reinstalled = try store.install(unpackedAt: fixture.directory, publicKey: nil)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == reinstalled.id }
            }

            XCTAssertEqual(reinstalled.id, installed.id)
            XCTAssertTrue(engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == reinstalled.id && $0.isEnabled })
        }
    }

    // MARK: - Configuring: enable / disable through ExtensionStore.setEnabled

    func testDisablingATrackedExtensionUnloadsItAndReEnablingReactivatesItWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let store = self.makeTrackedStore()
            let runtime = ExtensionRuntime(store: store)
            runtime.bind(to: engine)
            defer {
                for record in store.installed() { try? store.remove(id: record.id) }
                runtime.unbind()
            }

            let fixture = try self.makeFixture(named: "Orbit Tracked Enable Disable Test")
            let installed = try store.install(unpackedAt: fixture.directory, publicKey: nil)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }

            try store.setEnabled(false, id: installed.id)
            XCTAssertFalse(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id },
                "disabling a tracked extension must unload it from the running engine immediately, with no restart"
            )

            try store.setEnabled(true, id: installed.id)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id && $0.isEnabled }
            }
            XCTAssertTrue(engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id && $0.isEnabled })
        }
    }

    // MARK: - Full lifecycle soak: removing an active extension used to crash
    // the process because ExtensionStore.remove deleted its install directory before notifying ExtensionRuntime.

    func testFullExtensionLifecycleInstallRemoveReinstallDisableEnableWithAnActiveContentScriptAndBackgroundWorkerDoesNotCrashTheRunningEngine() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let store = self.makeTrackedStore()
            let runtime = ExtensionRuntime(store: store)
            runtime.bind(to: engine)
            defer {
                for record in store.installed() { try? store.remove(id: record.id) }
                runtime.unbind()
            }

            let fixture = try self.makeFixture(named: "Orbit Full Lifecycle Soak Test")
            let server = try self.makeServer()
            defer { server.stop() }

            // 1. Install.
            let installed = try store.install(unpackedAt: fixture.directory, publicKey: nil)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }

            // 2. Genuinely active: real tab, content script injected, worker
            // actually responded, not just "registered".
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Self.pollUntil(timeout: .seconds(15)) {
                try await contents.evaluateJavaScript(
                    "document.documentElement.getAttribute('\(fixture.backgroundResponseMarkerAttribute)')"
                ) as? String == "true"
            }
            let activeBeforeRemoval = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(fixture.contentScriptMarkerAttribute)')"
            ) as? String
            XCTAssertEqual(activeBeforeRemoval, "true", "fixture must be genuinely running before the removal this test exercises")

            let directory = installed.directory
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "install directory must exist before removal")

            // 3. Remove it WHILE the tab above is still open and the extension
            // is still active -- this is the crash this test exists to catch.
            try store.remove(id: installed.id)

            XCTAssertFalse(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id },
                "remove must unload the still-running extension from the engine with no restart"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path),
                "remove must still delete the install directory -- just after the engine has fully unloaded it, not before"
            )

            // 4. Re-install.
            let reinstalled = try store.install(unpackedAt: fixture.directory, publicKey: nil)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == reinstalled.id }
            }
            XCTAssertEqual(reinstalled.id, installed.id)

            // 5. Disable.
            try store.setEnabled(false, id: reinstalled.id)
            XCTAssertFalse(engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == reinstalled.id })

            // 6. Re-enable.
            try store.setEnabled(true, id: reinstalled.id)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == reinstalled.id && $0.isEnabled }
            }
            XCTAssertTrue(engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == reinstalled.id && $0.isEnabled })
        }
    }

    // MARK: - Update-while-running: twin of the removal ordering bug.
    // ExtensionStore.install now fires .willReplace, synchronously unloading
    // the running copy, before stageInstall touches any file.

    func testInstallingANewVersionOverAnActivelyRunningExtensionDoesNotCrashTheEngineAndReplacesItCleanlyWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let store = self.makeTrackedStore()
            let runtime = ExtensionRuntime(store: store)
            runtime.bind(to: engine)
            defer {
                for record in store.installed() { try? store.remove(id: record.id) }
                runtime.unbind()
            }

            // Fixed key so v1/v2, two independent source trees, derive the
            // same extension id, as a real Web Store update would.
            let sharedPublicKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
            let server = try self.makeServer()
            defer { server.stop() }

            let v1Source = try self.writeVersionedActiveFixture(
                name: "Orbit Update Soak Test", version: "1.0", matchHost: "127.0.0.1", uniqueFileName: "v1-only.txt"
            )
            let v1 = try store.install(unpackedAt: v1Source, publicKey: sharedPublicKey)
            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == v1.id && $0.version == "1.0" }
            }

            // Make it genuinely active before the update: real tab, content
            // script injected, background worker having actually answered.
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Self.pollUntil(timeout: .seconds(15)) {
                try await contents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-update-soak-response')"
                ) as? String == "orbit-update-soak-pong-1.0"
            }

            // Install v2 under the SAME id WHILE the tab above is still open
            // and v1 is still actively running -- this is the crash window.
            let v2Source = try self.writeVersionedActiveFixture(
                name: "Orbit Update Soak Test", version: "2.0", matchHost: "127.0.0.1", uniqueFileName: "v2-only.txt"
            )
            let v2 = try store.install(unpackedAt: v2Source, publicKey: sharedPublicKey)
            XCTAssertEqual(v2.id, v1.id, "an update installed under the same key must keep the same extension id")

            try await Self.pollUntil(timeout: .seconds(15)) {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == v2.id && $0.version == "2.0" }
            }

            // No crash: the engine is still alive and can still run script in
            // the tab that was hosting the old, now-replaced version.
            let arithmetic = try await contents.evaluateJavaScript("1 + 1") as? Int
            XCTAssertEqual(arithmetic, 2, "the tab that hosted v1 no longer evaluates JavaScript after v2 replaced it")

            // Exactly one registration for the id, not two.
            let matching = engine.loadedExtensions(session: engine.defaultSession).filter { $0.id == v2.id }
            XCTAssertEqual(matching.count, 1, "installing a new version over a running one must leave exactly one registration, not two")

            // No stale files, no missing new files, in the directory the
            // engine itself reports for this extension.
            let runningDirectory = try XCTUnwrap(matching.first?.directory)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: runningDirectory.appendingPathComponent("v1-only.txt").path),
                "a file only v1 shipped survived the update in the directory the running engine reports for this extension"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: runningDirectory.appendingPathComponent("v2-only.txt").path),
                "v2's own file is missing from the directory the running engine reports for this extension"
            )

            // A fresh navigation exercises the new version for real, not just registry bookkeeping.
            let freshContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { freshContents.close() }
            freshContents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(freshContents)
            try await Self.pollUntil(timeout: .seconds(15)) {
                try await freshContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-update-soak-response')"
                ) as? String == "orbit-update-soak-pong-2.0"
            }
        }
    }
}
