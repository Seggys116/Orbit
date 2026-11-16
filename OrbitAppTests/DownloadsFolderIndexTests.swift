import Darwin
import Foundation
import Observation
import XCTest
@testable import Orbit

@MainActor
final class DownloadsFolderIndexTests: XCTestCase {

    private var scratchRoot: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadsFolderIndexTests-\(UUID().uuidString)", isDirectory: true)
        folder = scratchRoot.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchRoot, FileManager.default.fileExists(atPath: scratchRoot.path) {
            try FileManager.default.removeItem(at: scratchRoot)
        }
        scratchRoot = nil
        folder = nil
        try super.tearDownWithError()
    }

    private var storeFileURL: URL { scratchRoot.appendingPathComponent("downloads.json") }

    @discardableResult
    private func writeFile(_ name: String, bytes: Int = 4) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func makeStore() -> DownloadStore {
        DownloadStore(fileURL: storeFileURL, indexedFolder: folder)
    }

    private func setWhereFroms(_ sources: [String], on url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: sources, format: .binary, options: 0)
        let result = data.withUnsafeBytes {
            setxattr(url.path, DownloadsFolderIndex.whereFromsAttribute, $0.baseAddress, data.count, 0, 0)
        }
        XCTAssertEqual(result, 0)
    }

    // MARK: - Scanning

    func testScanListsRegularFilesAndSkipsHiddenPartialAndDirectories() throws {
        try writeFile("notes.txt", bytes: 10)
        try writeFile("paper.pdf", bytes: 20)
        try writeFile(".hidden")
        try writeFile("a.crdownload")
        try writeFile("b.download")
        try writeFile("c.part")
        try writeFile("d.opdownload")
        try writeFile("e.tmp")
        try writeFile("UPPER.CRDOWNLOAD")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Subfolder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Thing.app"), withIntermediateDirectories: true)
        try writeFile("inside.txt")
        try FileManager.default.moveItem(at: folder.appendingPathComponent("inside.txt"), to: folder.appendingPathComponent("Subfolder/inside.txt"))

        let items = DownloadsFolderIndex.scan(directory: folder)

        XCTAssertEqual(Set(items.map(\.suggestedFileName)), ["notes.txt", "paper.pdf"])
    }

    func testScannedItemFieldsDescribeACompletedFile() throws {
        let url = try writeFile("paper.pdf", bytes: 128)

        let item = try XCTUnwrap(DownloadsFolderIndex.scan(directory: folder).first)

        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.totalBytes, 128)
        XCTAssertEqual(item.receivedBytes, 128)
        XCTAssertEqual(item.destinationURL.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(item.suggestedFileName, "paper.pdf")
        XCTAssertEqual(item.mimeType, "application/pdf")
        XCTAssertEqual(item.sourceURL.standardizedFileURL, url.standardizedFileURL)
        XCTAssertNil(item.apiID)
    }

    func testSourceURLComesFromTheWhereFromsAttribute() throws {
        let url = try writeFile("paper.pdf")
        try setWhereFroms(["https://example.com/files/paper.pdf", "https://example.com/page"], on: url)

        let item = try XCTUnwrap(DownloadsFolderIndex.scan(directory: folder).first)

        XCTAssertEqual(item.sourceURL, URL(string: "https://example.com/files/paper.pdf"))
    }

    func testUnparseableWhereFromsFallsBackToTheFileURL() throws {
        let url = try writeFile("paper.pdf")
        try setWhereFroms(["not a url"], on: url)

        let item = try XCTUnwrap(DownloadsFolderIndex.scan(directory: folder).first)

        XCTAssertTrue(item.sourceURL.isFileURL)
    }

    func testMissingDirectoryScansEmpty() {
        let missing = scratchRoot.appendingPathComponent("does-not-exist", isDirectory: true)

        XCTAssertTrue(DownloadsFolderIndex.scan(directory: missing).isEmpty)
    }

    func testItemsAreSortedNewestFirst() throws {
        for index in 0..<6 { try writeFile("file-\(index).txt") }

        let dates = DownloadsFolderIndex.scan(directory: folder).map(\.startedAt)

        XCTAssertEqual(dates.count, 6)
        XCTAssertEqual(dates, dates.sorted(by: >))
    }

    // MARK: - Identity

    func testIDsAreDeterministicAcrossRescans() async throws {
        try writeFile("one.txt")
        try writeFile("two.txt")
        let index = DownloadsFolderIndex(directory: folder)

        await index.rescanNow()
        let first = Dictionary(uniqueKeysWithValues: index.items.map { ($0.suggestedFileName, $0.id) })
        try writeFile("three.txt")
        await index.rescanNow()
        let second = Dictionary(uniqueKeysWithValues: index.items.map { ($0.suggestedFileName, $0.id) })

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(second["one.txt"], first["one.txt"])
        XCTAssertEqual(second["two.txt"], first["two.txt"])
        XCTAssertEqual(Set(second.values).count, 3)
    }

    func testStableIDDependsOnlyOnTheStandardizedPath() {
        let direct = folder.appendingPathComponent("a.txt")
        let roundabout = folder.appendingPathComponent("sub/../a.txt")

        XCTAssertEqual(DownloadsFolderIndex.stableID(for: direct), DownloadsFolderIndex.stableID(for: roundabout))
        XCTAssertNotEqual(
            DownloadsFolderIndex.stableID(for: direct),
            DownloadsFolderIndex.stableID(for: folder.appendingPathComponent("b.txt"))
        )
    }

    // MARK: - Rescanning

    func testRescanPicksUpAddedAndRemovedFiles() async throws {
        let index = DownloadsFolderIndex(directory: folder)
        XCTAssertTrue(index.items.isEmpty)

        let added = try writeFile("new.txt")
        await index.rescanNow()
        XCTAssertEqual(index.items.map(\.suggestedFileName), ["new.txt"])

        try FileManager.default.removeItem(at: added)
        await index.rescanNow()
        XCTAssertTrue(index.items.isEmpty)
    }

    func testWatchingScansOnStartAndAfterDirectoryChanges() async throws {
        try writeFile("before.txt")
        let index = DownloadsFolderIndex(directory: folder)
        defer { index.stopWatching() }

        let initial = expectation(description: "initial scan published")
        withObservationTracking { _ = index.items } onChange: { initial.fulfill() }
        index.startWatching()
        XCTAssertTrue(index.isWatching)
        await fulfillment(of: [initial], timeout: 10)
        XCTAssertEqual(index.items.map(\.suggestedFileName), ["before.txt"])

        let changed = expectation(description: "change published")
        withObservationTracking { _ = index.items } onChange: { changed.fulfill() }
        try writeFile("after.txt")
        await fulfillment(of: [changed], timeout: 10)
        XCTAssertEqual(Set(index.items.map(\.suggestedFileName)), ["before.txt", "after.txt"])
    }

    func testStopWatchingReleasesTheWatcher() {
        let index = DownloadsFolderIndex(directory: folder)
        index.startWatching()
        XCTAssertTrue(index.isWatching)

        index.stopWatching()

        XCTAssertFalse(index.isWatching)
    }

    // MARK: - DownloadStore merge

    func testStoreWithoutAFolderNeverIndexes() {
        let store = DownloadStore(fileURL: storeFileURL)
        store.startWatchingFolder()

        XCTAssertNil(store.folderIndex)
        XCTAssertEqual(store.allDownloads, store.downloads)
    }

    func testAllDownloadsMergesFolderFilesAndKeepsTrackedSeparate() async throws {
        let store = makeStore()
        try writeFile("loose.txt")
        let tracked = store.beginDownload(
            sourceURL: URL(string: "https://example.com/mine.zip")!,
            destinationURL: folder.appendingPathComponent("mine.zip"),
            suggestedFileName: "mine.zip"
        )
        store.updateProgress(id: tracked.id, progress: DownloadProgress(receivedBytes: 4, totalBytes: 4, state: .completed))
        try writeFile("mine.zip")
        await store.folderIndex?.rescanNow()

        XCTAssertEqual(store.downloads.map(\.id), [tracked.id])
        let all = store.allDownloads
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter { $0.destinationURL.lastPathComponent == "mine.zip" }.map(\.id), [tracked.id])
        let loose = try XCTUnwrap(all.first { $0.destinationURL.lastPathComponent == "loose.txt" })
        XCTAssertTrue(store.isFolderOnly(loose.id))
        XCTAssertFalse(store.isFolderOnly(tracked.id))
        XCTAssertEqual(store.item(id: loose.id), loose)
        XCTAssertEqual(store.item(id: tracked.id)?.id, tracked.id)
        XCTAssertNil(store.item(id: UUID()))
    }

    func testAllDownloadsSortsTrackedAndFolderItemsNewestFirst() async throws {
        let future = Date().addingTimeInterval(3_600)
        let past = Date(timeIntervalSince1970: 1_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func record(_ name: String, at date: Date) -> DownloadItem {
            DownloadItem(
                sourceURL: URL(string: "https://example.com/\(name)")!,
                destinationURL: scratchRoot.appendingPathComponent(name),
                suggestedFileName: name,
                state: .cancelled,
                startedAt: date,
                apiID: name == "future.zip" ? 1 : 2
            )
        }
        let newest = record("future.zip", at: future)
        let oldest = record("past.zip", at: past)
        try encoder.encode(DownloadsFile(nextAPIID: 3, items: [oldest, newest])).write(to: storeFileURL)
        try writeFile("middle.txt")

        let store = makeStore()
        await store.folderIndex?.rescanNow()

        XCTAssertEqual(store.allDownloads.map(\.suggestedFileName), ["future.zip", "middle.txt", "past.zip"])
    }

    func testFolderOnlyItemsNeverEnterTheTrackedList() async throws {
        let store = makeStore()
        try writeFile("loose.txt")
        await store.folderIndex?.rescanNow()

        XCTAssertEqual(store.allDownloads.count, 1)
        XCTAssertTrue(store.downloads.isEmpty)
        store.removeAllRecords()
        store.clearList()
        XCTAssertEqual(store.allDownloads.count, 1)
    }

    func testFileStillExistsFollowsFolderItems() async throws {
        let store = makeStore()
        let url = try writeFile("loose.txt")
        await store.folderIndex?.rescanNow()
        let item = try XCTUnwrap(store.allDownloads.first)

        XCTAssertTrue(store.fileStillExists(item.id))
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(store.fileStillExists(item.id))
    }

    // MARK: - Move to Trash

    func testMoveToTrashRemovesTheFolderOnlyFileAndItsRow() async throws {
        let store = makeStore()
        var trashed: [URL] = []
        store.trashItem = { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        let url = try writeFile("loose.txt")
        try writeFile("keep.txt")
        await store.folderIndex?.rescanNow()
        let target = try XCTUnwrap(store.allDownloads.first { $0.suggestedFileName == "loose.txt" })

        XCTAssertTrue(store.moveToTrash(target.id))

        XCTAssertEqual(trashed.map(\.lastPathComponent), [url.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.item(id: target.id))
        XCTAssertEqual(store.allDownloads.map(\.suggestedFileName), ["keep.txt"])
        await store.folderIndex?.rescanNow()
        XCTAssertEqual(store.allDownloads.map(\.suggestedFileName), ["keep.txt"])
    }

    func testMoveToTrashLeavesTheItemWhenTrashingFails() async throws {
        struct Refused: Error {}
        let store = makeStore()
        store.trashItem = { _ in throw Refused() }
        let url = try writeFile("loose.txt")
        await store.folderIndex?.rescanNow()
        let target = try XCTUnwrap(store.allDownloads.first)

        XCTAssertFalse(store.moveToTrash(target.id))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.allDownloads.map(\.id), [target.id])
    }

    func testMoveToTrashRefusesTrackedDownloads() async throws {
        let store = makeStore()
        var trashCalls = 0
        store.trashItem = { _ in trashCalls += 1 }
        let url = try writeFile("mine.zip")
        let tracked = store.beginDownload(
            sourceURL: URL(string: "https://example.com/mine.zip")!,
            destinationURL: url,
            suggestedFileName: "mine.zip"
        )
        await store.folderIndex?.rescanNow()

        XCTAssertFalse(store.moveToTrash(tracked.id))
        XCTAssertEqual(trashCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
