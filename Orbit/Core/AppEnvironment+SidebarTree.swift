import Foundation

extension AppEnvironment {

    func moveNode(_ nodeID: UUID, toParent parentFolderID: FolderID?, atIndex index: Int, in spaceID: SpaceID) {
        store.moveNode(nodeID, toParent: parentFolderID, atIndex: index, in: spaceID)
    }

    func moveTodayTab(_ tabID: TabID, toIndex index: Int, in spaceID: SpaceID) {
        // chromiumTabIndex, not the Space-scoped Today position: onMoved's
        // fromIndex/toIndex must be in the same coordinate space as Tab.index.
        let fromIndex = chromiumTabIndex(for: tabID)
        store.reorderTab(tabID, toIndex: index, in: spaceID)
        pushChromiumTabMoved(tabID, fromIndex: fromIndex)
    }

    func pinTab(_ tabID: TabID, toParent parentFolderID: FolderID?, atIndex index: Int, in spaceID: SpaceID) {
        let capture = livePinCapture(for: tabID)
        store.pin(tabID, toParent: parentFolderID, atIndex: index, in: spaceID, capturedURL: capture.url, capturedTitle: capture.title)
        pushChromiumTabPinnedChanged(tabID)
    }

    func unpinTab(_ tabID: TabID, toIndex index: Int, in spaceID: SpaceID) {
        store.unpin(tabID, toIndex: index, in: spaceID)
        pushChromiumTabPinnedChanged(tabID)
    }

    // Favorite.id and TabID are both bare UUIDs — never pass a .favorite payload's nodeID as a TabID; resolve it here.
    @discardableResult
    func resolvedTab(forFavorite favoriteID: UUID, in spaceID: SpaceID) -> TabID? {
        guard let favorite = favorites(for: spaceID).first(where: { $0.id == favoriteID }) else { return nil }
        if let liveTabID = favorite.liveTabID, tab(liveTabID) != nil {
            return liveTabID
        }
        let newTabID = openTab(url: favorite.url, in: spaceID, section: .today, activate: false)
        store.bindLiveTab(newTabID, toFavorite: favoriteID, in: spaceID)
        return newTabID
    }

    @discardableResult
    func createFolder(name: String, in spaceID: SpaceID, parent parentFolderID: FolderID? = nil, index: Int = .max) -> FolderID {
        store.createFolder(name: name, in: spaceID, parent: parentFolderID, at: index)
    }

    @discardableResult
    func groupIntoNewFolder(name: String, firstID: UUID, secondID: UUID, parent parentFolderID: FolderID?, atIndex index: Int, in spaceID: SpaceID) -> FolderID {
        store.groupIntoNewFolder(name: name, firstID: firstID, secondID: secondID, parent: parentFolderID, atIndex: index, in: spaceID)
    }

    func renameFolder(_ id: FolderID, to name: String, in spaceID: SpaceID) {
        store.renameFolder(id, to: name, in: spaceID)
    }

    func setFolderIcon(_ icon: String?, isEmoji: Bool, forFolder id: FolderID, in spaceID: SpaceID) {
        store.setFolderIcon(icon, isEmoji: isEmoji, forFolder: id, in: spaceID)
    }

    func toggleFolderExpanded(_ id: FolderID, in spaceID: SpaceID) {
        store.toggleFolderExpanded(id, in: spaceID)
    }

    func deleteFolder(_ id: FolderID, in spaceID: SpaceID, keepingChildren: Bool) {
        guard let folder = store.folder(id, in: spaceID) else { return }
        if !keepingChildren {
            for tabID in folder.allTabIDs {
                closeTab(tabID)
            }
        }
        store.deleteFolder(id, in: spaceID)
    }

    func groupTodayTabsIntoFolder(_ tabIDs: [TabID], name: String, in spaceID: SpaceID) {
        guard !tabIDs.isEmpty else { return }
        store.createFolder(fromSelection: tabIDs, name: name, in: spaceID)
    }

    func shouldShowTidyTabsBroom(in spaceID: SpaceID) -> Bool {
        todayTabs(in: spaceID).count > AssistRuntime.tidyTabsMinimumTabs
    }

    // MARK: - Tidy Tabs

    @discardableResult
    func applyTidyTabGroups(_ groups: [AssistRuntime.TidyTabGroup], in spaceID: SpaceID) -> [String] {
        store.applyTidyTabGroups(groups.map { (name: $0.name, tabIDs: $0.tabIDs) }, in: spaceID)
    }

    func removeTidyGroup(named name: String, in spaceID: SpaceID) {
        store.removeTidyGroup(named: name, in: spaceID)
    }

    func convertTidyGroupToFolder(named name: String, in spaceID: SpaceID) {
        let members = store.tidyGroupMembers(named: name, in: spaceID)
        guard !members.isEmpty else { return }
        groupTodayTabsIntoFolder(members, name: name, in: spaceID)
    }

    func closeTidyGroup(named name: String, in spaceID: SpaceID) {
        for tabID in store.tidyGroupMembers(named: name, in: spaceID) {
            closeTab(tabID)
        }
    }

    // Not a fallback for a failed model call — never invoked on error.
    @discardableResult
    func tidyTodayTabsByHost(in spaceID: SpaceID) -> [String] {
        let tabs = todayTabs(in: spaceID)
        var order: [String] = []
        var members: [String: [TabID]] = [:]
        for tab in tabs {
            let host = tab.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "Other"
            if members[host] == nil { order.append(host) }
            members[host, default: []].append(tab.id)
        }
        let groups = order
            .filter { (members[$0]?.count ?? 0) >= AssistRuntime.tidyTabsMinimumGroupSize }
            .map { (name: $0.capitalized, tabIDs: members[$0] ?? []) }
        guard !groups.isEmpty else { return [] }
        return store.applyTidyTabGroups(groups, in: spaceID)
    }
}
