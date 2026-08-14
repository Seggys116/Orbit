//  Favicons (Chromium SQLite): icon_mapping(page_url, icon_id) -> favicons(id, url, icon_type) -> favicon_bitmaps(icon_id, image_data, width, height).
//  icon_mapping is keyed per page URL, not per host — https://www.youtube.com/redirect?q=github.com genuinely carries GitHub's icon — so a host's icon is the one most of its page URLs agree on.

import Foundation
import SQLite3

public struct ArcFavicon: Sendable, Hashable {
    public var host: String
    public var imageData: Data
    public var width: Int
    public var height: Int

    public init(host: String, imageData: Data, width: Int, height: Int) {
        self.host = host
        self.imageData = imageData
        self.width = width
        self.height = height
    }

    var isSquare: Bool { width == height }
}

public enum ArcFaviconReader {

    static let databaseName = "Favicons"
    private static let blobBatchSize = 400

    struct Bitmap: Hashable {
        var id: Int64
        var width: Int
        var height: Int

        var isSquare: Bool { width == height }
    }

    struct Icon {
        var bitmap: Bitmap
        var lastUpdated: Int64
        var host: String?
    }

    struct Candidate {
        var bitmap: Bitmap
        var mappings: Int
        var isSameSite: Bool
        var lastUpdated: Int64
        var iconID: Int64
    }

    private struct HostIcon: Hashable {
        var host: String
        var iconID: Int64
    }

    public static func read(
        profileDirectory: URL,
        browser: ImportableBrowser,
        limit: Int = 2000
    ) throws -> [ArcFavicon] {
        let url = profileDirectory.appendingPathComponent(databaseName, isDirectory: false)
        guard limit > 0, FileManager.default.fileExists(atPath: url.path) else { return [] }

        return try ImportSQLiteSnapshot.withReadOnlyCopy(of: url, browser: browser) { handle in
            let icons = try readIcons(handle, browser: browser)
            guard !icons.isEmpty else { return [] }

            let winners = try rankHosts(handle, browser: browser, icons: icons, limit: limit)
            guard !winners.isEmpty else { return [] }

            let blobs = try readImageData(handle, browser: browser, bitmapIDs: winners.map(\.bitmap.id))
            return winners.compactMap { winner in
                guard let data = blobs[winner.bitmap.id] else { return nil }
                return ArcFavicon(
                    host: winner.host,
                    imageData: data,
                    width: winner.bitmap.width,
                    height: winner.bitmap.height
                )
            }
        }
    }

    /// Metadata only — the blobs of every bitmap in the database run to tens of megabytes, and all but one per host is discarded.
    static func readIcons(_ handle: OpaquePointer, browser: ImportableBrowser) throws -> [Int64: Icon] {
        var icons: [Int64: Icon] = [:]
        _ = try ImportSQLiteSnapshot.query(
            handle,
            sql: """
            SELECT b.id, b.icon_id, b.width, b.height, b.last_updated, f.url
            FROM favicon_bitmaps b
            JOIN favicons f ON f.id = b.icon_id
            WHERE f.icon_type != 0
              AND b.width > 0
              AND b.height > 0
              AND b.image_data IS NOT NULL
              AND length(b.image_data) > 0;
            """,
            browser: browser
        ) { statement -> Bool? in
            let iconID = sqlite3_column_int64(statement, 1)
            let bitmap = Bitmap(
                id: sqlite3_column_int64(statement, 0),
                width: Int(sqlite3_column_int64(statement, 2)),
                height: Int(sqlite3_column_int64(statement, 3))
            )
            let lastUpdated = sqlite3_column_int64(statement, 4)

            if var existing = icons[iconID] {
                if isBetter(bitmap, than: existing.bitmap) { existing.bitmap = bitmap }
                existing.lastUpdated = max(existing.lastUpdated, lastUpdated)
                icons[iconID] = existing
            } else {
                icons[iconID] = Icon(
                    bitmap: bitmap,
                    lastUpdated: lastUpdated,
                    host: ImportSQLiteSnapshot.columnText(statement, 5).flatMap(host(ofPageURL:))
                )
            }
            return nil
        }
        return icons
    }

    static func rankHosts(
        _ handle: OpaquePointer,
        browser: ImportableBrowser,
        icons: [Int64: Icon],
        limit: Int
    ) throws -> [(host: String, bitmap: Bitmap)] {
        var mappings: [HostIcon: Int] = [:]
        _ = try ImportSQLiteSnapshot.query(
            handle,
            sql: "SELECT page_url, icon_id FROM icon_mapping WHERE icon_id IS NOT NULL;",
            browser: browser
        ) { statement -> Bool? in
            let iconID = sqlite3_column_int64(statement, 1)
            guard icons[iconID] != nil,
                  let pageURL = ImportSQLiteSnapshot.columnText(statement, 0),
                  let host = host(ofPageURL: pageURL)
            else { return nil }
            mappings[HostIcon(host: host, iconID: iconID), default: 0] += 1
            return nil
        }

        var bestByHost: [String: Candidate] = [:]
        for (key, count) in mappings {
            guard let icon = icons[key.iconID] else { continue }
            let candidate = Candidate(
                bitmap: icon.bitmap,
                mappings: count,
                isSameSite: icon.host.map { isSameSite(iconHost: $0, pageHost: key.host) } ?? false,
                lastUpdated: icon.lastUpdated,
                iconID: key.iconID
            )
            if let current = bestByHost[key.host], !outranks(candidate, current) { continue }
            bestByHost[key.host] = candidate
        }

        return bestByHost
            .sorted { left, right in
                left.value.mappings == right.value.mappings
                    ? left.key < right.key
                    : left.value.mappings > right.value.mappings
            }
            .prefix(max(limit, 0))
            .map { (host: $0.key, bitmap: $0.value.bitmap) }
    }

    static func readImageData(
        _ handle: OpaquePointer,
        browser: ImportableBrowser,
        bitmapIDs: [Int64]
    ) throws -> [Int64: Data] {
        var blobs: [Int64: Data] = [:]
        for start in stride(from: 0, to: bitmapIDs.count, by: blobBatchSize) {
            let batch = Array(bitmapIDs[start..<min(start + blobBatchSize, bitmapIDs.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try ImportSQLiteSnapshot.query(
                handle,
                sql: "SELECT id, image_data FROM favicon_bitmaps WHERE id IN (\(placeholders));",
                browser: browser,
                bindInt64: batch
            ) { statement -> (Int64, Data)? in
                guard let data = ImportSQLiteSnapshot.columnBlob(statement, 1) else { return nil }
                return (sqlite3_column_int64(statement, 0), data)
            }
            for (id, data) in rows { blobs[id] = data }
        }
        return blobs
    }

    /// Agreement across the host's page URLs first; a host serving its own icon settles the rest.
    static func outranks(_ candidate: Candidate, _ current: Candidate) -> Bool {
        if candidate.mappings != current.mappings { return candidate.mappings > current.mappings }
        if candidate.isSameSite != current.isSameSite { return candidate.isSameSite }
        if candidate.lastUpdated != current.lastUpdated { return candidate.lastUpdated > current.lastUpdated }
        return candidate.iconID > current.iconID
    }

    /// Width first, then square over stretched — a 32x16 bitmap renders letterboxed where a 32x32 one fills the slot.
    static func isBetter(_ candidate: Bitmap, than current: Bitmap) -> Bool {
        if candidate.width != current.width { return candidate.width > current.width }
        if candidate.isSquare != current.isSquare { return candidate.isSquare }
        return candidate.height > current.height
    }

    static func isSameSite(iconHost: String, pageHost: String) -> Bool {
        iconHost == pageHost || iconHost.hasSuffix(".\(pageHost)") || pageHost.hasSuffix(".\(iconHost)")
    }

    /// The key Orbit caches live favicons under — lowercased, www intact — parsed by hand because Foundation rejects URLs Chromium stores happily.
    static func host(ofPageURL pageURL: String) -> String? {
        guard let separator = pageURL.range(of: "://") else { return nil }
        let scheme = pageURL[pageURL.startIndex..<separator.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }

        var host = pageURL[separator.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let credentials = host.lastIndex(of: "@") { host = host[host.index(after: credentials)...] }
        if host.first == "[" {
            guard let close = host.firstIndex(of: "]") else { return nil }
            host = host[host.index(after: host.startIndex)..<close]
        } else if let port = host.lastIndex(of: ":") {
            host = host[host.startIndex..<port]
        }

        let result = host.lowercased()
        return result.isEmpty ? nil : result
    }
}
