//  chrome.downloads end to end, cross-checked against the real DownloadStore.
//
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_searchReportsTheRealDownloadStoreRecords
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_searchFiltersByQueryStateAndTimeWindow
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_searchHonoursOrderByAndLimit
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_idsSurviveAReloadOfTheStore
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_onCreatedAndOnChangedFollowTheRealDownload
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_eraseRemovesTheRecordKeepsTheFileAndFiresOnErased
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_removeFileDeletesTheRealFileAndMarksTheRecord
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pauseAndResumeRefuseARecordTheEngineNoLongerTracks
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_openRequiresItsOwnPermission
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anExtensionWithoutThePermissionCannotSeeTheNamespace

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionDownloadsLiveTests: LiveEnvironmentTestCase {

    private var temporaryDirectories: [URL] = []
    private var previousProcessRoot: AppEnvironment?

    override func tearDown() {
        if let previousProcessRoot {
            AppEnvironment.processRoot = previousProcessRoot
            // Re-arm, or the bridge keeps observing this suite's scratch store and
            // pushes its records into every later suite's engine.
            OrbitChromiumDownloadsBridge.shared.install()
        }
        previousProcessRoot = nil
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-Downloads-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func writeFixture(named name: String, permissions: String) throws -> URL {
        let directory = try makeTemporaryDirectory("Extension")

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": [\(permissions)],
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var orbitEvents = [];
        if (typeof chrome.downloads !== 'undefined') {
          chrome.downloads.onCreated.addListener(function (item) {
            orbitEvents.push({ event: 'onCreated', item: item });
          });
          chrome.downloads.onChanged.addListener(function (delta) {
            orbitEvents.push({ event: 'onChanged', delta: delta });
          });
          chrome.downloads.onErased.addListener(function (id) {
            orbitEvents.push({ event: 'onErased', id: id });
          });
        }

        function reply(sendResponse, promise) {
          promise.then(function (result) {
            sendResponse(JSON.stringify({ result: result === undefined ? null : result, error: null }));
          }, function (error) {
            sendResponse(JSON.stringify({ result: null, error: String(error && error.message || error) }));
          });
        }

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          var call = JSON.parse(message);
          if (call.method === 'namespaceDefined') {
            sendResponse(JSON.stringify({ result: typeof chrome.downloads, error: null }));
            return false;
          }
          if (call.method === 'events') {
            sendResponse(JSON.stringify({ result: orbitEvents, error: null }));
            return false;
          }
          if (call.method === 'clearEvents') {
            orbitEvents = [];
            sendResponse(JSON.stringify({ result: true, error: null }));
            return false;
          }
          // Argument validation throws synchronously; without this the listener
          // dies, sendResponse never runs, and the probe reads back "undefined".
          try {
            var out = chrome.downloads[call.method].apply(chrome.downloads, call.args);
            // show/showDefaultFolder return undefined rather than a promise.
            if (out && typeof out.then === 'function') {
              reply(sendResponse, out);
              return true;
            }
            sendResponse(JSON.stringify({ result: null, error: null }));
          } catch (e) {
            sendResponse(JSON.stringify({ result: null, error: String(e && e.message || e) }));
          }
          return false;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Orbit Downloads Probe</title></head>
        <body><div id="orbit-downloads-probe">ready</div><script src="probe.js"></script></body></html>
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
        var downloadsDirectory: URL
        var completed: DownloadItem
        var inProgress: DownloadItem
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

    @discardableResult
    private func call(
        _ harness: Harness, _ method: String, _ args: [Any] = []
    ) async throws -> (result: Any?, error: String?) {
        let payload = try JSONSerialization.data(withJSONObject: ["method": method, "args": args])
        let message = try XCTUnwrap(String(data: payload, encoding: .utf8))
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        _ = try await harness.probe.evaluateJavaScript("window.orbitAsk('\(escaped)'); 'sent'")
        try await Self.pollUntil("the worker to answer \(method)") {
            try await harness.probe.evaluateJavaScript("window.__orbitOut !== null") as? Bool == true
        }
        let raw = try await harness.probe.evaluateJavaScript("window.__orbitOut") as? String ?? ""
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(raw.data(using: .utf8))) as? [String: Any],
            "chrome.downloads.\(method) did not answer with an envelope; it answered \(raw)"
        )
        return (envelope["result"] is NSNull ? nil : envelope["result"],
                envelope["error"] as? String)
    }

    private func succeed(
        _ harness: Harness, _ method: String, _ args: [Any] = []
    ) async throws -> Any? {
        let answer = try await call(harness, method, args)
        XCTAssertNil(answer.error, "chrome.downloads.\(method) failed with \(answer.error ?? "")")
        return answer.result
    }

    private func search(_ harness: Harness, _ query: [String: Any] = [:]) async throws -> [[String: Any]] {
        let raw = try await succeed(harness, "search", [query])
        return try XCTUnwrap(raw as? [[String: Any]])
    }

    private func events(_ harness: Harness) async throws -> [[String: Any]] {
        (try await succeed(harness, "events")) as? [[String: Any]] ?? []
    }

    private func withLoadedFixture(
        permissions: String = "\"downloads\"",
        _ body: (Harness) async throws -> Void
    ) async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        let env = self.env
        env._test_engineOverride = engine

        // The bridge resolves processRoot per call; without this removeFile would delete a real user file.
        previousProcessRoot = AppEnvironment.processRoot
        AppEnvironment.processRoot = env
        OrbitChromiumDownloadsBridge.shared.install()

        let bridge = OrbitChromiumTabsBridge.shared
        if !bridge.isWindowRegistered(env) {
            bridge.windowCreated(owner: env, focused: false)
        }
        bridge.windowFocusChanged(owner: env)

        let downloadsDirectory = try makeTemporaryDirectory("Files")
        let (completed, inProgress) = try await seedDownloads(in: env, directory: downloadsDirectory)

        let directory = try writeFixture(named: "Orbit Downloads", permissions: permissions)
        let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
        defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

        let probe = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { probe.close() }
        probe.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(probe)
        try await Self.pollUntil("the probe page to load") {
            try await probe.evaluateJavaScript("typeof window.orbitAsk === 'function'") as? Bool == true
        }

        try await body(Harness(
            engine: engine, extensionID: loaded.id, probe: probe,
            downloadsDirectory: downloadsDirectory, completed: completed, inProgress: inProgress))
    }

    /// Two real DownloadStore records on a scratch data root: one finished with a
    /// real file on disk, one still running. Never the user's own ~/Downloads.
    private func seedDownloads(
        in env: AppEnvironment, directory: URL
    ) async throws -> (completed: DownloadItem, inProgress: DownloadItem) {
        let store = env.downloadStore
        store.removeAllRecords()

        let completedURL = directory.appendingPathComponent("orbit-report.pdf")
        try Data(repeating: 0x41, count: 2048).write(to: completedURL)
        let completed = store.beginDownload(
            sourceURL: URL(string: "https://orbit-browser.app/files/orbit-report.pdf")!,
            destinationURL: completedURL,
            suggestedFileName: "orbit-report.pdf",
            mimeType: "application/pdf",
            totalBytes: 2048)
        store.updateProgress(
            id: completed.id,
            progress: DownloadProgress(receivedBytes: 2048, totalBytes: 2048, state: .completed))

        // startTime is reported to the millisecond, so without this the two
        // records tie and orderBy would be decided by the id tiebreak instead.
        try await Task.sleep(for: .milliseconds(5))

        let inProgress = store.beginDownload(
            sourceURL: URL(string: "https://orbit-browser.app/files/orbit-archive.zip")!,
            destinationURL: directory.appendingPathComponent("orbit-archive.zip"),
            suggestedFileName: "orbit-archive.zip",
            mimeType: "application/zip",
            totalBytes: 40960)
        store.updateProgress(
            id: inProgress.id,
            progress: DownloadProgress(receivedBytes: 10240, totalBytes: 40960, state: .inProgress))

        let refreshedCompleted = try XCTUnwrap(store.downloads.first { $0.id == completed.id })
        let refreshedInProgress = try XCTUnwrap(store.downloads.first { $0.id == inProgress.id })
        return (refreshedCompleted, refreshedInProgress)
    }

    private func apiID(_ item: DownloadItem, in env: AppEnvironment) throws -> Int {
        let live = try XCTUnwrap(env.downloadStore.downloads.first { $0.id == item.id })
        return try XCTUnwrap(
            live.apiID,
            "DownloadStore handed out a record with no apiID, so chrome.downloads could never name it"
        )
    }

    // MARK: - Reading the real store

    func test_searchReportsTheRealDownloadStoreRecords() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let all = try await self.search(harness)
            XCTAssertEqual(
                all.count, self.env.downloadStore.downloads.count,
                "search({}) must report every record the real DownloadStore holds"
            )

            let completedID = try self.apiID(harness.completed, in: self.env)
            let report = try XCTUnwrap(
                all.first { $0["id"] as? Int == completedID },
                "the finished download is missing from search()"
            )
            XCTAssertEqual(report["state"] as? String, "complete")
            XCTAssertEqual(report["mime"] as? String, "application/pdf")
            XCTAssertEqual(report["url"] as? String, "https://orbit-browser.app/files/orbit-report.pdf")
            XCTAssertEqual(
                report["filename"] as? String, harness.completed.destinationURL.path,
                "filename is the real absolute destination path"
            )
            XCTAssertEqual(report["totalBytes"] as? Double, 2048)
            XCTAssertEqual(report["bytesReceived"] as? Double, 2048)
            XCTAssertEqual(report["exists"] as? Bool, true, "the file really is on disk")
            XCTAssertEqual(report["paused"] as? Bool, false)
            XCTAssertNotNil(report["startTime"] as? String, "startTime must be an ISO 8601 string")
            XCTAssertNotNil(report["endTime"] as? String, "a finished download reports an endTime")

            let running = try XCTUnwrap(
                all.first { $0["id"] as? Int == (try? self.apiID(harness.inProgress, in: self.env)) })
            XCTAssertEqual(running["state"] as? String, "in_progress")
            XCTAssertNil(running["endTime"], "an unfinished download has no endTime")
            XCTAssertEqual(
                running["exists"] as? Bool, false,
                "nothing was written for the running download, and exists must report that honestly"
            )
        }
    }

    func test_searchFiltersByQueryStateAndTimeWindow() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let byState = try await self.search(harness, ["state": "complete"])
            XCTAssertEqual(byState.count, 1)
            XCTAssertEqual(byState.first?["id"] as? Int, try self.apiID(harness.completed, in: self.env))

            let byTerm = try await self.search(harness, ["query": ["archive"]])
            XCTAssertEqual(
                byTerm.compactMap { $0["mime"] as? String }, ["application/zip"],
                "a query term must match against filename and url"
            )

            let negated = try await self.search(harness, ["query": ["-archive"]])
            XCTAssertEqual(
                negated.compactMap { $0["mime"] as? String }, ["application/pdf"],
                "a term beginning with '-' excludes, exactly as upstream documents"
            )

            let byRegex = try await self.search(harness, ["filenameRegex": "\\.pdf$"])
            XCTAssertEqual(byRegex.count, 1, "filenameRegex must really be evaluated as a regular expression")

            let bySize = try await self.search(harness, ["totalBytesGreater": 4096])
            XCTAssertEqual(bySize.compactMap { $0["mime"] as? String }, ["application/zip"])

            let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            let none = try await self.search(harness, ["startedAfter": future])
            XCTAssertTrue(none.isEmpty, "nothing started in the future")

            let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
            let both = try await self.search(harness, ["startedAfter": past])
            XCTAssertEqual(both.count, 2)

            // DownloadQuery.state is a schema enum, so the renderer rejects an
            // unknown value before the browser sees it -- as it does in Chrome,
            // which is why upstream's kInvalidState is unreachable from here.
            let badState = try await self.call(harness, "search", [["state": "not-a-state"]])
            XCTAssertNotNil(
                badState.error,
                "an unknown state must be rejected, not silently treated as no filter"
            )
            XCTAssertNil(badState.result, "a rejected query must not return results")

            // limit is a plain integer, so a negative one passes argument
            // validation and reaches Orbit's own query compiler.
            let badLimit = try await self.call(harness, "search", [["limit": -1]])
            XCTAssertEqual(badLimit.error, "Invalid query limit")
        }
    }

    func test_searchHonoursOrderByAndLimit() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let ascending = try await self.search(harness, ["orderBy": ["startTime"]])
            let descending = try await self.search(harness, ["orderBy": ["-startTime"]])
            XCTAssertEqual(
                ascending.compactMap { $0["id"] as? Int }, descending.compactMap { $0["id"] as? Int }.reversed(),
                "a '-' prefix must reverse the ordering rather than being ignored"
            )

            let limited = try await self.search(harness, ["orderBy": ["-startTime"], "limit": 1])
            XCTAssertEqual(limited.count, 1)
            XCTAssertEqual(limited.first?["id"] as? Int, descending.first?["id"] as? Int)

            let unlimited = try await self.search(harness, ["limit": 0])
            XCTAssertEqual(unlimited.count, 2, "limit 0 means every match, not none")

            let bad = try await self.call(harness, "search", [["orderBy": ["nonsense"]]])
            XCTAssertEqual(bad.error, "Invalid orderBy field")
        }
    }

    func test_idsSurviveAReloadOfTheStore() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let before = try await self.search(harness)
            let idsByFilename = Dictionary(uniqueKeysWithValues: before.compactMap { item -> (String, Int)? in
                guard let name = item["filename"] as? String, let id = item["id"] as? Int else { return nil }
                return (name, id)
            })
            XCTAssertEqual(idsByFilename.count, 2)

            // chrome.downloads guarantees an id that is persistent across sessions,
            // so it has to come back the same from the file on disk.
            try self.env.downloadStore.saveNow()
            let reloaded = DownloadStore(fileURL: self.env.dataRoot.downloadsFile)
            for record in reloaded.downloads {
                XCTAssertEqual(
                    record.apiID, idsByFilename[record.destinationURL.path],
                    "reloading DownloadStore renumbered \(record.suggestedFileName); every extension's stored id would break"
                )
            }
        }
    }

    // MARK: - Events

    func test_onCreatedAndOnChangedFollowTheRealDownload() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            _ = try await self.succeed(harness, "clearEvents")

            let started = self.env.downloadStore.beginDownload(
                sourceURL: URL(string: "https://orbit-browser.app/files/orbit-notes.txt")!,
                destinationURL: harness.downloadsDirectory.appendingPathComponent("orbit-notes.txt"),
                suggestedFileName: "orbit-notes.txt",
                mimeType: "text/plain",
                totalBytes: 512)
            let startedID = try self.apiID(started, in: self.env)

            try await Self.pollUntil("downloads.onCreated to fire") {
                try await self.events(harness).contains {
                    $0["event"] as? String == "onCreated"
                        && ($0["item"] as? [String: Any])?["id"] as? Int == startedID
                }
            }

            self.env.downloadStore.updateProgress(
                id: started.id,
                progress: DownloadProgress(receivedBytes: 512, totalBytes: 512, state: .completed))

            try await Self.pollUntil("downloads.onChanged to report the completion") {
                try await self.events(harness).contains { entry in
                    guard entry["event"] as? String == "onChanged",
                          let delta = entry["delta"] as? [String: Any],
                          delta["id"] as? Int == startedID,
                          let state = delta["state"] as? [String: Any] else { return false }
                    return state["current"] as? String == "complete"
                }
            }

            let deltas = try await self.events(harness)
                .filter { $0["event"] as? String == "onChanged" }
                .compactMap { $0["delta"] as? [String: Any] }
            XCTAssertFalse(
                deltas.contains { $0["bytesReceived"] != nil },
                "upstream excludes bytesReceived from DownloadDelta; including it would fire onChanged on every packet"
            )
        }
    }

    func test_eraseRemovesTheRecordKeepsTheFileAndFiresOnErased() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let completedID = try self.apiID(harness.completed, in: self.env)
            _ = try await self.succeed(harness, "clearEvents")

            let erasedRaw = try await self.succeed(harness, "erase", [["id": completedID]])
            let erased = try XCTUnwrap(erasedRaw as? [Int])
            XCTAssertEqual(erased, [completedID], "erase resolves with the ids it actually erased")

            XCTAssertFalse(
                self.env.downloadStore.downloads.contains { $0.id == harness.completed.id },
                "erase must remove the real record from DownloadStore"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: harness.completed.destinationURL.path),
                "erase removes the history entry only; deleting the file here would be data loss"
            )

            let fired = try await self.events(harness)
            XCTAssertTrue(
                fired.contains { $0["event"] as? String == "onErased" && $0["id"] as? Int == completedID },
                "erasing must fire downloads.onErased"
            )

            let remaining = try await self.search(harness)
            XCTAssertFalse(remaining.contains { $0["id"] as? Int == completedID })
        }
    }

    // MARK: - Destructive operations

    func test_removeFileDeletesTheRealFileAndMarksTheRecord() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let completedID = try self.apiID(harness.completed, in: self.env)
            let runningID = try self.apiID(harness.inProgress, in: self.env)

            let refused = try await self.call(harness, "removeFile", [runningID])
            XCTAssertEqual(
                refused.error, "Download must be complete",
                "removeFile on an unfinished download must refuse"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: harness.completed.destinationURL.path),
                "the refused call must not have touched the other download's file"
            )

            _ = try await self.succeed(harness, "removeFile", [completedID])
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: harness.completed.destinationURL.path),
                "removeFile must really delete the file on disk"
            )

            let after = try await self.search(harness, ["id": completedID])
            XCTAssertEqual(
                after.first?["exists"] as? Bool, false,
                "the record must survive removeFile and report that its file is gone"
            )
            XCTAssertEqual(
                after.first?["state"] as? String, "complete",
                "the transfer succeeded; deleting the file afterwards must not restate it as a failure"
            )
            XCTAssertNil(
                after.first?["error"],
                "Orbit does not record why a transfer ended, and inventing an interrupt reason here would be a lie"
            )
            XCTAssertEqual(
                self.env.downloadStore.downloads.first { $0.id == harness.completed.id }?.state, .completed,
                "removeFile deletes the file and nothing else"
            )

            let again = try await self.call(harness, "removeFile", [completedID])
            XCTAssertEqual(again.error, "Download file already deleted")

            let unknown = try await self.call(harness, "removeFile", [987654])
            XCTAssertEqual(unknown.error, "Invalid downloadId")
        }
    }

    func test_pauseAndResumeRefuseARecordTheEngineNoLongerTracks() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            // Seeded records exist in DownloadStore but were never real engine transfers,
            // which is exactly the shape of a download restored from a previous run.
            let runningID = try self.apiID(harness.inProgress, in: self.env)
            let completedID = try self.apiID(harness.completed, in: self.env)

            let paused = try await self.call(harness, "pause", [runningID])
            XCTAssertEqual(
                paused.error, "Download must be in progress",
                "a record the DownloadManager does not track cannot be paused, and must say so rather than pretending"
            )

            let resumed = try await self.call(harness, "resume", [runningID])
            XCTAssertEqual(resumed.error, "DownloadItem.canResume must be true")

            let pausedFinished = try await self.call(harness, "pause", [completedID])
            XCTAssertEqual(pausedFinished.error, "Download must be in progress")

            let unknown = try await self.call(harness, "pause", [987654])
            XCTAssertEqual(unknown.error, "Invalid downloadId")

            XCTAssertEqual(
                self.env.downloadStore.downloads.first { $0.id == harness.inProgress.id }?.state, .inProgress,
                "a refused pause must not have rewritten the real record"
            )
        }
    }

    func test_openRequiresItsOwnPermission() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let completedID = try self.apiID(harness.completed, in: self.env)
            let refused = try await self.call(harness, "open", [completedID])
            XCTAssertEqual(
                refused.error, "The \"downloads.open\" permission is required",
                "\"downloads\" alone must not be enough to launch a file"
            )
        }
    }

    // MARK: - Negative control

    func test_anExtensionWithoutThePermissionCannotSeeTheNamespace() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture(permissions: "\"storage\"") { harness in
            let answer = try await self.call(harness, "namespaceDefined")
            XCTAssertEqual(
                answer.result as? String, "undefined",
                "chrome.downloads must be gated on the downloads permission; reachable without it is a real leak"
            )
        }
    }
}
