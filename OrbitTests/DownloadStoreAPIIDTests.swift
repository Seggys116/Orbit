import Foundation
import XCTest

@MainActor
final class DownloadStoreAPIIDTests: XCTestCase {

    private var scratchRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DownloadStoreAPIIDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchRoot, FileManager.default.fileExists(atPath: scratchRoot.path) {
            try FileManager.default.removeItem(at: scratchRoot)
        }
        scratchRoot = nil
        try super.tearDownWithError()
    }

    // Never the real profile: every store here is rooted in this test's own scratch directory.
    private var storeFileURL: URL { scratchRoot.appendingPathComponent("downloads.json") }

    private func record(
        id: UUID = UUID(),
        startedAt: Date,
        state: DownloadState = .cancelled,
        apiID: Int? = nil,
        destination: URL? = nil
    ) -> DownloadItem {
        DownloadItem(
            id: id,
            sourceURL: URL(string: "https://example.com/file.zip")!,
            destinationURL: destination ?? scratchRoot.appendingPathComponent("\(id.uuidString).zip"),
            suggestedFileName: "file.zip",
            state: state,
            startedAt: startedAt,
            apiID: apiID
        )
    }

    private func writeRecords(_ records: [DownloadItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: storeFileURL, options: .atomic)
    }

    private func makeStore() -> DownloadStore { DownloadStore(fileURL: storeFileURL) }

    // MARK: - Backfill

    func testBackfillAssignsIDsInAscendingStartedAtOrder() throws {
        let oldest = record(startedAt: Date(timeIntervalSince1970: 1_000))
        let middle = record(startedAt: Date(timeIntervalSince1970: 2_000))
        let newest = record(startedAt: Date(timeIntervalSince1970: 3_000))
        try writeRecords([newest, middle, oldest])

        let store = makeStore()

        XCTAssertEqual(store.downloads.first(where: { $0.id == oldest.id })?.apiID, 1)
        XCTAssertEqual(store.downloads.first(where: { $0.id == middle.id })?.apiID, 2)
        XCTAssertEqual(store.downloads.first(where: { $0.id == newest.id })?.apiID, 3)
    }

    func testBackfillBreaksStartedAtTiesByUUIDString() throws {
        let sameInstant = Date(timeIntervalSince1970: 4_000)
        let ids = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        try writeRecords(ids.reversed().map { record(id: $0, startedAt: sameInstant) })

        let store = makeStore()

        XCTAssertEqual(ids.map { id in store.downloads.first { $0.id == id }?.apiID }, [1, 2, 3])
    }

    func testBackfillStartsAboveTheHighestIDAlreadyAssigned() throws {
        let assigned = record(startedAt: Date(timeIntervalSince1970: 5_000), apiID: 41)
        let unassigned = record(startedAt: Date(timeIntervalSince1970: 1_000))
        try writeRecords([assigned, unassigned])

        let store = makeStore()

        XCTAssertEqual(store.downloads.first(where: { $0.id == assigned.id })?.apiID, 41, "an already-assigned id must never move")
        XCTAssertEqual(store.downloads.first(where: { $0.id == unassigned.id })?.apiID, 42)
    }

    func testBackfilledIDsArePersistedAndSurviveAReload() throws {
        let first = record(startedAt: Date(timeIntervalSince1970: 1_000))
        let second = record(startedAt: Date(timeIntervalSince1970: 2_000))
        try writeRecords([second, first])

        let before = makeStore().downloads.map { ($0.id, $0.apiID) }
        let reloaded = makeStore().downloads.map { ($0.id, $0.apiID) }

        XCTAssertEqual(before.map(\.1), [2, 1])
        XCTAssertEqual(
            reloaded.map(\.1), before.map(\.1),
            "chrome.downloads guarantees ids persist across sessions, so the backfill must have been written to disk"
        )
        XCTAssertEqual(reloaded.map(\.0), before.map(\.0))
    }

    func testALegacyBareArrayFileIsLoadedAndRewrittenInTheCounterCarryingShape() throws {
        try writeRecords([
            record(startedAt: Date(timeIntervalSince1970: 2_000)),
            record(startedAt: Date(timeIntervalSince1970: 1_000)),
        ])

        let store = makeStore()
        XCTAssertEqual(store.downloads.map(\.apiID), [2, 1])

        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: storeFileURL)) as? [String: Any],
            "a bare array on disk must be upgraded in place, or the counter has nowhere to live"
        )
        XCTAssertEqual(rewritten["nextAPIID"] as? Int, 3)
        XCTAssertEqual((rewritten["items"] as? [[String: Any]])?.count, 2)
    }

    // MARK: - Allocation

    func testBeginDownloadAllocatesTheNextID() throws {
        try writeRecords([record(startedAt: Date(timeIntervalSince1970: 1_000), apiID: 7)])
        let store = makeStore()

        let first = store.beginDownload(
            sourceURL: URL(string: "https://example.com/a.zip")!,
            destinationURL: scratchRoot.appendingPathComponent("a.zip"),
            suggestedFileName: "a.zip"
        )
        let second = store.beginDownload(
            sourceURL: URL(string: "https://example.com/b.zip")!,
            destinationURL: scratchRoot.appendingPathComponent("b.zip"),
            suggestedFileName: "b.zip"
        )

        XCTAssertEqual(first.apiID, 8)
        XCTAssertEqual(second.apiID, 9)
        XCTAssertEqual(store.downloads.first?.apiID, 9, "the newest record is at the head of the list")
    }

    func testAnIDIsNeverReusedAfterItsRecordIsRemoved() {
        let store = makeStore()

        let first = store.beginDownload(
            sourceURL: URL(string: "https://example.com/a.zip")!,
            destinationURL: scratchRoot.appendingPathComponent("a.zip"),
            suggestedFileName: "a.zip"
        )
        let second = store.beginDownload(
            sourceURL: URL(string: "https://example.com/b.zip")!,
            destinationURL: scratchRoot.appendingPathComponent("b.zip"),
            suggestedFileName: "b.zip"
        )
        XCTAssertEqual([first.apiID, second.apiID], [1, 2])

        store.remove(second.id)
        store.remove(first.id)

        let third = store.beginDownload(
            sourceURL: URL(string: "https://example.com/c.zip")!,
            destinationURL: scratchRoot.appendingPathComponent("c.zip"),
            suggestedFileName: "c.zip"
        )

        XCTAssertEqual(third.apiID, 3, "removing a record must not hand its id to the next download")
    }

    private func begin(_ name: String, in store: DownloadStore) -> DownloadItem {
        store.beginDownload(
            sourceURL: URL(string: "https://example.com/\(name)")!,
            destinationURL: scratchRoot.appendingPathComponent(name),
            suggestedFileName: name
        )
    }

    func testTheHighestIDIsNotReusedAfterItsRecordIsErasedAndTheAppRestarts() throws {
        let first = makeStore()
        let ids = ["a.zip", "b.zip", "c.zip"].map { begin($0, in: first).apiID }
        XCTAssertEqual(ids, [1, 2, 3])
        first.remove(try XCTUnwrap(first.downloads.first(where: { $0.apiID == 3 })?.id))
        try first.saveNow()

        let restarted = makeStore()
        let next = begin("d.zip", in: restarted)

        XCTAssertEqual(
            next.apiID, 4,
            "id 3 was handed to an extension before the erase; reusing it would point a live downloadId at a different file"
        )
    }

    func testTheCounterSurvivesASaveAndLoadWithNoRecordsLeftAtAll() throws {
        let first = makeStore()
        _ = begin("a.zip", in: first)
        _ = begin("b.zip", in: first)
        first.removeAllRecords()
        try first.saveNow()
        XCTAssertTrue(first.downloads.isEmpty)

        let restarted = makeStore()

        XCTAssertEqual(
            begin("c.zip", in: restarted).apiID, 3,
            "an empty list still has to remember how far the counter got"
        )
    }

    // MARK: - removeFile

    private func makeFile(named name: String) throws -> URL {
        let url = scratchRoot.appendingPathComponent(name)
        try Data("payload".utf8).write(to: url, options: .atomic)
        return url
    }

    func testRemoveFileDeletesTheFileAndLeavesTheRecordComplete() throws {
        let file = try makeFile(named: "complete.zip")
        let completed = record(startedAt: Date(timeIntervalSince1970: 1_000), state: .completed, destination: file)
        try writeRecords([completed])
        let store = makeStore()
        XCTAssertEqual(store.downloads.first?.state, .completed, "the file exists, so the load check must have left it complete")

        XCTAssertTrue(store.removeFile(completed.id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "removeFile must actually delete the file on disk")
        XCTAssertEqual(store.downloads.count, 1, "the record itself stays; only the file goes")
        XCTAssertEqual(
            store.downloads.first?.state, .completed,
            "a completed download whose file is deleted did not fail; chrome keeps it complete with exists false"
        )
        XCTAssertEqual(store.downloads.first?.id, completed.id)
    }

    func testRemoveFileRefusesARecordThatIsNotComplete() throws {
        let file = try makeFile(named: "running.zip")
        let running = record(startedAt: Date(timeIntervalSince1970: 1_000), state: .inProgress, destination: file)
        try writeRecords([running])
        let store = makeStore()

        XCTAssertFalse(store.removeFile(running.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "an in-flight download's partial file must be left alone")
        XCTAssertEqual(store.downloads.first?.state, .inProgress)
    }

    func testRemoveFileRefusesAnUnknownID() throws {
        let file = try makeFile(named: "untouched.zip")
        try writeRecords([record(startedAt: Date(timeIntervalSince1970: 1_000), state: .completed, destination: file)])
        let store = makeStore()

        XCTAssertFalse(store.removeFile(UUID()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store.downloads.first?.state, .completed)
    }

    func testRemoveFileRefusesWhenTheFileIsAlreadyGone() throws {
        let file = try makeFile(named: "vanishing.zip")
        let completed = record(startedAt: Date(timeIntervalSince1970: 1_000), state: .completed, destination: file)
        try writeRecords([completed])
        let store = makeStore()

        try FileManager.default.removeItem(at: file)

        XCTAssertFalse(store.removeFile(completed.id), "there is nothing left to delete, so this is a failure, not a silent success")
    }
}
