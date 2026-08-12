//  Never opens the source database directly — a running browser holds it open in WAL mode, so a direct open can fail (SQLITE_BUSY) or silently miss recent visits in the -wal sidecar. withReadOnlyCopy copies main + -wal/-shm/-journal into a temp directory first.

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

enum ImportSQLiteSnapshot {

    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let siblingSuffixes = ["-wal", "-shm", "-journal"]

    static func withReadOnlyCopy<T>(
        of databaseURL: URL,
        browser: ImportableBrowser,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw BrowserImportError.notInstalled(browser)
        }

        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("OrbitBrowserImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw BrowserImportError.unreadable(browser, reason: "Couldn't create a scratch directory: \(error.localizedDescription)")
        }
        defer { try? fileManager.removeItem(at: scratch) }

        let copyURL = scratch.appendingPathComponent(databaseURL.lastPathComponent, isDirectory: false)
        do {
            try fileManager.copyItem(at: databaseURL, to: copyURL)
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(browser, path: databaseURL.path)
            }
            throw BrowserImportError.unreadable(browser, reason: "Couldn't copy the database: \(error.localizedDescription)")
        }

        for suffix in siblingSuffixes {
            let sibling = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sibling.path) else { continue }
            try? fileManager.copyItem(
                at: sibling,
                to: URL(fileURLWithPath: copyURL.path + suffix)
            )
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(copyURL.path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 returned \(openResult)"
            if let handle { sqlite3_close(handle) }
            throw BrowserImportError.unreadable(browser, reason: message)
        }
        defer { sqlite3_close(handle) }

        // Opened READWRITE (not READONLY) so SQLite can replay the copied -wal; a read-only connection can't checkpoint it.
        sqlite3_exec(handle, "PRAGMA journal_mode = DELETE;", nil, nil, nil)

        return try body(handle)
    }

    static func query<Row>(
        _ handle: OpaquePointer,
        sql: String,
        browser: ImportableBrowser,
        bindInt64: [Int64] = [],
        readRow: (OpaquePointer) -> Row?
    ) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            if let statement { sqlite3_finalize(statement) }
            throw BrowserImportError.unreadable(browser, reason: message)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in bindInt64.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(offset + 1), value) == SQLITE_OK else {
                throw BrowserImportError.unreadable(browser, reason: String(cString: sqlite3_errmsg(handle)))
            }
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw BrowserImportError.unreadable(browser, reason: String(cString: sqlite3_errmsg(handle)))
            }
            if let row = readRow(statement) { rows.append(row) }
        }
        return rows
    }

    static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    // MARK: - Epoch conversions

    /// Safari: history_visits.visit_time is CFAbsoluteTime, seconds since 2001-01-01 UTC.
    static func dateFromCFAbsoluteTime(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Chromium: urls.last_visit_time is microseconds since 1601-01-01 UTC (Windows/WebKit epoch).
    static let webkitEpochOffsetSeconds: Double = 11_644_473_600

    static func dateFromChromiumTime(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - webkitEpochOffsetSeconds)
    }

    /// Firefox: moz_places.last_visit_date / moz_historyvisits.visit_date is PRTime, microseconds since the Unix epoch — no offset, but wrong scale silently lands in a plausible-looking wrong year.
    static func dateFromPRTime(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }
}
