//  places.sqlite: moz_places(url, title, visit_count, typed, last_visit_date); moz_bookmarks is an
//  adjacency list (type 1=bookmark, 2=folder, 3=separator). Roots are identified by stable guid, not id (titles are localised); tags________ is excluded — it's pointers to already-bookmarked URLs.

import Foundation
import SQLite3

// MARK: - Profile discovery

struct FirefoxProfile: Sendable, Hashable {
    var directory: URL
    var displayName: String
}

enum FirefoxProfileLocator {

    static func rootDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
    }

    static func profiles(in root: URL) -> [FirefoxProfile] {
        let fileManager = FileManager.default
        var found: [FirefoxProfile] = []
        var seen: Set<String> = []

        for candidate in iniProfiles(in: root) {
            let path = candidate.directory.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            guard hasPlacesDatabase(candidate.directory) else { continue }
            seen.insert(path)
            found.append(candidate)
        }

        let profilesDirectory = root.appendingPathComponent("Profiles", isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in contents.sorted(by: { $0.path < $1.path }) {
            let path = entry.standardizedFileURL.path
            guard !seen.contains(path), hasPlacesDatabase(entry) else { continue }
            seen.insert(path)
            found.append(FirefoxProfile(directory: entry, displayName: displayName(forDirectory: entry)))
        }

        return found
    }

    static func hasPlacesDatabase(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("places.sqlite").path)
    }

    static func iniProfiles(in root: URL) -> [FirefoxProfile] {
        let url = root.appendingPathComponent("profiles.ini", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var profiles: [FirefoxProfile] = []
        var isInProfileSection = false
        var name: String?
        var path: String?
        var isRelative = true

        func flush() {
            defer { name = nil; path = nil; isRelative = true }
            guard isInProfileSection, let path, !path.isEmpty else { return }
            let directory = isRelative
                ? root.appendingPathComponent(path, isDirectory: true)
                : URL(fileURLWithPath: path, isDirectory: true)
            profiles.append(FirefoxProfile(
                directory: directory,
                displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? displayName(forDirectory: directory)
            ))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                isInProfileSection = line.hasPrefix("[Profile")
                continue
            }
            guard isInProfileSection, let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            switch key.lowercased() {
            case "name": name = value
            case "path": path = value
            case "isrelative": isRelative = value != "0"
            default: continue
            }
        }
        flush()

        return profiles
    }

    /// Strips Firefox's random 8-character profile-directory salt: `o353kq8r.default-release` -> `default-release`.
    static func displayName(forDirectory directory: URL) -> String {
        let name = directory.lastPathComponent
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, !parts[1].isEmpty else { return name }
        return String(parts[1])
    }
}

// MARK: - Reader

enum FirefoxImportReader {

    static let rootGUIDs: [(guid: String, name: String)] = [
        ("toolbar_____", "Bookmarks Toolbar"),
        ("menu________", "Bookmarks Menu"),
        ("unfiled_____", "Other Bookmarks"),
        ("mobile______", "Mobile Bookmarks"),
    ]

    private enum NodeType {
        static let bookmark: Int64 = 1
        static let folder: Int64 = 2
        // 3 is a separator: no address, dropped rather than imported.
    }

    private struct Node {
        var id: Int64
        var parent: Int64
        var type: Int64
        var title: String
        var url: URL?
        var guid: String
    }

    // MARK: Bookmarks

    static func readBookmarks(browser: ImportableBrowser, profile: FirefoxProfile) throws -> [ImportedBookmarkFolder] {
        let url = profile.directory.appendingPathComponent("places.sqlite", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let nodes = try ImportSQLiteSnapshot.withReadOnlyCopy(of: url, browser: browser) { handle in
            // LEFT JOIN, not JOIN: a folder has no fk, and an inner join would drop every folder and its contents.
            try ImportSQLiteSnapshot.query(
                handle,
                sql: """
                SELECT b.id, b.parent, b.type, b.title, p.url, b.guid
                FROM moz_bookmarks AS b
                LEFT JOIN moz_places AS p ON p.id = b.fk
                ORDER BY b.parent, b.position;
                """,
                browser: browser
            ) { statement -> Node? in
                let type = sqlite3_column_int64(statement, 2)
                guard type == NodeType.bookmark || type == NodeType.folder else { return nil }
                return Node(
                    id: sqlite3_column_int64(statement, 0),
                    parent: sqlite3_column_int64(statement, 1),
                    type: type,
                    title: ImportSQLiteSnapshot.columnText(statement, 3) ?? "",
                    url: ImportSQLiteSnapshot.columnText(statement, 4).flatMap(importableURL),
                    guid: ImportSQLiteSnapshot.columnText(statement, 5) ?? ""
                )
            }
        }

        var childrenByParent: [Int64: [Node]] = [:]
        var nodesByGUID: [String: Node] = [:]
        for node in nodes {
            childrenByParent[node.parent, default: []].append(node)
            if !node.guid.isEmpty { nodesByGUID[node.guid] = node }
        }

        var folders: [ImportedBookmarkFolder] = []
        for root in rootGUIDs {
            guard let node = nodesByGUID[root.guid] else { continue }
            let folder = self.folder(
                named: root.name,
                childrenOf: node.id,
                childrenByParent: childrenByParent,
                depth: 0
            )
            guard !folder.isEmpty else { continue }
            folders.append(folder.prunedOfEmptySubfolders())
        }
        return folders
    }

    /// `depth` is a cycle guard: moz_bookmarks has no constraint against a corrupt/hand-edited loop, which would otherwise recurse until the stack overflows.
    private static func folder(
        named name: String,
        childrenOf parent: Int64,
        childrenByParent: [Int64: [Node]],
        depth: Int
    ) -> ImportedBookmarkFolder {
        guard depth < 64 else { return ImportedBookmarkFolder(name: name) }

        var bookmarks: [ImportedBookmark] = []
        var subfolders: [ImportedBookmarkFolder] = []

        for child in childrenByParent[parent] ?? [] {
            switch child.type {
            case NodeType.bookmark:
                guard let url = child.url else { continue }
                bookmarks.append(ImportedBookmark(
                    title: child.title.isEmpty ? (url.host() ?? url.absoluteString) : child.title,
                    url: url
                ))
            case NodeType.folder:
                subfolders.append(folder(
                    named: child.title.isEmpty ? "Folder" : child.title,
                    childrenOf: child.id,
                    childrenByParent: childrenByParent,
                    depth: depth + 1
                ))
            default:
                continue
            }
        }

        return ImportedBookmarkFolder(name: name, bookmarks: bookmarks, subfolders: subfolders)
    }

    // MARK: History

    static func readHistory(browser: ImportableBrowser, profile: FirefoxProfile, limit: Int) throws -> [ImportedVisit] {
        let url = profile.directory.appendingPathComponent("places.sqlite", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        return try ImportSQLiteSnapshot.withReadOnlyCopy(of: url, browser: browser) { handle in
            // hidden = 0 drops framed subdocuments and redirect waypoints Firefox itself never shows in history.
            try ImportSQLiteSnapshot.query(
                handle,
                sql: """
                SELECT url, title, visit_count, typed, last_visit_date
                FROM moz_places
                WHERE last_visit_date IS NOT NULL
                  AND last_visit_date > 0
                  AND hidden = 0
                  AND (url LIKE 'http://%' OR url LIKE 'https://%')
                ORDER BY last_visit_date DESC
                LIMIT ?;
                """,
                browser: browser,
                bindInt64: [Int64(max(limit, 0))]
            ) { statement -> ImportedVisit? in
                guard let urlString = ImportSQLiteSnapshot.columnText(statement, 0),
                      let visitURL = importableURL(urlString),
                      let scheme = visitURL.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else { return nil }
                return ImportedVisit(
                    url: visitURL,
                    title: ImportSQLiteSnapshot.columnText(statement, 1) ?? "",
                    visitedAt: ImportSQLiteSnapshot.dateFromPRTime(sqlite3_column_int64(statement, 4)),
                    visitCount: max(Int(sqlite3_column_int64(statement, 2)), 1),
                    wasTyped: sqlite3_column_int64(statement, 3) > 0
                )
            }
        }
    }

    /// Excludes `place:` (Firefox's internal smart-folder scheme) and `javascript:` bookmarklets, which Orbit cannot open.
    static func importableURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "file": return url
        default: return nil
        }
    }
}
