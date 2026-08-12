//  Bookmarks JSON: roots.{bookmark_bar,other,synced} nodes, {type, name, url, children}.
//  History SQLite: urls(url, title, visit_count, typed_count, last_visit_time); last_visit_time is the WebKit epoch (see ImportSQLiteSnapshot).

import Foundation
import SQLite3

// MARK: - Profile discovery

struct ChromiumProfile: Sendable, Hashable {
    var directory: URL
    var displayName: String
}

enum ChromiumProfileLocator {

    /// The user-data directory itself is included because Opera stores its profile files there directly, not in a Default subfolder.
    static func profiles(in userDataDirectory: URL) -> [ChromiumProfile] {
        let fileManager = FileManager.default
        var candidates: [URL] = [userDataDirectory]

        let contents = (try? fileManager.contentsOfDirectory(
            at: userDataDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in contents {
            let name = entry.lastPathComponent
            guard name == "Default" || name.hasPrefix("Profile ") else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            candidates.append(entry)
        }

        return candidates
            .filter { directory in
                fileManager.fileExists(atPath: directory.appendingPathComponent("Bookmarks").path)
                    || fileManager.fileExists(atPath: directory.appendingPathComponent("History").path)
            }
            .map { ChromiumProfile(directory: $0, displayName: displayName(for: $0, userDataDirectory: userDataDirectory)) }
            .sorted { $0.directory.path < $1.directory.path }
    }

    private static func displayName(for directory: URL, userDataDirectory: URL) -> String {
        let preferencesURL = directory.appendingPathComponent("Preferences", isDirectory: false)
        if let data = try? Data(contentsOf: preferencesURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = json["profile"] as? [String: Any],
           let name = profile["name"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if directory.standardizedFileURL == userDataDirectory.standardizedFileURL {
            return "Default"
        }
        return directory.lastPathComponent
    }
}

// MARK: - Reader

enum ChromiumImportReader {

    // MARK: Bookmarks

    private static let rootKeys: [(key: String, fallbackName: String)] = [
        ("bookmark_bar", "Bookmarks Bar"),
        ("other", "Other Bookmarks"),
        ("synced", "Mobile Bookmarks"),
    ]

    static func readBookmarks(browser: ImportableBrowser, profile: ChromiumProfile) throws -> [ImportedBookmarkFolder] {
        let url = profile.directory.appendingPathComponent("Bookmarks", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(browser, path: url.path)
            }
            throw BrowserImportError.unreadable(browser, reason: "Couldn't read the Bookmarks file: \(error.localizedDescription)")
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BrowserImportError.unreadable(browser, reason: "The Bookmarks file isn't valid JSON: \(error.localizedDescription)")
        }

        guard let document = json as? [String: Any] else {
            throw BrowserImportError.unreadable(browser, reason: "The Bookmarks file's root isn't a JSON object.")
        }
        guard let roots = document["roots"] as? [String: Any] else {
            throw BrowserImportError.unreadable(browser, reason: "The Bookmarks file has no \"roots\" object.")
        }

        var folders: [ImportedBookmarkFolder] = []
        for (key, fallbackName) in rootKeys {
            guard let node = roots[key] as? [String: Any] else { continue }
            let name = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
            let folder = self.folder(from: node, name: name)
            guard !folder.isEmpty else { continue }
            folders.append(folder.prunedOfEmptySubfolders())
        }
        return folders
    }

    private static func folder(from node: [String: Any], name: String) -> ImportedBookmarkFolder {
        var bookmarks: [ImportedBookmark] = []
        var subfolders: [ImportedBookmarkFolder] = []

        for child in (node["children"] as? [Any] ?? []) {
            guard let childNode = child as? [String: Any] else { continue }
            let childName = (childNode["name"] as? String) ?? ""
            switch childNode["type"] as? String {
            case "url":
                guard let urlString = childNode["url"] as? String,
                      let url = URL(string: urlString),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" || scheme == "file"
                else { continue }
                bookmarks.append(ImportedBookmark(title: childName.isEmpty ? (url.host() ?? urlString) : childName, url: url))
            case "folder":
                subfolders.append(folder(from: childNode, name: childName.isEmpty ? "Folder" : childName))
            default:
                continue
            }
        }

        return ImportedBookmarkFolder(name: name, bookmarks: bookmarks, subfolders: subfolders)
    }

    // MARK: History

    static func readHistory(browser: ImportableBrowser, profile: ChromiumProfile, limit: Int) throws -> [ImportedVisit] {
        let url = profile.directory.appendingPathComponent("History", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        return try ImportSQLiteSnapshot.withReadOnlyCopy(of: url, browser: browser) { handle in
            try ImportSQLiteSnapshot.query(
                handle,
                sql: """
                SELECT url, title, visit_count, typed_count, last_visit_time
                FROM urls
                WHERE last_visit_time > 0
                  AND (url LIKE 'http://%' OR url LIKE 'https://%')
                ORDER BY last_visit_time DESC
                LIMIT ?;
                """,
                browser: browser,
                bindInt64: [Int64(max(limit, 0))]
            ) { statement -> ImportedVisit? in
                guard let urlString = ImportSQLiteSnapshot.columnText(statement, 0),
                      let visitURL = URL(string: urlString),
                      let scheme = visitURL.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else { return nil }
                let title = ImportSQLiteSnapshot.columnText(statement, 1) ?? ""
                let visitCount = Int(sqlite3_column_int64(statement, 2))
                let typedCount = Int(sqlite3_column_int64(statement, 3))
                let lastVisit = sqlite3_column_int64(statement, 4)
                return ImportedVisit(
                    url: visitURL,
                    title: title,
                    visitedAt: ImportSQLiteSnapshot.dateFromChromiumTime(lastVisit),
                    visitCount: max(visitCount, 1),
                    wasTyped: typedCount > 0
                )
            }
        }
    }
}
