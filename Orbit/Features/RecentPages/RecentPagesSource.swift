import Foundation

// MARK: - Query

public struct RecentPagesQuery: Hashable, Sendable {

    public static let arcLookback: TimeInterval = 2_592_000

    public var limit: Int
    public var lookback: TimeInterval
    public var excludedSpaceIDs: Set<SpaceID>

    public init(
        limit: Int = 5,
        lookback: TimeInterval = RecentPagesQuery.arcLookback,
        excludedSpaceIDs: Set<SpaceID> = []
    ) {
        self.limit = limit
        self.lookback = lookback
        self.excludedSpaceIDs = excludedSpaceIDs
    }
}

// MARK: - Source

public struct RecentPagesSource: Sendable {

    // Never throws: an empty result and a failed result must both produce no card, never a broken one.
    public let historyEntries: @Sendable (RecentPagesService, RecentPagesQuery) async -> [HistoryEntry]

    public init(historyEntries: @escaping @Sendable (RecentPagesService, RecentPagesQuery) async -> [HistoryEntry]) {
        self.historyEntries = historyEntries
    }

    public static let unavailable = RecentPagesSource { _, _ in [] }

    // historyStore is an actor, so the SQLite work runs on its executor, never the caller's.
    public static func live(historyStore: HistoryStore) -> RecentPagesSource {
        RecentPagesSource { service, query in
            do {
                return try await historyStore.entries(
                    matchingURLFragment: service.urlFragment,
                    since: Date().addingTimeInterval(-query.lookback),
                    limit: max(query.limit * 8, query.limit),
                    excludingSpaceIDs: query.excludedSpaceIDs
                )
            } catch {
                return []
            }
        }
    }
}

// MARK: - Production wiring

@MainActor
public enum RecentPagesHistoryConnection {

    public static var databaseURL: URL = HistoryStore.defaultDatabaseURL

    private static var store: HistoryStore?
    private static var didAttemptOpen = false

    public static func override(_ store: HistoryStore?) {
        Self.store = store
        didAttemptOpen = true
    }

    // Not latched on failure: latching would let one transient SQLITE_BUSY disable the card for
    // the rest of the session instead of just retrying on the next hover.
    public static func source() -> RecentPagesSource {
        if !didAttemptOpen {
            store = try? HistoryStore(databaseURL: databaseURL)
            didAttemptOpen = store != nil
        }
        guard let store else { return .unavailable }
        return .live(historyStore: store)
    }
}

// MARK: - The transform

public enum RecentPagesCard {

    public static func build(
        service: RecentPagesService,
        entries: [HistoryEntry],
        query: RecentPagesQuery,
        now: Date = Date()
    ) -> RecentPagesData? {
        let cutoff = now.addingTimeInterval(-query.lookback)

        var seenDocuments: Set<String> = []
        var seenURLs: Set<URL> = []
        var items: [RecentPagesItem] = []

        for entry in entries.sorted(by: { $0.visitedAt > $1.visitedAt }) {
            // Enforced a second time here even though HistoryStore already excludes these in SQL.
            if let spaceID = entry.spaceID, query.excludedSpaceIDs.contains(spaceID) { continue }

            guard service.matches(entry.url) else { continue }

            guard entry.visitedAt >= cutoff else { continue }

            let documentID = RecentPagesDocumentID.parse(entry.url, service: service)
            if let documentID {
                guard seenDocuments.insert(documentID).inserted else { continue }
            } else {
                guard seenURLs.insert(entry.url).inserted else { continue }
            }

            let tidy = RecentPagesTidyTitle.tidy(entry.title, for: service)
            let item = RecentPagesItem(
                url: entry.url,
                title: entry.title,
                tidyTitle: tidy,
                lastVisitDate: entry.visitedAt,
                documentID: documentID
            )
            let display = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty,
                  display.caseInsensitiveCompare(service.displayName) != .orderedSame
            else { continue }

            items.append(item)
            if items.count == query.limit { break }
        }

        return RecentPagesData(service: service, items: items)
    }
}
