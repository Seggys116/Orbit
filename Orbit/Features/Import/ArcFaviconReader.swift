//  Favicons (Chromium SQLite): icon_mapping(page_url, icon_id) -> favicons(id, icon_type) -> favicon_bitmaps(icon_id, image_data, width, height).
//  A host usually has several bitmaps (16, 32, 180…), so only the best one per host is worth importing; image_data is PNG or ICO bytes.

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
    /// Rows fetched per host allowed for, since a host contributes several bitmaps and several page URLs.
    static let rowsPerHost = 8

    public static func read(
        profileDirectory: URL,
        browser: ImportableBrowser,
        limit: Int = 2000
    ) throws -> [ArcFavicon] {
        let url = profileDirectory.appendingPathComponent(databaseName, isDirectory: false)
        guard limit > 0, FileManager.default.fileExists(atPath: url.path) else { return [] }

        let candidates = try ImportSQLiteSnapshot.withReadOnlyCopy(of: url, browser: browser) { handle in
            try ImportSQLiteSnapshot.query(
                handle,
                sql: """
                SELECT m.page_url, b.image_data, b.width, b.height
                FROM icon_mapping m
                JOIN favicons f ON f.id = m.icon_id
                JOIN favicon_bitmaps b ON b.icon_id = f.id
                WHERE f.icon_type != 0
                  AND b.width > 0
                  AND b.height > 0
                  AND b.image_data IS NOT NULL
                  AND length(b.image_data) > 0
                ORDER BY b.last_updated DESC, b.width DESC
                LIMIT ?;
                """,
                browser: browser,
                bindInt64: [Int64(min(limit, 100_000)) * Int64(rowsPerHost)]
            ) { statement -> ArcFavicon? in
                guard let pageURL = ImportSQLiteSnapshot.columnText(statement, 0),
                      let host = host(ofPageURL: pageURL),
                      let imageData = ImportSQLiteSnapshot.columnBlob(statement, 1)
                else { return nil }
                return ArcFavicon(
                    host: host,
                    imageData: imageData,
                    width: Int(sqlite3_column_int64(statement, 2)),
                    height: Int(sqlite3_column_int64(statement, 3))
                )
            }
        }

        return bestPerHost(candidates, limit: limit)
    }

    static func bestPerHost(_ candidates: [ArcFavicon], limit: Int) -> [ArcFavicon] {
        var bestByHost: [String: ArcFavicon] = [:]
        var order: [String] = []
        for candidate in candidates {
            guard let current = bestByHost[candidate.host] else {
                bestByHost[candidate.host] = candidate
                order.append(candidate.host)
                continue
            }
            if isBetter(candidate, than: current) { bestByHost[candidate.host] = candidate }
        }
        return order.prefix(max(limit, 0)).compactMap { bestByHost[$0] }
    }

    /// Width first, then square over stretched — a 32x16 bitmap renders letterboxed where a 32x32 one fills the slot.
    static func isBetter(_ candidate: ArcFavicon, than current: ArcFavicon) -> Bool {
        if candidate.width != current.width { return candidate.width > current.width }
        if candidate.isSquare != current.isSquare { return candidate.isSquare }
        return candidate.height > current.height
    }

    /// Matches the key Orbit caches live favicons under: URL.host(), lowercased and never stripped of www.
    static func host(ofPageURL pageURL: String) -> String? {
        guard let url = URL(string: pageURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return host.lowercased()
    }
}
