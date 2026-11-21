import AppKit
import Foundation

extension AppEnvironment {

    @discardableResult
    func createSiteProfile(name: String, for url: URL) -> SiteProfile? {
        guard let siteKey = SiteProfile.siteKey(for: url) else { return nil }
        return store.createSiteProfile(name: name, siteKey: siteKey)
    }

    @discardableResult
    func renameSiteProfile(_ id: SiteProfileID, to name: String) -> Bool {
        store.renameSiteProfile(id, to: name)
    }

    // Tabs on the profile move to Default first, in every window: WebKit refuses to remove a store a web view still uses.
    func deleteSiteProfile(_ id: SiteProfileID) {
        guard let profile = store.siteProfile(id) else { return }
        for environment in siteProfileEnvironments() {
            for tabID in environment.state.tabs.values.filter({ $0.siteProfileID == id }).map(\.id) {
                environment.switchSiteProfile(tabID: tabID, to: nil)
            }
        }
        store.deleteSiteProfile(id)
        let engine = self.engine
        Task { @MainActor in
            await Self.removeSiteProfileStores([profile], engine: engine)
        }
    }

    private func siteProfileEnvironments() -> [AppEnvironment] {
        var seen: [AppEnvironment] = []
        for environment in [self, rootEnvironment] + OrbitWindowController.openEnvironments
        where environment.store === store && !seen.contains(where: { $0 === environment }) {
            seen.append(environment)
        }
        return seen
    }

    // Also run by Reset Everything, whose state wipe has already dropped the profiles by the time the engine is cleared.
    static func removeSiteProfileStores(_ profiles: [SiteProfile], engine: (any BrowserEngine)?) async {
        guard let engine else { return }
        for profile in profiles {
            guard let session = try? engine.session(identifier: profile.sessionIdentifier, persistent: true) else { continue }
            if let webKitSession = session as? WebKitSession {
                webKitSession.clearContentSettings()
                _ = await webKitSession.removePersistentDataStore(recreating: false)
            }
            (engine as? WebKitEngine)?.forgetSession(identifier: profile.sessionIdentifier)
        }
    }

    // Website data belongs to the web view's data store, so a switch replaces the tab's web view; the tab itself keeps its identity, place, pin state and selection.
    func switchSiteProfile(tabID: TabID, to profileID: SiteProfileID?) {
        guard let tab = store.tab(tabID), tab.siteProfileID != profileID else { return }
        let liveURL = webContents[tabID]?.navigationState.url
        let wasLive = webContents[tabID] != nil
        guard store.setSiteProfile(profileID, forTab: tabID) else { return }
        guard wasLive else { return }

        navigationGeneration[tabID, default: 0] += 1
        releaseWebContents(for: tabID, keepingSessionState: false)
        removeNavigationState(for: tabID)
        mediaStates.removeValue(forKey: tabID)
        findResultsByTab.removeValue(forKey: tabID)
        tabErrors.removeValue(forKey: tabID)
        crashedTabs.remove(tabID)
        unresponsiveTabs.remove(tabID)
        store.setRendererLive(tabID, false)

        materializeWebContents(for: tabID, url: liveURL ?? tab.url)
        if activeTabID == tabID, !isCommandBarPresented, !isFindBarPresented {
            webContents[tabID]?.focus()
        }
    }

    // A page-created tab (window.open, target=_blank) on its opener's own site is built on the opener's data store; recording that keeps a later renderer release or relaunch on the same identity. One opened onto another site belongs to the Space, as the user never chose a profile for it.
    func inheritSiteProfile(from contents: any WebContents, for tabID: TabID, url: URL) {
        let identifier = contents.session.identifier
        guard store.tab(tabID)?.siteProfileID == nil,
              let profile = store.siteProfiles.first(where: { $0.sessionIdentifier == identifier })
        else { return }
        if let site = SiteProfile.siteKey(for: url), site != profile.siteKey { return }
        store.setSiteProfile(profile.id, forTab: tabID)
    }

    // A page on a Site Profile store that visits another site (a Google sign-in popup or redirect) sees that site exactly as the Space does, and the visit's changes go back to the Space.
    func installForeignSiteCookieMirror(on contents: any WebContents, tabID: TabID) {
        guard let page = contents as? WebKitWebContents,
              let pageStore = page.session as? WebKitSession,
              let siteProfile = store.siteProfiles.first(where: { $0.sessionIdentifier == pageStore.identifier }),
              let spaceID = state.tabs[tabID]?.spaceID,
              let spaceProfile = state.profiles.first(where: { $0.id == profileID(for: spaceID) }),
              let spaceStore = try? engine?.session(identifier: spaceProfile.sessionIdentifier, persistent: spaceProfile.isPersistent) as? WebKitSession,
              spaceStore !== pageStore
        else { return }
        let mirror = ForeignSiteCookieMirror(pageStore: pageStore, spaceStore: spaceStore, ownSite: siteProfile.siteKey)
        page.setMainFrameNavigationHook { url in
            await mirror.willNavigate(to: url)
        }
        page.setCloseHook {
            Task { @MainActor in await mirror.finish() }
        }
    }

    // MenuPrompt rather than a SwiftUI sheet: these run from a menu action, after the menu has torn down and left no view to attach a sheet to.
    func promptToCreateSiteProfile(forTab tabID: TabID) {
        guard store.canOfferSiteProfiles(forTab: tabID), let tab = store.tab(tabID),
              let siteKey = store.siteProfileDropdownSiteKey(forTab: tabID) ?? SiteProfile.siteKey(for: tab.url)
        else { return }
        let invitation = "Sign in to \(siteKey) with a separate account. Its cookies and site data stay apart from your other profiles for this site."
        var message = invitation
        var draft = ""
        while let typed = MenuPrompt.text(title: "New Profile for \(siteKey)", message: message, defaultValue: draft, acceptTitle: "Create") {
            if let created = store.createSiteProfile(name: typed, siteKey: siteKey) {
                switchSiteProfile(tabID: tabID, to: created.id)
                return
            }
            draft = typed
            message = "Choose a name that is not empty and not already used for \(siteKey)."
        }
    }

    func promptToRenameDefaultSiteProfile(siteKey: String) {
        let current = store.defaultSiteProfileName(forSiteKey: siteKey)
        var message = "Profile names are only shown for \(siteKey). Pages without another profile selected use this one."
        var draft = current
        while let typed = MenuPrompt.text(title: "Rename Profile", message: message, defaultValue: draft, acceptTitle: "Rename") {
            if store.renameDefaultSiteProfile(siteKey: siteKey, to: typed) { return }
            draft = typed
            message = "Choose a name that is not empty and not already used for \(siteKey)."
        }
    }

    func promptToRenameSiteProfile(_ id: SiteProfileID) {
        guard let profile = store.siteProfile(id) else { return }
        var message = "Profile names are only shown for \(profile.siteKey)."
        var draft = profile.name
        while let typed = MenuPrompt.text(title: "Rename Profile", message: message, defaultValue: draft, acceptTitle: "Rename") {
            if renameSiteProfile(id, to: typed) { return }
            draft = typed
            message = "Choose a name that is not empty and not already used for \(profile.siteKey)."
        }
    }

    func confirmDeleteSiteProfile(_ id: SiteProfileID) {
        guard let profile = store.siteProfile(id) else { return }
        let defaultName = store.defaultSiteProfileName(forSiteKey: profile.siteKey)
        let confirmed = MenuPrompt.confirmDestructive(
            title: "Delete the profile \"\(profile.name)\"?",
            message: "Its cookies and site data for \(profile.siteKey) are erased, and tabs using it go back to \(defaultName).",
            acceptTitle: "Delete"
        )
        guard confirmed else { return }
        deleteSiteProfile(id)
    }
}
