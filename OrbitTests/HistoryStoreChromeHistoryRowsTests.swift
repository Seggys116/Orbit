import Foundation
import XCTest

final class HistoryStoreChromeHistoryRowsTests: XCTestCase {

    private var directory: URL!
    private var databaseURL: URL!
    private let profile = ProfileID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreChromeHistoryRowsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("history.sqlite3", isDirectory: false)
    }

    override func tearDownWithError() throws {
        directory = nil
        databaseURL = nil
        try super.tearDownWithError()
    }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(databaseURL: databaseURL)
    }

    @discardableResult
    private func record(
        _ store: HistoryStore,
        _ urlString: String,
        title: String = "",
        at visitedAt: Date = Date(),
        typed: Bool = false
    ) async throws -> HistoryEntry {
        try await store.record(visit: HistoryVisit(
            url: XCTUnwrap(URL(string: urlString)),
            title: title,
            profileID: profile,
            wasTyped: typed,
            visitedAt: visitedAt
        ))
    }

    // MARK: - urlRow / visitRows

    func test_urlRowCarriesTheRealPrimaryKeyAndAggregates() async throws {
        let store = try makeStore()
        let now = Date()
        try await record(store, "https://a.example/one", title: "Alpha", at: now.addingTimeInterval(-60), typed: true)
        try await record(store, "https://a.example/one", title: "Alpha", at: now)

        let oneURL = try XCTUnwrap(URL(string: "https://a.example/one"))
        let oneRow = try await store.urlRow(forURL: oneURL)
        let row = try XCTUnwrap(oneRow)
        XCTAssertGreaterThan(row.id, 0, "HistoryItem.id has to be a real urls.id, not a placeholder")
        XCTAssertEqual(row.title, "Alpha")
        XCTAssertEqual(row.visitCount, 2)
        XCTAssertEqual(row.typedCount, 1)
        XCTAssertEqual(row.lastVisit.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)

        let missing = try await store.urlRow(forURL: XCTUnwrap(URL(string: "https://never.example/")))
        XCTAssertNil(missing, "a URL that was never visited has no row")
    }

    func test_visitRowsAreOnePerVisitOldestFirstWithTheirOwnIds() async throws {
        let store = try makeStore()
        let url = try XCTUnwrap(URL(string: "https://a.example/one"))
        let now = Date()
        try await record(store, url.absoluteString, at: now.addingTimeInterval(-600), typed: true)
        try await record(store, url.absoluteString, at: now)

        let visits = try await store.visitRows(forURL: url)
        XCTAssertEqual(visits.count, 2, "collapsing repeat visits would lose what getVisits exists to report")
        XCTAssertLessThan(visits[0].visitTime, visits[1].visitTime, "oldest first")
        XCTAssertNotEqual(visits[0].id, visits[1].id, "each visit needs its own visits.id")
        XCTAssertEqual(visits[0].urlID, visits[1].urlID, "both visits belong to one urls.id")
        XCTAssertTrue(visits[0].wasTyped)
        XCTAssertFalse(visits[1].wasTyped)

        let fetched = try await store.urlRow(forURL: url)
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(visits[0].urlID, row.id, "getVisits and search must agree on the item's identity")

        let none = try await store.visitRows(forURL: XCTUnwrap(URL(string: "https://never.example/")))
        XCTAssertEqual(none.count, 0)
    }

    // MARK: - urlRows(matchingText:start:end:limit:)

    func test_searchMatchesTitleAndUrlAndHonoursTheWindow() async throws {
        let store = try makeStore()
        let now = Date()
        try await record(store, "https://alpha.example/page", title: "Quarterly Report", at: now.addingTimeInterval(-3600))
        try await record(store, "https://beta.example/other", title: "Something Else", at: now.addingTimeInterval(-3600))
        try await record(store, "https://gamma.example/old", title: "Quarterly Archive", at: now.addingTimeInterval(-200_000))

        let byTitle = try await store.urlRows(matchingText: "quarterly", start: nil, end: nil, limit: 100)
        XCTAssertEqual(
            byTitle.map(\.url.absoluteString),
            ["https://alpha.example/page", "https://gamma.example/old"],
            "title matching is case-insensitive and ordered most recent first"
        )

        let byURL = try await store.urlRows(matchingText: "beta.example", start: nil, end: nil, limit: 100)
        XCTAssertEqual(byURL.map(\.url.absoluteString), ["https://beta.example/other"], "the URL is searchable too")

        let everyTerm = try await store.urlRows(matchingText: "quarterly archive", start: nil, end: nil, limit: 100)
        XCTAssertEqual(
            everyTerm.map(\.url.absoluteString), ["https://gamma.example/old"],
            "terms are ANDed; matching any one of them would return both rows"
        )

        let windowed = try await store.urlRows(
            matchingText: "quarterly", start: now.addingTimeInterval(-86_400), end: nil, limit: 100
        )
        XCTAssertEqual(
            windowed.map(\.url.absoluteString), ["https://alpha.example/page"],
            "startTime must exclude the older visit; a search that ignores it is not filtering"
        )

        let closed = try await store.urlRows(
            matchingText: "", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-1800), limit: 100
        )
        XCTAssertEqual(Set(closed.map(\.url.absoluteString)), ["https://alpha.example/page", "https://beta.example/other"])

        let capped = try await store.urlRows(matchingText: "", start: nil, end: nil, limit: 1)
        XCTAssertEqual(capped.count, 1, "maxResults has to bound the result set")
    }

    func test_searchRangeIsAboutVisitsNotTheUrlsLastVisitTime() async throws {
        let store = try makeStore()
        let now = Date()
        let url = "https://a.example/one"
        try await record(store, url, title: "Alpha", at: now.addingTimeInterval(-200_000))
        try await record(store, url, title: "Alpha", at: now)

        let old = try await store.urlRows(
            matchingText: "alpha",
            start: now.addingTimeInterval(-210_000),
            end: now.addingTimeInterval(-190_000),
            limit: 100
        )
        XCTAssertEqual(
            old.count, 1,
            "the URL has a visit inside that window even though its last visit is now; filtering on last_visit_time alone would miss it"
        )
        XCTAssertEqual(
            old.first?.lastVisit.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001,
            "the reported lastVisitTime is the row's own, as upstream's GetHistoryItem reads it"
        )
    }

    // MARK: - deleteVisits(in:)

    func test_deleteRangeSparesAUrlWhoseVisitsStraddleTheRange() async throws {
        let store = try makeStore()
        let now = Date()
        let inside = try XCTUnwrap(URL(string: "https://inside.example/x"))
        let straddling = try XCTUnwrap(URL(string: "https://straddling.example/y"))
        let untouched = try XCTUnwrap(URL(string: "https://untouched.example/z"))

        try await record(store, inside.absoluteString, at: now.addingTimeInterval(-7200))
        try await record(store, straddling.absoluteString, at: now.addingTimeInterval(-7200), typed: true)
        try await record(store, straddling.absoluteString, at: now.addingTimeInterval(-36_000))
        try await record(store, untouched.absoluteString, at: now.addingTimeInterval(-200_000))

        let purged = try await store.deleteVisits(
            in: now.addingTimeInterval(-3 * 3600)...now.addingTimeInterval(-3600)
        )
        XCTAssertEqual(
            purged, [inside],
            "only a URL whose every visit fell inside the range is purged, and it must be reported for onVisitRemoved"
        )

        let insideRow = try await store.urlRow(forURL: inside)
        XCTAssertNil(insideRow)
        let straddlingRow = try await store.urlRow(forURL: straddling)
        let survivor = try XCTUnwrap(
            straddlingRow,
            "a URL with a visit outside the range must survive; deleteRange is not clear(since:)"
        )
        XCTAssertEqual(survivor.visitCount, 1, "the in-range visit goes and the out-of-range one stays")
        XCTAssertEqual(survivor.typedCount, 0, "typed_count is recomputed from the surviving visits")

        let remaining = try await store.visitRows(forURL: straddling)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertLessThan(try XCTUnwrap(remaining.first).visitTime, now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(
            survivor.lastVisit.timeIntervalSince1970,
            try XCTUnwrap(remaining.first).visitTime.timeIntervalSince1970,
            accuracy: 0.001,
            "last_visit_time has to fall back to the newest surviving visit"
        )

        let untouchedRow = try await store.urlRow(forURL: untouched)
        XCTAssertNotNil(untouchedRow, "a URL entirely outside the range is untouched")
        let orphaned = try await store.visitRows(forURL: inside).count
        XCTAssertEqual(orphaned, 0, "no orphaned visits are left behind")
    }

    func test_deleteRangeOverAnEmptyWindowRemovesNothing() async throws {
        let store = try makeStore()
        let now = Date()
        try await record(store, "https://a.example/one", at: now)

        let purged = try await store.deleteVisits(
            in: now.addingTimeInterval(-200_000)...now.addingTimeInterval(-190_000)
        )
        XCTAssertEqual(purged, [], "a range containing no visits removes nothing and reports nothing")
        let survivingURL = try XCTUnwrap(URL(string: "https://a.example/one"))
        let survivingRow = try await store.urlRow(forURL: survivingURL)
        XCTAssertNotNil(survivingRow)
    }

}
