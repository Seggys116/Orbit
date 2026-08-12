//  A multi-word query once only worked for URLs (whole-string/substring/phrase-only
//  matching). Assertions are relationships, not absolute scores, so they survive re-tuning.

import XCTest
import SwiftUI
@testable import Orbit

@MainActor
final class CommandBarQueryTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var spaceID: SpaceID!
    private var profileID: ProfileID!

    override func setUp() {
        super.setUp()
        profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Query",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
        env.state.activeSpaceID = spaceID
    }

    private func results(_ query: String, suggestions: [String] = []) -> [CommandResult] {
        CommandBarEngine.results(
            query: query,
            mode: .newTab,
            env: env,
            suggestions: suggestions,
            searchEngine: env.searchEngine,
            siteSearch: env.siteSearchStore.state(active: nil)
        )
    }

    private func describe(_ results: [CommandResult]) -> String {
        results.map { "  [\(String(format: "%.1f", $0.score))] \($0.id) — \($0.title)" }.joined(separator: "\n")
    }

    @discardableResult
    private func recordVisit(url: URL, title: String, wasTyped: Bool = false, timeout: TimeInterval = 5) async -> Bool {
        env.recordVisit(url: url, title: title, profileID: profileID, spaceID: spaceID, wasTyped: wasTyped)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if env.localHistoryCache.contains(where: { $0.url == url }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("History never recorded \(url) — the store did not answer within \(timeout)s, so any history assertion below would be vacuous.")
        return false
    }

    // MARK: - 1. The matcher: a query is a set of terms, not one string

    func test_matcher_multiWordQueryMatchesTermsInAnyOrder() {
        let title = "PR #482 — anthropic-sdk-python: streaming tool use"

        XCTAssertNotNil(FuzzyMatcher.match(pattern: "anthropic streaming", in: title))
        XCTAssertNil(
            FuzzyMatcher.match(pattern: "streaming anthropic", in: title),
            "Precondition for the assertion below: the whole-string matcher is order-sensitive."
        )

        XCTAssertNotNil(FuzzyMatcher.matchQuery("anthropic streaming", in: [title]))
        XCTAssertNotNil(
            FuzzyMatcher.matchQuery("streaming anthropic", in: [title]),
            "A browser does not require you to recall a page title's word order."
        )
    }

    func test_matcher_termsMayMatchAcrossDifferentFields() {
        let title = "Pull Requests"
        let url = "https://github.com/anthropics/orbit/pulls"
        let fields = [title, url, "github.com"]

        XCTAssertNil(FuzzyMatcher.match(pattern: "github pulls", in: title), "Precondition: neither field alone contains the query…")
        XCTAssertNil(FuzzyMatcher.match(pattern: "github pulls", in: url), "…in the typed order, which is what the old rule required.")

        XCTAssertNotNil(FuzzyMatcher.matchQuery("github pulls", in: fields))
        XCTAssertNotNil(FuzzyMatcher.matchQuery("orbit requests", in: fields))
    }

    func test_matcher_everyTermMustMatchSomething() {
        let fields = ["Swift Concurrency Guide", "https://swift.org/concurrency"]
        XCTAssertNotNil(FuzzyMatcher.matchQuery("swift concurrency", in: fields))
        XCTAssertNil(
            FuzzyMatcher.matchQuery("swift concurrency kubernetes", in: fields),
            "\"kubernetes\" appears nowhere; the candidate must not match on a two-of-three."
        )
    }

    func test_matcher_scoreDoesNotInflateWithTermCount() {
        let fields = ["alpha beta gamma delta", "https://example.com/alpha/beta/gamma/delta"]
        let one = FuzzyMatcher.matchQuery("alpha", in: fields) ?? 0
        let four = FuzzyMatcher.matchQuery("alpha beta gamma delta", in: fields) ?? 0
        XCTAssertLessThan(
            four, one * 2.5,
            "A four-word query scored \(four) against a one-word query's \(one) — scores are summing, which would swamp the source offsets."
        )
    }

    // MARK: - 2. End to end: a general query returns the user's own content

    func test_generalQueryReturnsOwnedContent_notOnlyTheSearchFallback() {
        let tabID = env.openTab(url: URL(string: "https://github.com/anthropics/anthropic-sdk-python/pull/482")!, in: spaceID)
        env.renameTab(tabID, to: "PR #482 — anthropic-sdk-python: streaming tool use")

        let rows = results("anthropic streaming")
        XCTAssertGreaterThan(
            rows.count, 1,
            "A general query still returns only the generic search row:\n\(describe(rows))"
        )

        guard let tabRow = rows.first(where: { if case .openTab = $0.kind { return true } else { return false } }) else {
            return XCTFail("The open tab whose title contains both typed words was not offered at all:\n\(describe(rows))")
        }
        let searchRow = rows.first { if case .searchSuggestion = $0.kind { return true } else { return false } }
        XCTAssertNotNil(searchRow, "The literal search row must still be offered — it is the fallback, not the only option.")
        XCTAssertGreaterThan(
            tabRow.score, searchRow?.score ?? 0,
            "A page you have open that matches both words should outrank \"search the web for this\"."
        )
    }

    func test_generalQueryFindsHistoryByTermsNotBySubstring() async {
        let url = URL(string: "https://www.swift.org/documentation/concurrency/")!
        guard await recordVisit(url: url, title: "Swift Concurrency: The Complete Guide") else { return }

        let entries = env.historyResults(matching: "swift guide")
        XCTAssertTrue(
            entries.contains { $0.url == url },
            "A two-word query did not find a visited page whose title contains both words. Got: \(entries.map(\.title))"
        )

        let rows = results("swift guide")
        XCTAssertTrue(
            rows.contains { if case .history = $0.kind { return true } else { return false } },
            "The history entry never reached the result list:\n\(describe(rows))"
        )
    }

    func test_indexBackedSearchFindsMultiWordQueriesThroughTheRealStore() async {
        let url = URL(string: "https://example.com/reports/quarterly")!
        guard await recordVisit(url: url, title: "Quarterly Revenue Report") else { return }

        await env.prepareHistorySearch(for: "quarterly report")
        XCTAssertTrue(
            env.historySearchResults.contains { $0.url == url },
            """
            The real HistoryStore search found nothing for a two-word query whose \
            terms are both in the title but not adjacent. Got: \
            \(env.historySearchResults.map(\.title)).
            """
        )
    }

    // MARK: - 3. Ranking behaves the way a browser's omnibox does

    func test_ownedContentOutranksNetworkSuggestions() {
        let tabID = env.openTab(url: URL(string: "https://example.com/swift-concurrency")!, in: spaceID)
        env.renameTab(tabID, to: "Swift Concurrency Notes")

        let rows = results("swift concurrency", suggestions: ["swift concurrency book", "swift concurrency course"])
        guard let tabRow = rows.first(where: { if case .openTab = $0.kind { return true } else { return false } }),
              let suggestionRow = rows.first(where: { $0.id.hasPrefix("suggest-") })
        else {
            return XCTFail("Expected both an open-tab row and a suggestion row:\n\(describe(rows))")
        }
        XCTAssertGreaterThan(tabRow.score, suggestionRow.score, "A page you have open must outrank a fetched suggestion.")
    }

    func test_historyIsOrderedByFrecencyNotJustTextMatch() {
        let profile = profileID!
        let heavy = HistoryEntry(
            url: URL(string: "https://example.com/daily")!, title: "Example Report",
            visitedAt: Date(), visitCount: 40, profileID: profile, wasTyped: true
        )
        let stale = HistoryEntry(
            url: URL(string: "https://example.com/once")!, title: "Example Report",
            visitedAt: Date().addingTimeInterval(-60 * 86_400), visitCount: 1, profileID: profile, wasTyped: false
        )

        XCTAssertGreaterThan(
            CommandBarEngine.frecencyBoost(for: heavy),
            CommandBarEngine.frecencyBoost(for: stale),
            "A page visited 40 times today must rank above one visited once two months ago when the text match is identical."
        )
    }

    func test_oneDestinationProducesOneRow() async {
        let url = URL(string: "https://github.com/anthropics/orbit")!
        let tabID = env.openTab(url: url, in: spaceID)
        env.renameTab(tabID, to: "Orbit Repository")
        guard await recordVisit(url: url, title: "Orbit Repository") else { return }

        let rows = results("orbit repository")
        let destinations = rows.filter {
            switch $0.kind {
            case .openTab, .favorite, .history: return true
            default: return false
            }
        }
        let keys = destinations.compactMap { row -> String? in
            switch row.kind {
            case .openTab(let id): return env.tab(id).map { CommandBarEngine.dedupeKey(for: $0.url) }
            case .favorite(let favorite): return CommandBarEngine.dedupeKey(for: favorite.url)
            case .history(let entry): return CommandBarEngine.dedupeKey(for: entry.url)
            default: return nil
            }
        }
        XCTAssertEqual(
            keys.count, Set(keys).count,
            "The same destination is offered more than once:\n\(describe(rows))"
        )
        XCTAssertTrue(
            destinations.contains { if case .openTab = $0.kind { return true } else { return false } },
            "When one row survives de-duplication it must be the open tab — switching to it beats re-navigating."
        )
    }

    func test_suggestionsAreDedupedAgainstWhatIsAlreadyOffered() {
        let rows = results("weather", suggestions: ["weather", "weather tomorrow"])
        let weatherRows = rows.filter { $0.title.lowercased() == "weather" }
        XCTAssertEqual(weatherRows.count, 1, "The typed query and the echoed suggestion produced two identical rows:\n\(describe(rows))")
        XCTAssertTrue(rows.contains { $0.title == "weather tomorrow" }, "A genuinely new suggestion must still be offered.")
    }

    // MARK: - 4. The store's own query, which is where two of the three bugs were

    func test_historyStore_ftsExpressionRequiresEveryTermNotThePhrase() {
        let expression = HistoryStore.ftsMatchExpression(for: "anthropic streaming")
        XCTAssertTrue(expression.contains("AND"), "Terms must be ANDed, not phrase-matched: \(expression)")
        XCTAssertTrue(expression.contains("\"anthropic\"*"), "Each term must be its own quoted prefix token: \(expression)")
        XCTAssertTrue(expression.contains("\"streaming\"*"), "Each term must be its own quoted prefix token: \(expression)")
        XCTAssertFalse(
            expression.contains("\"anthropic streaming\""),
            "The whole query must not be one quoted phrase — that is the original defect: \(expression)"
        )
    }

    func test_historyStore_ftsExpressionStillQuotesURLPunctuation() {
        let expression = HistoryStore.ftsMatchExpression(for: "https://github.com/anthropics")
        XCTAssertEqual(expression, "\"https://github.com/anthropics\"*", "A single term with punctuation must stay one quoted token: \(expression)")
    }

    func test_historyResults_matchesEveryTermAnywhere() {
        let entry = HistoryEntry(
            url: URL(string: "https://www.swift.org/documentation/concurrency/")!,
            title: "Swift Concurrency: The Complete Guide",
            profileID: profileID
        )
        XCTAssertTrue(AppEnvironment.historyEntryMatches(entry, terms: ["swift", "guide"]))
        XCTAssertTrue(AppEnvironment.historyEntryMatches(entry, terms: ["guide", "swift"]), "Order must not matter.")
        XCTAssertTrue(AppEnvironment.historyEntryMatches(entry, terms: ["concurrency", "documentation"]), "One term in the title, one in the URL.")
        XCTAssertFalse(AppEnvironment.historyEntryMatches(entry, terms: ["swift", "kubernetes"]), "Every term must be present.")
    }
}
