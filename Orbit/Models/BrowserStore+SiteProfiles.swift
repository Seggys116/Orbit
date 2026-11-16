import Foundation

public extension BrowserStore {

    var siteProfiles: [SiteProfile] { state.siteProfiles }

    func siteProfile(_ id: SiteProfileID) -> SiteProfile? {
        state.siteProfiles.first { $0.id == id }
    }

    func siteProfiles(forSiteKey siteKey: String) -> [SiteProfile] {
        state.siteProfiles
            .filter { $0.siteKey == siteKey }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func boundSiteProfile(forTab tabID: TabID) -> SiteProfile? {
        guard let id = state.tabs[tabID]?.siteProfileID else { return nil }
        return siteProfile(id)
    }

    /// The profile whose website data the tab's web view must use. A tab in a non-persistent Orbit Profile never gets one.
    func siteProfileForSession(of tabID: TabID) -> SiteProfile? {
        guard let tab = state.tabs[tabID], hasPersistentProfile(inSpace: tab.spaceID) else { return nil }
        return boundSiteProfile(forTab: tabID)
    }

    /// New Site Profiles are offered only for an http(s) page in a regular Space of a persistent Orbit Profile.
    func canOfferSiteProfiles(forTab tabID: TabID) -> Bool {
        guard let tab = state.tabs[tabID],
              let tabSpace = space(tab.spaceID), !tabSpace.isEphemeral,
              hasPersistentProfile(inSpace: tab.spaceID)
        else { return false }
        return SiteProfile.siteKey(for: tab.url) != nil
    }

    /// The site the address-field dropdown lists profiles for, or nil when the tab shows no dropdown. A bound tab keeps its profile's site while it visits another site, so a sign-in redirect does not drop the identity.
    func siteProfileDropdownSiteKey(forTab tabID: TabID) -> String? {
        guard let tab = state.tabs[tabID],
              hasPersistentProfile(inSpace: tab.spaceID),
              let pageSiteKey = SiteProfile.siteKey(for: tab.url)
        else { return nil }
        if let bound = boundSiteProfile(forTab: tabID) { return bound.siteKey }
        guard canOfferSiteProfiles(forTab: tabID), !siteProfiles(forSiteKey: pageSiteKey).isEmpty else { return nil }
        return pageSiteKey
    }

    func isSiteProfileNameAvailable(_ name: String, siteKey: String, excluding id: SiteProfileID? = nil) -> Bool {
        guard let normalized = SiteProfile.normalizedName(name) else { return false }
        return !state.siteProfiles.contains {
            $0.siteKey == siteKey && $0.id != id && $0.name.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    private func hasPersistentProfile(inSpace spaceID: SpaceID) -> Bool {
        guard let owningSpace = space(spaceID), let owningProfile = profile(owningSpace.profileID) else { return false }
        return owningProfile.isPersistent
    }

    /// Nil when the name is empty, reserved, or already used for this site.
    @discardableResult
    func createSiteProfile(name: String, siteKey: String) -> SiteProfile? {
        guard !siteKey.isEmpty,
              let normalized = SiteProfile.normalizedName(name),
              isSiteProfileNameAvailable(normalized, siteKey: siteKey)
        else { return nil }
        let created = SiteProfile(siteKey: siteKey, name: normalized)
        var newState = state
        newState.siteProfiles.append(created)
        state = newState
        return created
    }

    @discardableResult
    func renameSiteProfile(_ id: SiteProfileID, to name: String) -> Bool {
        guard let index = state.siteProfiles.firstIndex(where: { $0.id == id }),
              let normalized = SiteProfile.normalizedName(name),
              isSiteProfileNameAvailable(normalized, siteKey: state.siteProfiles[index].siteKey, excluding: id)
        else { return false }
        guard state.siteProfiles[index].name != normalized else { return true }
        var newState = state
        newState.siteProfiles[index].name = normalized
        state = newState
        return true
    }

    @discardableResult
    func setSiteProfile(_ id: SiteProfileID?, forTab tabID: TabID) -> Bool {
        guard let tab = state.tabs[tabID], tab.siteProfileID != id else { return false }
        if let id {
            guard siteProfile(id) != nil, hasPersistentProfile(inSpace: tab.spaceID) else { return false }
        }
        var newState = state
        newState.tabs[tabID]?.siteProfileID = id
        state = newState
        return true
    }

    /// Returns the tabs that were bound to the deleted profile; they are back on Default.
    @discardableResult
    func deleteSiteProfile(_ id: SiteProfileID) -> [TabID] {
        guard state.siteProfiles.contains(where: { $0.id == id }) else { return [] }
        var newState = state
        newState.siteProfiles.removeAll { $0.id == id }
        let boundTabIDs = newState.tabs.values.filter { $0.siteProfileID == id }.map(\.id)
        for tabID in boundTabIDs {
            newState.tabs[tabID]?.siteProfileID = nil
        }
        state = newState
        return boundTabIDs
    }
}
