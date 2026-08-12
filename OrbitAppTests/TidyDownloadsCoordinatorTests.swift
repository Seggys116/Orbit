//  Drives Tidy Downloads against the real AppEnvironment/DownloadStore with real files on disk.
//  Every provider call goes through a recorded AssistSink, so nothing here touches the network.

import XCTest
@testable import Orbit

// MARK: - Recorded provider

private final class RecordedSink: @unchecked Sendable {
    private(set) var requests: [AssistRequest] = []
    var reply = "Tidied"
    var failure: AssistError?

    var sink: AssistSink {
        AssistSink(
            generate: { [self] request in
                requests.append(request)
                if let failure { throw failure }
                return reply
            },
            pageText: { nil }
        )
    }
}

@MainActor
final class TidyDownloadsCoordinatorTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var suite: UserDefaults!
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "TidyDownloadsCoordinatorTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
        AssistSettings.isTidyDownloadsEnabled = true
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-TidyDownloads-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        super.tearDown()
    }

    private func makeCompletedDownload(named name: String) throws -> UUID {
        let destination = scratch.appendingPathComponent(name)
        try Data("payload".utf8).write(to: destination)
        let item = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://mail.google.com/attachment")!,
            destinationURL: destination,
            suggestedFileName: name
        )
        env.downloadStore.updateProgress(
            id: item.id,
            progress: DownloadProgress(receivedBytes: 7, totalBytes: 7, state: .completed)
        )
        return item.id
    }

    func test_renamingMovesTheRealFileAndUpdatesTheRecord() throws {
        let id = try makeCompletedDownload(named: "6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf")

        let moved = env.downloadStore.renameFile(id: id, to: "AeroMexico Flight Confirmation.pdf")

        let newURL = try XCTUnwrap(moved)
        XCTAssertEqual(newURL.lastPathComponent, "AeroMexico Flight Confirmation.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path), "The file must actually be at its new path")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent("6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf").path),
            "and must no longer be at the old one"
        )
        XCTAssertEqual(
            env.downloadStore.downloads.first(where: { $0.id == id })?.destinationURL,
            newURL,
            "The record must point at where the file actually is"
        )
    }

    func test_renamingRefusesToClobberAnExistingFile() throws {
        let id = try makeCompletedDownload(named: "opaque-9f8e7d6c5b4a3210.pdf")
        try Data("other".utf8).write(to: scratch.appendingPathComponent("Taken.pdf"))

        let moved = try XCTUnwrap(env.downloadStore.renameFile(id: id, to: "Taken.pdf"))

        XCTAssertNotEqual(moved.lastPathComponent, "Taken.pdf")
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent("Taken.pdf")), Data("other".utf8), "The existing file must be untouched")
    }

    func test_renamingAnUnfinishedDownloadDoesNothing() throws {
        let destination = scratch.appendingPathComponent("partial.bin")
        try Data("x".utf8).write(to: destination)
        let item = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://example.com/f")!,
            destinationURL: destination,
            suggestedFileName: "partial.bin"
        )
        XCTAssertNil(env.downloadStore.renameFile(id: item.id, to: "Something.bin"))
    }

    func test_tidyRaisesTheAnnouncementOnlyWhenTheFileActuallyMoved() async throws {
        let coordinator = TidyDownloadsCoordinator()
        let provider = RecordedSink()
        provider.reply = "AeroMexico Flight Confirmation"
        let id = try makeCompletedDownload(named: "6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf")

        let announcement = await coordinator.tidy(
            downloadID: id,
            originalFileName: "6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf",
            sourceURL: URL(string: "https://mail.google.com/attachment")!,
            pageTitle: "Your April 14 AeroMexico flight",
            sink: provider.sink
        ) { newName in self.env.downloadStore.renameFile(id: id, to: newName) }

        let raised = try XCTUnwrap(announcement)
        XCTAssertEqual(raised.newFileName, "AeroMexico Flight Confirmation.pdf")
        XCTAssertEqual(raised.originalFileName, "6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf")
        XCTAssertEqual(coordinator.announcement, raised)
    }

    func test_tidyRaisesNoAnnouncementWhenTheMoveFailed() async throws {
        let coordinator = TidyDownloadsCoordinator()
        let provider = RecordedSink()
        provider.reply = "Something Better"
        let id = try makeCompletedDownload(named: "9f8e7d6c5b4a3210deadbeef.pdf")

        let announcement = await coordinator.tidy(
            downloadID: id,
            originalFileName: "9f8e7d6c5b4a3210deadbeef.pdf",
            sourceURL: URL(string: "https://example.com/f")!,
            pageTitle: nil,
            sink: provider.sink
        ) { _ in nil }

        XCTAssertNil(announcement)
        XCTAssertNil(coordinator.announcement)
    }

    func test_undoPutsTheFileBackAndClearsTheCard() async throws {
        let coordinator = TidyDownloadsCoordinator()
        let provider = RecordedSink()
        provider.reply = "AeroMexico Flight Confirmation"
        let original = "6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf"
        let id = try makeCompletedDownload(named: original)

        _ = await coordinator.tidy(
            downloadID: id,
            originalFileName: original,
            sourceURL: URL(string: "https://mail.google.com/attachment")!,
            pageTitle: "Your April 14 AeroMexico flight",
            sink: provider.sink
        ) { newName in self.env.downloadStore.renameFile(id: id, to: newName) }

        coordinator.undo { newName in self.env.downloadStore.renameFile(id: id, to: newName) }

        XCTAssertNil(coordinator.announcement)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent(original).path),
            "Undo must put the file back under the name it had"
        )
        XCTAssertEqual(env.downloadStore.downloads.first(where: { $0.id == id })?.destinationURL.lastPathComponent, original)
    }

    func test_oneDownloadIsOnlyConsideredOnce() async throws {
        let coordinator = TidyDownloadsCoordinator()
        let provider = RecordedSink()
        provider.reply = "Renamed"
        let id = try makeCompletedDownload(named: "deadbeefdeadbeef01.pdf")

        XCTAssertTrue(coordinator.shouldConsider(downloadID: id))
        _ = await coordinator.tidy(
            downloadID: id,
            originalFileName: "deadbeefdeadbeef01.pdf",
            sourceURL: URL(string: "https://example.com/f")!,
            pageTitle: nil,
            sink: provider.sink
        ) { newName in self.env.downloadStore.renameFile(id: id, to: newName) }

        XCTAssertFalse(
            coordinator.shouldConsider(downloadID: id),
            "A stream of .completed callbacks for one download must not start several requests"
        )
    }

    func test_withTheFeatureOffNothingIsRequestedAndNoFileMoves() async throws {
        AssistSettings.isTidyDownloadsEnabled = false
        let coordinator = TidyDownloadsCoordinator()
        let provider = RecordedSink()
        let original = "6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf"
        let id = try makeCompletedDownload(named: original)

        let announcement = await coordinator.tidy(
            downloadID: id,
            originalFileName: original,
            sourceURL: URL(string: "https://example.com/f")!,
            pageTitle: nil,
            sink: provider.sink
        ) { newName in self.env.downloadStore.renameFile(id: id, to: newName) }

        XCTAssertNil(announcement)
        XCTAssertTrue(provider.requests.isEmpty, "Nothing may leave the machine for a switched-off feature")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(original).path))
    }
}
