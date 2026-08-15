import Foundation

extension Notification.Name {
    static let orbitTabDidPin = Notification.Name("OrbitTabDidPin")
    static let orbitRecentlyClosedDidChange = Notification.Name("OrbitRecentlyClosedDidChange")
}

struct ClosedTabRecord: Sendable, Hashable {
    var tabID: TabID
    var previousSection: TabSection
    var closedAt: Date
    var pinnedURL: URL?
    var pinnedTitle: String?
}

public extension BrowserStore {

    // MARK: - Queries

    func tab(_ id: TabID) -> Tab? { state.tabs[id] }

    func todayTabs(in spaceID: SpaceID) -> [Tab] {
        guard let space = space(spaceID) else { return [] }
        return space.today.compactMap { state.tabs[$0] }
    }

    func activeTab(in spaceID: SpaceID) -> Tab? {
        guard let id = state.activeTabBySpace[spaceID] else { return nil }
        guard let tab = state.tabs[id], tab.spaceID == spaceID else { return nil }
        return tab
    }

    var activeTab: Tab? {
        guard let spaceID = state.activeSpaceID, let id = state.activeTabBySpace[spaceID] else { return nil }
        return state.tabs[id]
    }

    func archivedTabs(in spaceID: SpaceID? = nil) -> [Tab] {
        if let cached = archivedTabsCache[spaceID] { return cached }
        let result = state.tabs.values
            .filter { $0.section == .archived && (spaceID == nil || $0.spaceID == spaceID) }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        archivedTabsCache[spaceID] = result
        return result
    }

    // MARK: - Opening

    @discardableResult
    func openTab(url: URL, in spaceID: SpaceID, section: TabSection = .today, at index: Int? = nil, activate: Bool = true) -> TabID {
        var newState = state
        let tab = Tab(spaceID: spaceID, section: section, url: url, pinnedURL: section == .pinned ? url : nil)
        newState.tabs[tab.id] = tab

        if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == spaceID }) {
            switch section {
            case .today:
                var today = newState.spaces[spaceIndex].today
                let clamped = index.map { max(0, min($0, today.count)) } ?? today.count
                today.insert(tab.id, at: clamped)
                newState.spaces[spaceIndex].today = today
            case .pinned:
                let insertIndex = index ?? newState.spaces[spaceIndex].pinned.count
                newState.spaces[spaceIndex].pinned = PinnedNodeTree.inserting(
                    .tab(tab.id), parentFolderID: nil, at: insertIndex, into: newState.spaces[spaceIndex].pinned
                )
            case .favorite, .archived:
                break
            }
        }

        if activate {
            newState.activeTabBySpace[spaceID] = tab.id
            newState.activeSpaceID = spaceID
        }

        state = newState
        return tab.id
    }

    func selectTab(_ id: TabID) {
        // Without this the pane shows an archived page the sidebar has no row for — and that pairing persists across a relaunch.
        if state.tabs[id]?.section == .archived { restoreFromArchive(id, to: .today) }
        guard var tab = state.tabs[id] else { return }
        var newState = state
        tab.lastAccessedAt = Date()
        newState.tabs[id] = tab
        newState.activeTabBySpace[tab.spaceID] = id
        if newState.activeSpaceID != tab.spaceID {
            newState.activeSpaceID = tab.spaceID
        }
        state = newState
    }

    /// Selecting a tab was the only thing that ever moved `lastAccessedAt`, so a tab navigated in all day still read as idle to the archive sweep the moment it stopped being active.
    func noteTabAccessed(_ id: TabID, at date: Date = Date()) {
        guard let tab = state.tabs[id], tab.lastAccessedAt < date else { return }
        state.tabs[id]?.lastAccessedAt = date
    }

    // MARK: - Closing

    func closeTab(_ id: TabID) {
        guard let tab = state.tabs[id] else { return }
        switch tab.section {
        case .today, .favorite:
            archiveTab(id)
            pushRecentlyClosed(ClosedTabRecord(tabID: id, previousSection: .today, closedAt: Date()))
        case .pinned:
            // The unpin leaves the closed tab in the Space, so without this it also stays active — and its caller has already released the renderer, which is a blank pane.
            let previousState = state
            let wasActive = state.activeTabBySpace[tab.spaceID] == id
            unpin(id)
            if wasActive,
               let successor = fallbackActiveTab(excluding: id, in: tab.spaceID, previousState: previousState, newState: state) {
                state.activeTabBySpace[tab.spaceID] = successor
            }
            pushRecentlyClosed(
                ClosedTabRecord(
                    tabID: id,
                    previousSection: .pinned,
                    closedAt: Date(),
                    pinnedURL: tab.pinnedURL,
                    pinnedTitle: tab.pinnedTitle
                )
            )
        case .archived:
            break
        }
    }

    // MARK: - Bookmarked (pinned) rows that are also open tabs

    // No fallbackActiveTab: this is a deactivation, not "give me the next tab".
    // A successor here materialises folder siblings, which was the reported bug.
    func closeTabKeepingPin(_ id: TabID) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        var newState = state
        newState.tabs[id]?.isUnloaded = true
        if newState.activeTabBySpace[tab.spaceID] == id {
            newState.activeTabBySpace[tab.spaceID] = nil
        }
        state = newState
    }

    func removeBookmark(_ id: TabID) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        pushRecentlyClosed(
            ClosedTabRecord(
                tabID: id,
                previousSection: .pinned,
                closedAt: Date(),
                pinnedURL: tab.pinnedURL,
                pinnedTitle: tab.pinnedTitle
            )
        )
        archiveTab(id)
    }

    func closeTabsInSpace(_ spaceID: SpaceID, section: TabSection = .today) {
        switch section {
        case .today:
            for id in todayTabs(in: spaceID).map(\.id) { closeTab(id) }
        case .pinned:
            for id in pinnedNodes(in: spaceID).flatMap(\.allTabIDs) { closeTab(id) }
        case .favorite:
            for favorite in favorites(for: spaceID) {
                if let id = favorite.liveTabID { closeTab(id) }
            }
        case .archived:
            clearArchive(in: spaceID)
        }
    }

    private func pushRecentlyClosed(_ record: ClosedTabRecord) {
        recentlyClosedRecords.append(record)
        if recentlyClosedRecords.count > recentlyClosedCapacity {
            recentlyClosedRecords.removeFirst(recentlyClosedRecords.count - recentlyClosedCapacity)
        }
    }

    func reopenLastClosedTab() {
        guard let record = recentlyClosedRecords.popLast(), state.tabs[record.tabID] != nil else { return }
        restoreClosedTab(record)
        selectTab(record.tabID)
    }

    /// chrome.sessions.restore(sessionId) needs one specific entry back, not just the newest.
    /// Selection is the caller's, so a window-scoped AppEnvironment can do it through its own scoping.
    @discardableResult
    func reopenClosedTab(_ tabID: TabID) -> Bool {
        guard let index = recentlyClosedRecords.lastIndex(where: { $0.tabID == tabID }) else { return false }
        let record = recentlyClosedRecords.remove(at: index)
        guard state.tabs[record.tabID] != nil else { return false }
        restoreClosedTab(record)
        return true
    }

    private func restoreClosedTab(_ record: ClosedTabRecord) {
        switch record.previousSection {
        case .pinned:
            pin(record.tabID)
            var newState = state
            newState.tabs[record.tabID]?.pinnedURL = record.pinnedURL
            newState.tabs[record.tabID]?.pinnedTitle = record.pinnedTitle
            state = newState
        case .today, .favorite, .archived:
            restoreFromArchive(record.tabID, to: .today)
        }
    }

    // MARK: - Pin / unpin

    func pin(_ id: TabID, capturedURL: URL? = nil, capturedTitle: String? = nil) {
        guard let tab = state.tabs[id], tab.section != .pinned else { return }
        guard let spaceIndex = state.spaces.firstIndex(where: { $0.id == tab.spaceID }) else { return }
        var newState = state
        removeFromAllContainers(id, spaceID: tab.spaceID, in: &newState)
        newState.tabs[id]?.section = .pinned
        newState.tabs[id]?.archivedAt = nil
        newState.tabs[id]?.isUnloaded = false
        newState.tabs[id]?.pinnedURL = capturedURL ?? tab.url
        let capturedOrStoredTitle = capturedTitle ?? tab.title
        newState.tabs[id]?.pinnedTitle = capturedOrStoredTitle.isEmpty ? nil : capturedOrStoredTitle
        newState.spaces[spaceIndex].pinned.append(.tab(id))
        if newState.spaces[spaceIndex].isPinnedSectionCollapsed {
            newState.spaces[spaceIndex].isPinnedSectionCollapsed = false
        }
        state = newState

        NotificationCenter.default.post(name: .orbitTabDidPin, object: nil, userInfo: ["tabID": id])
    }

    func pin(_ id: TabID, toParent parentFolderID: FolderID?, atIndex index: Int, in spaceID: SpaceID, capturedURL: URL? = nil, capturedTitle: String? = nil) {
        guard let tab = state.tabs[id] else { return }
        guard let destinationSpaceIndex = state.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let wasAlreadyPinned = tab.section == .pinned
        let sourceSpaceID = tab.spaceID
        var newState = state
        removeFromAllContainers(id, spaceID: sourceSpaceID, in: &newState)
        newState.tabs[id]?.spaceID = spaceID
        newState.tabs[id]?.section = .pinned
        newState.tabs[id]?.archivedAt = nil
        newState.tabs[id]?.isUnloaded = false
        if !wasAlreadyPinned {
            newState.tabs[id]?.pinnedURL = capturedURL ?? tab.url
            let capturedOrStoredTitle = capturedTitle ?? tab.title
            newState.tabs[id]?.pinnedTitle = capturedOrStoredTitle.isEmpty ? nil : capturedOrStoredTitle
        }
        newState.spaces[destinationSpaceIndex].pinned = PinnedNodeTree.inserting(
            .tab(id), parentFolderID: parentFolderID, at: index, into: newState.spaces[destinationSpaceIndex].pinned
        )
        if newState.spaces[destinationSpaceIndex].isPinnedSectionCollapsed {
            newState.spaces[destinationSpaceIndex].isPinnedSectionCollapsed = false
        }
        if sourceSpaceID != spaceID, newState.activeTabBySpace[sourceSpaceID] == id {
            newState.activeTabBySpace[sourceSpaceID] = fallbackActiveTab(excluding: id, in: sourceSpaceID, previousState: state, newState: newState)
        }
        state = newState

        NotificationCenter.default.post(name: .orbitTabDidPin, object: nil, userInfo: ["tabID": id])
    }

    func unpin(_ id: TabID) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        var newState = state
        removeFromAllContainers(id, spaceID: tab.spaceID, in: &newState)
        newState.tabs[id]?.section = .today
        newState.tabs[id]?.tidiedTitle = nil
        if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == tab.spaceID }) {
            newState.spaces[spaceIndex].today.append(id)
        }
        state = newState
    }

    func unpin(_ id: TabID, toIndex index: Int, in spaceID: SpaceID) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        var newState = state
        removeFromAllContainers(id, spaceID: tab.spaceID, in: &newState)
        newState.tabs[id]?.section = .today
        newState.tabs[id]?.tidiedTitle = nil
        if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == tab.spaceID }) {
            var today = newState.spaces[spaceIndex].today
            let clamped = max(0, min(index, today.count))
            today.insert(id, at: clamped)
            newState.spaces[spaceIndex].today = today
        }
        state = newState
    }

    func togglePin(_ id: TabID) {
        guard let tab = state.tabs[id] else { return }
        tab.section == .pinned ? unpin(id) : pin(id)
    }

    // MARK: - Pinned origin ("Resetting" a Pinned Tab)

    @discardableResult
    func resetPinnedTab(_ id: TabID) -> URL? {
        guard let tab = state.tabs[id], tab.section == .pinned else { return nil }
        guard let origin = tab.pinnedURL, tab.hasNavigatedAwayFromPinnedURL else { return nil }
        let priorURL = tab.url
        var newState = state
        newState.tabs[id]?.url = origin
        newState.tabs[id]?.title = tab.pinnedTitle ?? ""
        state = newState
        return priorURL
    }

    func replacePinnedURLWithCurrent(_ id: TabID) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        var newState = state
        newState.tabs[id]?.pinnedURL = tab.url
        newState.tabs[id]?.pinnedTitle = tab.title.isEmpty ? nil : tab.title
        state = newState
    }

    func setPinnedURL(_ id: TabID, to url: URL) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        var newState = state
        newState.tabs[id]?.pinnedURL = url
        newState.tabs[id]?.pinnedTitle = nil
        state = newState
    }

    // MARK: - Archive

    func archiveTab(_ id: TabID) {
        guard var tab = state.tabs[id], tab.section != .archived else { return }
        var newState = state
        let folderTrail = tab.section == .pinned
            ? PinnedNodeTree.folderTrail(to: id, in: pinnedNodes(in: tab.spaceID))
            : []
        removeFromAllContainers(id, spaceID: tab.spaceID, in: &newState)
        tab.section = .archived
        tab.archivedAt = Date()
        tab.isUnloaded = true
        tab.archivedFolderTrail = folderTrail.isEmpty ? nil : folderTrail
        newState.tabs[id] = tab

        if newState.activeTabBySpace[tab.spaceID] == id {
            newState.activeTabBySpace[tab.spaceID] = fallbackActiveTab(excluding: id, in: tab.spaceID, previousState: state, newState: newState)
        }
        state = newState
    }

    func restoreFromArchive(_ id: TabID, to section: TabSection = .today) {
        guard var tab = state.tabs[id], tab.section == .archived else { return }
        var newState = state
        let trail = tab.archivedFolderTrail ?? []
        tab.section = section
        tab.archivedAt = nil
        tab.isUnloaded = false
        tab.archivedFolderTrail = nil
        newState.tabs[id] = tab
        if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == tab.spaceID }) {
            switch section {
            case .pinned where !trail.isEmpty:
                newState.spaces[spaceIndex].pinned = PinnedNodeTree.restoring(
                    .tab(id), intoTrail: trail, into: newState.spaces[spaceIndex].pinned
                )
            case .pinned:
                newState.spaces[spaceIndex].pinned.append(.tab(id))
            default:
                newState.spaces[spaceIndex].today.append(id)
            }
        }
        state = newState
    }

    func clearArchive(in spaceID: SpaceID? = nil) {
        var newState = state
        let idsToRemove = Set(
            newState.tabs.values
                .filter { $0.section == .archived && (spaceID == nil || $0.spaceID == spaceID) }
                .map(\.id)
        )
        guard !idsToRemove.isEmpty else { return }
        for id in idsToRemove {
            newState.tabs.removeValue(forKey: id)
        }
        recentlyClosedRecords.removeAll { idsToRemove.contains($0.tabID) }
        state = newState
    }

    // MARK: - Reordering / moving

    func reorderTab(_ id: TabID, toIndex index: Int, in spaceID: SpaceID) {
        guard let spaceIndex = state.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        var newState = state
        var today = newState.spaces[spaceIndex].today
        guard let currentIndex = today.firstIndex(of: id) else { return }
        today.remove(at: currentIndex)
        let clamped = max(0, min(index, today.count))
        today.insert(id, at: clamped)
        newState.spaces[spaceIndex].today = today
        state = newState
    }

    func moveTab(_ id: TabID, toSpace destinationSpaceID: SpaceID, section: TabSection? = nil) {
        guard var tab = state.tabs[id], state.spaces.contains(where: { $0.id == destinationSpaceID }) else { return }
        var newState = state
        let sourceSpaceID = tab.spaceID
        let resolvedSection: TabSection = section ?? (tab.section == .pinned ? .pinned : .today)
        removeFromAllContainers(id, spaceID: tab.spaceID, in: &newState)
        tab.spaceID = destinationSpaceID
        tab.section = resolvedSection
        newState.tabs[id] = tab
        if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == destinationSpaceID }) {
            switch resolvedSection {
            case .pinned: newState.spaces[spaceIndex].pinned.append(.tab(id))
            default: newState.spaces[spaceIndex].today.append(id)
            }
        }
        if newState.activeTabBySpace[sourceSpaceID] == id {
            newState.activeTabBySpace[sourceSpaceID] = fallbackActiveTab(excluding: id, in: sourceSpaceID, previousState: state, newState: newState)
        }
        state = newState
    }

    // MARK: - Renaming

    func renameTab(_ id: TabID, to customTitle: String) {
        guard state.tabs[id] != nil else { return }
        var newState = state
        newState.tabs[id]?.customTitle = customTitle
        state = newState
    }

    func resetTabName(_ id: TabID) {
        guard state.tabs[id] != nil else { return }
        var newState = state
        newState.tabs[id]?.customTitle = nil
        state = newState
    }

    func setTidiedTitle(_ tidied: String?, forTab id: TabID) {
        guard let existing = state.tabs[id], existing.tidiedTitle != tidied else { return }
        var newState = state
        newState.tabs[id]?.tidiedTitle = tidied
        state = newState
    }

    func clearAllTidiedTitles() {
        var newState = state
        var changed = false
        for id in newState.tabs.keys where newState.tabs[id]?.tidiedTitle != nil {
            newState.tabs[id]?.tidiedTitle = nil
            changed = true
        }
        guard changed else { return }
        state = newState
    }

    // MARK: - Tidy Tabs groups

    @discardableResult
    func applyTidyTabGroups(_ groups: [(name: String, tabIDs: [TabID])], in spaceID: SpaceID) -> [String] {
        guard let spaceIndex = state.spaces.firstIndex(where: { $0.id == spaceID }) else { return [] }
        var newState = state
        let today = newState.spaces[spaceIndex].today
        let todaySet = Set(today)

        var assigned: [TabID: String] = [:]
        var order: [TabID] = []
        var appliedNames: [String] = []

        for group in groups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var members: [TabID] = []
            for id in group.tabIDs {
                guard todaySet.contains(id), assigned[id] == nil else { continue }
                guard newState.tabs[id]?.section == .today, newState.tabs[id]?.spaceID == spaceID else { continue }
                assigned[id] = name
                members.append(id)
            }
            guard !members.isEmpty else { continue }
            appliedNames.append(name)
            order.append(contentsOf: members)
        }

        guard !assigned.isEmpty else { return [] }

        let ungrouped = today.filter { assigned[$0] == nil }

        for id in today {
            newState.tabs[id]?.tidyGroup = assigned[id]
        }
        newState.spaces[spaceIndex].today = ungrouped + order
        state = newState
        return appliedNames
    }

    func removeTidyGroup(named name: String, in spaceID: SpaceID) {
        guard let space = state.spaces.first(where: { $0.id == spaceID }) else { return }
        var newState = state
        var changed = false
        for id in space.today where newState.tabs[id]?.tidyGroup == name {
            newState.tabs[id]?.tidyGroup = nil
            changed = true
        }
        guard changed else { return }
        state = newState
    }

    func tidyGroupMembers(named name: String, in spaceID: SpaceID) -> [TabID] {
        guard let space = state.spaces.first(where: { $0.id == spaceID }) else { return [] }
        return space.today.filter { state.tabs[$0]?.tidyGroup == name }
    }

    // MARK: - Zoom

    // Duplicated, not read from SiteZoomStore/ZoomStep.p100: this file is also compiled into the SiteZoomStore-less OrbitTests target.
    static let unzoomedFactor: Double = 1.0

    func setZoomFactor(_ factor: Double?, for id: TabID) {
        guard state.tabs[id] != nil else { return }
        let normalized: Double? = (factor == Self.unzoomedFactor) ? nil : factor
        guard state.tabs[id]?.zoomFactor != normalized else { return }
        var newState = state
        newState.tabs[id]?.zoomFactor = normalized
        state = newState
    }

    // MARK: - Duplication

    @discardableResult
    func duplicateTab(_ id: TabID) -> TabID? {
        guard let original = state.tabs[id] else { return nil }
        var newState = state
        var copy = Tab(spaceID: original.spaceID, section: original.section, url: original.url)
        copy.title = original.title
        copy.customTitle = original.customTitle
        copy.faviconURL = original.faviconURL
        copy.zoomFactor = original.zoomFactor
        newState.tabs[copy.id] = copy

        switch original.section {
        case .today:
            if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == original.spaceID }),
               let position = newState.spaces[spaceIndex].today.firstIndex(of: id) {
                newState.spaces[spaceIndex].today.insert(copy.id, at: position + 1)
            } else if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == original.spaceID }) {
                newState.spaces[spaceIndex].today.append(copy.id)
            }
        case .pinned:
            if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == original.spaceID }) {
                let tree = newState.spaces[spaceIndex].pinned
                let parentID = PinnedNodeTree.parentFolderID(of: id, in: tree)
                let siblingPath = PinnedNodeTree.path(to: id, in: tree)
                let insertIndex = (siblingPath?.last ?? tree.count - 1) + 1
                newState.spaces[spaceIndex].pinned = PinnedNodeTree.inserting(
                    .tab(copy.id), parentFolderID: parentID, at: insertIndex, into: tree
                )
            }
        case .favorite, .archived:
            break
        }

        state = newState
        return copy.id
    }

    // MARK: - Shared removal helper

    func removeFromAllContainers(_ id: TabID, spaceID: SpaceID, in newState: inout OrbitState) {
        guard let spaceIndex = newState.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        newState.spaces[spaceIndex].today.removeAll { $0 == id }
        newState.tabs[id]?.tidyGroup = nil
        newState.spaces[spaceIndex].pinned = PinnedNodeTree.removing(id, from: newState.spaces[spaceIndex].pinned).forest
        for favoriteIndex in newState.spaces[spaceIndex].favorites.indices
        where newState.spaces[spaceIndex].favorites[favoriteIndex].liveTabID == id {
            newState.spaces[spaceIndex].favorites[favoriteIndex].liveTabID = nil
        }
        detachFromSplit(id, in: &newState)
    }

    func detachFromSplit(_ id: TabID, in newState: inout OrbitState) {
        guard let groupID = newState.tabs[id]?.splitGroupID, var group = newState.splitGroups[groupID] else { return }
        group.tabIDs.removeAll { $0 == id }
        newState.tabs[id]?.splitGroupID = nil
        newState.tabs[id]?.splitIndex = 0

        if group.tabIDs.count <= 1 {
            if let onlyRemaining = group.tabIDs.first {
                newState.tabs[onlyRemaining]?.splitGroupID = nil
                newState.tabs[onlyRemaining]?.splitIndex = 0
            }
            newState.splitGroups.removeValue(forKey: groupID)
        } else {
            let evenFraction = 1.0 / Double(group.tabIDs.count)
            group.fractions = Array(repeating: evenFraction, count: group.tabIDs.count)
            for (index, tabID) in group.tabIDs.enumerated() {
                newState.tabs[tabID]?.splitIndex = index
            }
            newState.splitGroups[groupID] = group
        }
    }

    // previousState is the pre-removal snapshot (still-unassigned `state`); newState confirms a candidate is still open.
    // Preference order: most recently active tab, then adjacent by index (the one
    // after, then the one before), then any open tab, Today before pinned.
    private func fallbackActiveTab(excluding id: TabID, in spaceID: SpaceID, previousState: OrbitState, newState: OrbitState) -> TabID? {
        guard let space = newState.spaces.first(where: { $0.id == spaceID }) else { return nil }
        let stillOpen = Set(space.today).union(space.pinned.flatMap(\.allTabIDs))

        if let history = activationHistoryBySpace[spaceID] {
            for candidate in history.reversed() where candidate != id && stillOpen.contains(candidate) {
                return candidate
            }
        }

        if let previousSpace = previousState.spaces.first(where: { $0.id == spaceID }) {
            if let adjacent = Self.adjacentStillOpenTab(to: id, in: previousSpace.today, stillOpen: stillOpen) {
                return adjacent
            }
            if let adjacent = Self.adjacentStillOpenTab(to: id, in: previousSpace.pinned.flatMap(\.allTabIDs), stillOpen: stillOpen) {
                return adjacent
            }
        }

        if let today = space.today.first(where: { $0 != id }) { return today }
        return space.pinned.flatMap(\.allTabIDs).first(where: { $0 != id })
    }

    private static func adjacentStillOpenTab(to id: TabID, in order: [TabID], stillOpen: Set<TabID>) -> TabID? {
        guard let index = order.firstIndex(of: id) else { return nil }
        if index + 1 < order.count, stillOpen.contains(order[index + 1]) { return order[index + 1] }
        if index - 1 >= 0, stillOpen.contains(order[index - 1]) { return order[index - 1] }
        return nil
    }
}
