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
}

enum CommandResultKind {
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

extension CommandResultKind {
    enum ActivationIntent {
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

struct CommandResult: Identifiable {
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

struct CommandAction: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var symbolName: String
    var keywords: [String] = []
    var perform: (AppEnvironment) -> Void
}

enum CommandBarEngine {

    // MARK: Actions

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
            CommandAction(id: "about", title: "About Orbit", subtitle: ChromiumBuild.engineDescription, symbolName: "info.circle") { _ in
                AboutWindowController.show()
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
    private enum PriorityScore {
        static let typedURL: Double = 200
        static let compoundSyntax: Double = 180
        static let literalSearchFallback: Double = 15
        static let chatGPTAsk: Double = 14
        // A history row scores textScore + frecency, and textScore can legitimately be 0; this must stay high enough that such a row cannot outrank every fetched suggestion on nothing at all.
        static let networkSuggestion: Double = 5
    }

    private static let historyRowBudget = 8

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
        var fields = [url.absoluteString]
        guard let host = url.host() else { return fields }
        fields.append(host)
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare != host { fields.append(bare) }
        let labels = bare.split(separator: ".")
        if labels.count > 1, let name = labels.first { fields.append(String(name)) }
        return fields
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
        var items: [CommandResult] = []

        // Returning early, not filtering at the end, makes the scoping invariant structural: a live Site Search chip means the list contains only rows that search the scoped site.
        if let engine = siteSearch.active {
            return siteSearchResults(query: trimmed, engine: engine, suggestions: suggestions)
        }

        if trimmed.isEmpty {
            items.append(contentsOf: emptyStateResults(env: env))
            return items
        }

        if let compound = compoundSyntaxResult(for: trimmed, searchEngine: searchEngine) {
            items.append(compound)
        }

        if let url = Self.detectTypedURL(trimmed) {
            items.append(CommandResult(id: "typed-url", kind: .typedURL(url), title: url.absoluteString, subtitle: "Go to this address", symbolName: "arrow.right", score: PriorityScore.typedURL, faviconURL: nil, faviconHost: nil))
        } else {
            let instantURL = isInstantLinksEnabled ? InstantLinkResolver.instantURL(for: trimmed, engine: searchEngine) : nil
            items.append(CommandResult(id: "search-\(trimmed)", kind: .searchSuggestion(trimmed), title: trimmed, subtitle: "Search \(searchEngine.displayName)", symbolName: "magnifyingglass", score: PriorityScore.literalSearchFallback, faviconURL: nil, faviconHost: nil, instantOpenURL: instantURL))
        }

        if isChatGPTCommandBarAvailable, let chatGPTURL = ChatGPTCommandBar.url(for: trimmed) {
            items.append(CommandResult(
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
        var claimedDestinations = Set<String>()

        let currentSpaceID = env.activeSpace?.id
        for tab in env.state.tabs.values where tab.section != .archived && tab.id != excludedTabID {
            let fields = [tab.displayTitle] + searchFields(for: tab.url)
            guard let score = FuzzyMatcher.matchQuery(trimmed, in: fields, strictness: .substring) else { continue }
            claimedDestinations.insert(dedupeKey(for: tab.url))
            let host = tab.url.host() ?? tab.url.absoluteString
            let isElsewhere = currentSpaceID != nil && tab.spaceID != currentSpaceID
            let spaceName = isElsewhere ? env.spaces.first(where: { $0.id == tab.spaceID })?.name : nil
            items.append(CommandResult(
                id: "tab-\(tab.id)",
                kind: isElsewhere ? .tabInOtherSpace(tab.id, spaceID: tab.spaceID) : .openTab(tab.id),
                title: tab.displayTitle,
                subtitle: spaceName.map { "\($0) · \(host)" } ?? host,
                symbolName: "square.on.square",
                // +30 lets an open tab outrank equivalent history/suggestions; another Space's tab does not earn it.
                score: isElsewhere ? score : score + 30,
                faviconURL: tab.faviconURL ?? faviconGuessURL(for: tab.url),
                faviconHost: host
            ))
        }

        // De-duplicated by destination, not by id: favourites are mirrored across every Space of a Profile, each mirror with its own fresh id, so an id-only check let one favourite appear as several identical rows.
        var seenFavoriteIDs = Set<UUID>()
        let favoriteSpaces = env.spaces.sorted { lhs, _ in lhs.id == env.activeSpace?.id }
        for space in favoriteSpaces {
            for favorite in space.favorites {
                guard seenFavoriteIDs.insert(favorite.id).inserted else { continue }
                guard !claimedDestinations.contains(dedupeKey(for: favorite.url)) else { continue }
                let fields = [favorite.title] + searchFields(for: favorite.url)
                guard let score = FuzzyMatcher.matchQuery(trimmed, in: fields, strictness: .substring) else { continue }
                claimedDestinations.insert(dedupeKey(for: favorite.url))
                items.append(CommandResult(
                    id: "fav-\(favorite.id)",
                    kind: .favorite(favorite),
                    title: favorite.title,
                    subtitle: favorite.url.host(),
                    symbolName: "star.fill",
                    score: score + 20,
                    faviconURL: liveFaviconURL(for: favorite, env: env) ?? faviconGuessURL(for: favorite.url),
                    faviconHost: favorite.url.host() ?? favorite.url.absoluteString
                ))
            }
        }

        // now is a parameter, not read directly: frecency makes this function's output time-dependent, and two calls microseconds apart can break a test comparing two result lists for equality.
        // Store is asked for a wide net (40) so entries rank against each other, but only historyRowBudget reach the list, or a query like "wikipedia" fills the list with near-identical rows.
        var historyItems: [CommandResult] = []
        for entry in env.historyResults(matching: trimmed, limit: 40) {
            let key = dedupeKey(for: entry.url)
            guard !claimedDestinations.contains(key) else { continue }
            claimedDestinations.insert(key)
            // Dropped, not admitted at zero: a row with no text score still carries frecencyBoost, which for a recently-visited page can outscore most genuine matches, so an unmatched row would rank first rather than last.
            guard let textScore = FuzzyMatcher.matchQuery(trimmed, in: [entry.title] + searchFields(for: entry.url), strictness: .substring) else { continue }
            historyItems.append(CommandResult(
                id: "hist-\(entry.id)",
                kind: .history(entry),
                title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                subtitle: CommandBarRelativeTime.string(from: entry.visitedAt),
                symbolName: "clock",
                score: textScore + frecencyBoost(for: entry, now: now),
                faviconURL: faviconGuessURL(for: entry.url),
                faviconHost: entry.url.host() ?? entry.url.absoluteString
            ))
        }
        items.append(contentsOf: historyItems.sorted { $0.score > $1.score }.prefix(historyRowBudget))

        for action in allActions() {
            let haystacks = [action.title] + action.keywords
            guard let score = FuzzyMatcher.matchQuery(trimmed, in: haystacks) else { continue }
            items.append(CommandResult(id: "action-\(action.id)", kind: .action(action), title: action.title, subtitle: action.subtitle, symbolName: action.symbolName, score: score + 4))
        }

        var claimedTitles = Set(items.map { $0.title.lowercased() })
        claimedTitles.insert(trimmed.lowercased())
        for suggestion in suggestions {
            guard claimedTitles.insert(suggestion.lowercased()).inserted else { continue }
            items.append(CommandResult(id: "suggest-\(suggestion)", kind: .searchSuggestion(suggestion), title: suggestion, subtitle: "Search \(searchEngine.displayName)", symbolName: "magnifyingglass", score: PriorityScore.networkSuggestion))
        }

        return pinningVerbatimRows(in: items.sorted { $0.score > $1.score }, query: trimmed)
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
    private static func pinningVerbatimRows(in results: [CommandResult], query: String) -> [CommandResult] {
        guard let verbatimIndex = results.firstIndex(where: { isVerbatimRow($0, query: query) }) else { return results }
        var remaining = results
        var block = [remaining.remove(at: verbatimIndex)]
        if let askIndex = remaining.firstIndex(where: { if case .chatGPTAsk = $0.kind { return true }; return false }) {
            block.append(remaining.remove(at: askIndex))
        }
        // A cross-Space row must never hold the default selection, or Enter on typed text would move the user Spaces.
        let leadsWithCrossSpaceRow = remaining.first.map { if case .tabInOtherSpace = $0.kind { return true } else { return false } } ?? false
        remaining.insert(contentsOf: block, at: leadsWithCrossSpaceRow ? 0 : min(verbatimIndex, 1))
        return remaining
    }

    // MARK: Site Search

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

    private static func liveFaviconURL(for favorite: Favorite, env: AppEnvironment) -> URL? {
        guard let liveTabID = favorite.liveTabID else { return nil }
        return env.tab(liveTabID)?.faviconURL
    }

    private static func faviconGuessURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }

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

    static func detectTypedURL(_ text: String) -> URL? {
        guard !text.contains(" ") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file", "orbit", "view-source"].contains(scheme) {
            return url
        }
        let hostCandidate = text.split(separator: "/").first.map(String.init) ?? text
        // "localhost"/"localhost:3000" have no dot, so the bare-domain heuristic below would otherwise reject them.
        let hostOnly = hostCandidate.split(separator: ":").first.map(String.init) ?? hostCandidate
        if hostOnly.lowercased() == "localhost",
           hostCandidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" }) {
            return URL(string: "http://\(text)")
        }
        guard hostCandidate.contains("."), !hostCandidate.hasSuffix("."),
              hostCandidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else {
            return nil
        }
        return URL(string: "https://\(text)")
    }

    // MARK: Compound syntax (spec §3.4)

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
