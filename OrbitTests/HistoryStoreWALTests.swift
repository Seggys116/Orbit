import Foundation
import XCTest

final class HistoryStoreWALTests: XCTestCase {

    private var directory: URL!
    private var databaseURL: URL!
    private let profile = ProfileID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreWALTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("history.sqlite3", isDirectory: false)
    }

    override func tearDownWithError() throws {
        directory = nil
        databaseURL = nil
        try super.tearDownWithError()
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private var walURL: URL {
        directory.appendingPathComponent("history.sqlite3-wal", isDirectory: false)
    }

    func test_manyRevisitsToAKnownURLDoNotGrowTheWALWithoutBound() async throws {
        let store = try HistoryStore(databaseURL: databaseURL)

        let distinctURLCount = 40
        let visitsPerURL = 15 // 600 total visits, ~4x the live profile that surfaced this bug.

        for round in 0..<visitsPerURL {
            for index in 0..<distinctURLCount {
                _ = try await store.record(visit: HistoryVisit(
                    url: URL(string: "https://site\(index).example.com/page")!,
                    title: "Site \(index)",
                    profileID: profile,
                    wasTyped: round == 0,
                    visitedAt: Date().addingTimeInterval(-Double((visitsPerURL - round) * distinctURLCount))
                ))
            }
        }

        let walBytes = fileSize(walURL)
        XCTAssertLessThan(
            walBytes,
            2_000_000,
            "After \(visitsPerURL * distinctURLCount) visits (mostly revisits to \(distinctURLCount) known URLs), " +
            "the WAL should stay small because every write checkpoints itself. Got \(walBytes) bytes — " +
            "if this fires, either the unreset `rowID(forURL:)` statement or the unguarded `urls_au` trigger has regressed."
        )

        let mainBytes = fileSize(databaseURL)
        XCTAssertGreaterThan(
            mainBytes,
            4_096,
            "The main database file should have received backfilled data from at least one successful checkpoint; " +
            "a value stuck at exactly one page (4,096 bytes) means no checkpoint has ever succeeded, which is the " +
            "exact failure mode this test exists to catch."
        )

        let results = try await store.search("site0")
        XCTAssertEqual(results.first?.visitCount, visitsPerURL, "visit_count must still aggregate correctly across every revisit.")
    }

    func test_aRealTitleChangeStillReachesTheFTSIndexDespiteTheTriggerGuard() async throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let url = URL(string: "https://example.com/live-title")!

        for _ in 0..<10 {
            _ = try await store.record(visit: HistoryVisit(url: url, title: "Original Title", profileID: profile))
        }
        var results = try await store.search("Original")
        XCTAssertEqual(results.first?.url, url)

        _ = try await store.record(visit: HistoryVisit(url: url, title: "Brand New Title", profileID: profile))

        results = try await store.search("Brand New")
        XCTAssertEqual(results.first?.url, url, "A real title change must still reach the FTS index.")

        results = try await store.search("Original")
        XCTAssertTrue(results.isEmpty, "The stale title must no longer be searchable once it has genuinely changed.")
    }

    func test_deleteAndClearStillBehaveCorrectlyAfterTheCheckpointChange() async throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let url = URL(string: "https://example.com/to-delete")!
        _ = try await store.record(visit: HistoryVisit(url: url, title: "Doomed", profileID: profile))

        let removed = try await store.deleteEntries(matching: url)
        XCTAssertTrue(removed)
        let afterDelete = try await store.search("Doomed")
        XCTAssertTrue(afterDelete.isEmpty)

        _ = try await store.record(visit: HistoryVisit(
            url: URL(string: "https://example.com/before-clear")!, title: "Before Clear", profileID: profile
        ))
        try await store.clear()
        let afterClear = try await store.search("Before Clear")
        XCTAssertTrue(afterClear.isEmpty)
    }
}
