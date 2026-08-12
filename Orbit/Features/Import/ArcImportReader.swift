//  | Orbit concept        | Arc source                                      |
//  |----------------------|-------------------------------------------------|
//  | Spaces, icons, themes| StorableSidebar.json -> sidebar.containers[]    |
//  | Pinned tabs, folders | same, each Space's pinned container             |
//  | Today tabs           | same, each Space's unpinned container           |
//  | Favourites           | same, the topApps container (per profile)       |
//  | Archived tabs        | StorableArchiveItems.json                       |
//  | History              | User Data/Default/History (Chromium SQLite)     |
//  | Per-host zoom        | Default/Preferences partition.per_host_zoom_levels |
//  | Site permissions     | Default/Preferences profile.content_settings    |
//  | Download directory   | Default/Preferences savefile.default_directory  |
//  | Search engine        | Default/Preferences + Default/Web Data          |
//  | Extensions           | Default/Extensions/<id>/<version>/manifest.json |
//  | Login sessions       | Default/Cookies (encrypted, Keychain-gated)     |
//  Cookies are read separately and their Keychain prompt must never appear mid-import unannounced.
//  Login Data (saved passwords) is never opened — Orbit has no password manager for it.

import Foundation

// MARK: - Payload

public struct ArcImportPayload: Sendable {
    public var sidebar: ArcSidebarDocument
    public var archived: [ArcArchivedTab]
    public var visits: [ImportedVisit]
    public var settings: ArcSettings
    public var extensions: [ArcExtension]
    public var keyBindings: ArcKeyBindingImport

    public init(
        sidebar: ArcSidebarDocument,
        archived: [ArcArchivedTab] = [],
        visits: [ImportedVisit] = [],
        settings: ArcSettings = ArcSettings(),
        extensions: [ArcExtension] = [],
        keyBindings: ArcKeyBindingImport = ArcKeyBindingImport()
    ) {
        self.sidebar = sidebar
        self.archived = archived
        self.visits = visits
        self.settings = settings
        self.extensions = extensions
        self.keyBindings = keyBindings
    }

    public var totalLiveTabCount: Int {
        sidebar.spaces.reduce(0) { running, space in
            running + space.pinned.flatMap(\.allTabs).count + space.today.flatMap(\.allTabs).count
        } + sidebar.topApps.count
    }

    public var totalFolderCount: Int {
        sidebar.spaces.reduce(0) { $0 + $1.pinned.flatMap(\.allFolders).count + $1.today.flatMap(\.allFolders).count }
    }
}

// MARK: - Reader

public enum ArcImportReader {

    public static func dataDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
    }

    public static func chromiumProfileDirectory(homeDirectory: URL) -> URL {
        dataDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("User Data/Default", isDirectory: true)
    }

    public static func isPresent(homeDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        let root = dataDirectory(homeDirectory: homeDirectory)
        if fileManager.fileExists(atPath: root.appendingPathComponent("StorableSidebar.json").path) { return true }
        let profile = chromiumProfileDirectory(homeDirectory: homeDirectory)
        return fileManager.fileExists(atPath: profile.appendingPathComponent("History").path)
    }

    public static func read(
        homeDirectory: URL,
        browser: ImportableBrowser = .arc,
        historyLimit: Int = 5000,
        archiveLimit: Int = 2000
    ) throws -> ArcImportPayload {
        guard isPresent(homeDirectory: homeDirectory) else {
            throw BrowserImportError.notInstalled(browser)
        }

        let root = dataDirectory(homeDirectory: homeDirectory)
        let profile = chromiumProfileDirectory(homeDirectory: homeDirectory)

        let sidebar: ArcSidebarDocument
        let sidebarURL = root.appendingPathComponent("StorableSidebar.json", isDirectory: false)
        if let data = try readIfPresent(sidebarURL, browser: browser) {
            sidebar = try ArcSidebarDocument.parse(data: data, browser: browser)
        } else {
            sidebar = ArcSidebarDocument(spaces: [])
        }

        var archived: [ArcArchivedTab] = []
        let archiveURL = root.appendingPathComponent("StorableArchiveItems.json", isDirectory: false)
        if let data = try readIfPresent(archiveURL, browser: browser) {
            archived = try ArcArchiveDocument.parse(data: data, browser: browser, limit: archiveLimit)
        }

        var visits: [ImportedVisit] = []
        if FileManager.default.fileExists(atPath: profile.appendingPathComponent("History").path) {
            visits = try ChromiumImportReader.readHistory(
                browser: browser,
                profile: ChromiumProfile(directory: profile, displayName: "Arc"),
                limit: historyLimit
            )
        }

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: browser)
        let extensions = try ArcExtensionInventory.read(profileDirectory: profile, browser: browser)
        let keyBindings = try ArcKeyBindingsReader.read(homeDirectory: homeDirectory, browser: browser)

        return ArcImportPayload(
            sidebar: sidebar,
            archived: archived,
            visits: visits,
            settings: settings,
            extensions: extensions,
            keyBindings: keyBindings
        )
    }

    private static func readIfPresent(_ url: URL, browser: ImportableBrowser) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(browser, path: url.path)
            }
            throw BrowserImportError.unreadable(browser, reason: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Bridging to the generic payload

    /// Fallback shape only — ArcImportCoordinator uses the native payload above, which preserves Spaces, themes, Today, favourites and the Archive.
    static func flattenedBookmarkFolders(_ sidebar: ArcSidebarDocument) -> [ImportedBookmarkFolder] {
        var folders: [ImportedBookmarkFolder] = []
        for space in sidebar.spaces {
            let folder = ImportedBookmarkFolder(
                name: space.title,
                bookmarks: space.pinned.compactMap(bookmark(from:)),
                subfolders: space.pinned.compactMap(subfolder(from:))
            )
            guard !folder.isEmpty else { continue }
            folders.append(folder)
        }
        if !sidebar.topApps.isEmpty {
            folders.append(ImportedBookmarkFolder(
                name: "Favorites",
                bookmarks: sidebar.topApps.map { ImportedBookmark(title: $0.customTitle ?? $0.title, url: $0.url) }
            ))
        }
        return folders
    }

    private static func bookmark(from item: ArcSidebarItem) -> ImportedBookmark? {
        guard case .tab(let tab) = item else { return nil }
        return ImportedBookmark(title: tab.customTitle ?? tab.title, url: tab.url)
    }

    private static func subfolder(from item: ArcSidebarItem) -> ImportedBookmarkFolder? {
        guard case .folder(let folder) = item else { return nil }
        return ImportedBookmarkFolder(
            name: folder.name,
            bookmarks: folder.children.compactMap(bookmark(from:)),
            subfolders: folder.children.compactMap(subfolder(from:))
        )
    }
}
