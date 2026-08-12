//  Synchronous and blocking (file copies and SQLite) — callers must never run this on the main thread.

import Foundation

public struct BrowserDataReader: Sendable {

    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func availableBrowsers() -> [ImportableBrowser] {
        ImportableBrowser.allCases.filter { $0.isPresent(homeDirectory: homeDirectory) }
    }

    public func read(_ browser: ImportableBrowser, historyLimit: Int = 5000) throws -> BrowserImportPayload {
        guard browser.isPresent(homeDirectory: homeDirectory) else {
            throw BrowserImportError.notInstalled(browser)
        }

        let folders: [ImportedBookmarkFolder]
        let visits: [ImportedVisit]

        switch browser {
        case .safari:
            folders = try SafariImportReader.readBookmarks(homeDirectory: homeDirectory)
            visits = try SafariImportReader.readHistory(homeDirectory: homeDirectory, limit: historyLimit)
        case .arc:
            // Flattened view (one folder per Space); readArc(...)/ArcImportCoordinator preserve the real structure.
            let payload = try ArcImportReader.read(
                homeDirectory: homeDirectory,
                browser: browser,
                historyLimit: historyLimit,
                archiveLimit: 0
            )
            folders = ArcImportReader.flattenedBookmarkFolders(payload.sidebar)
            visits = payload.visits
        case .firefox:
            (folders, visits) = try readFirefox(browser, historyLimit: historyLimit)
        case .chrome, .brave, .edge, .opera:
            (folders, visits) = try readChromium(browser, historyLimit: historyLimit)
        }

        return BrowserImportPayload(
            browser: browser,
            bookmarkRoot: ImportedBookmarkFolder(name: browser.importedFolderName, subfolders: folders),
            visits: visits
        )
    }

    // MARK: - Arc

    public func readArc(historyLimit: Int = 5000, archiveLimit: Int = 2000) throws -> ArcImportPayload {
        try ArcImportReader.read(
            homeDirectory: homeDirectory,
            historyLimit: historyLimit,
            archiveLimit: archiveLimit
        )
    }

    /// Separate from readArc() so a failure to parse Arc's plist can never cost the user their Spaces.
    public func readArcAppPreferences() throws -> ArcAppPreferences {
        try ArcAppPreferencesReader.read(homeDirectory: homeDirectory)
    }

    // MARK: - Firefox

    private func readFirefox(
        _ browser: ImportableBrowser,
        historyLimit: Int
    ) throws -> ([ImportedBookmarkFolder], [ImportedVisit]) {
        let root = FirefoxProfileLocator.rootDirectory(homeDirectory: homeDirectory)
        let profiles = FirefoxProfileLocator.profiles(in: root)
        guard !profiles.isEmpty else { throw BrowserImportError.notInstalled(browser) }

        var folders: [ImportedBookmarkFolder] = []
        var visits: [ImportedVisit] = []

        for profile in profiles {
            let profileFolders = try FirefoxImportReader.readBookmarks(browser: browser, profile: profile)
            if profiles.count > 1 {
                let wrapped = ImportedBookmarkFolder(name: profile.displayName, subfolders: profileFolders)
                if !wrapped.isEmpty { folders.append(wrapped) }
            } else {
                folders.append(contentsOf: profileFolders)
            }
            visits.append(contentsOf: try FirefoxImportReader.readHistory(
                browser: browser,
                profile: profile,
                limit: historyLimit
            ))
        }

        visits.sort { $0.visitedAt > $1.visitedAt }
        if visits.count > historyLimit {
            visits = Array(visits.prefix(max(historyLimit, 0)))
        }

        return (folders, visits)
    }

    // MARK: - Chromium family

    private func readChromium(
        _ browser: ImportableBrowser,
        historyLimit: Int
    ) throws -> ([ImportedBookmarkFolder], [ImportedVisit]) {
        guard let userData = browser.userDataDirectory(homeDirectory: homeDirectory) else {
            throw BrowserImportError.notInstalled(browser)
        }
        let profiles = ChromiumProfileLocator.profiles(in: userData)
        guard !profiles.isEmpty else { throw BrowserImportError.notInstalled(browser) }

        var folders: [ImportedBookmarkFolder] = []
        var visits: [ImportedVisit] = []

        for profile in profiles {
            let profileFolders = try ChromiumImportReader.readBookmarks(browser: browser, profile: profile)
            if profiles.count > 1 {
                let wrapped = ImportedBookmarkFolder(name: profile.displayName, subfolders: profileFolders)
                if !wrapped.isEmpty { folders.append(wrapped) }
            } else {
                folders.append(contentsOf: profileFolders)
            }
            visits.append(contentsOf: try ChromiumImportReader.readHistory(
                browser: browser,
                profile: profile,
                limit: historyLimit
            ))
        }

        visits.sort { $0.visitedAt > $1.visitedAt }
        if visits.count > historyLimit {
            visits = Array(visits.prefix(max(historyLimit, 0)))
        }

        return (folders, visits)
    }
}
