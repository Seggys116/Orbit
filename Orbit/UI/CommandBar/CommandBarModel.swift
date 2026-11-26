//  Result types and ranking engine for the Command Bar's unified, fuzzy-matched list (spec §3.3).

import Foundation

enum CommandBarMode: Equatable {
    case newTab
    case editURL(URL?)
    case chatGPT
    // Carries the target TabID rather than relying on env.activeTabID: a blank pane that is not the focused one still gets its own page.
    case blankPane(TabID)

    var initialQuery: String {
        switch self {
        case .newTab, .chatGPT, .blankPane: return ""
        case .editURL(let url): return url?.absoluteString ?? ""
        }
    }

    var targetTabID: TabID? {
        switch self {
        case .blankPane(let tabID): return tabID
        case .newTab, .chatGPT, .editURL: return nil
        }
    }

    /// True when the bar was opened by clicking a tab's own address: the user is rewriting that tab's URL, so what they typed is the answer to Enter. Every other row (an open tab, a favourite, an action) is a suggestion they must arrow or click to, never the default.
    var editsCurrentPage: Bool {
        if case .editURL = self { return true }
        return false
    }
}

// The result types below are nonisolated because the scoring pass builds rows off the main actor.
nonisolated enum CommandResultKind {
    case typedURL(URL)
    case searchSuggestion(String)
    case openTab(TabID)
    // A tab in a Space the user is not in — the only row kind allowed to move them.
    case tabInOtherSpace(TabID, spaceID: SpaceID)
    case pinnedTab(TabID)
    case favorite(Favorite)
    case history(HistoryEntry)
    case action(CommandAction)
    case siteSearch(engine: SiteSearchEngine, query: String, url: URL)
    case chatGPTAsk(query: String, url: URL)
}

nonisolated extension CommandResultKind {
    nonisolated enum ActivationIntent {
        case navigate(URL)
        case searchGoogle(String)
        case switchToTab(TabID)
        case switchToSpaceAndTab(spaceID: SpaceID, tabID: TabID)
        case activateFavoriteResult(Favorite)
        case runAction(id: String)
    }

    var activationIntent: ActivationIntent {
        switch self {
        case .typedURL(let url):
            return .navigate(url)
        case .searchSuggestion(let text):
            return .searchGoogle(text)
        case .openTab(let tabID), .pinnedTab(let tabID):
            return .switchToTab(tabID)
        case .tabInOtherSpace(let tabID, let spaceID):
            return .switchToSpaceAndTab(spaceID: spaceID, tabID: tabID)
        case .favorite(let favorite):
            return .activateFavoriteResult(favorite)
        case .history(let entry):
            return .navigate(entry.url)
        case .action(let action):
            return .runAction(id: action.id)
        case .siteSearch(_, _, let url):
            return .navigate(url)
        case .chatGPTAsk(_, let url):
            return .navigate(url)
        }
    }
}

nonisolated struct CommandResult: Identifiable {
    var id: String
    var kind: CommandResultKind
    var title: String
    var subtitle: String?
    var symbolName: String
    var score: Double
    var faviconURL: URL?
    var faviconHost: String?
    var instantOpenURL: URL? = nil
}

nonisolated struct CommandAction: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var symbolName: String
    var keywords: [String] = []
    var perform: (AppEnvironment) -> Void
}

// nonisolated so the history/tab/favourite scoring can run on a background task. Everything that touches the environment or builds an action stays @MainActor.
nonisolated enum CommandBarEngine {

    // MARK: Actions

    @MainActor
    static func allActions() -> [CommandAction] {
        [
            CommandAction(id: "new-space", title: "New Space", subtitle: "Create a themed workspace", symbolName: "plus.square.on.square") { _ in
                NotificationCenter.default.post(name: .orbitPresentNewSpaceFlow, object: nil)
            },
            CommandAction(id: "new-incognito", title: "New Incognito Window", subtitle: "Private browsing", symbolName: "eyeglasses") { env in
                env.perform(.newIncognitoWindow)
            },
            CommandAction(id: "new-note", title: "New Note", subtitle: "Rich-text note pinned to this Space", symbolName: "note.text") { env in
                env.perform(.newNote)
            },
            CommandAction(id: "new-easel", title: "New Easel", subtitle: "Infinite canvas", symbolName: "scribble.variable") { env in
                env.perform(.newEasel)
            },
            CommandAction(id: "toggle-sidebar", title: "Toggle Sidebar", subtitle: "Show or hide the sidebar", symbolName: "sidebar.left") { env in
                env.perform(.toggleSidebar)
            },
            CommandAction(id: "clear-today", title: "Clear All Today Tabs", subtitle: "Archive every unpinned tab", symbolName: "tray.and.arrow.down", keywords: ["archive"]) { env in
                env.perform(.clearTodayTabs)
            },
            CommandAction(
                id: "open-task-manager",
                title: "Open Task Manager",
                subtitle: "Memory and CPU per Orbit process",
                symbolName: "gauge.with.dots.needle.bottom.50percent",
                keywords: ["task manager", "troubleshooting", "memory", "cpu", "performance"]
            ) { _ in
                TaskManagerWindowController.show()
            },
            CommandAction(id: "settings-general", title: "Settings: General", subtitle: "App-wide preferences", symbolName: "gearshape") { _ in
                SettingsWindowController.show(pane: .general)
            },
            CommandAction(id: "settings-profiles", title: "Settings: Profiles", subtitle: "Archive timing, search engine, storage", symbolName: "person.crop.circle") { _ in
                SettingsWindowController.show(pane: .profiles)
            },
            CommandAction(id: "settings-links", title: "Settings: Links", subtitle: "Air Traffic Control routing rules", symbolName: "arrow.triangle.branch") { _ in
                SettingsWindowController.show(pane: .links)
            },
            // id stays "settings-shortcuts" even though the title reads "Keybinds": SettingsPane.shortcuts's raw value is unchanged (deep links depend on it).
            CommandAction(id: "settings-shortcuts", title: "Settings: Keybinds", subtitle: "Remap keyboard shortcuts", symbolName: "keyboard") { _ in
                SettingsWindowController.show(pane: .shortcuts)
            },
            CommandAction(id: "settings-extensions", title: "Settings: Extensions", subtitle: "Install and manage extensions", symbolName: "puzzlepiece.extension", keywords: ["extension", "chrome", "crx", "add-on"]) { _ in
                SettingsWindowController.show(pane: .extensions)
            },
            CommandAction(id: "settings-ad-blocker", title: "Settings: Ad Blocker", subtitle: "Toggle content-blocking filter lists", symbolName: "shield.lefthalf.filled", keywords: ["ad blocker", "content blocking", "filter lists", "privacy"]) { _ in
                SettingsWindowController.show(pane: .adBlocker)
            },
            CommandAction(
                id: SiteSearchSettingsPresenter.commandActionID,
                title: "Site Search Settings",
                subtitle: "Directly search any website",
                symbolName: "magnifyingglass.circle",
                keywords: ["site search", "search engines"]
            ) { _ in
                SiteSearchSettingsPresenter.present()
            },
            // Title says "Turn On", not "Toggle": pressing this a second time with Developer Mode already on must not switch it back off.
            CommandAction(id: "developer-mode", title: "Turn On Developer Mode for This Site", subtitle: "Element-precise capture, inspector shortcuts", symbolName: "hammer") { env in
                DeveloperModeSettings.isEnabled = true
                env.siteControlPresentedTabID = env.activeTabID
            },
            CommandAction(id: "history", title: "Show History", subtitle: "Cmd+Y", symbolName: "clock") { env in
                env.perform(.history)
            },
            CommandAction(id: "downloads", title: "Show Downloads", subtitle: "Cmd+Shift+J", symbolName: "arrow.down.circle") { env in
                env.perform(.downloads)
            },
            CommandAction(id: "library", title: "Open Library", subtitle: "Cmd+Shift+L", symbolName: "square.grid.2x2") { env in
                env.perform(.library)
            },
            CommandAction(
                id: "view-archive",
                title: "View Archive",
                subtitle: "Search closed and auto-archived tabs across Spaces",
                symbolName: "archivebox",
                keywords: ["archived tabs", "view archived tabs", "archive"]
            ) { env in
                env.perform(.archivedTabs)
            },
            CommandAction(id: "little-orbit", title: "New Little Orbit", subtitle: "Cmd+Option+N", symbolName: "rectangle.inset.filled") { env in
                env.perform(.newLittleOrbit)
            },
            CommandAction(id: "about", title: "About Orbit", subtitle: WebKitProduct.versionDescription, symbolName: "info.circle") { _ in
                SettingsWindowController.show(pane: .general)
            },
            // ORBIT_SPARKLE, not #if canImport(Sparkle): canImport(Sparkle) evaluates true even in OrbitTests, which doesn't link Sparkle, because Xcode's SwiftPM integration exposes a resolved product's build output to every target sharing the products directory.
            // ORBIT_SPARKLE is a SWIFT_ACTIVE_COMPILATION_CONDITIONS flag set on the Orbit target alone.
            CommandAction(
                id: "check-for-updates",
                title: "Check for Updates",
                subtitle: "See whether a newer version of Orbit is available",
                symbolName: "arrow.triangle.2.circlepath",
                keywords: ["update", "updates", "sparkle", "version", "upgrade", "new version"]
            ) { _ in
                #if ORBIT_SPARKLE
                UpdaterController.shared.checkForUpdates()
                #endif
            },
        ]
    }

    // MARK: Ranking

    // Calibrated against FuzzyMatcher.match's actual output range so a clearly-matching open tab can outrank the generic search fallback. Regression guard: CommandBarRankingTests.test_results_matchingOpenTab_surfacesAsOpenTabKind_endToEnd.
    private nonisolated enum PriorityScore {
        static let typedURL: Double = 200
        static let compoundSyntax: Double = 180
        static let literalSearchFallback: Double = 15
        static let chatGPTAsk: Double = 14
        // A history row scores textScore + frecency, and textScore can legitimately be 0; this must stay high enough that such a row cannot outrank every fetched suggestion on nothing at all.
        static let networkSuggestion: Double = 5
        // How far a site's root row sits above the best-ranked history row of that site, so Enter on a partial like "x" lands on the root rather than the last deep page visited. Kept tiny so the root stays below an open tab that outranks that history row today.
        static let siteRootMargin: Double = 0.01
        // Added when the query is exactly the site's name ("x" for x.com), so that site's root also leads other sites that merely contain the text and are more frecent.
        static let exactSiteBonus: Double = 40
    }

    private static let historyRowBudget = 8
    // Site root rows share historyRowBudget with ordinary history rows; this caps how many of those slots they can take.
    private static let siteRootRowLimit = 2

    // Mirrors HistoryStore.frecencyScore, reimplemented because this file also compiles into the host-less OrbitTests target, which has no HistoryStore.
    // Both read the same three HistoryEntry fields, so they can't disagree about "frecent" without one being edited alone.
    static func frecencyBoost(for entry: HistoryEntry, now: Date = Date()) -> Double {
        let halfLifeDays = 4.0
        let recencyFloor = 0.15
        let frecencyWeight = 4.0

        let frequency = log2(Double(max(entry.visitCount, 0)) + 1) + (entry.wasTyped ? 1.5 : 0)
        let ageInDays = max(0, now.timeIntervalSince(entry.visitedAt) / 86_400)
        let recencyDecay = exp(-log(2.0) * ageInDays / halfLifeDays)
        return frequency * (recencyFloor + (1 - recencyFloor) * recencyDecay) * frecencyWeight
    }

    static func searchFields(for url: URL) -> [String] {
        [url.absoluteString] + hostFields(for: url)
    }

    // The host-derived subset of searchFields: what "the typed text names this site" is judged against, so a word that only appears in a page's path or title never promotes that site's root.
    private static func hostFields(for url: URL) -> [String] {
        guard let host = url.host() else { return [] }
        var fields = [host]
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare != host { fields.append(bare) }
        let labels = bare.split(separator: ".")
        if labels.count > 1, let name = labels.first { fields.append(String(name)) }
        return fields
    }

    // The prepared (lowercased once) equivalent of [title] + searchFields(for: url); `host` is the hostFields subset, shared with `search`.
    static func preparedFields(title: String, url: URL) -> (search: [FuzzyMatcher.PreparedText], host: [FuzzyMatcher.PreparedText]) {
        let host = hostFields(for: url).map(FuzzyMatcher.PreparedText.init)
        return ([FuzzyMatcher.PreparedText(title), FuzzyMatcher.PreparedText(url.absoluteString)] + host, host)
    }

    // Scheme, host and port only. Port is kept because localhost:3000 and localhost:8080 are different sites. Nil for schemes with no meaningful root (file, orbit, view-source).
    static func siteRootURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host() else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }

    // Query strings are kept: ?q=a and ?q=b are genuinely different pages.
    static func dedupeKey(for url: URL) -> String {
        var key = url.absoluteString.lowercased()
        if let fragmentRange = key.range(of: "#") { key = String(key[key.startIndex..<fragmentRange.lowerBound]) }
        for prefix in ["https://", "http://"] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
        }
        if key.hasPrefix("www.") { key = String(key.dropFirst(4)) }
        while key.hasSuffix("/") { key = String(key.dropLast()) }
        return key
    }

    // searchEngine/isChatGPTCommandBarAvailable/isInstantLinksEnabled are passed in, not read off env: this file also compiles into the host-less OrbitTests target, where AppEnvironment resolves to a hand-written double.
    @MainActor
    static func results(
        query: String,
        mode: CommandBarMode,
        env: AppEnvironment,
        suggestions: [String],
        searchEngine: SearchEngine = .fallback,
        siteSearch: SiteSearchState = SiteSearchState(),
        isChatGPTCommandBarAvailable: Bool = false,
        isInstantLinksEnabled: Bool = false,
        now: Date = Date()
    ) -> [CommandResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Returning early, not filtering at the end, makes the scoping invariant structural: a live Site Search chip means the list contains only rows that search the scoped site.
        if let engine = siteSearch.active {
            return siteSearchResults(query: trimmed, engine: engine, suggestions: suggestions)
        }

        if trimmed.isEmpty {
            return emptyStateResults(env: env)
        }

        // The synchronous entry point: env.historyResults has already blended and capped the candidates, so they go in as the pre-ranked "indexed" list.
        let sourcePlan = plan(
            query: trimmed, mode: mode, env: env,
            historyIndexed: env.historyResults(matching: trimmed, limit: historyCandidateLimit).map(PreparedHistoryEntry.init),
            historyCached: [],
            searchEngine: searchEngine,
            isChatGPTCommandBarAvailable: isChatGPTCommandBarAvailable,
            isInstantLinksEnabled: isInstantLinksEnabled,
            now: now
        )
        return assemble(sourcePlan, scored: scoreSources(sourcePlan.request), suggestions: suggestions)
    }

    // MARK: Plan, score, assemble

    // Store is asked for a wide net (40) so entries rank against each other, but only historyRowBudget reach the list, or a query like "wikipedia" fills the list with near-identical rows.
    static let historyCandidateLimit = 40

    /// One favourite with the one piece of its row that needs the live environment.
    nonisolated struct FavoriteSource: Sendable {
        var favorite: Favorite
        var liveFaviconURL: URL?
    }

    /// Everything the scoring pass reads, copied out of the environment so it can run off the main actor.
    nonisolated struct SourceRequest: Sendable {
        /// The trimmed query, lowercased once.
        var query: FuzzyMatcher.PreparedQuery
        var typedURL: URL?
        var excludedTabID: TabID?
        var currentSpaceID: SpaceID?
        /// A copy-on-write handle on the environment's tab table: O(1) to take, filtered by the scoring pass.
        var tabs: [TabID: Tab]
        var spaceNames: [SpaceID: String]
        /// Every Space's favourites, active Space first; de-duplicated by the scoring pass.
        var favorites: [FavoriteSource]
        /// History in blend order: `historyIndexed` (the store's FTS hits for this query) then `historyCached` (the recency cache).
        var historyIndexed: [PreparedHistoryEntry]
        var historyCached: [PreparedHistoryEntry]
        var now: Date
    }

    /// The tab, favourite and history rows, ranked and capped, with the cross-Space clamp applied.
    // @unchecked: CommandResult can carry a CommandAction closure, but no row built here ever does (actions are added by `assemble` on the main actor).
    nonisolated struct ScoredSources: @unchecked Sendable {
        var rows: [CommandResult]
        /// True when a cancelled task stopped scoring early; `rows` is then incomplete and must be dropped.
        var wasCancelled = false
    }

    /// The main-actor half of a results call: the rows that carry closures or need main-actor services, plus the copied scoring inputs.
    nonisolated struct Plan {
        var request: SourceRequest
        var head: [CommandResult]
        var searchEngine: SearchEngine
        var editsCurrentPage: Bool
    }

    // Precondition: trimmed is non-empty and no Site Search chip is active (results(...) and the view route those cases elsewhere).
    @MainActor
    static func plan(
        query trimmed: String,
        mode: CommandBarMode,
        env: AppEnvironment,
        historyIndexed: [PreparedHistoryEntry],
        historyCached: [PreparedHistoryEntry],
        searchEngine: SearchEngine,
        isChatGPTCommandBarAvailable: Bool,
        isInstantLinksEnabled: Bool,
        now: Date
    ) -> Plan {
        var head: [CommandResult] = []

        if let compound = compoundSyntaxResult(for: trimmed, searchEngine: searchEngine) {
            head.append(compound)
        }

        let typedURL = Self.detectTypedURL(trimmed)
        if let url = typedURL {
            head.append(CommandResult(id: "typed-url", kind: .typedURL(url), title: url.absoluteString, subtitle: "Go to this address", symbolName: "arrow.right", score: PriorityScore.typedURL, faviconURL: faviconGuessURL(for: url), faviconHost: url.host()))
        } else {
            let instantURL = isInstantLinksEnabled ? InstantLinkResolver.instantURL(for: trimmed, engine: searchEngine) : nil
            head.append(CommandResult(id: "search-\(trimmed)", kind: .searchSuggestion(trimmed), title: trimmed, subtitle: "Search \(searchEngine.displayName)", symbolName: "magnifyingglass", score: PriorityScore.literalSearchFallback, faviconURL: nil, faviconHost: nil, instantOpenURL: instantURL))
        }

        if isChatGPTCommandBarAvailable, let chatGPTURL = ChatGPTCommandBar.url(for: trimmed) {
            head.append(CommandResult(
                id: "chatgpt-ask-\(trimmed)",
                kind: .chatGPTAsk(query: trimmed, url: chatGPTURL),
                title: trimmed,
                subtitle: nil,
                symbolName: "bubble.left.and.text.bubble.right.fill",
                score: PriorityScore.chatGPTAsk,
                faviconURL: nil,
                faviconHost: nil
            ))
        }

        // .editURL excludes the current tab (offering it back as "switch to it" is meaningless); .blankPane excludes its own target, which has no title/page and would otherwise appear as a nameless row for the tab the user is already looking at.
        let excludedTabID: TabID? = {
            if case .editURL = mode { return env.activeTabID }
            return mode.targetTabID
        }()

        let activeSpaceID = env.activeSpace?.id
        let spaces = env.spaces
        var spaceNames: [SpaceID: String] = [:]
        for space in spaces where spaceNames[space.id] == nil { spaceNames[space.id] = space.name }

        // The active Space's favourites lead, so the mirror of a favourite that lives in every Space is kept from the Space the user is in.
        var favorites: [FavoriteSource] = []
        for space in spaces.sorted(by: { lhs, _ in lhs.id == activeSpaceID }) {
            for favorite in space.favorites {
                favorites.append(FavoriteSource(favorite: favorite, liveFaviconURL: liveFaviconURL(for: favorite, env: env)))
            }
        }

        let request = SourceRequest(
            query: FuzzyMatcher.PreparedQuery(trimmed),
            typedURL: typedURL,
            excludedTabID: excludedTabID,
            currentSpaceID: activeSpaceID,
            tabs: env.state.tabs,
            spaceNames: spaceNames,
            favorites: favorites,
            historyIndexed: historyIndexed,
            historyCached: historyCached,
            now: now
        )
        return Plan(request: request, head: head, searchEngine: searchEngine, editsCurrentPage: mode.editsCurrentPage)
    }

    /// Scores open tabs, favourites and history. Pure over `request`, so it can run on any thread; `cancellable` makes it stop early when the surrounding task is cancelled.
    static func scoreSources(_ request: SourceRequest, cancellable: Bool = false) -> ScoredSources {
        let query = request.query
        let loweredQuery = query.phrase
        var items: [CommandResult] = []
        var claimedDestinations = Set<String>()
        var crossSpaceTabIDs = Set<String>()

        for tab in request.tabs.values where tab.section != .archived && tab.id != request.excludedTabID {
            if cancellable && Task.isCancelled { return ScoredSources(rows: [], wasCancelled: true) }
            let title = tab.displayTitle
            let fields = preparedFields(title: title, url: tab.url).search
            guard let score = FuzzyMatcher.matchQuery(query, in: fields, strictness: .substring) else { continue }
            let isElsewhere = request.currentSpaceID != nil && tab.spaceID != request.currentSpaceID
            // Another Space's tab must not claim its address, or the history row for a page visited before is dropped in favour of a Space switch.
            if !isElsewhere { claimedDestinations.insert(dedupeKey(for: tab.url)) }
            let host = tab.url.host() ?? tab.url.absoluteString
            let spaceName = isElsewhere ? request.spaceNames[tab.spaceID] : nil
            let namesSpaceExactly = spaceName.map { $0.lowercased() == loweredQuery } ?? false
            if isElsewhere && !namesSpaceExactly { crossSpaceTabIDs.insert("tab-\(tab.id)") }
            items.append(CommandResult(
                id: "tab-\(tab.id)",
                kind: isElsewhere ? .tabInOtherSpace(tab.id, spaceID: tab.spaceID) : .openTab(tab.id),
                title: title,
                subtitle: spaceName.map { "\($0) · \(host)" } ?? host,
                symbolName: "square.on.square",
                // +30 lets an open tab outrank suggestions and actions; history and favourites still lead it (see the clamp below), and another Space's tab earns the boost only when the query is exactly that Space's name.
                score: !isElsewhere || namesSpaceExactly ? score + 30 : score,
                faviconURL: tab.faviconURL ?? faviconGuessURL(for: tab.url),
                faviconHost: host
            ))
        }

        // De-duplicated by destination, not by id: favourites are mirrored across every Space of a Profile, each mirror with its own fresh id, so an id-only check let one favourite appear as several identical rows.
        var seenFavoriteIDs = Set<UUID>()
        for source in request.favorites {
            if cancellable && Task.isCancelled { return ScoredSources(rows: [], wasCancelled: true) }
            let favorite = source.favorite
            guard seenFavoriteIDs.insert(favorite.id).inserted else { continue }
            let key = dedupeKey(for: favorite.url)
            guard !claimedDestinations.contains(key) else { continue }
            let fields = preparedFields(title: favorite.title, url: favorite.url).search
            guard let score = FuzzyMatcher.matchQuery(query, in: fields, strictness: .substring) else { continue }
            claimedDestinations.insert(key)
            items.append(CommandResult(
                id: "fav-\(favorite.id)",
                kind: .favorite(favorite),
                title: favorite.title,
                subtitle: favorite.url.host(),
                symbolName: "star.fill",
                score: score + 20,
                faviconURL: source.liveFaviconURL ?? faviconGuessURL(for: favorite.url),
                faviconHost: favorite.url.host() ?? favorite.url.absoluteString
            ))
        }

        // now is a parameter, not read directly: frecency makes this function's output time-dependent, and two calls microseconds apart can break a test comparing two result lists for equality.
        // Taken before the history loop adds its own keys: a site root already offered as an open tab, a favourite or the typed address must not be offered again as a synthesised row.
        var siteRootClaims = claimedDestinations
        if let typedURL = request.typedURL { siteRootClaims.insert(dedupeKey(for: typedURL)) }

        if cancellable && Task.isCancelled { return ScoredSources(rows: [], wasCancelled: true) }
        var rankedHistory: [ScoredHistory] = []
        for entry in blendHistory(indexed: request.historyIndexed, cached: request.historyCached, query: query, limit: historyCandidateLimit) {
            let key = entry.dedupeKey
            guard !claimedDestinations.contains(key) else { continue }
            claimedDestinations.insert(key)
            // Dropped, not admitted at zero: a row with no text score still carries frecencyBoost, which for a recently-visited page can outscore most genuine matches, so an unmatched row would rank first rather than last.
            guard let textScore = FuzzyMatcher.matchQuery(query, in: entry.searchFields, strictness: .substring) else { continue }
            rankedHistory.append(ScoredHistory(entry: entry, score: textScore + frecencyBoost(for: entry.entry, now: request.now)))
        }
        // A site the text names gets its root URL (no path, query or fragment) ranked above every history row of that site, so Enter on "x" opens x.com instead of the last post visited there. Roots count against historyRowBudget.
        rankedHistory.sort { $0.score > $1.score }
        let siteRoots = siteRootRows(query: query, rankedHistory: rankedHistory, claimed: siteRootClaims)
        items.append(contentsOf: siteRoots.rows)
        // Row construction (relative time, favicon guess) is deferred to here, so only the rows that survive the budget pay for it.
        let keptHistory = rankedHistory.filter { !siteRoots.absorbedIDs.contains($0.entry.entry.id) }.prefix(max(historyRowBudget - siteRoots.rows.count, 0))
        items.append(contentsOf: keptHistory.map { historyRow($0.entry, score: $0.score) })

        // An address the user has been to (a site root, a visited page or a favourite) always leads a tab row: typing a site means going to it, and a tab that merely matches is the second answer. A tab in another Space sits below every such row, so Enter can never move the user between Spaces while a page they have visited is on offer. Only a query that is exactly a Space's name lets that Space's tab lead.
        var bestHistoryScore: Double?
        var bestFavoriteScore: Double?
        var lowestAddressScore: Double?
        for item in items {
            switch item.kind {
            case .history:
                bestHistoryScore = max(bestHistoryScore ?? item.score, item.score)
            case .favorite:
                bestFavoriteScore = max(bestFavoriteScore ?? item.score, item.score)
            default:
                continue
            }
            lowestAddressScore = min(lowestAddressScore ?? item.score, item.score)
        }
        let sameSpaceCeiling = [bestHistoryScore, bestFavoriteScore].compactMap { $0 }.min()
        if let sameSpaceCeiling, let lowestAddressScore {
            for index in items.indices {
                switch items[index].kind {
                case .openTab, .pinnedTab:
                    items[index].score = min(items[index].score, sameSpaceCeiling - 0.001)
                case .tabInOtherSpace where crossSpaceTabIDs.contains(items[index].id):
                    items[index].score = min(items[index].score, lowestAddressScore - 0.001)
                default:
                    break
                }
            }
        }

        return ScoredSources(rows: items)
    }

    /// Adds the rows that need the main actor (actions, fetched suggestions) to the scored sources and produces the final list.
    @MainActor
    static func assemble(_ plan: Plan, scored: ScoredSources, suggestions: [String]) -> [CommandResult] {
        let query = plan.request.query
        let trimmed = query.text
        var items = plan.head + scored.rows

        for entry in preparedActions {
            guard let score = FuzzyMatcher.matchQuery(query, in: entry.fields) else { continue }
            let action = entry.action
            items.append(CommandResult(id: "action-\(action.id)", kind: .action(action), title: action.title, subtitle: action.subtitle, symbolName: action.symbolName, score: score + 4))
        }

        var claimedTitles = Set(items.map { $0.title.lowercased() })
        claimedTitles.insert(query.phrase)
        for suggestion in suggestions {
            guard claimedTitles.insert(suggestion.lowercased()).inserted else { continue }
            items.append(CommandResult(id: "suggest-\(suggestion)", kind: .searchSuggestion(suggestion), title: suggestion, subtitle: "Search \(plan.searchEngine.displayName)", symbolName: "magnifyingglass", score: PriorityScore.networkSuggestion))
        }

        return pinningVerbatimRows(in: limitingRepeatedPages(in: items.sorted { $0.score > $1.score }), query: trimmed, atTop: plan.editsCurrentPage)
    }

    // Actions never change at runtime, so their lowercased search text is built once instead of on every keystroke.
    private struct PreparedAction {
        var action: CommandAction
        var fields: [FuzzyMatcher.PreparedText]
    }

    @MainActor
    private static let preparedActions: [PreparedAction] = allActions().map {
        PreparedAction(action: $0, fields: ([$0.title] + $0.keywords).map(FuzzyMatcher.PreparedText.init))
    }

    private nonisolated struct ScoredHistory {
        var entry: PreparedHistoryEntry
        var score: Double
    }

    // MARK: History blending

    // Both sources are filtered here, not just the recency cache: a HistoryStore.search result reflects the row's state when indexed, not now, so an unmatched row must be dropped rather than ranked on stale frecency.
    // Every term must appear in the title or the URL; an empty query admits everything. Deduplicated by lowercased URL, indexed hits first.
    static func blendHistory(
        indexed: [PreparedHistoryEntry],
        cached: [PreparedHistoryEntry],
        query: FuzzyMatcher.PreparedQuery,
        limit: Int
    ) -> [PreparedHistoryEntry] {
        var seen = Set<String>()
        var results: [PreparedHistoryEntry] = []

        func take(_ entry: PreparedHistoryEntry) {
            guard results.count < limit else { return }
            guard query.terms.allSatisfy({ entry.title.containsLowered($0) || entry.urlText.containsLowered($0) }) else { return }
            guard seen.insert(entry.urlText.lowered).inserted else { return }
            results.append(entry)
        }

        for entry in indexed {
            take(entry)
        }
        for entry in cached {
            if results.count >= limit { break }
            take(entry)
        }
        return results
    }

    private static func historyRow(_ prepared: PreparedHistoryEntry, score: Double) -> CommandResult {
        let entry = prepared.entry
        return CommandResult(
            id: "hist-\(entry.id)",
            kind: .history(entry),
            title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
            subtitle: CommandBarRelativeTime.string(from: entry.visitedAt),
            symbolName: "clock",
            score: score,
            faviconURL: faviconGuessURL(for: entry.url),
            faviconHost: entry.url.host() ?? entry.url.absoluteString
        )
    }

    // MARK: One site, not a flood

    // At most this many open-tab rows from one host. History is already held to historyRowBudget, but open tabs have no budget, so a site with dozens of tabs open would fill the list with itself and push the site's own address, the thing being typed towards, out of view.
    private static let openTabRowsPerHostLimit = 4

    // Best-first input. Keeps the first row for each (host, title): seventeen pages all called "Settings" on one site are one useful answer, not seventeen. Then caps each host's open-tab rows at openTabRowsPerHostLimit. Site-root rows are never dropped, and rows that are not pages (the typed address, searches, actions) are untouched.
    static func limitingRepeatedPages(in results: [CommandResult]) -> [CommandResult] {
        var seenTitles = Set<String>()
        var tabRowsPerHost: [String: Int] = [:]
        return results.filter { result in
            guard let page = pageIdentity(of: result) else { return true }
            if isSiteRootRow(result) { return true }
            guard seenTitles.insert(page.host + "\u{1}" + page.title).inserted else { return false }
            guard isOpenTabRow(result) else { return true }
            let count = tabRowsPerHost[page.host, default: 0]
            guard count < openTabRowsPerHostLimit else { return false }
            tabRowsPerHost[page.host] = count + 1
            return true
        }
    }

    private static func isOpenTabRow(_ result: CommandResult) -> Bool {
        switch result.kind {
        case .openTab, .pinnedTab, .tabInOtherSpace: return true
        default: return false
        }
    }

    // A history row whose address is already its site's root, whether synthesised by siteRootRows or promoted from a real visit.
    private static func isSiteRootRow(_ result: CommandResult) -> Bool {
        guard case .history(let entry) = result.kind, let root = siteRootURL(for: entry.url) else { return false }
        return dedupeKey(for: root) == dedupeKey(for: entry.url)
    }

    private static func pageIdentity(of result: CommandResult) -> (host: String, title: String)? {
        let host: String?
        switch result.kind {
        case .history(let entry): host = entry.url.host()
        case .favorite(let favorite): host = favorite.url.host()
        // A tab row carries its host as the faviconHost it was built with.
        case .openTab, .pinnedTab, .tabInOtherSpace: host = result.faviconHost
        default: return nil
        }
        guard let host else { return nil }
        return (host.lowercased(), result.title.lowercased())
    }

    // MARK: Site roots

    // Walks history best-first and, for each of the first few sites whose host the query names, produces one root row. A history row that already is the root is promoted (re-scored, absorbed) rather than copied; otherwise a row is synthesised from the site's best history entry. Roots are only offered for sites with history behind them, and never for a root already claimed elsewhere in the list.
    private static func siteRootRows(
        query: FuzzyMatcher.PreparedQuery,
        rankedHistory: [ScoredHistory],
        claimed: Set<String>
    ) -> (rows: [CommandResult], absorbedIDs: Set<UUID>) {
        var rows: [CommandResult] = []
        var absorbedIDs = Set<UUID>()
        var visitedSites = Set<String>()
        let loweredQuery = query.phrase

        for row in rankedHistory {
            guard rows.count < siteRootRowLimit else { break }
            let entry = row.entry.entry
            guard let root = siteRootURL(for: entry.url) else { continue }
            let siteKey = dedupeKey(for: root)
            // rankedHistory is best-first, so the first row seen for a site is that site's best one.
            guard visitedSites.insert(siteKey).inserted, !claimed.contains(siteKey) else { continue }
            guard FuzzyMatcher.matchQuery(query, in: row.entry.hostFields, strictness: .substring) != nil else { continue }

            var score = row.score + PriorityScore.siteRootMargin
            if isExactSiteName(loweredQuery, for: entry.url) { score += PriorityScore.exactSiteBonus }

            let existingRoot = rankedHistory.first { $0.entry.dedupeKey == siteKey }
            if let existingRoot {
                rows.append(historyRow(existingRoot.entry, score: score))
                absorbedIDs.insert(existingRoot.entry.entry.id)
            } else {
                let host = root.host() ?? root.absoluteString
                let rootEntry = HistoryEntry(url: root, title: host, visitedAt: entry.visitedAt, visitCount: entry.visitCount, profileID: entry.profileID, spaceID: entry.spaceID)
                rows.append(CommandResult(
                    id: "site-root-\(siteKey)",
                    kind: .history(rootEntry),
                    title: host,
                    subtitle: "Go to this site",
                    symbolName: "globe",
                    score: score,
                    faviconURL: faviconGuessURL(for: root),
                    faviconHost: host
                ))
            }
        }
        return (rows.sorted { $0.score > $1.score }, absorbedIDs)
    }

    // True when the whole query is the site's host or its name label: "x" for x.com, "github" or "github.com" for www.github.com.
    private static func isExactSiteName(_ loweredQuery: String, for url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if loweredQuery == host || loweredQuery == bare { return true }
        let labels = bare.split(separator: ".")
        return labels.count > 1 && labels.first.map(String.init) == loweredQuery
    }

    // MARK: The verbatim row

    private static func isVerbatimRow(_ result: CommandResult, query: String) -> Bool {
        switch result.kind {
        case .typedURL:
            return true
        case .searchSuggestion(let text):
            return text == query
        default:
            return false
        }
    }

    // Verbatim row gets a reserved slot, not a raised score (which would re-break
    // CommandBarRankingTests): literalSearchFallback is low enough that history alone can sink it off-screen. min(_,1) makes this a reservation, not a promotion.
    // atTop: editing a tab's own URL. There the verbatim row leads unconditionally, so Enter can never "switch to" an open tab that merely matches what was typed.
    private static func pinningVerbatimRows(in results: [CommandResult], query: String, atTop: Bool = false) -> [CommandResult] {
        guard let verbatimIndex = results.firstIndex(where: { isVerbatimRow($0, query: query) }) else { return results }
        var remaining = results
        var block = [remaining.remove(at: verbatimIndex)]
        if let askIndex = remaining.firstIndex(where: { if case .chatGPTAsk = $0.kind { return true }; return false }) {
            block.append(remaining.remove(at: askIndex))
        }
        // A cross-Space row must never hold the default selection, or Enter on typed text would move the user Spaces.
        let leadsWithCrossSpaceRow = remaining.first.map { if case .tabInOtherSpace = $0.kind { return true } else { return false } } ?? false
        // A page that matched only because the text appears somewhere in its address ("x" in github.com/x/a) is not what the user named, so Enter on typed text must not open it.
        let leadsWithPathOnlyMatch = remaining.first.map { first in
            if case .history(let entry) = first.kind { return !namesTheEntry(entry, query: query) }
            return false
        } ?? false
        remaining.insert(contentsOf: block, at: atTop || leadsWithCrossSpaceRow || leadsWithPathOnlyMatch ? 0 : min(verbatimIndex, 1))
        return remaining
    }

    /// Whether the text is in the entry's title or names its site, as opposed to turning up only in the path or query.
    private static func namesTheEntry(_ entry: HistoryEntry, query: String) -> Bool {
        let prepared = FuzzyMatcher.PreparedQuery(query)
        let fields = ([entry.title] + hostFields(for: entry.url)).map(FuzzyMatcher.PreparedText.init)
        return FuzzyMatcher.matchQuery(prepared, in: fields, strictness: .substring) != nil
    }

    // MARK: Site Search

    @MainActor
    private static func siteSearchResults(
        query: String,
        engine: SiteSearchEngine,
        suggestions: [String]
    ) -> [CommandResult] {
        guard !query.isEmpty else { return [] }
        var items: [CommandResult] = []

        if let url = SiteSearchMatcher.searchURL(for: query, using: engine) {
            items.append(CommandResult(
                id: "site-search-literal",
                kind: .siteSearch(engine: engine, query: query, url: url),
                title: query,
                subtitle: nil,
                symbolName: "magnifyingglass",
                score: PriorityScore.typedURL,
                faviconURL: nil,
                faviconHost: nil
            ))
        }

        for suggestion in suggestions where suggestion.lowercased() != query.lowercased() {
            guard let url = SiteSearchMatcher.searchURL(for: suggestion, using: engine) else { continue }
            items.append(CommandResult(
                id: "site-search-suggest-\(suggestion)",
                kind: .siteSearch(engine: engine, query: suggestion, url: url),
                title: suggestion,
                subtitle: nil,
                symbolName: "magnifyingglass",
                score: PriorityScore.networkSuggestion,
                faviconURL: nil,
                faviconHost: nil
            ))
        }

        return items.sorted { $0.score > $1.score }
    }

    @MainActor
    private static func liveFaviconURL(for favorite: Favorite, env: AppEnvironment) -> URL? {
        guard let liveTabID = favorite.liveTabID else { return nil }
        return env.tab(liveTabID)?.faviconURL
    }

    private static func faviconGuessURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/favicon.ico"
        return components.url
    }

    @MainActor
    private static func emptyStateResults(env: AppEnvironment) -> [CommandResult] {
        var items: [CommandResult] = []
        for entry in env.historyResults(matching: "", limit: 6) {
            items.append(CommandResult(
                id: "recent-\(entry.id)",
                kind: .history(entry),
                title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                subtitle: CommandBarRelativeTime.string(from: entry.visitedAt),
                symbolName: "clock",
                score: 0,
                faviconURL: faviconGuessURL(for: entry.url),
                faviconHost: entry.url.host() ?? entry.url.absoluteString
            ))
        }
        if let spaceID = env.activeSpace?.id {
            for favorite in env.favorites(for: spaceID).prefix(4) {
                items.append(CommandResult(
                    id: "fav-\(favorite.id)",
                    kind: .favorite(favorite),
                    title: favorite.title,
                    subtitle: favorite.url.host(),
                    symbolName: "star.fill",
                    score: 0,
                    faviconURL: liveFaviconURL(for: favorite, env: env) ?? faviconGuessURL(for: favorite.url),
                    faviconHost: favorite.url.host() ?? favorite.url.absoluteString
                ))
            }
        }
        return items
    }

    // MARK: Typed URL detection

    // "Has a dot" is not enough: Chromium's omnibox only calls a bare host
    // navigable when its final label is a real, registered TLD
    // (AutocompleteInput::Parse's has_known_tld gate in
    // components/omnibox/browser/autocomplete_input.cc) — otherwise "google.c"
    // would out-rank the "google.com" the user actually meant. A host with an
    // unrecognised TLD falls through to nil here and is left for history to
    // resolve via ordinary ranking, exactly as Chromium leaves it to the
    // HistoryURLProvider's inline-autocomplete pass rather than the
    // what-you-typed match. Like that pass, the resolved destination is the
    // site's root (siteRootRows), never a deeper page of it that was visited last.
    @MainActor
    static func detectTypedURL(_ text: String) -> URL? {
        guard !text.contains(" ") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file", "orbit", "view-source"].contains(scheme) {
            return url
        }
        let hostCandidate = text.split(separator: "/").first.map(String.init) ?? text
        // "localhost"/"localhost:3000" have no dot, so the known-TLD gate below would otherwise reject them.
        let hostOnly = hostCandidate.split(separator: ":").first.map(String.init) ?? hostCandidate
        if hostOnly.lowercased() == "localhost",
           hostCandidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" }) {
            return URL(string: "http://\(text)")
        }
        guard hostCandidate.contains("."), !hostCandidate.hasSuffix("."),
              hostCandidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }),
              KnownTLDs.isNavigableHost(hostOnly) else {
            return nil
        }
        return URL(string: "https://\(text)")
    }

    // MARK: Compound syntax (spec §3.4)

    @MainActor
    private static func compoundSyntaxResult(for text: String, searchEngine: SearchEngine) -> CommandResult? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("video of ") {
            let subject = String(text.dropFirst("video of ".count))
            guard !subject.isEmpty else { return nil }
            let action = CommandAction(id: "video-of", title: "Video of \(subject)", subtitle: "Search YouTube", symbolName: "play.rectangle.fill") { env in
                guard let spaceID = env.activeSpace?.id else { return }
                let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
                if let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") {
                    env.openTab(url: url, in: spaceID)
                }
            }
            return CommandResult(id: "compound-video", kind: .action(action), title: action.title, subtitle: action.subtitle, symbolName: action.symbolName, score: PriorityScore.compoundSyntax)
        }
        if lowered.hasPrefix("folder of ") {
            let subject = String(text.dropFirst("folder of ".count))
            guard !subject.isEmpty else { return nil }
            let action = CommandAction(id: "folder-of", title: "Folder of \(subject)", subtitle: "Create a Pinned folder of related links", symbolName: "folder.badge.plus") { env in
                Task { await CommandBarEngine.createFolderOfLinks(subject: subject, searchEngine: searchEngine, env: env) }
            }
            return CommandResult(id: "compound-folder", kind: .action(action), title: action.title, subtitle: action.subtitle, symbolName: action.symbolName, score: PriorityScore.compoundSyntax)
        }
        return nil
    }

    @MainActor
    private static func createFolderOfLinks(subject: String, searchEngine engine: SearchEngine, env: AppEnvironment) async {
        guard let spaceID = env.activeSpace?.id else { return }
        // Must honour includesSearchSuggestions like CommandBarView.refreshResults, or this hits the suggestion endpoint even when suggestions are off.
        let related = env.includesSearchSuggestions
            ? await SearchSuggestionsClient.shared.suggestions(for: subject, engine: engine)
            : []
        let folderID = env.createFolder(name: subject.capitalized, in: spaceID)
        let queries = related.isEmpty ? [subject] : Array(related.prefix(5))
        for query in queries {
            guard let url = engine.searchURL(for: query) else { continue }
            let tabID = env.openTab(url: url, in: spaceID, section: .pinned, activate: false)
            env.moveNode(tabID, toParent: folderID, atIndex: .max, in: spaceID)
        }
    }
}

/// A history entry with its search text lowercased once, when it enters the history cache, instead of on every keystroke.
/// A class so that copying the cache into a scoring request moves references, not the prepared strings.
nonisolated final class PreparedHistoryEntry: Sendable {
    let entry: HistoryEntry
    let title: FuzzyMatcher.PreparedText
    let urlText: FuzzyMatcher.PreparedText
    /// What the Command Bar fuzzy-matches: [title] + CommandBarEngine.searchFields(for: url).
    let searchFields: [FuzzyMatcher.PreparedText]
    /// The host-derived subset of `searchFields`.
    let hostFields: [FuzzyMatcher.PreparedText]
    let dedupeKey: String

    init(_ entry: HistoryEntry) {
        self.entry = entry
        let fields = CommandBarEngine.preparedFields(title: entry.title, url: entry.url)
        title = fields.search[0]
        urlText = fields.search[1]
        searchFields = fields.search
        hostFields = fields.host
        dedupeKey = CommandBarEngine.dedupeKey(for: entry.url)
    }
}
