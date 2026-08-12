import XCTest

@MainActor
final class SiteSearchTests: XCTestCase {

    private func makeEngines() -> [SiteSearchEngine] {
        SiteSearchEngine.sourcedDefaults()
    }

    private func engine(named name: String) -> SiteSearchEngine {
        makeEngines().first { $0.name == name }!
    }

    private func makeEnvironment() -> AppEnvironment {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id
        return env
    }

    // MARK: - 1. Shortcut matching

    func test_shortcutMatching_exactShortcutResolvesItsEngine() {
        let engines = makeEngines()
        XCTAssertEqual(SiteSearchMatcher.engine(forShortcut: "tw", in: engines)?.name, "Twitter")
        XCTAssertEqual(SiteSearchMatcher.engine(forShortcut: "yt", in: engines)?.name, "YouTube")
        XCTAssertEqual(SiteSearchMatcher.engine(forShortcut: "a", in: engines)?.name, "Amazon")
    }

    func test_shortcutMatching_prefixOfAShortcutDoesNotResolve() {
        XCTAssertNil(SiteSearchMatcher.engine(forShortcut: "t", in: makeEngines()))
        XCTAssertNil(SiteSearchMatcher.engine(forShortcut: "y", in: makeEngines()))
    }

    func test_shortcutMatching_isCaseInsensitive() {
        XCTAssertEqual(SiteSearchMatcher.engine(forShortcut: "TW", in: makeEngines())?.name, "Twitter")
        XCTAssertEqual(SiteSearchMatcher.engine(forShortcut: "Yt", in: makeEngines())?.name, "YouTube")
    }

    func test_shortcutMatching_unknownShortcutResolvesNothing() {
        XCTAssertNil(SiteSearchMatcher.engine(forShortcut: "zzz", in: makeEngines()))
        XCTAssertNil(SiteSearchMatcher.engine(forShortcut: "", in: makeEngines()))
    }

    func test_armedEngine_isNilWhileAlreadyScoped() {
        let engines = makeEngines()
        let scoped = SiteSearchState(engines: engines, active: engine(named: "Twitter"))
        XCTAssertNil(scoped.armedEngine(forTypedQuery: "yt"))

        let unscoped = SiteSearchState(engines: engines, active: nil)
        XCTAssertEqual(unscoped.armedEngine(forTypedQuery: "yt")?.name, "YouTube")
    }

    // MARK: - 2. Template expansion

    func test_templateExpansion_substitutesAndEncodesTheQuery() throws {
        let url = try XCTUnwrap(
            SiteSearchMatcher.searchURL(for: "hammer & tongs", using: engine(named: "Twitter"))
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "twitter.com")
        let queryItems = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(queryItems.count, 1, "An unescaped `&` would have produced a second query item: \(queryItems)")
        XCTAssertEqual(queryItems.first?.name, "q")
        XCTAssertEqual(queryItems.first?.value, "hammer & tongs", "The expanded URL must round-trip back to exactly what was typed.")
    }

    func test_templateExpansion_placeholderIsReplacedNotLeftBehind() throws {
        let url = try XCTUnwrap(
            SiteSearchMatcher.searchURL(for: "yaeji", using: engine(named: "YouTube"))
        )
        XCTAssertFalse(url.absoluteString.contains(SiteSearchEngine.queryPlaceholder), "The %s placeholder must be gone from the expanded URL.")
        XCTAssertTrue(url.absoluteString.contains("yaeji"))
    }

    func test_templateExpansion_templateWithoutPlaceholderYieldsNothing() {
        let broken = SiteSearchEngine(name: "Broken", shortcut: "b", urlTemplate: "https://example.com/search")
        XCTAssertNil(SiteSearchMatcher.searchURL(for: "anything", using: broken))
    }

    func test_templateExpansion_pathStyleTemplateDoesNotGainExtraPathSegments() throws {
        let spotify = SiteSearchEngine(name: "Spotify", shortcut: "sp", urlTemplate: "https://open.spotify.com/search/%s")
        let url = try XCTUnwrap(SiteSearchMatcher.searchURL(for: "ac/dc", using: spotify))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath.split(separator: "/").count, 2, "Expected /search/<one segment>, got \(components.percentEncodedPath)")
    }

    // MARK: - 3. The scoping invariant

    func test_scopedResults_containOnlySiteSearchRows() {
        let env = makeEnvironment()
        let space = env.state.spaces[0]
        let profile = env.state.profiles[0]

        let tab = Tab(spaceID: space.id, section: .today, url: URL(string: "https://example.com/history")!, title: "Browsing History Notes")
        env.state.tabs[tab.id] = tab

        var themedSpace = space
        themedSpace.favorites = [Favorite(url: URL(string: "https://history.example.com")!, title: "History Channel")]
        env.state.spaces = [themedSpace]

        env.historyEntries = [
            HistoryEntry(url: URL(string: "https://rome.example.com")!, title: "History of Rome", visitedAt: Date().addingTimeInterval(-600), profileID: profile.id),
        ]

        let unscoped = CommandBarEngine.results(query: "history", mode: .newTab, env: env, suggestions: ["history podcast"])
        let unscopedKinds = unscoped.map(\.kind)
        XCTAssertTrue(unscopedKinds.contains { if case .openTab = $0 { return true }; return false }, "Fixture is wrong: no open-tab row to exclude.")
        XCTAssertTrue(unscopedKinds.contains { if case .favorite = $0 { return true }; return false }, "Fixture is wrong: no favourite row to exclude.")
        XCTAssertTrue(unscopedKinds.contains { if case .history = $0 { return true }; return false }, "Fixture is wrong: no history row to exclude.")
        XCTAssertTrue(unscopedKinds.contains { if case .action = $0 { return true }; return false }, "Fixture is wrong: no Action row to exclude (\"Show History\" should match \"history\").")
        XCTAssertTrue(unscopedKinds.contains { if case .searchSuggestion = $0 { return true }; return false }, "Fixture is wrong: no plain search row to exclude.")

        let scoped = CommandBarEngine.results(
            query: "history",
            mode: .newTab,
            env: env,
            suggestions: ["history podcast"],
            siteSearch: SiteSearchState(engines: makeEngines(), active: engine(named: "YouTube"))
        )

        XCTAssertFalse(scoped.isEmpty, "A scoped bar with a typed query must still offer the query itself.")
        for result in scoped {
            guard case .siteSearch = result.kind else {
                XCTFail("While scoped to a site the list must contain only site-search rows — found \(result.kind) (\"\(result.title)\").")
                continue
            }
        }
    }

    func test_scopedResults_typedTermIsTheTopRow() {
        let env = makeEnvironment()
        let scoped = CommandBarEngine.results(
            query: "Yaeji - With a Hammer",
            mode: .newTab,
            env: env,
            suggestions: ["yaeji raingurl"],
            siteSearch: SiteSearchState(engines: makeEngines(), active: engine(named: "YouTube"))
        )
        XCTAssertEqual(scoped.first?.title, "Yaeji - With a Hammer")
    }

    func test_scopedResults_areEmptyBeforeAnythingIsTyped() {
        let env = makeEnvironment()
        let scoped = CommandBarEngine.results(
            query: "",
            mode: .newTab,
            env: env,
            suggestions: [],
            siteSearch: SiteSearchState(engines: makeEngines(), active: engine(named: "Twitter"))
        )
        XCTAssertTrue(scoped.isEmpty, "A scoped bar with nothing typed must not fall back to the unscoped recents list.")
    }

    // MARK: - 4. Activating a site-search result navigates to the expanded URL

    func test_activationIntent_siteSearchNavigatesToTheExpandedURL() throws {
        let env = makeEnvironment()
        let twitter = engine(named: "Twitter")
        let scoped = CommandBarEngine.results(
            query: "megan",
            mode: .newTab,
            env: env,
            suggestions: [],
            siteSearch: SiteSearchState(engines: makeEngines(), active: twitter)
        )
        let row = try XCTUnwrap(scoped.first)
        guard case .navigate(let url) = row.kind.activationIntent else {
            XCTFail("A site-search row must activate as .navigate, got \(row.kind.activationIntent).")
            return
        }
        XCTAssertEqual(url, SiteSearchMatcher.searchURL(for: "megan", using: twitter))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "twitter.com", "Activating must go to the scoped site, not to the default search engine.")
        XCTAssertEqual(components.queryItems?.first?.value, "megan")
    }

    // MARK: - 5. Regression guard: no active engine leaves ranking untouched

    func test_noActiveEngine_leavesTheBlendedRankingByteForByteUnchanged() {
        let env = makeEnvironment()
        let space = env.state.spaces[0]
        let profile = env.state.profiles[0]

        let tab = Tab(spaceID: space.id, section: .today, url: URL(string: "https://github.com/pulls")!, title: "GitHub - Pull Requests")
        env.state.tabs[tab.id] = tab

        var themedSpace = space
        themedSpace.favorites = [Favorite(url: URL(string: "https://gitea.example.com")!, title: "Gitea Self-Hosted")]
        env.state.spaces = [themedSpace]

        env.historyEntries = [
            HistoryEntry(url: URL(string: "https://github.com")!, title: "GitHub", visitedAt: Date().addingTimeInterval(-3600), profileID: profile.id),
        ]

        let now = Date()

        let baseline = CommandBarEngine.results(query: "git", mode: .newTab, env: env, suggestions: ["gitlab"], now: now)

        let withEnginesConfigured = CommandBarEngine.results(
            query: "git",
            mode: .newTab,
            env: env,
            suggestions: ["gitlab"],
            siteSearch: SiteSearchState(engines: makeEngines(), active: nil),
            now: now
        )

        XCTAssertFalse(baseline.isEmpty)
        XCTAssertEqual(
            baseline.map(\.id), withEnginesConfigured.map(\.id),
            "Configuring site-search engines must not change the unscoped blended list at all — same rows, same order."
        )
        XCTAssertEqual(baseline.map(\.title), withEnginesConfigured.map(\.title))
        XCTAssertEqual(baseline.map(\.score), withEnginesConfigured.map(\.score))
    }

    // MARK: - The Command Bar action Arc documents as the only way in

    func test_allActions_offersSiteSearchSettingsUnderArcsOwnWording() throws {
        let action = try XCTUnwrap(
            CommandBarEngine.allActions().first { $0.id == SiteSearchSettingsPresenter.commandActionID },
            "allActions() must offer a Site Search settings command."
        )
        XCTAssertEqual(action.title, "Site Search Settings")

        let env = makeEnvironment()
        for typed in ["Site Search", "Site Search Settings"] {
            let results = CommandBarEngine.results(query: typed, mode: .newTab, env: env, suggestions: [])
            let found = results.contains { result in
                if case .action(let candidate) = result.kind { return candidate.id == action.id }
                return false
            }
            XCTAssertTrue(found, "Typing \"\(typed)\" into the Command Bar must surface the Site Search settings action.")
        }
    }

    func test_siteSearchSettingsAction_runsTheInstalledPresenter() {
        let previous = SiteSearchSettingsPresenter.present
        defer { SiteSearchSettingsPresenter.present = previous }

        var presentedCount = 0
        SiteSearchSettingsPresenter.present = { presentedCount += 1 }

        let action = CommandBarEngine.allActions().first { $0.id == SiteSearchSettingsPresenter.commandActionID }
        XCTAssertNotNil(action)
        action?.perform(AppEnvironment())
        XCTAssertEqual(presentedCount, 1, "Running the Site Search settings action must invoke the installed presenter exactly once.")
    }

    // MARK: - Sourced defaults

    func test_sourcedDefaults_areArcsOwnThreeSitesWithArcsOwnValues() {
        let defaults = SiteSearchEngine.sourcedDefaults()
        XCTAssertEqual(defaults.map(\.name), ["Amazon", "Twitter", "YouTube"])
        XCTAssertEqual(defaults.map(\.shortcut), ["a", "tw", "yt"])
        XCTAssertEqual(defaults.map(\.urlTemplate), [
            "https://www.amazon.com/s?k=%s",
            "https://twitter.com/search?q=%s",
            "https://www.youtube.com/results?search_query=%s",
        ])
        for engine in defaults {
            XCTAssertNotNil(SiteSearchMatcher.searchURL(for: "test", using: engine), "\(engine.name)'s seeded template does not expand.")
        }
    }

    func test_engineHost_isDerivedFromTheTemplateEvenWithThePlaceholderInThePath() {
        XCTAssertEqual(engine(named: "YouTube").host, "www.youtube.com")
        XCTAssertEqual(engine(named: "Twitter").host, "twitter.com")
        let spotify = SiteSearchEngine(name: "Spotify", shortcut: "sp", urlTemplate: "https://open.spotify.com/search/%s")
        XCTAssertEqual(spotify.host, "open.spotify.com", "The host must resolve even when %s sits in the path.")
    }

    // MARK: - Trigger key

    func test_triggerKey_onlySpaceOrTabAcceptsSpace() {
        XCTAssertFalse(SiteSearchTriggerKey.tab.acceptsSpace)
        XCTAssertTrue(SiteSearchTriggerKey.spaceOrTab.acceptsSpace)
        XCTAssertEqual(SiteSearchState().triggerKey, .tab, "Tab must be the default.")
    }
}
