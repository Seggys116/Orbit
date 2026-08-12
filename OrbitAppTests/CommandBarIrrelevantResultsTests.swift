import XCTest
import SwiftUI
@testable import Orbit

@MainActor
final class CommandBarIrrelevantResultsTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var spaceID: SpaceID!
    private var profileID: ProfileID!

    override func setUp() {
        super.setUp()
        profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Relevance",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
        env.state.activeSpaceID = spaceID
        // Clears the Wikipedia favourite/tab AppEnvironment.demo seeds by default.
        env.state.tabs = [:]
        for index in env.state.spaces.indices {
            env.state.spaces[index].favorites = []
        }
    }

    @discardableResult
    private func recordVisit(url: URL, title: String, timeout: TimeInterval = 5) async -> Bool {
        env.recordVisit(url: url, title: title, profileID: profileID, spaceID: spaceID, wasTyped: false)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if env.localHistoryCache.contains(where: { $0.url == url && $0.title == title }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("History never recorded \(title) — any assertion below would be vacuous.")
        return false
    }

    private func results(_ query: String) -> [CommandResult] {
        CommandBarEngine.results(
            query: query,
            mode: .newTab,
            env: env,
            suggestions: [],
            searchEngine: env.searchEngine,
            siteSearch: env.siteSearchStore.state(active: nil)
        )
    }

    private func describe(_ results: [CommandResult]) -> String {
        results.map { "  [\(String(format: "%.1f", $0.score))] \($0.id) — \($0.title)" }.joined(separator: "\n")
    }

    func test_typedTermWithNoMatchAnywhereOffersTheSearchRowFirstAndNothingElseAboveIt() async {
        guard await recordVisit(url: URL(string: "https://www.figma.com/file/abc123/Q4-Roadmap")!, title: "Q4 Roadmap — Figma") else { return }
        guard await recordVisit(url: URL(string: "https://mail.google.com/mail/u/0/")!, title: "Gmail") else { return }
        guard await recordVisit(url: URL(string: "https://linear.app/orbit/cycle/42")!, title: "2024-Q4 cycle — Linear") else { return }

        await env.prepareHistorySearch(for: "wikipedia")
        let rows = results("wikipedia ")

        guard case .searchSuggestion(let text) = rows.first?.kind, text == "wikipedia" else {
            return XCTFail("""
            The top row for a term matching nothing the user owns must be "search for what I typed". Got:
            \(describe(rows))
            """)
        }

        let irrelevant = rows.filter { row in
            switch row.kind {
            case .history(let entry): return !entry.title.lowercased().contains("wikipedia") && !entry.url.absoluteString.lowercased().contains("wikipedia")
            case .openTab(let id): return !(env.tab(id).map { $0.displayTitle.lowercased().contains("wikipedia") || $0.url.absoluteString.lowercased().contains("wikipedia") } ?? false)
            default: return false
            }
        }
        XCTAssertTrue(irrelevant.isEmpty, "Rows with no textual relevance to \"wikipedia\" were offered:\n\(describe(irrelevant))")
    }

    /// `history_fts` is an external-content FTS5 table, so a MATCH can return
    /// a rowid whose current title/URL (read back from `urls`) no longer
    /// contain the tokens that were indexed under an old title.
    func test_aPageRetitledAfterIndexingIsNotReturnedForItsOldTitle() async {
        let url = URL(string: "https://www.figma.com/file/xyz789/Roadmap")!
        guard await recordVisit(url: url, title: "Wikipedia — Main Page") else { return }
        guard await recordVisit(url: url, title: "Q4 Roadmap — Figma") else { return }

        await env.prepareHistorySearch(for: "wikipedia")
        XCTAssertFalse(
            env.historySearchResults.contains { $0.url == url },
            """
            The history index returned a page whose current title and URL contain "wikipedia" nowhere \
            — it only ever did under a title it no longer has. Got: \(env.historySearchResults.map(\.title))
            """
        )

        let rows = results("wikipedia")
        XCTAssertFalse(
            rows.contains { if case .history(let entry) = $0.kind { return entry.url == url }; return false },
            "The stale-index row reached the Command Bar:\n\(describe(rows))"
        )
    }

    func test_aVeryRecentIrrelevantPageDoesNotOutrankTheSearchRow() async {
        let url = URL(string: "https://www.figma.com/file/def456/Board")!
        guard await recordVisit(url: url, title: "Wikipedia — Main Page") else { return }
        guard await recordVisit(url: url, title: "Q4 Roadmap — Figma") else { return }
        for _ in 0..<5 {
            env.recordVisit(url: url, title: "Q4 Roadmap — Figma", profileID: profileID, spaceID: spaceID, wasTyped: true)
        }

        await env.prepareHistorySearch(for: "wikipedia")
        let rows = results("wikipedia")
        guard case .searchSuggestion = rows.first?.kind else {
            return XCTFail("A page visited seconds ago outranked the search row for a term it does not contain:\n\(describe(rows))")
        }
    }

    func test_matchingHistoryIsStillOffered() async {
        let url = URL(string: "https://en.wikipedia.org/wiki/Orbital_mechanics")!
        guard await recordVisit(url: url, title: "Orbital mechanics — Wikipedia") else { return }

        await env.prepareHistorySearch(for: "wikipedia")
        let rows = results("wikipedia")
        XCTAssertTrue(
            rows.contains { if case .history(let entry) = $0.kind { return entry.url == url }; return false },
            "A page whose title and URL both contain the typed term must still be offered:\n\(describe(rows))"
        )
    }
}
