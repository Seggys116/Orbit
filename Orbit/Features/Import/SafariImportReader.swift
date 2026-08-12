//  Bookmarks.plist node kinds: WebBookmarkTypeList (folder: Title, Children), WebBookmarkTypeLeaf (bookmark: URLString, URIDictionary.title), WebBookmarkTypeProxy (built-in pseudo-item, skipped).
//  History.db: history_items(id, url, visit_count) joined to history_visits(history_item, visit_time, title); visit_time is CFAbsoluteTime. No typed/omnibox flag exists in this schema.

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

enum SafariImportReader {

    // MARK: - Bookmarks

    private static let displayNameOverrides: [String: String] = [
        "BookmarksBar": "Favourites",
        "BookmarksMenu": "Bookmarks Menu",
    ]

    private static let skippedListTitles: Set<String> = ["com.apple.ReadingList"]

    static func readBookmarks(homeDirectory: URL) throws -> [ImportedBookmarkFolder] {
        let url = ImportableBrowser.safari
            .safariDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("Bookmarks.plist", isDirectory: false)

        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(.safari, path: url.path)
            }
            throw BrowserImportError.unreadable(.safari, reason: "Couldn't read Bookmarks.plist: \(error.localizedDescription)")
        }

        let root: Any
        do {
            var format = PropertyListSerialization.PropertyListFormat.binary
            root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw BrowserImportError.unreadable(.safari, reason: "Bookmarks.plist isn't a readable property list: \(error.localizedDescription)")
        }

        guard let rootDictionary = root as? [String: Any] else {
            throw BrowserImportError.unreadable(.safari, reason: "Bookmarks.plist's root isn't a dictionary.")
        }

        let children = rootDictionary["Children"] as? [Any] ?? []
        return children.compactMap { node -> ImportedBookmarkFolder? in
            guard let dictionary = node as? [String: Any] else { return nil }
            guard let folder = folder(from: dictionary) else { return nil }
            return folder.isEmpty ? nil : folder.prunedOfEmptySubfolders()
        }
    }

    private static func folder(from dictionary: [String: Any]) -> ImportedBookmarkFolder? {
        guard (dictionary["WebBookmarkType"] as? String) == "WebBookmarkTypeList" else { return nil }
        let rawTitle = (dictionary["Title"] as? String) ?? ""
        guard !skippedListTitles.contains(rawTitle) else { return nil }

        let name = displayNameOverrides[rawTitle] ?? (rawTitle.isEmpty ? "Bookmarks" : rawTitle)
        var bookmarks: [ImportedBookmark] = []
        var subfolders: [ImportedBookmarkFolder] = []

        for child in (dictionary["Children"] as? [Any] ?? []) {
            guard let childDictionary = child as? [String: Any] else { continue }
            switch childDictionary["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                if let bookmark = bookmark(from: childDictionary) { bookmarks.append(bookmark) }
            case "WebBookmarkTypeList":
                if let subfolder = folder(from: childDictionary) { subfolders.append(subfolder) }
            default:
                continue
            }
        }

        return ImportedBookmarkFolder(name: name, bookmarks: bookmarks, subfolders: subfolders)
    }

    private static func bookmark(from dictionary: [String: Any]) -> ImportedBookmark? {
        guard let urlString = dictionary["URLString"] as? String,
              let url = URL(string: urlString),
              url.scheme != nil
        else { return nil }
        let uriDictionary = dictionary["URIDictionary"] as? [String: Any]
        let title = (uriDictionary?["title"] as? String)
            ?? (dictionary["Title"] as? String)
            ?? url.host()
            ?? urlString
        return ImportedBookmark(title: title, url: url)
    }

    // MARK: - History

    static func readHistory(homeDirectory: URL, limit: Int) throws -> [ImportedVisit] {
        let url = ImportableBrowser.safari
            .safariDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("History.db", isDirectory: false)

        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        return try ImportSQLiteSnapshot.withReadOnlyCopy(of: url, browser: .safari) { handle in
            try ImportSQLiteSnapshot.query(
                handle,
                sql: """
                SELECT history_items.url,
                       history_visits.title,
                       history_visits.visit_time,
                       history_items.visit_count
                FROM history_visits
                JOIN history_items ON history_items.id = history_visits.history_item
                ORDER BY history_visits.visit_time DESC
                LIMIT ?;
                """,
                browser: .safari,
                bindInt64: [Int64(max(limit, 0))]
            ) { statement -> ImportedVisit? in
                guard let urlString = ImportSQLiteSnapshot.columnText(statement, 0),
                      let visitURL = URL(string: urlString),
                      visitURL.scheme != nil
                else { return nil }
                let title = ImportSQLiteSnapshot.columnText(statement, 1) ?? ""
                let visitTime = sqlite3_column_double(statement, 2)
                let visitCount = Int(sqlite3_column_int64(statement, 3))
                return ImportedVisit(
                    url: visitURL,
                    title: title,
                    visitedAt: ImportSQLiteSnapshot.dateFromCFAbsoluteTime(visitTime),
                    visitCount: max(visitCount, 1),
                    wasTyped: false
                )
            }
        }
    }
}
