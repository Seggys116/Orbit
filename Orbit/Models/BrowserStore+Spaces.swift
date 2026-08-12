import Foundation

public extension BrowserStore {

    // MARK: - Queries

    var spaces: [Space] { state.spaces.sorted { $0.order < $1.order } }

    var activeSpace: Space? {
        guard let id = state.activeSpaceID else { return spaces.first }
        return state.spaces.first { $0.id == id } ?? spaces.first
    }

    func space(_ id: SpaceID) -> Space? {
        state.spaces.first { $0.id == id }
    }

    func space(for tabID: TabID) -> Space? {
        guard let tab = state.tabs[tabID] else { return nil }
        return space(tab.spaceID)
    }

    // MARK: - Creation

    @discardableResult
    func createSpace(
        name: String,
        icon: String = "circle.grid.2x2",
        iconIsEmoji: Bool = false,
        iconOverride: SpaceIcon? = nil,
        theme: SpaceTheme? = nil,
        profileID: ProfileID? = nil,
        activate: Bool = true
    ) -> SpaceID {
        var newState = state

        let resolvedProfileID: ProfileID
        if let profileID, newState.profiles.contains(where: { $0.id == profileID }) {
            resolvedProfileID = profileID
        } else if let oldest = newState.profiles.min(by: { $0.createdAt < $1.createdAt }) {
            resolvedProfileID = oldest.id
        } else {
            let fallback = Profile(name: "default")
            newState.profiles.append(fallback)
            resolvedProfileID = fallback.id
        }

        let isEphemeralSpace = newState.profiles
            .first { $0.id == resolvedProfileID }
            .map { OrbitState.isEphemeral($0) } ?? false

        let order = (newState.spaces.map(\.order).max() ?? -1) + 1
        var space = Space(
            name: name,
            icon: icon,
            iconIsEmoji: iconIsEmoji,
            theme: theme ?? SpaceThemePalette.nextDefaultTheme(avoiding: newState.spaces.map(\.theme)),
            profileID: resolvedProfileID,
            order: order,
            isEphemeral: isEphemeralSpace
        )
        if let iconOverride {
            space.apply(iconOverride)
        }
        newState.spaces.append(space)
        if activate { newState.activeSpaceID = space.id }
        adoptSharedFavorites(forSpace: space.id, in: &newState)
        state = newState
        return space.id
    }

    // MARK: - Identity

    func renameSpace(_ id: SpaceID, to name: String) {
        mutateSpace(id) { $0.name = name }
    }

    func setIcon(_ icon: String, isEmoji: Bool, forSpace id: SpaceID) {
        mutateSpace(id) {
            if isEmoji {
                $0.setIcon(emoji: icon)
            } else {
                $0.setIcon(symbol: icon)
            }
        }
    }

    func setIcon(_ icon: SpaceIcon, forSpace id: SpaceID) {
        mutateSpace(id) { $0.apply(icon) }
    }

    func setTheme(_ theme: SpaceTheme, forSpace id: SpaceID) {
        mutateSpace(id) { $0.theme = theme }
    }

    func setProfile(_ profileID: ProfileID, forSpace id: SpaceID) {
        guard state.profiles.contains(where: { $0.id == profileID }) else { return }
        mutateSpace(id) { $0.profileID = profileID }
    }

    func setArchivePolicy(_ policy: ArchivePolicy, forProfile id: ProfileID) {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }),
              state.profiles[index].archivePolicy != policy else { return }
        var newState = state
        newState.profiles[index].archivePolicy = policy
        state = newState
    }

    func archivePolicy(forSpace spaceID: SpaceID) -> ArchivePolicy {
        guard let profileID = state.spaces.first(where: { $0.id == spaceID })?.profileID,
              let profile = state.profiles.first(where: { $0.id == profileID })
        else { return .after12Hours }
        return profile.archivePolicy
    }

    // MARK: - Duplication

    @discardableResult
    func duplicateSpace(_ id: SpaceID) -> SpaceID? {
        guard let original = space(id) else { return nil }
        var newState = state

        let newSpaceID = SpaceID()
        let (duplicatedPinned, clonedTabs) = BrowserStore.cloning(original.pinned, forSpace: newSpaceID, sourceTabs: newState.tabs)

        var duplicate = original
        duplicate.id = newSpaceID
        duplicate.name = "\(original.name) Copy"
        duplicate.order = (newState.spaces.map(\.order).max() ?? -1) + 1
        duplicate.createdAt = Date()
        duplicate.favorites = []
        duplicate.pinned = duplicatedPinned
        duplicate.today = []
        duplicate.legacyArchivePolicy = nil

        for tab in clonedTabs {
            newState.tabs[tab.id] = tab
        }
        newState.spaces.append(duplicate)
        adoptSharedFavorites(forSpace: newSpaceID, in: &newState)
        state = newState
        return newSpaceID
    }

    private static func cloning(
        _ nodes: [SidebarNode],
        forSpace spaceID: SpaceID,
        sourceTabs: [TabID: Tab]
    ) -> (forest: [SidebarNode], tabs: [Tab]) {
        var clonedTabs: [Tab] = []

        func clone(_ nodes: [SidebarNode]) -> [SidebarNode] {
            nodes.map { node in
                switch node {
                case .tab(let tabID):
                    guard let original = sourceTabs[tabID] else { return node }
                    var copy = Tab(spaceID: spaceID, section: .pinned, url: original.url)
                    copy.title = original.title
                    copy.customTitle = original.customTitle
                    copy.faviconURL = original.faviconURL
                    clonedTabs.append(copy)
                    return .tab(copy.id)
                case .folder(var folder):
                    folder.id = FolderID()
                    folder.children = clone(folder.children)
                    return .folder(folder)
                }
            }
        }

        return (clone(nodes), clonedTabs)
    }

    // MARK: - Deletion

    func deleteSpace(_ id: SpaceID) {
        guard state.spaces.count > 1, let index = state.spaces.firstIndex(where: { $0.id == id }) else { return }
        var newState = state
        newState.spaces.remove(at: index)

        let tabIDsToRemove = newState.tabs.values.filter { $0.spaceID == id }.map(\.id)
        var touchedGroups: Set<UUID> = []
        for tabID in tabIDsToRemove {
            if let groupID = newState.tabs[tabID]?.splitGroupID {
                touchedGroups.insert(groupID)
            }
            newState.tabs.removeValue(forKey: tabID)
        }
        for groupID in touchedGroups {
            newState.splitGroups.removeValue(forKey: groupID)
        }
        newState.activeTabBySpace.removeValue(forKey: id)
        recentlyClosedRecords.removeAll { tabIDsToRemove.contains($0.tabID) }

        if newState.activeSpaceID == id {
            let remaining = newState.spaces.sorted { $0.order < $1.order }
            let fallbackIndex = min(index, max(remaining.count - 1, 0))
            newState.activeSpaceID = remaining.indices.contains(fallbackIndex) ? remaining[fallbackIndex].id : remaining.first?.id
        }

        state = newState
    }

    // MARK: - Ordering

    func reorderSpaces(_ ids: [SpaceID]) {
        var newState = state
        for (index, id) in ids.enumerated() {
            if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == id }) {
                newState.spaces[spaceIndex].order = index
            }
        }
        state = newState
    }

    func moveSpaceLeft(_ id: SpaceID) {
        let ordered = spaces
        guard let index = ordered.firstIndex(where: { $0.id == id }), index > 0 else { return }
        var ids = ordered.map(\.id)
        ids.swapAt(index, index - 1)
        reorderSpaces(ids)
    }

    func moveSpaceRight(_ id: SpaceID) {
        let ordered = spaces
        guard let index = ordered.firstIndex(where: { $0.id == id }), index < ordered.count - 1 else { return }
        var ids = ordered.map(\.id)
        ids.swapAt(index, index + 1)
        reorderSpaces(ids)
    }

    // MARK: - Switching

    func switchToSpace(_ id: SpaceID) {
        guard state.spaces.contains(where: { $0.id == id }) else { return }
        var newState = state
        newState.activeSpaceID = id
        state = newState
    }

    func nextSpace() {
        guard let current = activeSpace, !spaces.isEmpty,
              let index = spaces.firstIndex(where: { $0.id == current.id }) else { return }
        switchToSpace(spaces[(index + 1) % spaces.count].id)
    }

    func previousSpace() {
        guard let current = activeSpace, !spaces.isEmpty,
              let index = spaces.firstIndex(where: { $0.id == current.id }) else { return }
        let count = spaces.count
        switchToSpace(spaces[(index - 1 + count) % count].id)
    }

    // MARK: - Shared mutation helper

    // Every Favorite mutation must route through here: it mirrors favorites.diff, matched by URL, across every sibling Space on the same Profile.
    func mutateSpace(_ id: SpaceID, _ transform: (inout Space) -> Void) {
        guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return }
        var newState = state
        let before = newState.spaces[index]
        transform(&newState.spaces[index])
        let profileChanged = newState.spaces[index].profileID != before.profileID

        if newState.spaces[index].favorites != before.favorites {
            newState.spaces[index].favorites = BrowserStore.deduplicatedByURL(newState.spaces[index].favorites)
            mirrorFavoriteChange(from: before.favorites, to: newState.spaces[index].favorites, originSpaceID: id, in: &newState)
        }

        if profileChanged {
            adoptSharedFavorites(forSpace: id, in: &newState)
        }

        state = newState
    }

    func groupIntoNewFolder(name: String, firstID: UUID, secondID: UUID, parent parentFolderID: FolderID?, atIndex index: Int, in spaceID: SpaceID) -> FolderID {
        let newFolder = Folder(name: name)
        mutateSpace(spaceID) { space in
            space.pinned = PinnedNodeTree.inserting(.folder(newFolder), parentFolderID: parentFolderID, at: index, into: space.pinned)
            space.pinned = PinnedNodeTree.moveNode(firstID, toParent: newFolder.id, atIndex: 0, in: space.pinned)
            space.pinned = PinnedNodeTree.moveNode(secondID, toParent: newFolder.id, atIndex: 1, in: space.pinned)
        }
        return newFolder.id
    }
}

// MARK: - Cross-profile Favourites

private extension BrowserStore {

    static func deduplicatedByURL(_ favorites: [Favorite]) -> [Favorite] {
        var seenURLs: Set<URL> = []
        var result: [Favorite] = []
        for favorite in favorites {
            guard !seenURLs.contains(favorite.url) else { continue }
            seenURLs.insert(favorite.url)
            result.append(favorite)
        }
        return result
    }

    func mirrorFavoriteChange(from before: [Favorite], to after: [Favorite], originSpaceID: SpaceID, in newState: inout OrbitState) {
        guard let originIndex = newState.spaces.firstIndex(where: { $0.id == originSpaceID }) else { return }
        let profileID = newState.spaces[originIndex].profileID
        let siblingIndices = newState.spaces.indices.filter {
            newState.spaces[$0].profileID == profileID && newState.spaces[$0].id != originSpaceID
        }
        guard !siblingIndices.isEmpty else { return }

        let beforeURLs = Set(before.map(\.url))
        let afterURLs = Set(after.map(\.url))
        let addedURLs = afterURLs.subtracting(beforeURLs)
        let removedURLs = beforeURLs.subtracting(afterURLs)
        let afterOrder = after.map(\.url)

        for siblingIndex in siblingIndices {
            var favorites = newState.spaces[siblingIndex].favorites

            if !removedURLs.isEmpty {
                favorites.removeAll { removedURLs.contains($0.url) }
            }
            for url in addedURLs where !favorites.contains(where: { $0.url == url }) {
                guard let source = after.first(where: { $0.url == url }) else { continue }
                favorites.append(Favorite(url: source.url, title: source.title))
            }

            var reordered: [Favorite] = []
            var remaining = favorites
            for url in afterOrder {
                if let matchIndex = remaining.firstIndex(where: { $0.url == url }) {
                    reordered.append(remaining.remove(at: matchIndex))
                }
            }
            reordered.append(contentsOf: remaining)
            newState.spaces[siblingIndex].favorites = BrowserStore.deduplicatedByURL(reordered)
        }
    }

    func adoptSharedFavorites(forSpace id: SpaceID, in newState: inout OrbitState) {
        guard let index = newState.spaces.firstIndex(where: { $0.id == id }) else { return }
        let profileID = newState.spaces[index].profileID
        guard let donor = newState.spaces.first(where: { $0.profileID == profileID && $0.id != id }) else { return }
        newState.spaces[index].favorites = BrowserStore.deduplicatedByURL(
            donor.favorites.map { Favorite(url: $0.url, title: $0.title) }
        )
    }
}
