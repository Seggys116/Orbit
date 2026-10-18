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
        case .cookiesAndLogins: return "Cookies, local and session storage, IndexedDB, service workers and the other data sites store on this Mac. Passwords saved to the system keychain are not touched."
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

    // Website data and site settings are cleared live through WebKit; loaded
    // extensions and values the running UI has already read only reset on relaunch.
    var requiresRelaunch: Bool {
        switch self {
        case .extensions, .preferences: return true
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
    var contentSettingsDirectory: URL
    var syncDirectory: URL
    var contentBlockingDirectory: URL
    // nil means every session the engine and the open tabs know about.
    var engineSessions: (@MainActor () -> [any EngineSession])?

    static func live(for environment: AppEnvironment) -> DataResetTargets {
        DataResetTargets(
            faviconCache: environment.faviconCache,
            spaceIconImages: environment.spaceIconImages,
            extensions: environment.extensionStore,
            contentBlocking: ContentBlockingRuntime.shared.controller,
            contentSettingsDirectory: environment.dataRoot.contentSettings,
            syncDirectory: environment.dataRoot.sync,
            contentBlockingDirectory: FilterListStore.defaultDirectory(),
            engineSessions: nil
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

        await clearEverythingInEngine()
        materializeActiveTabIfNeeded()
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
            return await clearEngineData(.cookies)
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

    // Past what any scope names, then the persistent stores themselves. Tabs go first, since
    // WebKit will not remove a store a web view still uses; the caller rebuilds the active tab.
    func clearEverythingInEngine() async {
        // Taken before the tabs close, so a private tab's session is still in the list.
        let sessions = knownEngineSessions()
        for session in sessions {
            await (session as? WebKitSession)?.clearAllWebsiteData()
        }
        for tabID in Array(webContents.keys) {
            releaseWebContents(for: tabID)
        }
        // A store WebKit refuses to remove has still been emptied above, so this is not a failure.
        for session in sessions {
            _ = await (session as? WebKitSession)?.removePersistentDataStore()
        }
    }

    private func knownEngineSessions() -> [any EngineSession] {
        if let provided = dataResetTargets.engineSessions { return provided() }
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
        var cleared = true
        for session in knownEngineSessions() {
            if let session = session as? WebKitSession, !session.clearContentSettings() { cleared = false }
        }
        // Covers sessions this process never created, such as a deleted profile's.
        if !AppEnvironment.removeContents(of: dataResetTargets.contentSettingsDirectory) { cleared = false }
        return cleared
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
