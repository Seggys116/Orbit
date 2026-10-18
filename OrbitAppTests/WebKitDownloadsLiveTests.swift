//  Page-initiated downloads on system WebKit: attachment and unshowable responses become real
//  WKDownloads, land on disk, and are reported through the WebContentsDelegate into DownloadStore.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitDownloadsLiveTests: LiveEnvironmentTestCase {

    private var scratchDirectories: [URL] = []

    override func tearDown() {
        WebKitDownloads.downloadsDirectoryOverride = nil
        for url in scratchDirectories { try? FileManager.default.removeItem(at: url) }
        scratchDirectories.removeAll()
        super.tearDown()
    }

    /// Chooses a scratch destination, records into the real DownloadStore, and keeps every state it saw.
    private final class DownloadRecorder: WebContentsDelegate {
        let env: AppEnvironment
        let directory: URL
        var states: [DownloadState] = []
        var downloadID: UUID?
        var totalBytesAnnounced: Int64 = 0

        init(env: AppEnvironment, directory: URL) {
            self.env = env
            self.directory = directory
        }

        func webContents(
            _ contents: WebContents, willBeginDownload suggestedName: String, mimeType: String,
            totalBytes: Int64, sourceURL: URL, downloadID: UUID
        ) async -> URL? {
            let destination = DownloadStore.uniqueDestination(in: directory, suggestedName: suggestedName)
            _ = env.addDownload(
                id: downloadID, sourceURL: sourceURL, destinationURL: destination,
                suggestedFileName: suggestedName, mimeType: mimeType, totalBytes: totalBytes)
            self.downloadID = downloadID
            totalBytesAnnounced = totalBytes
            return destination
        }

        func webContents(_ contents: WebContents, download id: UUID, didUpdate progress: DownloadProgress) {
            states.append(progress.state)
            env.updateDownload(id: id, progress: progress)
        }
    }

    private struct Fixture {
        var server: LiveHTTPTestServer
        var contents: WebKitWebContents
        var recorder: DownloadRecorder
        var directory: URL
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WebKitDownloads-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        return directory
    }

    private static func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
    }

    private static func poll(
        _ waitingFor: String, timeout: Duration = .seconds(25), _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out waiting for \(waitingFor)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func withFixture(
        routes: [String: LiveHTTPTestServer.Route],
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let server = try LiveHTTPTestServer(routes: routes)
        defer { server.stop() }
        let directory = try makeDirectory("Files")
        let contents = try await WebKitLiveEngineHost.makeContents()
        defer { contents.close() }
        let recorder = DownloadRecorder(env: env, directory: directory)
        contents.delegate = recorder
        try await body(Fixture(server: server, contents: contents, recorder: recorder, directory: directory))
    }

    private func record(_ fixture: Fixture) -> DownloadItem? {
        fixture.recorder.downloadID.flatMap { id in env.downloadStore.downloads.first { $0.id == id } }
    }

    // MARK: - Attachments

    func test_anAttachmentResponseDownloadsToDiskAndCompletes() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let body = Self.payload(300_000)
            try await self.withFixture(routes: [
                "/report.bin": .init(
                    contentType: "application/octet-stream", data: body,
                    extraHeaders: ["Content-Disposition": "attachment; filename=\"orbit-report.bin\""]),
            ]) { fixture in
                fixture.contents.load(fixture.server.baseURL.appendingPathComponent("report.bin"))
                try await Self.poll("the download to complete") { self.record(fixture)?.state == .completed }

                let item = try XCTUnwrap(self.record(fixture))
                XCTAssertEqual(item.destinationURL.lastPathComponent, "orbit-report.bin")
                XCTAssertEqual(item.destinationURL.deletingLastPathComponent().standardizedFileURL, fixture.directory.standardizedFileURL)
                XCTAssertEqual(try Data(contentsOf: item.destinationURL), body, "the bytes on disk must be the bytes served")
                XCTAssertEqual(item.receivedBytes, Int64(body.count))
                XCTAssertEqual(item.sourceURL.path, "/report.bin")
                XCTAssertNotNil(item.apiID, "the record must be addressable from chrome.downloads")
                XCTAssertEqual(fixture.recorder.states.last, .completed)
                XCTAssertEqual(fixture.recorder.states.filter { $0 == .completed }.count, 1)
                XCTAssertFalse(fixture.contents.navigationState.isLoading, "a navigation that became a download must not leave the tab loading")
            }
        }
    }

    func test_aResponseTheEngineCannotShowBecomesADownload() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let body = Self.payload(4096)
            try await self.withFixture(routes: [
                "/blob.orbit": .init(contentType: "application/x-orbit-unshowable", data: body),
            ]) { fixture in
                fixture.contents.load(fixture.server.baseURL.appendingPathComponent("blob.orbit"))
                try await Self.poll("the download to complete") { self.record(fixture)?.state == .completed }

                let item = try XCTUnwrap(self.record(fixture))
                XCTAssertEqual(item.destinationURL.lastPathComponent, "blob.orbit")
                XCTAssertEqual(try Data(contentsOf: item.destinationURL), body)
                XCTAssertEqual(item.mimeType, "application/x-orbit-unshowable")
            }
        }
    }

    func test_aDeclinedDownloadWritesNothing() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let server = try LiveHTTPTestServer(routes: [
                "/declined.bin": .init(
                    contentType: "application/octet-stream", data: Self.payload(2048),
                    extraHeaders: ["Content-Disposition": "attachment"]),
            ])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("declined.bin"))
            try await Self.poll("the request to reach the server") { server.requestLog.first(path: "/declined.bin") != nil }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(self.env.downloadStore.downloads.isEmpty, "no delegate accepted it, so no record may exist")
        }
    }

    // MARK: - Cancel, pause, resume

    private static let slowChunk = 64 * 1024
    private static let slowDelay: TimeInterval = 0.12

    private func slowRoute(_ body: Data) -> LiveHTTPTestServer.Route {
        .init(
            contentType: "application/octet-stream", data: body,
            extraHeaders: [
                "Content-Disposition": "attachment; filename=\"slow.bin\"",
                "ETag": "\"orbit-slow-1\"",
                "Last-Modified": "Mon, 01 Jan 2024 00:00:00 GMT",
            ],
            supportsRangeRequests: true,
            throttle: (Self.slowChunk, Self.slowDelay))
    }

    func test_cancellingMidDownloadStopsTheTransfer() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let body = Self.payload(Self.slowChunk * 60)
            try await self.withFixture(routes: ["/slow.bin": self.slowRoute(body)]) { fixture in
                fixture.contents.load(fixture.server.baseURL.appendingPathComponent("slow.bin"))
                try await Self.poll("bytes to start arriving") {
                    (self.record(fixture)?.receivedBytes ?? 0) > 0
                }
                let id = try XCTUnwrap(fixture.recorder.downloadID)
                XCTAssertTrue(WebKitDownloads.shared.isTracking(id))

                fixture.contents.cancelDownload(id: id)
                try await Self.poll("the record to read cancelled") { self.record(fixture)?.state == .cancelled }

                let frozen = try XCTUnwrap(self.record(fixture)).receivedBytes
                try await Task.sleep(for: .seconds(1))
                let item = try XCTUnwrap(self.record(fixture))
                XCTAssertEqual(item.state, .cancelled)
                XCTAssertEqual(item.receivedBytes, frozen, "a cancelled download must stop receiving")
                XCTAssertLessThan(item.receivedBytes, Int64(body.count))
                XCTAssertFalse(fixture.recorder.states.contains(.completed))
                XCTAssertFalse(WebKitDownloads.shared.isTracking(id))
                XCTAssertFalse(FileManager.default.fileExists(atPath: item.destinationURL.path), "a cancelled download must not leave a finished-looking file")
            }
        }
    }

    func test_pausingThenResumingCompletesWithTheFullBytes() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let body = Self.payload(Self.slowChunk * 50)
            try await self.withFixture(routes: ["/slow.bin": self.slowRoute(body)]) { fixture in
                fixture.contents.load(fixture.server.baseURL.appendingPathComponent("slow.bin"))
                try await Self.poll("bytes to start arriving") {
                    (self.record(fixture)?.receivedBytes ?? 0) > 0
                }
                let id = try XCTUnwrap(fixture.recorder.downloadID)

                let pauseError = await WebKitDownloads.shared.pause(id: id)
                XCTAssertNil(pauseError)
                XCTAssertEqual(self.record(fixture)?.state, .paused)
                XCTAssertTrue(WebKitDownloads.shared.canResume(id))
                let pausedAt = try XCTUnwrap(self.record(fixture)).receivedBytes
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(self.record(fixture)?.receivedBytes, pausedAt, "a paused download must not keep receiving")

                let resumeError = await WebKitDownloads.shared.resume(id: id)
                XCTAssertNil(resumeError)
                XCTAssertEqual(self.record(fixture)?.state, .inProgress)
                try await Self.poll("the resumed download to complete", timeout: .seconds(60)) {
                    self.record(fixture)?.state == .completed
                }

                let item = try XCTUnwrap(self.record(fixture))
                XCTAssertEqual(item.destinationURL.lastPathComponent, "slow.bin")
                XCTAssertEqual(try Data(contentsOf: item.destinationURL), body, "pause then resume must still produce the exact bytes")
                XCTAssertEqual(self.env.downloadStore.downloads.filter { $0.suggestedFileName == "slow.bin" }.count, 1, "resuming must reuse the record, not create a second one")
            }
        }
    }

    func test_pausingADownloadTheEngineDoesNotTrackIsRefused() throws {
        try WebKitLiveEngineHost.runLive {
            let pause = await WebKitDownloads.shared.pause(id: UUID())
            XCTAssertEqual(pause, WebKitDownloads.mustBeInProgress)
            let resume = await WebKitDownloads.shared.resume(id: UUID())
            XCTAssertEqual(resume, WebKitDownloads.cannotResume)
        }
    }

    // MARK: - Save page

    func test_savePageWritesAUniquelyNamedWebArchive() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let directory = try self.makeDirectory("SavePage")
            WebKitDownloads.downloadsDirectoryOverride = directory
            let server = try LiveHTTPTestServer(routes: [
                "/page": .init(contentType: "text/html", body: "<html><head><title>Orbit Save Page</title></head><body>hello archive</body></html>"),
            ])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("page"))
            try await Self.poll("the page title") { contents.navigationState.title == "Orbit Save Page" && !contents.navigationState.isLoading }

            contents.savePage()
            contents.savePage()
            try await Self.poll("both archives to land") {
                ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count == 2
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            XCTAssertEqual(names, ["Orbit Save Page 2.webarchive", "Orbit Save Page.webarchive"], "a second save must not overwrite the first")
            for name in names {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                XCTAssertGreaterThan(data.count, 0)
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                XCTAssertNotNil(plist?["WebMainResource"], "the file must be a real web archive")
            }
        }
    }
}
