//  chrome.storage.local has zero coverage elsewhere. Proves a value written
//  by one content script is readable by a separate one, and survives an unload/reload.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionStoragePersistenceLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func writeStorageExtension(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-StoragePersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["storage"],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message && message.type === 'orbit-storage-write') {
            chrome.storage.local.set({ orbitStorageMarker: message.value }, function() { sendResponse('ok'); });
            return true;
          }
          if (message === 'orbit-storage-read') {
            chrome.storage.local.get(['orbitStorageMarker'], function(result) {
              sendResponse(result.orbitStorageMarker || null);
            });
            return true;
          }
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        if (location.pathname === '/writer') {
          chrome.runtime.sendMessage({ type: 'orbit-storage-write', value: 'orbit-storage-value-from-writer-tab' }, function(ack) {
            document.documentElement.setAttribute('data-orbit-storage-write-acked', ack || 'no-ack');
          });
        }
        if (location.pathname === '/reader') {
          chrome.runtime.sendMessage('orbit-storage-read', function(value) {
            document.documentElement.setAttribute('data-orbit-storage-read-result', value === null ? 'null' : value);
          });
        }
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/writer": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>writer</body></html>"),
            "/reader": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>reader</body></html>"),
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

    // MARK: - A value written in one tab's content script is readable from a completely separate tab

    func testAValueWrittenToChromeStorageLocalInOneTabIsReadableFromACompletelySeparateTab() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeStorageExtension(named: "Orbit Storage Cross-Tab Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let server = try self.makeServer()
            defer { server.stop() }

            let writerContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            // close() is idempotent; this only ensures a timed-out poll
            // doesn't leave the tab open for the rest of the pass.
            defer { writerContents.close() }
            writerContents.load(server.baseURL.appendingPathComponent("writer"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(writerContents)
            try await Self.pollUntil {
                try await writerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-storage-write-acked')"
                ) as? String == "ok"
            }
            writerContents.close()

            let readerContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { readerContents.close() }
            readerContents.load(server.baseURL.appendingPathComponent("reader"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(readerContents)
            try await Self.pollUntil {
                try await readerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-storage-read-result')"
                ) != nil
            }
            let result = try await readerContents.evaluateJavaScript(
                "document.documentElement.getAttribute('data-orbit-storage-read-result')"
            ) as? String

            XCTAssertEqual(
                result, "orbit-storage-value-from-writer-tab",
                "chrome.storage.local did not persist a value written by one tab's content script to a completely separate tab's -- either it never wrote, or it is not genuinely shared, persisted storage"
            )
        }
    }

    // MARK: - The same value survives the extension being unloaded and reloaded in the running engine

    func testAValueWrittenToChromeStorageLocalSurvivesTheExtensionBeingUnloadedAndReloaded() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeStorageExtension(named: "Orbit Storage Reload Persistence Test")
            let firstLoad = try await engine.loadExtension(at: directory, session: engine.defaultSession)

            let server = try self.makeServer()
            defer { server.stop() }

            let writerContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { writerContents.close() }
            writerContents.load(server.baseURL.appendingPathComponent("writer"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(writerContents)
            try await Self.pollUntil {
                try await writerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-storage-write-acked')"
                ) as? String == "ok"
            }
            writerContents.close()

            // Unload, then reload the SAME on-disk directory -- same path-derived id, a fresh
            // extension registration in the running engine, no restart of Orbit itself.
            engine.unloadExtension(id: firstLoad.id, session: engine.defaultSession)
            let secondLoad = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: secondLoad.id, session: engine.defaultSession) }
            XCTAssertEqual(secondLoad.id, firstLoad.id, "the same unpacked directory must derive the same extension id on reload")

            let readerContents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { readerContents.close() }
            readerContents.load(server.baseURL.appendingPathComponent("reader"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(readerContents)
            try await Self.pollUntil {
                try await readerContents.evaluateJavaScript(
                    "document.documentElement.getAttribute('data-orbit-storage-read-result')"
                ) != nil
            }
            let result = try await readerContents.evaluateJavaScript(
                "document.documentElement.getAttribute('data-orbit-storage-read-result')"
            ) as? String

            XCTAssertEqual(
                result, "orbit-storage-value-from-writer-tab",
                "a value written before the extension was unloaded did not survive being reloaded -- chrome.storage.local is not genuinely persisted at the profile/extension-id level"
            )
        }
    }
}
