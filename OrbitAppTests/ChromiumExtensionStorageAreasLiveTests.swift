//  Regression: chrome.storage.sync/managed passed feature detection but
//  failed every call with lastError, silently losing settings for Dark Reader, Vimium, uBlock and Stylus.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionStorageAreasLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func writeStorageAreasExtension(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-StorageAreas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["storage"],
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        function definedAreas() {
          return ['local', 'session', 'sync', 'managed'].filter(function (name) {
            return !!chrome.storage[name];
          }).join(',');
        }

        function done(sendResponse) {
          return function (value) {
            sendResponse(chrome.runtime.lastError ? 'error:' + chrome.runtime.lastError.message : value);
          };
        }

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'areas') {
            sendResponse(definedAreas());
            return true;
          }
          if (message === 'sync-quotas') {
            sendResponse([
              chrome.storage.sync.QUOTA_BYTES,
              chrome.storage.sync.QUOTA_BYTES_PER_ITEM,
              chrome.storage.sync.MAX_ITEMS
            ].join(','));
            return true;
          }
          if (message === 'sync-write') {
            chrome.storage.sync.set({ orbitSyncMarker: 'orbit-sync-value' }, function () {
              done(sendResponse)('ok');
            });
            return true;
          }
          if (message === 'sync-read') {
            chrome.storage.sync.get(['orbitSyncMarker'], function (result) {
              done(sendResponse)(result.orbitSyncMarker || 'missing');
            });
            return true;
          }
          if (message === 'sync-read-local') {
            chrome.storage.local.get(['orbitSyncMarker'], function (result) {
              done(sendResponse)(result.orbitSyncMarker || 'missing');
            });
            return true;
          }
          if (message === 'sync-oversized-item') {
            var oversized = new Array(9000).join('x');
            chrome.storage.sync.set({ orbitOversized: oversized }, function () {
              sendResponse(chrome.runtime.lastError ? 'rejected' : 'accepted');
            });
            return true;
          }
          if (message === 'managed-read') {
            chrome.storage.managed.get(null, function (result) {
              done(sendResponse)(JSON.stringify(result));
            });
            return true;
          }
          if (message === 'managed-write') {
            chrome.storage.managed.set({ orbitManaged: 'nope' }, function () {
              sendResponse(chrome.runtime.lastError ? 'rejected' : 'accepted');
            });
            return true;
          }
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probe = """
        <!DOCTYPE html>
        <html><head><title>Orbit Storage Areas Probe</title></head>
        <body><script src="probe.js"></script></body></html>
        """
        try probe.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let probeScript = """
        var question = new URL(location.href).searchParams.get('ask');
        document.documentElement.setAttribute('data-orbit-page-areas',
          ['local', 'session', 'sync', 'managed'].filter(function (name) {
            return !!chrome.storage[name];
          }).join(','));
        chrome.runtime.sendMessage(question, function (response) {
          document.documentElement.setAttribute('data-orbit-answer',
            chrome.runtime.lastError ? 'error:' + chrome.runtime.lastError.message : String(response));
        });
        """
        try probeScript.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
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

    /// Loads the probe page, which asks the worker `question` and puts the
    /// answer in the DOM. Returns (worker answer, areas the page itself sees).
    private func ask(_ question: String, extensionID: String, engine: ChromiumEngine) async throws -> (answer: String, pageAreas: String) {
        let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { contents.close() }
        contents.load(URL(string: "chrome-extension://\(extensionID)/probe.html?ask=\(question)")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
        try await Self.pollUntil {
            try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('data-orbit-answer')"
            ) as? String != nil
        }
        let answer = try await contents.evaluateJavaScript(
            "document.documentElement.getAttribute('data-orbit-answer')"
        ) as? String ?? ""
        let pageAreas = try await contents.evaluateJavaScript(
            "document.documentElement.getAttribute('data-orbit-page-areas')"
        ) as? String ?? ""
        return (answer, pageAreas)
    }

    // MARK: - Reflection: which areas an extension actually sees

    func testEveryStorageAreaTheSchemaDefinesIsPresentInBothTheServiceWorkerAndAnExtensionPage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeStorageAreasExtension(named: "Orbit Storage Areas Reflection Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let (workerAreas, pageAreas) = try await self.ask("areas", extensionID: loaded.id, engine: engine)
            XCTAssertEqual(
                workerAreas, "local,session,sync,managed",
                "the MV3 service worker does not see every storage area the schema defines -- an extension feature-detecting one of these gets the wrong answer"
            )
            XCTAssertEqual(
                pageAreas, "local,session,sync,managed",
                "a privileged extension page does not see every storage area the schema defines"
            )
        }
    }

    // MARK: - sync is a working, durable area, not a property that rejects

    func testChromeStorageSyncWritesAndReadsBackFromTheServiceWorkerAndSurvivesAnUnloadAndReload() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeStorageAreasExtension(named: "Orbit Storage Sync Round Trip Test")
            let firstLoad = try await engine.loadExtension(at: directory, session: engine.defaultSession)

            let write = try await self.ask("sync-write", extensionID: firstLoad.id, engine: engine)
            XCTAssertEqual(
                write.answer, "ok",
                "chrome.storage.sync.set failed -- this is the exact failure that silently loses Dark Reader's, Vimium's and Stylus's settings"
            )

            let read = try await self.ask("sync-read", extensionID: firstLoad.id, engine: engine)
            XCTAssertEqual(read.answer, "orbit-sync-value", "chrome.storage.sync.get did not return what set() had just written")

            // Distinct from local, not an alias for it: a key written to sync
            // must not show up in local.
            let localRead = try await self.ask("sync-read-local", extensionID: firstLoad.id, engine: engine)
            XCTAssertEqual(
                localRead.answer, "missing",
                "the sync area is writing into the local store -- the two areas are supposed to be separate backing stores"
            )

            // Unload and reload the same directory: same id, and the value
            // must still be there, making this a durable area, not an in-memory one.
            engine.unloadExtension(id: firstLoad.id, session: engine.defaultSession)
            let secondLoad = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: secondLoad.id, session: engine.defaultSession) }
            XCTAssertEqual(secondLoad.id, firstLoad.id)

            let readAgain = try await self.ask("sync-read", extensionID: secondLoad.id, engine: engine)
            XCTAssertEqual(
                readAgain.answer, "orbit-sync-value",
                "a chrome.storage.sync value did not survive the extension being unloaded and reloaded -- the area is not persistent"
            )
        }
    }

    func testChromeStorageSyncEnforcesTheQuotaItsOwnSchemaAdvertises() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeStorageAreasExtension(named: "Orbit Storage Sync Quota Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let quotas = try await self.ask("sync-quotas", extensionID: loaded.id, engine: engine)
            XCTAssertEqual(
                quotas.answer, "102400,8192,512",
                "chrome.storage.sync does not advertise the documented QUOTA_BYTES / QUOTA_BYTES_PER_ITEM / MAX_ITEMS"
            )

            // ~9 KB in one item, over the 8 KB per-item limit advertised
            // above; an area that advertises a quota it doesn't enforce lies to callers.
            let oversized = try await self.ask("sync-oversized-item", extensionID: loaded.id, engine: engine)
            XCTAssertEqual(
                oversized.answer, "rejected",
                "chrome.storage.sync accepted an item larger than QUOTA_BYTES_PER_ITEM"
            )
        }
    }

    // MARK: - managed is a real, empty, read-only area

    func testChromeStorageManagedReadsEmptyAndRefusesWritesRatherThanRejectingEveryCall() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeStorageAreasExtension(named: "Orbit Storage Managed Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            // Orbit has no policy source, so "no managed settings" is the
            // correct answer, exactly what Chrome returns on an unmanaged profile.
            let read = try await self.ask("managed-read", extensionID: loaded.id, engine: engine)
            XCTAssertEqual(
                read.answer, "{}",
                "chrome.storage.managed.get did not resolve with an empty object -- an unguarded managed.get(), which is correct against Chrome, breaks"
            )

            let write = try await self.ask("managed-write", extensionID: loaded.id, engine: engine)
            XCTAssertEqual(
                write.answer, "rejected",
                "chrome.storage.managed accepted a write -- the managed area is read-only in every browser"
            )
        }
    }
}
