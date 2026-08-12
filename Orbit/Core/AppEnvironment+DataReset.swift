import AppKit
import Foundation

// MARK: - Categories

nonisolated enum DataResetCategory: String, CaseIterable, Identifiable, Sendable {
    case history
    case cookiesAndLogins
    case cache
    case downloads
    case spacesAndTabs
    case favourites
    case notes
    case easels
    case boosts
    case extensions
    case siteSettings
    case preferences
    case syncCache

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "Browsing History"
        case .cookiesAndLogins: return "Cookies and Logins"
        case .cache: return "Cache"
        case .downloads: return "Downloads List"
        case .spacesAndTabs: return "Spaces and Tabs"
        case .favourites: return "Favourites and Bookmarks"
        case .notes: return "Notes"
        case .easels: return "Easels"
        case .boosts: return "Boosts"
        case .extensions: return "Extensions"
        case .siteSettings: return "Site Settings"
        case .preferences: return "Preferences"
        case .syncCache: return "Local iCloud Sync Cache"
        }
    }

    var detail: String {
        switch self {
        case .history: return "Every page visit Orbit has recorded on this Mac."
        case .cookiesAndLogins: return "Cookies, saved passwords, autofill entries and the data sites store on this Mac."
        case .cache: return "Cached pages, scripts and site icons."
        case .downloads: return "Orbit's list of downloads. The downloaded files stay on disk."
        case .spacesAndTabs: return "Every Space, tab and Space icon, back to a fresh sidebar."
        case .favourites: return "Favourites, bookmarked rows and bookmark folders in every Space."
        case .notes: return "Every note and everything written in it."
        case .easels: return "Every Easel and the images stored in it."
        case .boosts: return "Every Boost, including its custom CSS and JavaScript."
        case .extensions: return "Every installed extension and its files."
        case .siteSettings: return "Per-site permissions, zoom, custom site searches and the ad-blocker allowlist."
        case .preferences: return "Every Orbit setting, back to its default."
        case .syncCache: return "Orbit's local sync bookkeeping. Nothing is removed from iCloud."
        }
    }

    // A running browser process holds the profile files open and rewrites
    // Preferences on exit, so a clear only sticks after a relaunch.
    var requiresRelaunch: Bool {
        switch self {
        case .cookiesAndLogins, .extensions, .siteSettings, .preferences: return true
        default: return false
        }
    }
}

// MARK: - Outcome

nonisolated struct DataResetOutcome: Sendable, Equatable {
    var clearedCategories: Set<DataResetCategory>
    var failedCategories: Set<DataResetCategory>
    var needsRelaunch: Bool

    init(
        clearedCategories: Set<DataResetCategory> = [],
        failedCategories: Set<DataResetCategory> = [],
        needsRelaunch: Bool = false
    ) {
        self.clearedCategories = clearedCategories
        self.failedCategories = failedCategories
        self.needsRelaunch = needsRelaunch
    }
}

// MARK: - Process-global targets

// Stores and engine-side directories come from the resetting environment's data root, except
// the content-blocking cache, which is process-wide because the engine it feeds is.
@MainActor
struct DataResetTargets {
    var faviconCache: FaviconCache
    var spaceIconImages: SpaceIconImageStore
    var extensions: ExtensionStore
    var contentBlocking: ContentBlockingController
    var chromiumProfileDirectory: URL
    var syncDirectory: URL
    var contentBlockingDirectory: URL

    static func live(for environment: AppEnvironment) -> DataResetTargets {
        DataResetTargets(
            faviconCache: environment.faviconCache,
            spaceIconImages: environment.spaceIconImages,
            extensions: environment.extensionStore,
            contentBlocking: ContentBlockingRuntime.shared.controller,
            chromiumProfileDirectory: environment.dataRoot.chromiumProfile,
            syncDirectory: environment.dataRoot.sync,
            contentBlockingDirectory: FilterListStore.defaultDirectory()
        )
    }

    #if DEBUG
    // Substituted whole by a test that must not reach even the process-wide
    // content-blocking directory. nil means "use the environment's own".
    static var override: DataResetTargets?
    #endif
}

extension AppEnvironment {
    var dataResetTargets: DataResetTargets {
        #if DEBUG
        if let override = DataResetTargets.override { return override }
        #endif
        return .live(for: self)
    }
}

// MARK: - Chromium profile files

nonisolated enum ChromiumProfileData {

    static let credentialAndStorageEntries = [
        "Cookies",
        "Login Data",
        "Login Data For Account",
        "Web Data",
        "Account Web Data",
        "Affiliation Database",
        "Local Storage",
        "Session Storage",
        "WebStorage",
        "IndexedDB",
        "Service Worker",
        "File System",
    ]

    static let sqliteSidecarSuffixes = ["", "-journal", "-wal", "-shm"]

    static let preferencesFileName = "Preferences"
    static let contentSettingsKeyPath = ["profile", "content_settings", "exceptions"]

    // Every persistent session gets its own directory, so a reset sweeps them all.
    static func profileDirectories(in root: URL) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        let children = (try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return [root] + children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    static func removeCredentialsAndSiteStorage(in root: URL) -> Bool {
        let manager = FileManager.default
        var succeeded = true
        for directory in profileDirectories(in: root) {
            for entry in credentialAndStorageEntries {
                for suffix in sqliteSidecarSuffixes {
                    let url = directory.appendingPathComponent(entry + suffix)
                    guard manager.fileExists(atPath: url.path) else { continue }
                    do {
                        try manager.removeItem(at: url)
                    } catch {
                        succeeded = false
                    }
                }
            }
        }
        return succeeded
    }

    // Preferences carries state no reset category claims, so it is rewritten.
    static func clearContentSettingsExceptions(in root: URL) -> Bool {
        var succeeded = true
        for directory in profileDirectories(in: root) {
            let url = directory.appendingPathComponent(preferencesFileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONSerialization.jsonObject(with: data),
                  var json = decoded as? [String: Any] else {
                succeeded = false
                continue
            }
            guard let stripped = removingContentSettingsExceptions(from: json) else { continue }
            json = stripped
            guard let encoded = try? JSONSerialization.data(withJSONObject: json),
                  (try? encoded.write(to: url, options: .atomic)) != nil else {
                succeeded = false
                continue
            }
        }
        return succeeded
    }

    static func removingContentSettingsExceptions(from json: [String: Any]) -> [String: Any]? {
        var json = json
        guard var profile = json[contentSettingsKeyPath[0]] as? [String: Any],
              var contentSettings = profile[contentSettingsKeyPath[1]] as? [String: Any],
              contentSettings[contentSettingsKeyPath[2]] != nil else { return nil }
        contentSettings.removeValue(forKey: contentSettingsKeyPath[2])
        profile[contentSettingsKeyPath[1]] = contentSettings
        json[contentSettingsKeyPath[0]] = profile
        return json
    }
}

// MARK: - First-run document

extension BrowserStore {

    // Reuses the real first-run bootstrap rather than hand-building a document.
    @discardableResult
    func resetToFirstRun() -> OrbitState {
        recentlyClosedRecords.removeAll()
        state = OrbitState()
        bootstrapIfNeeded()
        try? saveNow()
        return state
    }
}

// MARK: - Reset

extension AppEnvironment {

    @discardableResult
    func resetData(_ categories: Set<DataResetCategory>) async -> DataResetOutcome {
        var outcome = DataResetOutcome()
        for category in DataResetCategory.allCases where categories.contains(category) {
            if await clear(category) {
                outcome.clearedCategories.insert(category)
            } else {
                outcome.failedCategories.insert(category)
            }
        }
        outcome.needsRelaunch = outcome.clearedCategories.contains { $0.requiresRelaunch }
        return outcome
    }

    @discardableResult
    func resetEverything() async -> DataResetOutcome {
        var outcome = await resetData(Set(DataResetCategory.allCases))
        let targets = dataResetTargets

        if !AppEnvironment.removeContents(of: targets.chromiumProfileDirectory) {
            outcome.clearedCategories.remove(.cookiesAndLogins)
            outcome.failedCategories.insert(.cookiesAndLogins)
        }
        if AppEnvironment.removeContents(of: targets.contentBlockingDirectory) {
            ContentBlockingRuntime.shared.reset()
        } else {
            outcome.clearedCategories.remove(.siteSettings)
            outcome.failedCategories.insert(.siteSettings)
        }

        outcome.needsRelaunch = true
        return outcome
    }

    // MARK: - Per category

    private func clear(_ category: DataResetCategory) async -> Bool {
        switch category {
        case .history:
            return await clearAllHistory()
        case .cookiesAndLogins:
            let engineCleared = await clearEngineData(.cookies)
            let filesRemoved = ChromiumProfileData.removeCredentialsAndSiteStorage(
                in: dataResetTargets.chromiumProfileDirectory
            )
            return engineCleared && filesRemoved
        case .cache:
            dataResetTargets.faviconCache.removeAll()
            return await clearEngineData(.cache)
        case .downloads:
            downloadStore.removeAllRecords()
            downloadIDByTab.removeAll()
            return true
        case .spacesAndTabs:
            return resetSpacesAndTabs()
        case .favourites:
            return resetFavouritesAndBookmarks()
        case .notes:
            noteStore.deleteAllNotes()
            return true
        case .easels:
            easelStore.deleteAllEasels()
            return true
        case .boosts:
            boostStore.deleteAllBoosts()
            BoostRuntime.shared.reset()
            return true
        case .extensions:
            do {
                try dataResetTargets.extensions.removeAllExtensions()
                return true
            } catch {
                return false
            }
        case .siteSettings:
            return await resetSiteSettings()
        case .preferences:
            resetPreferences()
            return true
        case .syncCache:
            return resetLocalSyncCache()
        }
    }

    // An environment with no engine has no engine-side data to clear, which is
    // not a failure — a failure here means the clear was asked for and refused.
    private func clearEngineData(_ scope: BrowsingDataScope) async -> Bool {
        guard let engine else { return true }
        for session in knownEngineSessions() {
            await engine.clearBrowsingData(scope, session: session, since: nil)
        }
        return true
    }

    private func knownEngineSessions() -> [any EngineSession] {
        var seen: Set<ObjectIdentifier> = []
        var sessions: [any EngineSession] = []

        func take(_ session: any EngineSession) {
            guard seen.insert(ObjectIdentifier(session)).inserted else { return }
            sessions.append(session)
        }

        for contents in webContents.values where !contents.isClosed {
            take(contents.session)
        }
        guard let engine else { return sessions }
        for profile in state.profiles {
            guard let session = try? engine.session(
                identifier: profile.sessionIdentifier,
                persistent: profile.isPersistent
            ) else { continue }
            take(session)
        }
        take(engine.defaultSession)
        return sessions
    }

    private func resetSpacesAndTabs() -> Bool {
        for tabID in Array(webContents.keys) {
            releaseWebContents(for: tabID)
        }
        navigationStates.removeAll()
        navigationGeneration.removeAll()
        themeColors.removeAll()
        documentColors.removeAll()
        mediaStates.removeAll()
        tabErrors.removeAll()
        crashedTabs.removeAll()
        unresponsiveTabs.removeAll()
        certificateProblems.removeAll()
        refusedCertificateTabIDs.removeAll()
        findResultsByTab.removeAll()
        dismissedMiniPlayerTabIDs.removeAll()
        expandedFolderOverride.removeAll()

        store.resetToFirstRun()
        dataResetTargets.spaceIconImages.pruneOrphaned(keeping: [])

        if let activeSpaceID = state.activeSpaceID {
            selectSpace(activeSpaceID)
        }
        materializeActiveTabIfNeeded()
        return true
    }

    private func resetFavouritesAndBookmarks() -> Bool {
        for spaceID in store.spaces.map(\.id) {
            for favorite in store.favorites(for: spaceID) {
                store.removeFavorite(favorite.id, from: spaceID)
            }
            for tabID in store.pinnedNodes(in: spaceID).flatMap(\.allTabIDs) {
                removeBookmark(tabID)
            }
            // deleteFolder hoists children, so a nested folder becomes
            // top-level rather than vanishing — hence the sweep.
            var sweeps = 0
            while sweeps < 64 {
                let folderIDs = store.pinnedNodes(in: spaceID).compactMap { node -> FolderID? in
                    guard case .folder(let folder) = node else { return nil }
                    return folder.id
                }
                if folderIDs.isEmpty { break }
                for folderID in folderIDs {
                    store.deleteFolder(folderID, in: spaceID)
                }
                sweeps += 1
            }
        }
        return true
    }

    private func resetSiteSettings() async -> Bool {
        SiteZoomStore.removeAll()
        siteSearchStore.deleteAllEngines()
        let controller = dataResetTargets.contentBlocking
        for host in controller.allowlistedHosts {
            guard let url = URL(string: "https://\(host)") else { continue }
            _ = await controller.setAllowlisted(false, for: url)
        }
        return ChromiumProfileData.clearContentSettingsExceptions(
            in: dataResetTargets.chromiumProfileDirectory
        )
    }

    // Onboarding completion is deliberately preserved: Restart Onboarding owns it.
    private func resetPreferences() {
        let defaults = AppEnvironment.defaults
        let preserved = AppEnvironment.Keys.onboardingComplete
        for key in defaults.dictionaryRepresentation().keys
        where key != preserved && AppEnvironment.ownedPreferencePrefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    static let ownedPreferencePrefixes = ["Orbit", "contentBlocking."]

    private func resetLocalSyncCache() -> Bool {
        syncEngine?.clearLocalCaches()
        SyncPreferences.resetToDefault()
        return AppEnvironment.removeContents(of: dataResetTargets.syncDirectory)
    }

    // Never shells out: a reset that mis-resolves a path must fail, not delete
    // whatever the shell happened to glob.
    static func removeContents(of directory: URL) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return true
        }
        guard let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        var succeeded = true
        for url in contents {
            do {
                try manager.removeItem(at: url)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }
}
