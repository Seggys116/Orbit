import Foundation
import XCTest

final class DownloadItemProjectionTests: XCTestCase {

    private final class StubFileManager: FileManager {
        var existingPaths: Set<String> = []
        override func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
    }

    private static let started = Date(timeIntervalSince1970: 1_739_577_600)
    private static let finished = Date(timeIntervalSince1970: 1_739_577_612)

    private func makeDownload(
        id: UUID = UUID(),
        state: DownloadState = .completed,
        totalBytes: Int64 = 5678,
        receivedBytes: Int64 = 1234,
        finishedAt: Date? = DownloadItemProjectionTests.finished,
        apiID: Int? = 7,
        destination: URL = URL(fileURLWithPath: "/tmp/OrbitDownloadItemProjectionTests/archive.zip")
    ) -> DownloadItem {
        DownloadItem(
            id: id,
            sourceURL: URL(string: "https://example.com/archive.zip")!,
            destinationURL: destination,
            suggestedFileName: "archive.zip",
            mimeType: "application/zip",
            totalBytes: totalBytes,
            receivedBytes: receivedBytes,
            state: state,
            startedAt: DownloadItemProjectionTests.started,
            finishedAt: finishedAt,
            apiID: apiID
        )
    }

    // MARK: - Shape

    func testItemEmitsExactlyTheContractsKeys() {
        let item = DownloadItemProjection.item(for: makeDownload(), fileManager: StubFileManager())
        XCTAssertEqual(
            Set(item.keys),
            [
                "id", "guid", "url", "finalUrl", "filename", "mime", "startTime", "endTime",
                "state", "paused", "bytesReceived", "totalBytes", "exists",
            ],
            "the C++ registry reads this dictionary key for key; an extra or missing key is a contract break"
        )
    }

    func testOnlyACancelledRecordCarriesAnErrorReason() {
        let cancelled = DownloadItemProjection.item(for: makeDownload(state: .cancelled), fileManager: StubFileManager())
        XCTAssertEqual(cancelled["error"] as? String, "USER_CANCELED")

        for state in [DownloadState.pending, .inProgress, .paused, .completed, .interrupted] {
            let item = DownloadItemProjection.item(for: makeDownload(state: state), fileManager: StubFileManager())
            XCTAssertNil(
                item["error"],
                "Orbit records no reason for \(state); inventing one would misreport why the transfer ended"
            )
        }
    }

    func testGuidIsTheLowercasedRecordUUIDAndFinalURLMirrorsURL() {
        let id = UUID()
        let item = DownloadItemProjection.item(for: makeDownload(id: id), fileManager: StubFileManager())

        XCTAssertEqual(item["guid"] as? String, id.uuidString.lowercased())
        XCTAssertNil(item["gid"], "the key is spelled guid")
        XCTAssertEqual(item["url"] as? String, "https://example.com/archive.zip")
        XCTAssertEqual(item["finalUrl"] as? String, "https://example.com/archive.zip")
        XCTAssertEqual(item["id"] as? Int, 7)
        XCTAssertEqual(item["filename"] as? String, "/tmp/OrbitDownloadItemProjectionTests/archive.zip")
        XCTAssertEqual(item["mime"] as? String, "application/zip")
        XCTAssertEqual(item["bytesReceived"] as? Double, 1234)
    }

    func testStartTimeIsSecondsSinceEpochNotMilliseconds() {
        let item = DownloadItemProjection.item(for: makeDownload(), fileManager: StubFileManager())
        XCTAssertEqual(item["startTime"] as? Double, 1_739_577_600)
        XCTAssertEqual(item["endTime"] as? Double, 1_739_577_612)
    }

    func testEndTimeIsNullWhileTheDownloadIsStillRunning() {
        let item = DownloadItemProjection.item(
            for: makeDownload(state: .inProgress, finishedAt: nil), fileManager: StubFileManager()
        )
        XCTAssertTrue(item["endTime"] is NSNull, "an unfinished download has no end time to report")
        XCTAssertNil(item["endTime"] as? Double)
    }

    func testUnknownTotalBytesIsPassedThroughAsZero() {
        let item = DownloadItemProjection.item(
            for: makeDownload(state: .inProgress, totalBytes: 0, finishedAt: nil), fileManager: StubFileManager()
        )
        XCTAssertEqual(item["totalBytes"] as? Double, 0, "turning 0 into -1 is the C++ side's job")
    }

    // MARK: - State mapping

    func testEveryDownloadStateMapsToItsChromeStateAndPausedFlag() {
        let expected: [DownloadState: (String, Bool)] = [
            .pending: ("in_progress", false),
            .inProgress: ("in_progress", false),
            .paused: ("in_progress", true),
            .completed: ("complete", false),
            .cancelled: ("interrupted", false),
            .interrupted: ("interrupted", false),
        ]
        for (state, (chromeState, paused)) in expected {
            let item = DownloadItemProjection.item(for: makeDownload(state: state), fileManager: StubFileManager())
            XCTAssertEqual(item["state"] as? String, chromeState, "wrong chrome state for \(state)")
            XCTAssertEqual(item["paused"] as? Bool, paused, "wrong paused flag for \(state)")
        }
    }

    // MARK: - exists

    func testExistsIsDrivenByTheInjectedFileManager() {
        let destination = URL(fileURLWithPath: "/tmp/OrbitDownloadItemProjectionTests/present.zip")
        let download = makeDownload(destination: destination)

        let absent = StubFileManager()
        XCTAssertEqual(
            DownloadItemProjection.item(for: download, fileManager: absent)["exists"] as? Bool, false
        )

        let present = StubFileManager()
        present.existingPaths = [destination.path]
        XCTAssertEqual(
            DownloadItemProjection.item(for: download, fileManager: present)["exists"] as? Bool, true
        )
    }

    // MARK: - Collections

    func testARecordWithoutAnAPIIDIsSkippedRatherThanGivenAMadeUpID() {
        let withID = makeDownload(apiID: 3)
        let withoutID = makeDownload(apiID: nil)

        let items = DownloadItemProjection.itemsObject(for: [withoutID, withID], fileManager: StubFileManager())

        XCTAssertEqual(items.count, 1, "a record with no persisted id must not be emitted at all")
        XCTAssertEqual(items.first?["id"] as? Int, 3)
    }

    func testItemsJSONIsAJSONArrayInStoreOrder() throws {
        let first = makeDownload(apiID: 9)
        let second = makeDownload(apiID: 4)

        let json = DownloadItemProjection.itemsJSON(for: [first, second], fileManager: StubFileManager())
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.map { $0["id"] as? Int }, [9, 4], "the snapshot keeps DownloadStore's newest-first order")
        XCTAssertTrue(decoded[0]["endTime"] is NSNumber)
    }

    func testItemsJSONOfAnEmptyStoreIsAnEmptyArray() {
        XCTAssertEqual(DownloadItemProjection.itemsJSON(for: [], fileManager: StubFileManager()), "[]")
    }
}
