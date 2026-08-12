import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Errors

public enum HistoryStoreError: Error, LocalizedError, Sendable {
    case openFailed(reason: String)
    case sqlFailed(reason: String)
    case bindFailed(reason: String)
    case invalidRow(reason: String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let reason): return "Couldn't open the history database: \(reason)"
        case .sqlFailed(let reason): return "History database error: \(reason)"
        case .bindFailed(let reason): return "Failed to bind a history query parameter: \(reason)"
        case .invalidRow(let reason): return "History database returned an unreadable row: \(reason)"
        }
    }
}

// MARK: - A visit event to record

public struct HistoryVisit: Sendable, Hashable {
    public var url: URL
    public var title: String
    public var profileID: ProfileID
    public var spaceID: SpaceID?
    public var wasTyped: Bool
    public var visitedAt: Date

    public init(
        url: URL,
        title: String,
        profileID: ProfileID,
        spaceID: SpaceID? = nil,
        wasTyped: Bool = false,
        visitedAt: Date = Date()
    ) {
        self.url = url
        self.title = title
        self.profileID = profileID
        self.spaceID = spaceID
        self.wasTyped = wasTyped
        self.visitedAt = visitedAt
    }
}

// MARK: - HistoryStore

public actor HistoryStore {

    private let db: OpaquePointer
    private var statementCache: [String: OpaquePointer] = [:]

    // MARK: Init / teardown

    public init(databaseURL: URL = HistoryStore.defaultDatabaseURL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error (code \(openResult))"
            if let handle { sqlite3_close(handle) }
            throw HistoryStoreError.openFailed(reason: message)
        }
        self.db = handle

        try configurePragmas()
        try createSchemaIfNeeded()

        checkpointPassive()
    }

    deinit {
        for (_, statement) in statementCache {
            sqlite3_finalize(statement)
        }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_close(db)
    }

    public nonisolated static var defaultDatabaseURL: URL { OrbitDataRoot.processDefault.historyDatabase }

    // MARK: - Schema

    private func configurePragmas() throws {
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA wal_autocheckpoint = 200;")
    }

    private func createSchemaIfNeeded() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS urls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            host TEXT NOT NULL DEFAULT '',
            visit_count INTEGER NOT NULL DEFAULT 0,
            typed_count INTEGER NOT NULL DEFAULT 0,
            last_visit_time REAL NOT NULL DEFAULT 0,
            profile_id TEXT NOT NULL,
            space_id TEXT
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url_id INTEGER NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
            visit_time REAL NOT NULL,
            was_typed INTEGER NOT NULL DEFAULT 0,
            profile_id TEXT NOT NULL,
            space_id TEXT
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_urls_host ON urls(host);")
        try exec("CREATE INDEX IF NOT EXISTS idx_urls_last_visit ON urls(last_visit_time DESC);")
        try exec("CREATE INDEX IF NOT EXISTS idx_urls_url_prefix ON urls(url);")
        try exec("CREATE INDEX IF NOT EXISTS idx_visits_time ON visits(visit_time DESC);")
        try exec("CREATE INDEX IF NOT EXISTS idx_visits_url_id ON visits(url_id);")

        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
            title, url, content='urls', content_rowid='id'
        );
        """)
        try exec("""
        CREATE TRIGGER IF NOT EXISTS urls_ai AFTER INSERT ON urls BEGIN
            INSERT INTO history_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
        END;
        """)
        try exec("""
        CREATE TRIGGER IF NOT EXISTS urls_ad AFTER DELETE ON urls BEGIN
            INSERT INTO history_fts(history_fts, rowid, title, url) VALUES('delete', old.id, old.title, old.url);
        END;
        """)
        try exec("DROP TRIGGER IF EXISTS urls_au;")
        try exec("""
        CREATE TRIGGER urls_au AFTER UPDATE ON urls
        WHEN new.title IS NOT old.title OR new.url IS NOT old.url
        BEGIN
            INSERT INTO history_fts(history_fts, rowid, title, url) VALUES('delete', old.id, old.title, old.url);
            INSERT INTO history_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
        END;
        """)
    }

    // MARK: - Recording visits

    @discardableResult
    public func record(visit: HistoryVisit) throws -> HistoryEntry {
        let urlString = visit.url.absoluteString
        let host = visit.url.host() ?? ""
        let time = visit.visitedAt.timeIntervalSince1970

        try exec("BEGIN IMMEDIATE;")
        do {
            let upsert = try statement("""
            INSERT INTO urls (url, title, host, visit_count, typed_count, last_visit_time, profile_id, space_id)
            VALUES (?, ?, ?, 1, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET
                title = excluded.title,
                host = excluded.host,
                visit_count = urls.visit_count + 1,
                typed_count = urls.typed_count + excluded.typed_count,
                last_visit_time = excluded.last_visit_time,
                profile_id = excluded.profile_id,
                space_id = excluded.space_id
            WHERE excluded.last_visit_time >= urls.last_visit_time OR urls.last_visit_time IS NULL;
            """)
            sqlite3_reset(upsert)
            sqlite3_clear_bindings(upsert)
            try bindText(upsert, 1, urlString)
            try bindText(upsert, 2, visit.title)
            try bindText(upsert, 3, host)
            try bindInt(upsert, 4, visit.wasTyped ? 1 : 0)
            try bindDouble(upsert, 5, time)
            try bindText(upsert, 6, visit.profileID.uuidString)
            try bindOptionalText(upsert, 7, visit.spaceID?.uuidString)
            let stepResult = sqlite3_step(upsert)
            guard stepResult == SQLITE_DONE else {
                throw HistoryStoreError.sqlFailed(reason: lastErrorMessage())
            }

            let touchedRows = sqlite3_changes(db)
            if touchedRows == 0 {
                let bump = try statement("""
                UPDATE urls SET
                    visit_count = visit_count + 1,
                    typed_count = typed_count + ?
                WHERE url = ?;
                """)
                sqlite3_reset(bump)
                sqlite3_clear_bindings(bump)
                try bindInt(bump, 1, visit.wasTyped ? 1 : 0)
                try bindText(bump, 2, urlString)
                guard sqlite3_step(bump) == SQLITE_DONE else {
                    throw HistoryStoreError.sqlFailed(reason: lastErrorMessage())
                }
            }

            let urlID = try rowID(forURL: urlString)

            let insertVisit = try statement("""
            INSERT INTO visits (url_id, visit_time, was_typed, profile_id, space_id)
            VALUES (?, ?, ?, ?, ?);
            """)
            sqlite3_reset(insertVisit)
            sqlite3_clear_bindings(insertVisit)
            try bindInt64(insertVisit, 1, urlID)
            try bindDouble(insertVisit, 2, time)
            try bindInt(insertVisit, 3, visit.wasTyped ? 1 : 0)
            try bindText(insertVisit, 4, visit.profileID.uuidString)
            try bindOptionalText(insertVisit, 5, visit.spaceID?.uuidString)
            guard sqlite3_step(insertVisit) == SQLITE_DONE else {
                throw HistoryStoreError.sqlFailed(reason: lastErrorMessage())
            }

            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        checkpointPassive()

        guard let entry = try entry(forURL: urlString) else {
            throw HistoryStoreError.invalidRow(reason: "Row for \(urlString) vanished immediately after upsert.")
        }
        return entry
    }

    // MARK: - Frecency-ranked search

    public func search(_ query: String, limit: Int = 50, now: Date = Date()) throws -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        struct Candidate {
            let entry: HistoryEntry
            let visitCount: Int
            let typedCount: Int
            let host: String
        }

        var candidates: [Candidate] = []

        if trimmed.isEmpty {
            let stmt = try statement("""
            SELECT url, title, visit_count, typed_count, last_visit_time, profile_id, space_id, host
            FROM urls ORDER BY last_visit_time DESC LIMIT ?;
            """)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindInt(stmt, 1, Int32(max(limit, 1) * 4))
            candidates = try readCandidates(stmt).map {
                Candidate(entry: $0.entry, visitCount: $0.visitCount, typedCount: $0.typedCount, host: $0.host)
            }
        } else {
            let ftsQuery = Self.ftsMatchExpression(for: trimmed)
            let stmt = try statement("""
            SELECT urls.url, urls.title, urls.visit_count, urls.typed_count, urls.last_visit_time,
                   urls.profile_id, urls.space_id, urls.host
            FROM history_fts
            JOIN urls ON urls.id = history_fts.rowid
            WHERE history_fts MATCH ?
            LIMIT ?;
            """)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindText(stmt, 1, ftsQuery)
            try bindInt(stmt, 2, Int32(max(limit, 1) * 4))
            candidates = try readCandidates(stmt).map {
                Candidate(entry: $0.entry, visitCount: $0.visitCount, typedCount: $0.typedCount, host: $0.host)
            }

            if candidates.isEmpty {
                let terms = Self.searchTerms(in: trimmed)
                let clause = terms
                    .map { _ in "(url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')" }
                    .joined(separator: " AND ")
                let likeStmt = try statement("""
                SELECT url, title, visit_count, typed_count, last_visit_time, profile_id, space_id, host
                FROM urls
                WHERE \(clause)
                ORDER BY last_visit_time DESC LIMIT ?;
                """)
                sqlite3_reset(likeStmt)
                sqlite3_clear_bindings(likeStmt)
                var index: Int32 = 1
                for term in terms {
                    let pattern = "%\(Self.escapeLikePattern(term))%"
                    try bindText(likeStmt, index, pattern)
                    try bindText(likeStmt, index + 1, pattern)
                    index += 2
                }
                try bindInt(likeStmt, index, Int32(max(limit, 1) * 4))
                candidates = try readCandidates(likeStmt).map {
                    Candidate(entry: $0.entry, visitCount: $0.visitCount, typedCount: $0.typedCount, host: $0.host)
                }
            }
        }

        let lowerQuery = trimmed.lowercased()
        let leadingTerm = Self.searchTerms(in: trimmed).first?.lowercased() ?? ""
        let scored = candidates.map { candidate -> (HistoryEntry, Double) in
            let base = Self.frecencyScore(
                visitCount: candidate.visitCount,
                typedCount: candidate.typedCount,
                lastVisit: candidate.entry.visitedAt,
                now: now
            )
            let host = candidate.host.lowercased()
            let title = candidate.entry.title.lowercased()
            let urlString = candidate.entry.url.absoluteString.lowercased()
            let matchMultiplier: Double
            if lowerQuery.isEmpty {
                matchMultiplier = 1.0
            } else if host.hasPrefix(lowerQuery) {
                matchMultiplier = 3.0
            } else if title.hasPrefix(lowerQuery) || urlString.hasPrefix(lowerQuery) {
                matchMultiplier = 2.5
            } else if !leadingTerm.isEmpty, host.hasPrefix(leadingTerm) {
                matchMultiplier = 2.0
            } else if !leadingTerm.isEmpty, title.hasPrefix(leadingTerm) {
                matchMultiplier = 1.75
            } else {
                matchMultiplier = 1.0
            }
            return (candidate.entry, base * matchMultiplier)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    public nonisolated static func frecencyScore(
        visitCount: Int,
        typedCount: Int,
        lastVisit: Date,
        now: Date = Date()
    ) -> Double {
        let halfLifeDays = 4.0
        let typedBonus = 2.0
        let recencyFloor = 0.15

        let ageInDays = max(0, now.timeIntervalSince(lastVisit) / 86_400)
        let recencyDecay = exp(-log(2) * ageInDays / halfLifeDays)
        let frequencyWeight = log2(Double(max(visitCount, 0)) + 1) + typedBonus * log2(Double(max(typedCount, 0)) + 1)
        return frequencyWeight * (recencyFloor + (1 - recencyFloor) * recencyDecay)
    }

    // MARK: - Date-range listing (Cmd+Y)

    public func entries(in dateRange: ClosedRange<Date>, limit: Int = 1000) throws -> [HistoryEntry] {
        let stmt = try statement("""
        SELECT urls.url, urls.title, visits.visit_time, urls.visit_count, urls.typed_count,
               visits.profile_id, visits.space_id, urls.host, visits.was_typed
        FROM visits
        JOIN urls ON urls.id = visits.url_id
        WHERE visits.visit_time >= ? AND visits.visit_time <= ?
        ORDER BY visits.visit_time DESC
        LIMIT ?;
        """)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        try bindDouble(stmt, 1, dateRange.lowerBound.timeIntervalSince1970)
        try bindDouble(stmt, 2, dateRange.upperBound.timeIntervalSince1970)
        try bindInt(stmt, 3, Int32(max(limit, 1)))

        var results: [HistoryEntry] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw HistoryStoreError.sqlFailed(reason: lastErrorMessage()) }
            guard let urlString = columnText(stmt, 0), let url = URL(string: urlString) else { continue }
            let title = columnText(stmt, 1) ?? ""
            let visitTime = sqlite3_column_double(stmt, 2)
            let visitCount = Int(sqlite3_column_int64(stmt, 3))
            let profileIDString = columnText(stmt, 5) ?? ""
            let spaceIDString = columnText(stmt, 6)
            let wasTyped = sqlite3_column_int(stmt, 8) != 0
            guard let profileID = UUID(uuidString: profileIDString) else { continue }
            results.append(HistoryEntry(
                url: url,
                title: title,
                visitedAt: Date(timeIntervalSince1970: visitTime),
                visitCount: visitCount,
                profileID: profileID,
                spaceID: spaceIDString.flatMap(UUID.init(uuidString:)),
                wasTyped: wasTyped
            ))
        }
        return results
    }

    // MARK: - URL-fragment listing (recent-pages Previews)

    public func entries(
        matchingURLFragment fragment: String,
        since: Date,
        limit: Int = 50,
        excludingSpaceIDs: Set<UUID> = []
    ) throws -> [HistoryEntry] {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let excluded = excludingSpaceIDs.map { $0.uuidString }.sorted()
        let exclusionClause = excluded.isEmpty
            ? ""
            : " AND (space_id IS NULL OR space_id NOT IN (\(Array(repeating: "?", count: excluded.count).joined(separator: ", "))))"

        let stmt = try statement("""
        SELECT url, title, visit_count, typed_count, last_visit_time, profile_id, space_id, host
        FROM urls
        WHERE url LIKE ? ESCAPE '\\' AND last_visit_time >= ?\(exclusionClause)
        ORDER BY last_visit_time DESC
        LIMIT ?;
        """)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)

        var index: Int32 = 1
        try bindText(stmt, index, "%\(Self.escapeLikePattern(trimmed))%")
        index += 1
        try bindDouble(stmt, index, since.timeIntervalSince1970)
        index += 1
        for spaceID in excluded {
            try bindText(stmt, index, spaceID)
            index += 1
        }
        try bindInt(stmt, index, Int32(max(limit, 1)))

        return try readCandidates(stmt).map(\.entry)
    }

    // MARK: - Deletion

    @discardableResult
    public func deleteEntries(matching url: URL) throws -> Bool {
        let stmt = try statement("DELETE FROM urls WHERE url = ?;")
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        try bindText(stmt, 1, url.absoluteString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sqlFailed(reason: lastErrorMessage())
        }
        let removed = sqlite3_changes(db) > 0
        checkpointPassive()
        return removed
    }

    @discardableResult
    public func deleteEntries(forHost host: String, includingSubdomains: Bool = true) throws -> Int {
        let stmt: OpaquePointer
        if includingSubdomains {
            stmt = try statement("DELETE FROM urls WHERE host = ? OR host LIKE ?;")
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindText(stmt, 1, host)
            try bindText(stmt, 2, "%.\(Self.escapeLikePattern(host))")
        } else {
            stmt = try statement("DELETE FROM urls WHERE host = ?;")
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindText(stmt, 1, host)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sqlFailed(reason: lastErrorMessage())
        }
        let changed = Int(sqlite3_changes(db))
        checkpointPassive()
        return changed
    }

    public func clear(since: Date? = nil) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            if let since {
                let deleteVisits = try statement("DELETE FROM visits WHERE visit_time >= ?;")
                sqlite3_reset(deleteVisits)
                sqlite3_clear_bindings(deleteVisits)
                try bindDouble(deleteVisits, 1, since.timeIntervalSince1970)
                guard sqlite3_step(deleteVisits) == SQLITE_DONE else {
                    throw HistoryStoreError.sqlFailed(reason: lastErrorMessage())
                }
                try exec("""
                UPDATE urls SET
                    visit_count = (SELECT COUNT(*) FROM visits WHERE visits.url_id = urls.id),
                    typed_count = (SELECT COUNT(*) FROM visits WHERE visits.url_id = urls.id AND visits.was_typed = 1),
                    last_visit_time = COALESCE((SELECT MAX(visit_time) FROM visits WHERE visits.url_id = urls.id), 0);
                """)
                try exec("DELETE FROM urls WHERE visit_count = 0;")
            } else {
                try exec("DELETE FROM visits;")
                try exec("DELETE FROM urls;")
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        checkpointPassive()
    }

    // MARK: - Lookup helpers

    private func entry(forURL urlString: String) throws -> HistoryEntry? {
        let stmt = try statement("""
        SELECT url, title, visit_count, typed_count, last_visit_time, profile_id, space_id, host
        FROM urls WHERE url = ? LIMIT 1;
        """)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        try bindText(stmt, 1, urlString)
        let rows = try readCandidates(stmt)
        return rows.first?.entry
    }

    private func rowID(forURL urlString: String) throws -> Int64 {
        let stmt = try statement("SELECT id FROM urls WHERE url = ? LIMIT 1;")
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        try bindText(stmt, 1, urlString)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_reset(stmt)
            throw HistoryStoreError.invalidRow(reason: "No urls row for \(urlString) after upsert.")
        }
        let id = sqlite3_column_int64(stmt, 0)
        sqlite3_reset(stmt)
        return id
    }

    private func readCandidates(_ stmt: OpaquePointer) throws -> [(entry: HistoryEntry, visitCount: Int, typedCount: Int, host: String)] {
        var results: [(HistoryEntry, Int, Int, String)] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw HistoryStoreError.sqlFailed(reason: lastErrorMessage()) }
            guard let urlString = columnText(stmt, 0), let url = URL(string: urlString) else { continue }
            let title = columnText(stmt, 1) ?? ""
            let visitCount = Int(sqlite3_column_int64(stmt, 2))
            let typedCount = Int(sqlite3_column_int64(stmt, 3))
            let lastVisit = sqlite3_column_double(stmt, 4)
            let profileIDString = columnText(stmt, 5) ?? ""
            let spaceIDString = columnText(stmt, 6)
            let host = columnText(stmt, 7) ?? ""
            guard let profileID = UUID(uuidString: profileIDString) else { continue }
            let entry = HistoryEntry(
                url: url,
                title: title,
                visitedAt: Date(timeIntervalSince1970: lastVisit),
                visitCount: visitCount,
                profileID: profileID,
                spaceID: spaceIDString.flatMap(UUID.init(uuidString:)),
                wasTyped: typedCount > 0
            )
            results.append((entry, visitCount, typedCount, host))
        }
        return results
    }

    // MARK: - Low-level SQLite plumbing

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw HistoryStoreError.sqlFailed(reason: lastErrorMessage())
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            return cached
        }
        var handle: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard result == SQLITE_OK, let handle else {
            throw HistoryStoreError.sqlFailed(reason: lastErrorMessage())
        }
        statementCache[sql] = handle
        return handle
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private func checkpointPassive() {
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) throws {
        let result = sqlite3_bind_text(stmt, index, value, -1, Self.sqliteTransient)
        guard result == SQLITE_OK else { throw HistoryStoreError.bindFailed(reason: lastErrorMessage()) }
    }

    private func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) throws {
        if let value {
            try bindText(stmt, index, value)
        } else {
            guard sqlite3_bind_null(stmt, index) == SQLITE_OK else {
                throw HistoryStoreError.bindFailed(reason: lastErrorMessage())
            }
        }
    }

    private func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int32) throws {
        guard sqlite3_bind_int(stmt, index, value) == SQLITE_OK else {
            throw HistoryStoreError.bindFailed(reason: lastErrorMessage())
        }
    }

    private func bindInt64(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(stmt, index, value) == SQLITE_OK else {
            throw HistoryStoreError.bindFailed(reason: lastErrorMessage())
        }
    }

    private func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double) throws {
        guard sqlite3_bind_double(stmt, index, value) == SQLITE_OK else {
            throw HistoryStoreError.bindFailed(reason: lastErrorMessage())
        }
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private nonisolated static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    nonisolated static func searchTerms(in query: String) -> [String] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return terms.isEmpty ? [query] : terms
    }

    nonisolated static func ftsMatchExpression(for query: String) -> String {
        searchTerms(in: query)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " AND ")
    }

    // SQLITE_TRANSIENT: tells SQLite to copy the string now; SQLITE_STATIC here would be a use-after-free once the Swift String is deallocated.
    private nonisolated static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
