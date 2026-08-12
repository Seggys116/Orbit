import XCTest
import SwiftUI

@MainActor
final class CommandBarRankingTests: XCTestCase {

    // MARK: - 1. FuzzyMatcher ranking on realistic inputs

    func test_fuzzyMatcher_exactPrefixOutranksMidStringSubstring() {
        let prefixScore = try! XCTUnwrap(FuzzyMatcher.match(pattern: "git", in: "GitHub"))
        let midWordScore = try! XCTUnwrap(FuzzyMatcher.match(pattern: "git", in: "My Legitimate Site"))
        XCTAssertGreaterThan(
            prefixScore, midWordScore,
            "A prefix, word-boundary match for \"git\" should outscore the same letters buried inside \"Legitimate\"."
        )
    }

    func test_fuzzyMatcher_consecutiveRunOutranksScatteredSubsequence() {
        let consecutive = try! XCTUnwrap(FuzzyMatcher.match(pattern: "abc", in: "abcdef"))
        let scattered = try! XCTUnwrap(FuzzyMatcher.match(pattern: "abc", in: "aXbYcZ"))
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func test_fuzzyMatcher_shorterHaystackOutranksLongerForSamePattern() {
        let short = try! XCTUnwrap(FuzzyMatcher.match(pattern: "orbit", in: "Orbit"))
        let long = try! XCTUnwrap(FuzzyMatcher.match(pattern: "orbit", in: "Orbit — A Very Long Page Title About Many Other Things Too"))
        XCTAssertGreaterThan(short, long)
    }

    func test_fuzzyMatcher_nonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatcher.match(pattern: "xyz", in: "abcdef"), "\"xyz\" is not a subsequence of \"abcdef\" and must not match.")
    }

    func test_fuzzyMatcher_caseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.match(pattern: "GIT", in: "github.com"))
        XCTAssertNotNil(FuzzyMatcher.match(pattern: "git", in: "GITHUB.COM"))
    }

    // MARK: - 2. Typed-URL vs search-query detection

    func test_detectTypedURL_bareDomainDetectedAsURL() {
        XCTAssertEqual(CommandBarEngine.detectTypedURL("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(CommandBarEngine.detectTypedURL("sub.example.co.uk/path")?.absoluteString, "https://sub.example.co.uk/path")
    }

    func test_detectTypedURL_fullySchemedURLDetectedAsURL() {
        XCTAssertEqual(CommandBarEngine.detectTypedURL("https://www.google.com")?.absoluteString, "https://www.google.com")
        XCTAssertEqual(CommandBarEngine.detectTypedURL("file:///Users/me/file.txt")?.scheme, "file")
    }

    func test_detectTypedURL_localhostWithPortDetectedAsURL() {
        XCTAssertEqual(CommandBarEngine.detectTypedURL("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(CommandBarEngine.detectTypedURL("localhost")?.absoluteString, "http://localhost")
    }

    func test_detectTypedURL_plainSearchPhraseIsNotAURL() {
        XCTAssertNil(CommandBarEngine.detectTypedURL("how to make pasta"), "A multi-word phrase with spaces must never be detected as a typed URL.")
        XCTAssertNil(CommandBarEngine.detectTypedURL("weather"), "A bare word with no dot and not \"localhost\" must not be detected as a typed URL.")
    }

    func test_results_typedDomainProducesTypedURLResultAheadOfEverythingElse() {
        let env = AppEnvironment()
        env.state.profiles = [Profile(name: "Personal")]
        let space = Space(name: "Personal", profileID: env.state.profiles[0].id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let results = CommandBarEngine.results(query: "example.com", mode: .newTab, env: env, suggestions: [])
        guard case .typedURL(let url) = results.first?.kind else {
            XCTFail("Expected the top result for \"example.com\" to be a typedURL kind, got \(String(describing: results.first?.kind)).")
            return
        }
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func test_results_plainWordProducesSearchSuggestionNotTypedURL() {
        let env = AppEnvironment()
        env.state.profiles = [Profile(name: "Personal")]
        let space = Space(name: "Personal", profileID: env.state.profiles[0].id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let results = CommandBarEngine.results(query: "recipes", mode: .newTab, env: env, suggestions: [])
        guard case .searchSuggestion(let text) = results.first?.kind else {
            XCTFail("Expected the top result for a plain word with no matching tab/history/favourite to be a searchSuggestion kind, got \(String(describing: results.first?.kind)).")
            return
        }
        XCTAssertEqual(text, "recipes")
    }

    // MARK: - 3. Selecting an open tab switches to it, never duplicates

    func test_activationIntent_openTabMapsToSwitchNeverNavigate() {
        let tabID = TabID()
        let intent = CommandResultKind.openTab(tabID).activationIntent
        guard case .switchToTab(let resolvedID) = intent else {
            XCTFail("CommandResultKind.openTab(_:).activationIntent must be .switchToTab, got \(intent) — this is exactly the regression spec §3.3 forbids (a duplicate new tab instead of switching).")
            return
        }
        XCTAssertEqual(resolvedID, tabID)
    }

    func test_activationIntent_pinnedTabAlsoMapsToSwitch() {
        let tabID = TabID()
        guard case .switchToTab(let resolvedID) = CommandResultKind.pinnedTab(tabID).activationIntent else {
            XCTFail("CommandResultKind.pinnedTab(_:).activationIntent must also be .switchToTab.")
            return
        }
        XCTAssertEqual(resolvedID, tabID)
    }

    func test_activationIntent_typedURLAndHistoryMapToNavigateNotSwitch() {
        let url = URL(string: "https://example.com")!
        guard case .navigate(let navigatedURL) = CommandResultKind.typedURL(url).activationIntent else {
            XCTFail("typedURL must map to .navigate.")
            return
        }
        XCTAssertEqual(navigatedURL, url)

        let entry = HistoryEntry(url: url, title: "Example", profileID: ProfileID())
        guard case .navigate(let historyURL) = CommandResultKind.history(entry).activationIntent else {
            XCTFail("history must map to .navigate, not .switchToTab — a history entry is not a live tab.")
            return
        }
        XCTAssertEqual(historyURL, url)
    }

    func test_results_matchingOpenTab_surfacesAsOpenTabKind_endToEnd() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let tab = Tab(spaceID: space.id, section: .today, url: URL(string: "https://github.com/pulls")!, title: "GitHub - Pull Requests")
        env.state.tabs[tab.id] = tab

        let results = CommandBarEngine.results(query: "github", mode: .newTab, env: env, suggestions: [])

        guard let tabResult = results.first(where: { result in
            if case .openTab(let id) = result.kind { return id == tab.id }
            return false
        }) else {
            XCTFail("Expected an .openTab result for the matching open tab; results were: \(results.map(\.title))")
            return
        }

        guard case .switchToTab(let resolvedID) = tabResult.kind.activationIntent else {
            XCTFail("The open-tab result's activationIntent must be .switchToTab.")
            return
        }
        XCTAssertEqual(resolvedID, tab.id, "Activating this result must switch to the existing tab, never open a duplicate.")

        XCTAssertEqual(results.first?.id, tabResult.id, "The matching open tab should be the top-ranked result for a query that matches its title as a prefix.")
    }

    func test_results_editURLMode_excludesTheTabBeingEdited() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let currentURL = URL(string: "https://github.com/pulls")!
        let tab = Tab(spaceID: space.id, section: .today, url: currentURL, title: "GitHub - Pull Requests")
        env.state.tabs[tab.id] = tab
        env.activeTabID = tab.id

        let results = CommandBarEngine.results(query: "github", mode: .editURL(currentURL), env: env, suggestions: [])
        let stillOffersSelfSwitch = results.contains { result in
            if case .openTab(let id) = result.kind { return id == tab.id }
            return false
        }
        XCTAssertFalse(stillOffersSelfSwitch, "In .editURL mode, the tab currently being edited must not appear as a \"switch to it\" result.")
    }

    func test_results_newTabMode_stillOffersAllOpenTabs() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let tab = Tab(spaceID: space.id, section: .today, url: URL(string: "https://github.com/pulls")!, title: "GitHub - Pull Requests")
        env.state.tabs[tab.id] = tab
        env.activeTabID = tab.id

        let results = CommandBarEngine.results(query: "github", mode: .newTab, env: env, suggestions: [])
        let offersSwitch = results.contains { result in
            if case .openTab(let id) = result.kind { return id == tab.id }
            return false
        }
        XCTAssertTrue(offersSwitch, "In .newTab mode (Cmd+T), even the active tab should still be offered as a switch-to-it result.")
    }

    // MARK: - Blending sanity: tabs/history/favourites/actions in one ranked list

    func test_results_blendsOpenTabsHistoryFavoritesAndActionsInOneList() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        var space = Space(name: "Personal", profileID: profile.id)
        space.favorites = [Favorite(url: URL(string: "https://gitea.example.com")!, title: "Gitea Self-Hosted")]
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let tab = Tab(spaceID: space.id, section: .today, url: URL(string: "https://github.com/pulls")!, title: "GitHub - Pull Requests")
        env.state.tabs[tab.id] = tab

        env.historyEntries = [
            HistoryEntry(url: URL(string: "https://github.com")!, title: "GitHub", visitedAt: Date().addingTimeInterval(-3600), profileID: profile.id),
        ]

        let results = CommandBarEngine.results(query: "git", mode: .newTab, env: env, suggestions: [])

        let kinds = results.map(\.kind)
        XCTAssertTrue(kinds.contains { if case .openTab = $0 { return true }; return false }, "Expected the open tab to appear in the blended list.")
        XCTAssertTrue(kinds.contains { if case .history = $0 { return true }; return false }, "Expected the history entry to appear in the blended list.")
        XCTAssertTrue(kinds.contains { if case .favorite = $0 { return true }; return false }, "Expected the favourite (\"Gitea\") to appear in the blended list.")
        XCTAssertTrue(kinds.contains { if case .searchSuggestion = $0 { return true }; return false }, "Expected the literal \"search Google for git\" fallback to still be offered.")

        let tabIndex = results.firstIndex { if case .openTab = $0.kind { return true }; return false }
        let historyIndex = results.firstIndex { if case .history = $0.kind { return true }; return false }
        XCTAssertNotNil(tabIndex)
        XCTAssertNotNil(historyIndex)
        if let tabIndex, let historyIndex {
            XCTAssertLessThan(tabIndex, historyIndex, "An open tab should rank above the equivalent history entry (spec §3.3).")
        }
    }

    // MARK: - Relevance: a subsequence in a long URL is not a match

    func test_matcher_substringStrictnessRejectsAScatteredSubsequenceInALongURL() {
        let url = "https://www.youtube.com/watch?v=xKiwqxlWkQI"

        XCTAssertNotNil(
            FuzzyMatcher.matchQuery("wiki", in: [url], strictness: .subsequence),
            "Precondition: w-i-k-i really can be threaded through this URL's characters, which is the whole defect."
        )
        XCTAssertNil(
            FuzzyMatcher.matchQuery("wiki", in: [url], strictness: .substring),
            "\"wiki\" appears nowhere in this URL as text; a page like this must not be offered for that query."
        )
    }

    func test_matcher_substringStrictnessStillMatchesRealContent() {
        let fields = ["Wikipedia, the free encyclopedia", "https://en.wikipedia.org/wiki/Main_Page", "wikipedia.org"]
        XCTAssertNotNil(FuzzyMatcher.matchQuery("wiki", in: fields, strictness: .substring))
        XCTAssertNotNil(
            FuzzyMatcher.matchQuery("free wikipedia", in: fields, strictness: .substring),
            "Terms in any order, across any field, is still the rule — strictness governs how literally each term must appear, not where."
        )
        XCTAssertNil(
            FuzzyMatcher.matchQuery("wikipedia kubernetes", in: fields, strictness: .substring),
            "AND across terms is unchanged."
        )
    }

    func test_results_openTabMatchingOnlyAsAScatteredSubsequenceIsNotOffered() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let irrelevant = Tab(spaceID: space.id, section: .today, url: URL(string: "https://www.youtube.com/watch?v=xKiwqxlWkQI")!, title: "Yaeji - With a Hammer")
        env.state.tabs[irrelevant.id] = irrelevant

        let results = CommandBarEngine.results(query: "wiki", mode: .newTab, env: env, suggestions: [])
        let offersIrrelevantTab = results.contains { result in
            if case .openTab(let id) = result.kind { return id == irrelevant.id }
            return false
        }
        XCTAssertFalse(
            offersIrrelevantTab,
            "A tab whose title and URL contain \"wiki\" only as a scattered subsequence must not be offered — it was, and with a +30 open-tab bonus on top."
        )
    }

    func test_results_actionsStillMatchFuzzily() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let results = CommandBarEngine.results(query: "tglsdbr", mode: .newTab, env: env, suggestions: [])
        let offersToggleSidebar = results.contains { result in
            if case .action(let action) = result.kind { return action.id == "toggle-sidebar" }
            return false
        }
        XCTAssertTrue(offersToggleSidebar, "An abbreviation must still reach an Action; results were: \(results.map(\.title))")
    }

    func test_results_historyRowsAreBudgeted() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        env.historyEntries = (1...30).map { index in
            HistoryEntry(
                url: URL(string: "https://en.wikipedia.org/wiki/Article_\(index)")!,
                title: "Wikipedia — Article \(index)",
                visitedAt: Date().addingTimeInterval(-Double(index) * 60),
                visitCount: index,
                profileID: profile.id
            )
        }

        let results = CommandBarEngine.results(query: "wikipedia", mode: .newTab, env: env, suggestions: [])
        let historyRows = results.filter { if case .history = $0.kind { return true }; return false }
        XCTAssertEqual(historyRows.count, 8, "Thirty matching history entries produced \(historyRows.count) rows; the list shows about ten in total.")

        let dropped = historyRows.contains { $0.title == "Wikipedia — Article 30" }
        XCTAssertTrue(dropped, "Article 30 is the most-visited entry and must survive the budget: \(historyRows.map(\.title))")
    }

    // MARK: - The verbatim row is always offered

    func test_results_verbatimSearchRowIsOfferedInTheTopTwo_evenBuriedInMatchingHistory() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        var space = Space(name: "Personal", profileID: profile.id)
        space.favorites = [Favorite(url: URL(string: "https://en.wikipedia.org/wiki/Main_Page")!, title: "Wikipedia, the free encyclopedia")]
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let tab = Tab(spaceID: space.id, section: .today, url: URL(string: "https://en.wikipedia.org/wiki/Orbit")!, title: "Wikipedia — Orbit")
        env.state.tabs[tab.id] = tab

        env.historyEntries = (1...12).map { index in
            HistoryEntry(
                url: URL(string: "https://en.wikipedia.org/wiki/Article_\(index)")!,
                title: "Wikipedia — Article \(index)",
                visitedAt: Date().addingTimeInterval(-60),
                visitCount: 50,
                profileID: profile.id,
                wasTyped: true
            )
        }

        let results = CommandBarEngine.results(query: "wikipedia", mode: .newTab, env: env, suggestions: [])

        guard let verbatimIndex = results.firstIndex(where: { result in
            if case .searchSuggestion(let text) = result.kind { return text == "wikipedia" }
            return false
        }) else {
            XCTFail("The \"search for exactly what I typed\" row must be offered; results were: \(results.map(\.title))")
            return
        }
        XCTAssertLessThanOrEqual(
            verbatimIndex, 1,
            "The verbatim row must be reserved rank 0 or 1 so it is always visible without scrolling — it was at \(verbatimIndex) of \(results.count)."
        )

        guard case .openTab = results.first?.kind else {
            XCTFail("A clearly-matching open tab must still be the top result, got \(String(describing: results.first?.kind)).")
            return
        }
    }

    func test_results_verbatimTypedURLKeepsRankZeroRatherThanBeingPushedToOne() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let tab = Tab(spaceID: space.id, section: .today, url: URL(string: "https://example.com/deep/page")!, title: "Example Domain")
        env.state.tabs[tab.id] = tab

        let results = CommandBarEngine.results(query: "example.com", mode: .newTab, env: env, suggestions: [])
        guard case .typedURL = results.first?.kind else {
            XCTFail("A typed address must stay the top result, got \(String(describing: results.first?.kind)).")
            return
        }
    }

    func test_results_chatGPTAskRowStaysDirectlyBelowTheVerbatimRow() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let tab = Tab(spaceID: space.id, section: .today, url: URL(string: "https://en.wikipedia.org/wiki/Orbit")!, title: "Wikipedia — Orbit")
        env.state.tabs[tab.id] = tab
        env.historyEntries = (1...6).map { index in
            HistoryEntry(
                url: URL(string: "https://en.wikipedia.org/wiki/Article_\(index)")!,
                title: "Wikipedia — Article \(index)",
                visitedAt: Date().addingTimeInterval(-60),
                visitCount: 50,
                profileID: profile.id,
                wasTyped: true
            )
        }

        let results = CommandBarEngine.results(
            query: "wikipedia", mode: .newTab, env: env, suggestions: [],
            isChatGPTCommandBarAvailable: true
        )

        let verbatimIndex = results.firstIndex { result in
            if case .searchSuggestion(let text) = result.kind { return text == "wikipedia" }
            return false
        }
        let askIndex = results.firstIndex { if case .chatGPTAsk = $0.kind { return true }; return false }
        XCTAssertNotNil(verbatimIndex, "Expected the verbatim row.")
        XCTAssertNotNil(askIndex, "Expected an .chatGPTAsk row when the feature is available.")
        if let verbatimIndex, let askIndex {
            XCTAssertEqual(askIndex, verbatimIndex + 1, "The Ask ChatGPT row must sit directly below the verbatim row.")
        }
    }

    // MARK: - RelativeTimeFormatter (the history row's dim secondary line)

    func test_relativeTime_justNowForVeryRecent() {
        let now = Date()
        XCTAssertEqual(CommandBarRelativeTime.string(from: now.addingTimeInterval(-5), relativeTo: now), "Just now")
    }

    func test_relativeTime_minutesAgo() {
        let now = Date()
        XCTAssertEqual(CommandBarRelativeTime.string(from: now.addingTimeInterval(-18 * 60), relativeTo: now), "18 minutes ago")
        XCTAssertEqual(CommandBarRelativeTime.string(from: now.addingTimeInterval(-60), relativeTo: now), "1 minute ago")
    }

    func test_relativeTime_hoursAgo() {
        let now = Date()
        XCTAssertEqual(CommandBarRelativeTime.string(from: now.addingTimeInterval(-3 * 3600), relativeTo: now), "3 hours ago")
        XCTAssertEqual(CommandBarRelativeTime.string(from: now.addingTimeInterval(-3600), relativeTo: now), "1 hour ago")
    }

    func test_results_historyRowSubtitleIsRelativeTime() {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let now = Date()
        env.historyEntries = [
            HistoryEntry(url: URL(string: "https://example.com")!, title: "Example Domain", visitedAt: now.addingTimeInterval(-120), profileID: profile.id),
        ]

        let results = CommandBarEngine.results(query: "example", mode: .newTab, env: env, suggestions: [])
        let historyResult = results.first { if case .history = $0.kind { return true }; return false }
        XCTAssertEqual(historyResult?.subtitle, "2 minutes ago", "refs/reference/arc-bookmarks-search.png shows a relative-time secondary line under a history result, not the host.")
    }
}
