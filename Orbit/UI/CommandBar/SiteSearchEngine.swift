// This file is symlinked into the host-less OrbitTests target: it must never import AppEnvironment or AppKit/SwiftUI.

import Foundation

// MARK: - Record

nonisolated struct SiteSearchEngine: Identifiable, Codable, Equatable, Sendable {

    static let queryPlaceholder = "%s"

    var id: UUID
    var name: String
    var shortcut: String
    var urlTemplate: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        shortcut: String,
        urlTemplate: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.urlTemplate = urlTemplate
        self.createdAt = createdAt
    }

    // Placeholder is stripped before parsing: %s can appear in the path (not just the query), which URL(string:) does not tolerate everywhere.
    var host: String? {
        let stripped = urlTemplate.replacingOccurrences(of: Self.queryPlaceholder, with: "")
        guard let url = URL(string: stripped), let host = url.host() else { return nil }
        return host
    }

    static func sourcedDefaults(createdAt: Date = Date()) -> [SiteSearchEngine] {
        [
            SiteSearchEngine(name: "Amazon", shortcut: "a", urlTemplate: "https://www.amazon.com/s?k=%s", createdAt: createdAt),
            SiteSearchEngine(name: "Twitter", shortcut: "tw", urlTemplate: "https://twitter.com/search?q=%s", createdAt: createdAt),
            SiteSearchEngine(name: "YouTube", shortcut: "yt", urlTemplate: "https://www.youtube.com/results?search_query=%s", createdAt: createdAt),
        ]
    }
}

// MARK: - Trigger key

nonisolated enum SiteSearchTriggerKey: String, Codable, CaseIterable, Sendable {
    case tab
    case spaceOrTab

    var hintKeyCapLabel: String { "Tab" }

    var acceptsSpace: Bool {
        switch self {
        case .tab: return false
        case .spaceOrTab: return true
        }
    }
}

// MARK: - State handed to the ranking engine

nonisolated struct SiteSearchState: Equatable, Sendable {
    var engines: [SiteSearchEngine]
    var active: SiteSearchEngine?
    var triggerKey: SiteSearchTriggerKey

    init(
        engines: [SiteSearchEngine] = [],
        active: SiteSearchEngine? = nil,
        triggerKey: SiteSearchTriggerKey = .tab
    ) {
        self.engines = engines
        self.active = active
        self.triggerKey = triggerKey
    }

    func armedEngine(forTypedQuery query: String) -> SiteSearchEngine? {
        guard active == nil else { return nil }
        return SiteSearchMatcher.engine(forShortcut: query, in: engines)
    }
}

// MARK: - Matching and expansion

nonisolated enum SiteSearchMatcher {

    // Exact match, not a prefix: a prefix match would make typing "t" on the way to "tw" prematurely claim a shorter shortcut like "a".
    static func engine(forShortcut shortcut: String, in engines: [SiteSearchEngine]) -> SiteSearchEngine? {
        let needle = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return engines.first {
            $0.shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    // .urlQueryAllowed alone permits &=+?#/, so an unescaped query could splice a second query parameter into the URL or extend a path-style template's path.
    private static let queryEscapingAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/;")
        return allowed
    }()

    static func searchURL(for query: String, using engine: SiteSearchEngine) -> URL? {
        let template = engine.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains(SiteSearchEngine.queryPlaceholder) else { return nil }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }
        let encoded = trimmedQuery.addingPercentEncoding(withAllowedCharacters: queryEscapingAllowed) ?? trimmedQuery
        let expanded = template.replacingOccurrences(of: SiteSearchEngine.queryPlaceholder, with: encoded)
        return URL(string: expanded)
    }
}

// MARK: - Command Bar action identity

enum SiteSearchSettingsPresenter {
    static let commandActionID = "site-search-settings"

    static var present: () -> Void = {}
}
