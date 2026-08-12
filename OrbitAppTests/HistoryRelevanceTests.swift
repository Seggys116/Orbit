import XCTest
@testable import Orbit

final class HistoryRelevanceTests: XCTestCase {

    private let profileID = ProfileID()

    private func entry(_ title: String, _ url: String, minutesAgo: Double = 1, visits: Int = 1) -> HistoryEntry {
        HistoryEntry(
            url: URL(string: url)!,
            title: title,
            visitedAt: Date().addingTimeInterval(-minutesAgo * 60),
            visitCount: visits,
            profileID: profileID
        )
    }

    func test_anIndexedEntryThatDoesNotContainTheQueryIsDropped() {
        let stale = entry("Q4 Roadmap — Figma", "https://www.figma.com/file/abc123/Q4-Roadmap")
        let blended = AppEnvironment.blendHistory(indexed: [stale], cached: [], matching: "wikipedia", limit: 40)
        XCTAssertTrue(
            blended.isEmpty,
            "The index returned a row whose current title and URL contain \"wikipedia\" nowhere; it must not be passed on. Got: \(blended.map(\.title))"
        )
    }

    func test_anIndexedEntryThatDoesContainTheQueryIsKept() {
        let real = entry("Orbital mechanics — Wikipedia", "https://en.wikipedia.org/wiki/Orbital_mechanics")
        let blended = AppEnvironment.blendHistory(indexed: [real], cached: [], matching: "wikipedia", limit: 40)
        XCTAssertEqual(blended.map(\.url), [real.url])
    }

    func test_aWordPrefixHitFromTheIndexSurvivesTheFilter() {
        let real = entry("Swift Concurrency Guide", "https://swift.org/concurrency")
        let blended = AppEnvironment.blendHistory(indexed: [real], cached: [], matching: "concur", limit: 40)
        XCTAssertEqual(blended.map(\.url), [real.url], "A prefix of a word in the title is exactly what FTS5's `\"concur\"*` matches.")
    }

    func test_everyTermMustBePresent() {
        let real = entry("Swift Concurrency Guide", "https://swift.org/concurrency")
        XCTAssertEqual(AppEnvironment.blendHistory(indexed: [real], cached: [], matching: "swift guide", limit: 40).count, 1)
        XCTAssertTrue(
            AppEnvironment.blendHistory(indexed: [real], cached: [], matching: "swift kubernetes", limit: 40).isEmpty,
            "AND across terms, for the indexed source as well as the cached one."
        )
    }

    func test_theTwoSourcesAreDeduplicatedByDestination() {
        let fromIndex = entry("Orbital mechanics — Wikipedia", "https://en.wikipedia.org/wiki/Orbital_mechanics")
        let sameFromCache = entry("Orbital mechanics — Wikipedia", "https://en.wikipedia.org/wiki/Orbital_mechanics")
        let blended = AppEnvironment.blendHistory(indexed: [fromIndex], cached: [sameFromCache], matching: "wikipedia", limit: 40)
        XCTAssertEqual(blended.count, 1, "One destination, one row.")
    }

    func test_theLimitIsHonoured() {
        let entries = (1...20).map { entry("Wikipedia — Article \($0)", "https://en.wikipedia.org/wiki/Article_\($0)") }
        XCTAssertEqual(AppEnvironment.blendHistory(indexed: entries, cached: [], matching: "wikipedia", limit: 5).count, 5)
    }

    func test_anEmptyQueryFiltersNothing() {
        let entries = [entry("Q4 Roadmap — Figma", "https://www.figma.com/file/abc123/Q4-Roadmap"), entry("Gmail", "https://mail.google.com/")]
        XCTAssertEqual(AppEnvironment.blendHistory(indexed: [], cached: entries, matching: "", limit: 40).count, 2)
    }
}
