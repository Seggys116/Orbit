//  Importing twice never merges: a numbered folder ("Imported From Safari 2") is created instead.

import Foundation

public struct BrowserImportSummary: Sendable, Hashable {
    public var browser: ImportableBrowser
    public var foldersCreated: Int
    public var bookmarksImported: Int
    public var historyEntriesImported: Int

    public init(
        browser: ImportableBrowser,
        foldersCreated: Int,
        bookmarksImported: Int,
        historyEntriesImported: Int
    ) {
        self.browser = browser
        self.foldersCreated = foldersCreated
        self.bookmarksImported = bookmarksImported
        self.historyEntriesImported = historyEntriesImported
    }
}

@MainActor
public enum BrowserImportCoordinator {

    /// `historyStore` nil opens the real database (safe for a second connection — WAL + SQLITE_OPEN_FULLMUTEX); tests always pass a scratch-rooted store.
    @discardableResult
    static func performImport(
        _ browser: ImportableBrowser,
        into spaceID: SpaceID,
        env: AppEnvironment,
        reader: BrowserDataReader = BrowserDataReader(),
        historyStore: HistoryStore? = nil,
        progress: ImportProgressHandler? = nil
    ) async throws -> BrowserImportSummary {
        let payload = try await Task.detached(priority: .userInitiated) {
            try reader.read(browser)
        }.value

        progress?(.planned(.bookmarks, total: payload.bookmarkRoot.totalBookmarkCount))
        progress?(.planned(.history, total: payload.visits.count))

        let bookmarkResult = applyBookmarks(payload.bookmarkRoot, into: spaceID, env: env)
        progress?(.finished(.bookmarks, completed: bookmarkResult.bookmarksImported))
        let recorded = await applyHistory(
            payload.visits,
            into: spaceID,
            env: env,
            historyStore: historyStore,
            progress: progress
        )
        progress?(.finished(.history, completed: recorded))

        return BrowserImportSummary(
            browser: browser,
            foldersCreated: bookmarkResult.foldersCreated,
            bookmarksImported: bookmarkResult.bookmarksImported,
            historyEntriesImported: recorded
        )
    }

    // MARK: - Bookmarks

    private struct BookmarkApplyResult {
        var foldersCreated = 0
        var bookmarksImported = 0
    }

    private static func applyBookmarks(
        _ root: ImportedBookmarkFolder,
        into spaceID: SpaceID,
        env: AppEnvironment
    ) -> BookmarkApplyResult {
        var result = BookmarkApplyResult()
        guard env.store.space(spaceID) != nil else { return result }
        guard !root.isEmpty else { return result }

        let name = uniqueRootFolderName(root.name, in: spaceID, env: env)
        let rootFolderID = env.store.createFolder(name: name, in: spaceID)
        result.foldersCreated += 1

        apply(folder: root, intoFolder: rootFolderID, spaceID: spaceID, env: env, result: &result)
        return result
    }

    private static func apply(
        folder: ImportedBookmarkFolder,
        intoFolder parentID: FolderID,
        spaceID: SpaceID,
        env: AppEnvironment,
        result: inout BookmarkApplyResult
    ) {
        for bookmark in folder.bookmarks {
            let tabID = env.store.openTab(url: bookmark.url, in: spaceID, section: .pinned, activate: false)
            env.store.moveNode(tabID, toParent: parentID, atIndex: .max, in: spaceID)
            let title = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                env.store.renameTab(tabID, to: title)
            }
            result.bookmarksImported += 1
        }

        for subfolder in folder.subfolders {
            let childID = env.store.createFolder(name: subfolder.name, in: spaceID, parent: parentID)
            result.foldersCreated += 1
            apply(folder: subfolder, intoFolder: childID, spaceID: spaceID, env: env, result: &result)
        }
    }

    private static func uniqueRootFolderName(
        _ preferred: String,
        in spaceID: SpaceID,
        env: AppEnvironment
    ) -> String {
        let existing = Set(env.store.pinnedNodes(in: spaceID).compactMap { node -> String? in
            guard case .folder(let folder) = node else { return nil }
            return folder.name
        })
        guard existing.contains(preferred) else { return preferred }
        var suffix = 2
        while existing.contains("\(preferred) \(suffix)") { suffix += 1 }
        return "\(preferred) \(suffix)"
    }

    // MARK: - History

    private static func applyHistory(
        _ visits: [ImportedVisit],
        into spaceID: SpaceID,
        env: AppEnvironment,
        historyStore: HistoryStore?,
        progress: ImportProgressHandler?
    ) async -> Int {
        guard !visits.isEmpty else { return 0 }
        guard let space = env.store.space(spaceID) else { return 0 }
        let profileID = space.profileID

        let store: HistoryStore
        if let historyStore {
            store = historyStore
        } else {
            guard let opened = try? HistoryStore() else { return 0 }
            store = opened
        }

        var recorded = 0
        for (processed, visit) in visits.enumerated() {
            let historyVisit = HistoryVisit(
                url: visit.url,
                title: visit.title,
                profileID: profileID,
                spaceID: spaceID,
                wasTyped: visit.wasTyped,
                visitedAt: visit.visitedAt
            )
            do {
                _ = try await store.record(visit: historyVisit)
                recorded += 1
            } catch {
                // A visit the store rejects still counts as processed, so the bar reaches its total.
            }
            if (processed + 1) % ImportProgressCadence.historyBatch == 0 {
                progress?(.advanced(.history, completed: processed + 1))
            }
        }

        // This path bypasses recordVisit(...), so the Command Bar's history cache needs an explicit refresh or the import stays invisible to Cmd+T.
        if historyStore == nil, recorded > 0 {
            await env.reloadHistoryCacheAfterBulkImport()
        }

        return recorded
    }
}
