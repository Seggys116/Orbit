//  Assigned in one mutateSpace, not per-node calls — each of those autosaves, and thousands of nodes would queue thousands of full-document encodes.

import Foundation

public struct ArcImportSummary: Sendable, Hashable {
    public var spacesCreated: Int
    public var foldersCreated: Int
    public var pinnedTabsImported: Int
    public var todayTabsImported: Int
    public var archivedTabsImported: Int
    public var favoritesImported: Int
    public var historyEntriesImported: Int
    public var faviconsImported: Int
    public var zoomLevelsImported: Int
    public var sitePermissionsImported: Int
    public var routingRulesImported: Int
    public var extensionsFound: Int
    public var extensionsInstalled: Int
    public var extensionsAlreadyInstalled: Int
    public var extensionsNeedingManualInstall: [String]
    /// True when the engine needs a restart before newly installed extensions load (Chromium reads --load-extension only at launch).
    public var extensionsNeedRestart: Bool
    public var keyBindingsImported: Int
    public var keyBindingsNeedingManualRebind: [String]
    public var cookies: ArcCookieImportOutcome
    public var siteData: ArcSiteDataImportOutcome

    public init(
        spacesCreated: Int = 0,
        foldersCreated: Int = 0,
        pinnedTabsImported: Int = 0,
        todayTabsImported: Int = 0,
        archivedTabsImported: Int = 0,
        favoritesImported: Int = 0,
        historyEntriesImported: Int = 0,
        faviconsImported: Int = 0,
        zoomLevelsImported: Int = 0,
        sitePermissionsImported: Int = 0,
        routingRulesImported: Int = 0,
        extensionsFound: Int = 0,
        extensionsInstalled: Int = 0,
        extensionsAlreadyInstalled: Int = 0,
        extensionsNeedingManualInstall: [String] = [],
        extensionsNeedRestart: Bool = false,
        keyBindingsImported: Int = 0,
        keyBindingsNeedingManualRebind: [String] = [],
        cookies: ArcCookieImportOutcome = .notAttempted,
        siteData: ArcSiteDataImportOutcome = .notAttempted
    ) {
        self.spacesCreated = spacesCreated
        self.foldersCreated = foldersCreated
        self.pinnedTabsImported = pinnedTabsImported
        self.todayTabsImported = todayTabsImported
        self.archivedTabsImported = archivedTabsImported
        self.favoritesImported = favoritesImported
        self.historyEntriesImported = historyEntriesImported
        self.faviconsImported = faviconsImported
        self.zoomLevelsImported = zoomLevelsImported
        self.sitePermissionsImported = sitePermissionsImported
        self.routingRulesImported = routingRulesImported
        self.extensionsFound = extensionsFound
        self.extensionsInstalled = extensionsInstalled
        self.extensionsAlreadyInstalled = extensionsAlreadyInstalled
        self.extensionsNeedingManualInstall = extensionsNeedingManualInstall
        self.extensionsNeedRestart = extensionsNeedRestart
        self.keyBindingsImported = keyBindingsImported
        self.keyBindingsNeedingManualRebind = keyBindingsNeedingManualRebind
        self.cookies = cookies
        self.siteData = siteData
    }

    public var totalTabsImported: Int {
        pinnedTabsImported + todayTabsImported + archivedTabsImported
    }
}

public enum ArcCookieImportOutcome: Sendable, Hashable {
    case notAttempted
    /// Decrypted but no engine session was reachable to receive them (no engine running, or the target Profile has no session).
    case decryptedButEngineCannotInstall(count: Int)
    case imported(count: Int)
    /// The ordinary outcome for a real jar, not an error: expired or __Host-/__Secure- cookies the engine legitimately rejects.
    case partiallyImported(stored: Int, decrypted: Int)
    case keychainDenied
    case failed(reason: String)
}

/// Local Storage and IndexedDB, staged here and merged in before the next launch.
public enum ArcSiteDataImportOutcome: Sendable, Hashable {
    case notAttempted
    case nothingToImport
    case staged(sites: Int, indexedDBSites: Int, bytes: Int64)
    case failed(reason: String)

    public var stagedSiteCount: Int {
        guard case .staged(let sites, let indexedDBSites, _) = self else { return 0 }
        return max(sites, indexedDBSites)
    }
}

/// Local two-case enum, not Result: the failure payload is a report (ArcCookieImportOutcome), not an Error.
enum ArcCookieDecryptionResult: Sendable {
    case decrypted([ArcCookie])
    case stopped(ArcCookieImportOutcome)
}

@MainActor
public enum ArcImportCoordinator {

    // MARK: - Entry point

    /// profileID must be a persistent Profile — StateStore strips Spaces on non-persistent Profiles at the write boundary.
    @discardableResult
    static func performImport(
        env: AppEnvironment,
        profileID: ProfileID? = nil,
        reader: BrowserDataReader = BrowserDataReader(),
        historyStore: HistoryStore? = nil,
        importCookies: Bool = false,
        importSiteData: Bool = true,
        historyLimit: Int = 5000,
        archiveLimit: Int = 2000,
        faviconLimit: Int = 2000,
        extensionStore: ExtensionStore? = nil,
        extensionInstaller: ExtensionInstaller? = nil
    ) async throws -> ArcImportSummary {
        let payload = try await Task.detached(priority: .userInitiated) {
            try reader.readArc(historyLimit: historyLimit, archiveLimit: archiveLimit, faviconLimit: faviconLimit)
        }.value

        // A plist Orbit cannot parse must not cost the user their Spaces — failure here is swallowed.
        let appPreferences = try? await Task.detached(priority: .userInitiated) {
            try reader.readArcAppPreferences()
        }.value

        var summary = apply(payload, appPreferences: appPreferences, env: env, profileID: profileID)
        summary.historyEntriesImported = await applyHistory(
            payload.visits,
            env: env,
            profileID: resolvedProfileID(profileID, env: env),
            historyStore: historyStore
        )

        await installExtensions(
            payload.extensions,
            installer: extensionInstaller,
            store: extensionStore ?? env.extensionStore,
            summary: &summary
        )

        if importCookies {
            summary.cookies = await importArcCookies(
                reader: reader,
                env: env,
                profileID: resolvedProfileID(profileID, env: env)
            )
        }

        if importSiteData {
            summary.siteData = await stageArcSiteData(reader: reader, stagingDirectory: env.dataRoot.pendingSiteData)
        }

        return summary
    }

    // MARK: - Site data

    static func stageArcSiteData(
        reader: BrowserDataReader,
        stagingDirectory: URL
    ) async -> ArcSiteDataImportOutcome {
        let profile = ArcImportReader.chromiumProfileDirectory(homeDirectory: reader.homeDirectory)
        return await Task.detached(priority: .userInitiated) { () -> ArcSiteDataImportOutcome in
            do {
                let staged = try ArcSiteDataStager.stage(profileDirectory: profile, into: stagingDirectory)
                guard !staged.isEmpty else { return .nothingToImport }
                return .staged(
                    sites: staged.localStorageOrigins,
                    indexedDBSites: staged.indexedDBOrigins,
                    bytes: staged.bytesStaged
                )
            } catch {
                return .failed(reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }.value
    }

    // MARK: - Apply

    @discardableResult
    static func apply(
        _ payload: ArcImportPayload,
        appPreferences: ArcAppPreferences? = nil,
        env: AppEnvironment,
        profileID: ProfileID? = nil,
        defaults: UserDefaults = OrbitDefaults.standard,
        shortcutRegistry: ShortcutRegistry = .shared
    ) -> ArcImportSummary {
        var summary = ArcImportSummary()
        summary.extensionsFound = payload.extensions.count
        // Host-keyed and Profile-independent, so it lands even when there is no Profile to build Spaces in.
        summary.faviconsImported = applyFavicons(payload.favicons, cache: env.faviconCache)

        let profile = resolvedProfileID(profileID, env: env)
        guard let profile else { return summary }

        env.store.setArchivePolicy(archivePolicy(from: appPreferences?.autoArchiveThreshold), forProfile: profile)

        var archivedBySpace: [UUID: [ArcArchivedTab]] = [:]
        var archivedWithoutSpace: [ArcArchivedTab] = []
        for item in payload.archived {
            if let source = item.sourceSpaceID {
                archivedBySpace[source, default: []].append(item)
            } else {
                archivedWithoutSpace.append(item)
            }
        }

        var createdSpaceByArcID: [UUID: SpaceID] = [:]

        for (offset, arcSpace) in payload.sidebar.spaces.enumerated() {
            let spaceID = env.store.createSpace(
                name: uniqueSpaceName(arcSpace.title, env: env),
                icon: icon(for: arcSpace.icon).name,
                iconIsEmoji: icon(for: arcSpace.icon).isEmoji,
                theme: spaceTheme(from: arcSpace.theme),
                profileID: profile,
                activate: false
            )
            createdSpaceByArcID[arcSpace.arcID] = spaceID
            summary.spacesCreated += 1

            var pinnedTabs: [TabID: Tab] = [:]
            let forest = pinnedForest(
                arcSpace.pinned,
                spaceID: spaceID,
                tabs: &pinnedTabs,
                foldersCreated: &summary.foldersCreated
            )
            summary.pinnedTabsImported += pinnedTabs.count

            var todayIDs: [TabID] = []
            for arcTab in arcSpace.today.flatMap(\.allTabs) {
                let tab = makeTab(arcTab, spaceID: spaceID, section: .today)
                pinnedTabs[tab.id] = tab
                todayIDs.append(tab.id)
                summary.todayTabsImported += 1
            }

            for item in (archivedBySpace[arcSpace.arcID] ?? []) {
                var tab = makeTab(item.tab, spaceID: spaceID, section: .archived)
                tab.archivedAt = item.archivedAt
                pinnedTabs[tab.id] = tab
                summary.archivedTabsImported += 1
            }
            if offset == 0 {
                for item in archivedWithoutSpace {
                    var tab = makeTab(item.tab, spaceID: spaceID, section: .archived)
                    tab.archivedAt = item.archivedAt
                    pinnedTabs[tab.id] = tab
                    summary.archivedTabsImported += 1
                }
            }

            env.store.state.tabs.merge(pinnedTabs) { _, new in new }
            env.store.mutateSpace(spaceID) { space in
                space.pinned = forest
                space.today = todayIDs
            }
        }

        // Added once, to the first imported Space — BrowserStore already mirrors a favourite across every Space sharing a Profile, so adding per-Space would duplicate.
        if let firstSpace = payload.sidebar.spaces.first.flatMap({ createdSpaceByArcID[$0.arcID] }) {
            for arcTab in payload.sidebar.topApps {
                if env.store.addFavorite(url: arcTab.url, title: arcTab.customTitle ?? arcTab.title, in: firstSpace).succeeded {
                    summary.favoritesImported += 1
                }
            }
        }

        summary.zoomLevelsImported = applyZoom(payload.settings.hostZoomLevels)
        summary.sitePermissionsImported = applySitePermissions(
            payload.settings.sitePermissions,
            profileID: profile,
            env: env
        )
        summary.routingRulesImported = applyRoutingRules(
            appPreferences?.routingRules ?? [],
            spaceByArcID: createdSpaceByArcID,
            env: env
        )
        applySearchEngine(payload.settings.searchEngineName, profileID: profile, env: env)
        applyAppPreferences(appPreferences, spaceByArcID: createdSpaceByArcID, env: env, defaults: defaults)
        // Extensions need network I/O (Web Store download + CRX3 verify) — that's installExtensions(), awaited separately by performImport.
        applyKeyBindings(payload.keyBindings, registry: shortcutRegistry, summary: &summary)

        return summary
    }

    // MARK: Favicons

    static func applyFavicons(_ favicons: [ArcFavicon], cache: FaviconCache) -> Int {
        guard !favicons.isEmpty else { return 0 }
        let byHost = Dictionary(favicons.map { ($0.host, $0.imageData) }, uniquingKeysWith: { first, _ in first })
        return cache.cacheImported(imageDataByHost: byHost)
    }

    // MARK: Key bindings

    private static func applyKeyBindings(
        _ imported: ArcKeyBindingImport,
        registry: ShortcutRegistry,
        summary: inout ArcImportSummary
    ) {
        summary.keyBindingsNeedingManualRebind = imported.unmappedActions
        guard !imported.bindings.isEmpty else { return }

        for arcBinding in imported.bindings {
            guard let command = ArcShortcutCommandMap.command(for: arcBinding.action) else {
                summary.keyBindingsNeedingManualRebind.append(arcBinding.action)
                continue
            }
            let binding = KeyBinding(key: arcBinding.key, modifiers: arcBinding.modifierFlags)
            // excluding: command, so a remap matching the command's own existing binding isn't reported as conflicting with itself.
            guard registry.commands(conflictingWith: binding, excluding: command).isEmpty else {
                summary.keyBindingsNeedingManualRebind.append(arcBinding.action)
                continue
            }
            registry.setBinding(binding, for: command)
            summary.keyBindingsImported += 1
        }
    }

    // MARK: Extensions

    // Downloads and CRX3-verifies each id from the Web Store — never copies Arc's unpacked disk directory, which carries no signature.
    // Import-then-review consent: the "Import from Arc" click is the one approval; the default installer auto-approves rather than prompting per extension, and the summary reports what happened.
    static func installExtensions(
        _ extensions: [ArcExtension],
        installer: ExtensionInstaller?,
        store: ExtensionStore,
        summary: inout ArcImportSummary
    ) async {
        guard !extensions.isEmpty else { return }
        let installer = installer ?? ExtensionInstaller(store: store) { _ in true }

        for arcExtension in extensions {
            do {
                let result = try await installer.install(arcExtension.identifier)
                guard case .installed(let loaded, _, _) = result else {
                    summary.extensionsNeedingManualInstall.append(arcExtension.name)
                    continue
                }
                if arcExtension.isEnabled == false {
                    try? store.setEnabled(false, id: loaded.id)
                }
                summary.extensionsInstalled += 1
            } catch ExtensionInstallError.alreadyInstalled {
                summary.extensionsAlreadyInstalled += 1
            } catch {
                summary.extensionsNeedingManualInstall.append(arcExtension.name)
            }
        }

        if summary.extensionsInstalled > 0 {
            summary.extensionsNeedRestart = store.hasPendingChanges
        }
    }

    // MARK: Spaces

    private static func resolvedProfileID(_ requested: ProfileID?, env: AppEnvironment) -> ProfileID? {
        if let requested, env.store.profile(requested) != nil { return requested }
        return env.store.defaultProfile?.id
    }

    static func uniqueSpaceName(_ preferred: String, env: AppEnvironment) -> String {
        let existing = Set(env.store.spaces.map(\.name))
        guard existing.contains(preferred) else { return preferred }
        var suffix = 2
        while existing.contains("\(preferred) \(suffix)") { suffix += 1 }
        return "\(preferred) \(suffix)"
    }

    /// A Material Symbols name is not mapped to an SF Symbol — the two sets share no namespace, so the Space keeps Orbit's default icon instead of a guessed, possibly-wrong one.
    static func icon(for arcIcon: ArcIcon?) -> (name: String, isEmoji: Bool) {
        switch arcIcon {
        case .emoji(let emoji) where !emoji.isEmpty:
            return (emoji, true)
        case .emoji, .materialSymbol, .none:
            return ("circle.grid.2x2", false)
        }
    }

    static func spaceTheme(from arcTheme: ArcSpaceTheme?) -> SpaceTheme? {
        guard let arcTheme, !arcTheme.baseColors.isEmpty else { return nil }

        let colors = arcTheme.baseColors.prefix(4).map {
            ThemeColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
        }
        let style: SpaceTheme.Style
        switch colors.count {
        case 1: style = .solid
        case 2: style = .linear
        default: style = .mesh
        }

        return SpaceTheme(
            style: style,
            colors: Array(colors),
            angle: 18,
            // A named grain overlay with a zero noiseFactor still had visible grain in Arc, so the texture name is treated as evidence when the factor says nothing.
            grain: arcTheme.noiseFactor > 0 ? min(max(arcTheme.noiseFactor, 0), 1)
                : (arcTheme.overlayTexture == nil ? 0 : 0.5),
            followsSystemAppearance: arcTheme.prefersDarkContent == nil,
            prefersDarkContent: arcTheme.prefersDarkContent ?? false
        )
    }

    static func archivePolicy(from threshold: ArcAutoArchiveThreshold?) -> ArchivePolicy {
        switch threshold {
        case .never: return .never
        case .twelveHours: return .after12Hours
        case .twentyFourHours: return .after24Hours
        case .sevenDays: return .after7Days
        case .thirtyDays: return .after30Days
        case nil: return .after12Hours
        }
    }

    // MARK: Trees

    private static func pinnedForest(
        _ items: [ArcSidebarItem],
        spaceID: SpaceID,
        tabs: inout [TabID: Tab],
        foldersCreated: inout Int
    ) -> [SidebarNode] {
        var nodes: [SidebarNode] = []
        for item in items {
            switch item {
            case .tab(let arcTab):
                let tab = makeTab(arcTab, spaceID: spaceID, section: .pinned)
                tabs[tab.id] = tab
                nodes.append(.tab(tab.id))
            case .folder(let arcFolder):
                foldersCreated += 1
                let children = pinnedForest(
                    arcFolder.children,
                    spaceID: spaceID,
                    tabs: &tabs,
                    foldersCreated: &foldersCreated
                )
                let iconPair = icon(for: arcFolder.icon)
                nodes.append(.folder(Folder(
                    name: arcFolder.name,
                    isExpanded: true,
                    children: children,
                    icon: iconPair.isEmoji ? iconPair.name : nil,
                    iconIsEmoji: iconPair.isEmoji
                )))
            }
        }
        return nodes
    }

    static func makeTab(_ arcTab: ArcTab, spaceID: SpaceID, section: TabSection) -> Tab {
        Tab(
            spaceID: spaceID,
            section: section,
            url: arcTab.url,
            title: arcTab.title,
            customTitle: arcTab.customTitle,
            lastAccessedAt: arcTab.lastActiveAt ?? arcTab.createdAt,
            createdAt: arcTab.createdAt,
            isUnloaded: true,
            isMuted: arcTab.isMuted,
            pinnedURL: section == .pinned ? arcTab.url : nil,
            pinnedTitle: section == .pinned ? arcTab.title : nil
        )
    }

    // MARK: Settings

    private static func applyZoom(_ zooms: [ArcHostZoom]) -> Int {
        var applied = 0
        for zoom in zooms {
            guard abs(zoom.zoomFactor - 1.0) > 0.0001 else { continue }
            SiteZoomStore.setZoomFactor(zoom.zoomFactor, forHost: zoom.host)
            applied += 1
        }
        return applied
    }

    /// A permission the running engine cannot manage (per manageableContentSettings) is skipped, not written and lost.
    private static func applySitePermissions(
        _ permissions: [ArcSitePermission],
        profileID: ProfileID,
        env: AppEnvironment
    ) -> Int {
        guard let engine = env.engine, let profile = env.store.profile(profileID) else { return 0 }
        guard let session = try? engine.session(
            identifier: profile.sessionIdentifier,
            persistent: profile.isPersistent
        ) else { return 0 }
        let manageable = engine.manageableContentSettings

        var applied = 0
        for permission in permissions {
            guard let kind = permissionKind(permission.kind), manageable.contains(kind) else { continue }
            session.setContentSetting(permission.isAllowed ? .allow : .block, for: kind, url: permission.origin)
            applied += 1
        }
        return applied
    }

    static func permissionKind(_ kind: ArcPermissionKind) -> PermissionKind? {
        switch kind {
        case .notifications: return .notifications
        case .geolocation: return .geolocation
        case .camera: return .camera
        case .microphone: return .microphone
        case .clipboardRead: return .clipboardRead
        case .automaticDownloads, .localNetwork, .durableStorage: return nil
        }
    }

    private static func applyRoutingRules(
        _ rules: [ArcRoutingRule],
        spaceByArcID: [UUID: SpaceID],
        env: AppEnvironment
    ) -> Int {
        var applied = 0
        for rule in rules {
            let pattern = rule.match.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty,
                  !pattern.contains("/"),
                  !pattern.contains(" "),
                  pattern.contains(".")
            else { continue }

            switch rule.match {
            case .contains, .equals, .endsWith:
                break
            case .startsWith, .unsupported:
                continue
            }

            let destination: RoutingRule.Destination
            switch rule.destination {
            case .space(let arcSpaceID):
                guard let spaceID = spaceByArcID[arcSpaceID] else { continue }
                destination = .space(spaceID)
            case .mostRecentSpace:
                destination = .mostRecentSpace
            case .application(let bundleID):
                destination = .application(bundleID: bundleID)
            case .littleArc:
                destination = .littleOrbit
            case .unsupported:
                continue
            }

            guard !env.store.state.routingRules.contains(where: { $0.pattern.lowercased() == pattern }) else { continue }
            env.store.state.routingRules.append(RoutingRule(pattern: pattern, destination: destination))
            applied += 1
        }
        return applied
    }

    static func searchEngine(named name: String?) -> SearchEngine? {
        guard let name = name?.lowercased() else { return nil }
        if name.contains("google") { return .google }
        if name.contains("bing") { return .bing }
        if name.contains("duckduckgo") || name.contains("duck duck go") { return .duckDuckGo }
        if name.contains("ecosia") { return .ecosia }
        return nil
    }

    private static func applySearchEngine(_ name: String?, profileID: ProfileID, env: AppEnvironment) {
        guard let engine = searchEngine(named: name) else { return }
        guard let index = env.store.state.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        env.store.state.profiles[index].searchEngine = engine
    }

    /// Sync is deliberately not imported — turning on Orbit's iCloud sync because Arc's was on would start uploading data on the strength of a different app's preference.
    private static func applyAppPreferences(
        _ preferences: ArcAppPreferences?,
        spaceByArcID: [UUID: SpaceID],
        env: AppEnvironment,
        defaults: UserDefaults
    ) {
        guard let preferences else { return }

        if let showsToolbar = preferences.showsToolbar {
            defaults.set(showsToolbar, forKey: "OrbitToolbarVisible")
        }
        if let showsFullURLs = preferences.showsFullURLs {
            defaults.set(showsFullURLs, forKey: "OrbitToolbarShowsFullURL")
        }
        if let tidyTabs = preferences.tidyTabsEnabled {
            defaults.set(tidyTabs, forKey: "OrbitAssistTidyTabsEnabled")
        }
        if let instantLinks = preferences.instantLinksEnabled {
            defaults.set(instantLinks, forKey: "OrbitAssistInstantLinksEnabled")
        }
        if let width = preferences.sidebarWidth, width > 0 {
            defaults.set(width, forKey: "OrbitSidebarWidth")
        }
        if let focused = preferences.lastFocusedSpaceID, let spaceID = spaceByArcID[focused] {
            env.store.switchToSpace(spaceID)
        }
    }

    // MARK: Cookies

    static func importArcCookies(
        reader: BrowserDataReader,
        env: AppEnvironment,
        profileID: ProfileID? = nil
    ) async -> ArcCookieImportOutcome {
        let cookiesDatabase = ArcImportReader
            .chromiumProfileDirectory(homeDirectory: reader.homeDirectory)
            .appendingPathComponent("Cookies", isDirectory: false)
        guard FileManager.default.fileExists(atPath: cookiesDatabase.path) else {
            return .failed(reason: "There is no cookie database at \(cookiesDatabase.path).")
        }

        let decrypted = await Task.detached(priority: .userInitiated) { () -> ArcCookieDecryptionResult in
            do {
                let key = try ArcCookieDecryptor.safeStorageKey()
                return .decrypted(try ArcCookieDecryptor.readCookies(
                    cookiesDatabase: cookiesDatabase,
                    browser: .arc,
                    key: key
                ))
            } catch let error as ArcCookieError where error.isKeychainRefusal {
                return .stopped(.keychainDenied)
            } catch {
                return .stopped(.failed(reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }.value

        let cookies: [ArcCookie]
        switch decrypted {
        case .decrypted(let value): cookies = value
        case .stopped(let outcome): return outcome
        }
        guard !cookies.isEmpty else { return .imported(count: 0) }

        guard let session = session(for: profileID, env: env) else {
            return .decryptedButEngineCannotInstall(count: cookies.count)
        }

        let stored = await session.setCookies(cookies.map(engineCookie))
        if stored == cookies.count { return .imported(count: stored) }
        return .partiallyImported(stored: stored, decrypted: cookies.count)
    }

    private static func session(for profileID: ProfileID?, env: AppEnvironment) -> EngineSession? {
        guard let engine = env.engine else { return nil }
        guard let resolved = resolvedProfileID(profileID, env: env),
              let profile = env.store.profile(resolved)
        else { return nil }
        return try? engine.session(
            identifier: profile.sessionIdentifier,
            persistent: profile.isPersistent
        )
    }

    /// HttpOnly and SameSite are carried through exactly — stripping HttpOnly exposes a cookie to page JS the origin never intended, and altering SameSite breaks a sign-in redirect's cross-site match.
    static func engineCookie(_ cookie: ArcCookie) -> EngineCookie {
        EngineCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.hostKey,
            path: cookie.path,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly,
            sameSite: sameSite(cookie.sameSitePolicy),
            expiresAt: cookie.expiresAt,
            createdAt: cookie.createdAt,
            lastAccessedAt: cookie.lastAccessedAt
        )
    }

    static func sameSite(_ policy: ArcCookieSameSite) -> EngineCookie.SameSite {
        switch policy {
        case .unspecified: return .unspecified
        case .none: return .none
        case .lax: return .lax
        case .strict: return .strict
        }
    }

    // MARK: History

    private static func applyHistory(
        _ visits: [ImportedVisit],
        env: AppEnvironment,
        profileID: ProfileID?,
        historyStore: HistoryStore?
    ) async -> Int {
        guard !visits.isEmpty, let profileID else { return 0 }

        let store: HistoryStore
        if let historyStore {
            store = historyStore
        } else {
            guard let opened = try? HistoryStore() else { return 0 }
            store = opened
        }

        var recorded = 0
        for visit in visits {
            let historyVisit = HistoryVisit(
                url: visit.url,
                title: visit.title,
                profileID: profileID,
                wasTyped: visit.wasTyped,
                visitedAt: visit.visitedAt
            )
            do {
                _ = try await store.record(visit: historyVisit)
                recorded += 1
            } catch {
                continue
            }
        }

        // This path bypasses recordVisit(...) (no visitedAt param), so the Command Bar cache needs an explicit refresh or the import stays invisible to Cmd+T.
        if historyStore == nil, recorded > 0 {
            await env.reloadHistoryCacheAfterBulkImport()
        }
        return recorded
    }
}
