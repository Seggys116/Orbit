import XCTest
@testable import Orbit

/// Pure tests of `NewTabPageModel.siteTiles`: no window, no view, no app activation.
final class NewTabPageSiteTilesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let profileID = UUID()

    private func entry(_ urlString: String, visits: Int = 1, minutesAgo: Double = 0, typed: Bool = false) -> HistoryEntry {
        HistoryEntry(
            url: URL(string: urlString)!,
            title: "A page title that must never be shown",
            visitedAt: now.addingTimeInterval(-minutesAgo * 60),
            visitCount: visits,
            profileID: profileID,
            wasTyped: typed
        )
    }

    private func tiles(_ entries: [HistoryEntry], limit: Int = 6) -> [NewTabPageModel.SiteTile] {
        NewTabPageModel.siteTiles(from: entries, limit: limit, now: now)
    }

    func test_deepURLsCollapseToTheOriginRoot_withTheHostAsTitleAndSubtitle() {
        let result = tiles([
            entry("https://github.com/zak/orbit/pull/12?tab=files#diff", minutesAgo: 1),
            entry("https://github.com/zak", minutesAgo: 2),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.url.absoluteString, "https://github.com")
        XCTAssertEqual(result.first?.title, "github.com")
        XCTAssertEqual(result.first?.subtitle, "github.com")
    }

    func test_aSiteWithOnlyDeepPagesAppearsOnceAsItsRoot_andShowsNoPageTitle() {
        let result = tiles([entry("https://docs.example.com/a/very/deep/page.html")])

        XCTAssertEqual(result.map(\.url.absoluteString), ["https://docs.example.com"])
        XCTAssertEqual(result.map(\.title), ["docs.example.com"])
        XCTAssertFalse(result.contains { $0.title.contains("page title") || $0.subtitle.contains("page title") })
    }

    func test_wwwIsNotShown_butTheRootKeepsTheVisitedHost() {
        let result = tiles([entry("https://www.example.com/about")])

        XCTAssertEqual(result.map(\.title), ["example.com"])
        XCTAssertEqual(result.map(\.url.absoluteString), ["https://www.example.com"])
    }

    func test_twoLocalhostPortsStaySeparate_andAreLabelledWithTheirPort() {
        let result = tiles([
            entry("http://localhost:3000/dashboard", minutesAgo: 1),
            entry("http://localhost:8080/", minutesAgo: 2),
            entry("http://localhost:3000/login", minutesAgo: 3),
        ])

        XCTAssertEqual(result.map(\.title), ["localhost:3000", "localhost:8080"])
        XCTAssertEqual(result.map(\.subtitle), ["localhost:3000", "localhost:8080"])
        XCTAssertEqual(result.map(\.url.absoluteString), ["http://localhost:3000", "http://localhost:8080"])
    }

    func test_defaultPortsAreNeverShownOrKept() {
        let result = tiles([
            entry("https://secure.example.com:443/x", minutesAgo: 1),
            entry("http://plain.example.org:80/y", minutesAgo: 2),
        ])

        XCTAssertEqual(result.map(\.title), ["secure.example.com", "plain.example.org"])
        XCTAssertEqual(result.map(\.url.absoluteString), ["https://secure.example.com", "http://plain.example.org"])
    }

    func test_aNonDefaultPortIsKeptEvenWhenItIsTheOtherSchemesDefault() {
        let result = tiles([
            entry("https://example.com:8443/admin", minutesAgo: 1),
            entry("https://example.net:80/", minutesAgo: 2),
        ])

        XCTAssertEqual(result.map(\.title), ["example.com:8443", "example.net:80"])
        XCTAssertEqual(result.map(\.url.absoluteString), ["https://example.com:8443", "https://example.net:80"])
    }

    func test_theSameSiteVisitedOverSeveralSchemesAndSpellingsIsOneTile() {
        let result = tiles([
            entry("http://example.com/old", minutesAgo: 60),
            entry("https://www.example.com/new", minutesAgo: 1),
            entry("https://example.com/new", minutesAgo: 30),
            entry("https://example.com/new", minutesAgo: 30),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "example.com")
        XCTAssertEqual(result.first?.url.absoluteString, "https://www.example.com", "The root follows the newest visit.")
    }

    func test_recentAndFrequentSitesAreBothRepresented() {
        var entries: [HistoryEntry] = []
        for index in 0..<6 {
            entries.append(entry("https://recent\(index).example.com/page", visits: 1, minutesAgo: Double(index + 1)))
        }
        entries.append(entry("https://often-a.example.com/home", visits: 500, minutesAgo: 30 * 24 * 60))
        entries.append(entry("https://often-b.example.com/home", visits: 200, minutesAgo: 20 * 24 * 60))

        let result = tiles(entries, limit: 4)

        XCTAssertEqual(
            result.map(\.title),
            ["recent0.example.com", "often-a.example.com", "recent1.example.com", "often-b.example.com"],
            "Newest and most frequent sites alternate."
        )
    }

    func test_aSiteThatIsBothNewestAndMostFrequentTakesOneSlot() {
        let result = tiles([
            entry("https://top.example.com/", visits: 900, minutesAgo: 1),
            entry("https://second.example.com/", visits: 1, minutesAgo: 2),
            entry("https://third.example.com/", visits: 1, minutesAgo: 3),
        ], limit: 3)

        XCTAssertEqual(result.map(\.title), ["top.example.com", "second.example.com", "third.example.com"])
        XCTAssertEqual(Set(result.map(\.url)).count, 3)
    }

    func test_visitsToDifferentPagesOfOneSiteAddUpToItsFrequency() {
        var entries = (0..<5).map { entry("https://busy.example.com/p\($0)", visits: 3, minutesAgo: 10_000) }
        entries.append(entry("https://lone.example.com/p", visits: 5, minutesAgo: 10_000))
        entries.append(entry("https://fresh.example.com/", visits: 1, minutesAgo: 1))

        let result = tiles(entries, limit: 2)

        XCTAssertEqual(result.map(\.title), ["fresh.example.com", "busy.example.com"])
    }

    func test_theLimitIsRespected_andFewerSitesReturnEverything() {
        let many = (0..<10).map { entry("https://site\($0).example.com/", minutesAgo: Double($0)) }

        XCTAssertEqual(tiles(many, limit: 6).count, 6)
        XCTAssertEqual(tiles(many, limit: 3).count, 3)
        XCTAssertEqual(tiles(many, limit: 0).count, 0)
        XCTAssertEqual(tiles(Array(many.prefix(2)), limit: 6).count, 2)
        XCTAssertEqual(NewTabPageModel.siteTiles(from: many, now: now).count, NewTabPageModel.maximumRecents)
    }

    func test_nonWebURLsAreIgnored() {
        let result = tiles([
            entry("about:blank"),
            entry("orbit://new-tab"),
            entry("file:///Users/me/notes.html"),
            entry("view-source:https://example.com/"),
            entry("https://example.com/real", minutesAgo: 5),
        ])

        XCTAssertEqual(result.map(\.title), ["example.com"])
    }

    func test_noHistoryYieldsNoTiles() {
        XCTAssertTrue(tiles([]).isEmpty)
    }
}
