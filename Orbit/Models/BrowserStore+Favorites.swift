import Foundation

public enum FavoriteAddOutcome: Equatable {
    case added(UUID)
    case alreadyExists(UUID)
    case atCapacity

    public var favoriteID: UUID? {
        switch self {
        case .added(let id), .alreadyExists(let id): return id
        case .atCapacity: return nil
        }
    }

    public var succeeded: Bool {
        favoriteID != nil
    }
}

public extension BrowserStore {

    func favorites(for spaceID: SpaceID) -> [Favorite] {
        space(spaceID)?.favorites ?? []
    }

    func favorite(_ id: UUID, in spaceID: SpaceID) -> Favorite? {
        favorites(for: spaceID).first { $0.id == id }
    }

    func normalizedFavoriteKey(for url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        let defaultPorts: [String: Int] = ["https": 443, "http": 80]
        let port = (url.port == defaultPorts[scheme]) ? nil : url.port
        let path = url.path == "/" ? "" : url.path
        var key = "\(scheme)://\(host)"
        if let port { key += ":\(port)" }
        key += path
        if let query = url.query { key += "?\(query)" }
        if let fragment = url.fragment { key += "#\(fragment)" }
        return key
    }

    func favorite(matching url: URL, in spaceID: SpaceID) -> Favorite? {
        let key = normalizedFavoriteKey(for: url)
        return favorites(for: spaceID).first { normalizedFavoriteKey(for: $0.url) == key }
    }

    func canAddFavorite(in spaceID: SpaceID) -> Bool {
        favorites(for: spaceID).count < OrbitMetrics.favoritesMaximumCount
    }

    @discardableResult
    func addFavorite(url: URL, title: String, in spaceID: SpaceID) -> FavoriteAddOutcome {
        if let existing = favorite(matching: url, in: spaceID) { return .alreadyExists(existing.id) }
        guard canAddFavorite(in: spaceID) else { return .atCapacity }
        let favorite = Favorite(url: url, title: title)
        mutateSpace(spaceID) { $0.favorites.append(favorite) }
        return .added(favorite.id)
    }

    func removeFavorite(_ id: UUID, from spaceID: SpaceID) {
        mutateSpace(spaceID) { $0.favorites.removeAll { $0.id == id } }
    }

    func reorderFavorites(_ ids: [UUID], in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            let existing = space.favorites
            let reordered = ids.compactMap { id in existing.first { $0.id == id } }
            let remaining = existing.filter { favorite in !ids.contains(favorite.id) }
            space.favorites = reordered + remaining
        }
    }

    func bindLiveTab(_ tabID: TabID, toFavorite favoriteID: UUID, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            guard let index = space.favorites.firstIndex(where: { $0.id == favoriteID }) else { return }
            space.favorites[index].liveTabID = tabID
        }
    }

    func releaseLiveTab(fromFavorite favoriteID: UUID, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            guard let index = space.favorites.firstIndex(where: { $0.id == favoriteID }) else { return }
            space.favorites[index].liveTabID = nil
        }
    }

    func setCustomIcon(_ icon: String, isEmoji: Bool, forFavorite id: UUID, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            guard let index = space.favorites.firstIndex(where: { $0.id == id }) else { return }
            space.favorites[index].customIcon = icon
            space.favorites[index].customIconIsEmoji = isEmoji
        }
    }

    func clearCustomIcon(forFavorite id: UUID, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            guard let index = space.favorites.firstIndex(where: { $0.id == id }) else { return }
            space.favorites[index].customIcon = nil
            space.favorites[index].customIconIsEmoji = false
        }
    }

    func activateFavorite(_ id: UUID, in spaceID: SpaceID) {
        guard let favorite = favorite(id, in: spaceID) else { return }
        if let liveTabID = favorite.liveTabID, state.tabs[liveTabID] != nil {
            selectTab(liveTabID)
        } else {
            let newTabID = openTab(url: favorite.url, in: spaceID, section: .today, activate: true)
            bindLiveTab(newTabID, toFavorite: favorite.id, in: spaceID)
        }
    }

    @discardableResult
    func promoteTabToFavorite(_ tabID: TabID) -> FavoriteAddOutcome? {
        guard let tab = state.tabs[tabID] else { return nil }
        if let existing = favorite(matching: tab.url, in: tab.spaceID) {
            bindLiveTab(tabID, toFavorite: existing.id, in: tab.spaceID)
            return .alreadyExists(existing.id)
        }
        guard canAddFavorite(in: tab.spaceID) else { return .atCapacity }
        var favorite = Favorite(url: tab.url, title: tab.displayTitle)
        favorite.liveTabID = tabID
        mutateSpace(tab.spaceID) { $0.favorites.append(favorite) }
        return .added(favorite.id)
    }
}
