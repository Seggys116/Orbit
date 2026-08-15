import Foundation

nonisolated public enum BookmarkErrors {
    public static let noNode = "Can't find bookmark for id."
    public static let noParent = "Can't find parent bookmark for id."
    public static let folderNotEmpty = "Can't remove non-empty folder (use recursive to force)."
    public static let invalidID = "Bookmark id is invalid."
    public static let invalidIndex = "Index out of bounds."
    public static let invalidParent = "Parameter 'parentId' does not specify a folder."
    public static let invalidURL = "Invalid URL."
    public static let modifySpecial = "Can't modify the root bookmark folders."
    public static let cannotSetURLOfFolder = "Can't set URL of a bookmark folder."
    public static let invalidMoveDestination = "Can't move a folder to itself or its descendant."

    public static let favoritesAtCapacity =
        "Orbit allows at most \(OrbitMetrics.favoritesMaximumCount) favourites per Space."
    public static let favoritesCannotContainFolders = "Orbit favourites cannot contain folders."
    public static let folderBetweenSpaces = "Orbit cannot move a folder between Spaces."
    public static let favoriteOutOfFavorites = "Orbit cannot move a favourite out of Favourites."
    public static let unavailable = "Bookmarks are not available."
}

nonisolated public struct BookmarkMutationError: Error, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

@MainActor
enum BookmarkMutationRouter {

    static func apply(method: String, args: [String: Any], store: BrowserStore) throws -> BookmarkNodeID {
        switch method {
        case "create": return try create(args, store: store)
        case "move": return try move(args, store: store)
        case "update": return try update(args, store: store)
        case "remove": return try remove(args, store: store, recursive: false)
        case "removeTree": return try remove(args, store: store, recursive: true)
        default: throw BookmarkMutationError(BookmarkErrors.unavailable)
        }
    }

    // MARK: - create

    private static func create(_ args: [String: Any], store: BrowserStore) throws -> BookmarkNodeID {
        guard let parent = BookmarkNodeID(rawValue: string(args, "parentId") ?? "") else {
            throw BookmarkMutationError(BookmarkErrors.noParent)
        }
        let title = string(args, "title") ?? ""
        let index = int(args, "index")
        let urlString = string(args, "url")

        switch parent {
        case .root, .space:
            throw BookmarkMutationError(BookmarkErrors.modifySpecial)
        case .favorite, .pinnedTab:
            throw BookmarkMutationError(BookmarkErrors.invalidParent)
        case .favorites(let spaceID):
            guard let space = store.space(spaceID) else { throw BookmarkMutationError(BookmarkErrors.noParent) }
            guard let urlString else { throw BookmarkMutationError(BookmarkErrors.favoritesCannotContainFolders) }
            let url = try parseURL(urlString)
            try checkBounds(index, count: space.favorites.count)
            let outcome = store.addFavorite(url: url, title: title, in: spaceID)
            guard let favoriteID = outcome.favoriteID else {
                throw BookmarkMutationError(BookmarkErrors.favoritesAtCapacity)
            }
            if let index {
                var ids = store.favorites(for: spaceID).map(\.id)
                if let current = ids.firstIndex(of: favoriteID) {
                    ids.remove(at: current)
                    ids.insert(favoriteID, at: min(index, ids.count))
                    store.reorderFavorites(ids, in: spaceID)
                }
            }
            return .favorite(favoriteID)
        case .pinned, .pinnedFolder:
            let destination = try pinnedDestination(parent, store: store)
            try checkBounds(
                index,
                count: BookmarkTreeProjection.projectedChildCount(of: destination.siblings, state: store.state)
            )
            let modelIndex = index.map {
                BookmarkTreeProjection.modelIndex(forProjectedIndex: $0, in: destination.siblings, state: store.state)
            } ?? Int.max
            guard let urlString else {
                let folderID = store.createFolder(
                    name: title, in: destination.spaceID, parent: destination.folderID, at: modelIndex
                )
                return .pinnedFolder(folderID)
            }
            let url = try parseURL(urlString)
            let tabID = store.openTab(url: url, in: destination.spaceID, section: .pinned, at: nil, activate: false)
            if !title.isEmpty {
                store.renameTab(tabID, to: title)
            }
            store.moveNode(tabID, toParent: destination.folderID, atIndex: modelIndex, in: destination.spaceID)
            return .pinnedTab(tabID)
        }
    }

    // MARK: - move

    private static func move(_ args: [String: Any], store: BrowserStore) throws -> BookmarkNodeID {
        let node = try identifier(args)
        guard !node.isPermanent else { throw BookmarkMutationError(BookmarkErrors.modifySpecial) }
        let index = int(args, "index")
        let requestedParent = string(args, "parentId")

        switch node {
        case .favorite(let favoriteID):
            guard let space = BookmarkTreeProjection.space(containingFavorite: favoriteID, in: store.state) else {
                throw BookmarkMutationError(BookmarkErrors.noNode)
            }
            let destination = try parentIdentifier(requestedParent, fallback: .favorites(space.id), store: store)
            switch destination {
            case .root, .space:
                throw BookmarkMutationError(BookmarkErrors.modifySpecial)
            case .favorite, .pinnedTab:
                throw BookmarkMutationError(BookmarkErrors.invalidParent)
            case .pinned, .pinnedFolder:
                throw BookmarkMutationError(BookmarkErrors.favoriteOutOfFavorites)
            case .favorites(let destinationSpaceID):
                guard destinationSpaceID == space.id else {
                    throw BookmarkMutationError(BookmarkErrors.favoriteOutOfFavorites)
                }
                var ids = space.favorites.map(\.id)
                guard let current = ids.firstIndex(of: favoriteID) else {
                    throw BookmarkMutationError(BookmarkErrors.noNode)
                }
                try checkBounds(index, count: ids.count)
                var target = index ?? ids.count
                if target > current { target -= 1 }
                ids.remove(at: current)
                ids.insert(favoriteID, at: min(target, ids.count))
                store.reorderFavorites(ids, in: space.id)
                return node
            }

        case .pinnedTab(let tabID):
            guard let tab = store.state.tabs[tabID], tab.section == .pinned,
                  let sourceSpace = BookmarkTreeProjection.space(containingPinnedNode: tabID, in: store.state)
            else { throw BookmarkMutationError(BookmarkErrors.noNode) }
            let fallback = currentParent(of: tabID, in: sourceSpace)
            let destination = try parentIdentifier(requestedParent, fallback: fallback, store: store)
            switch destination {
            case .root, .space:
                throw BookmarkMutationError(BookmarkErrors.modifySpecial)
            case .favorite, .pinnedTab:
                throw BookmarkMutationError(BookmarkErrors.invalidParent)
            case .favorites:
                throw BookmarkMutationError(BookmarkErrors.favoriteOutOfFavorites)
            case .pinned, .pinnedFolder:
                let target = try pinnedDestination(destination, store: store)
                let modelIndex = try resolvedIndex(
                    index, moving: tabID, in: target.siblings,
                    sameParent: destination == fallback, store: store
                )
                if target.spaceID == sourceSpace.id {
                    store.moveNode(tabID, toParent: target.folderID, atIndex: modelIndex, in: target.spaceID)
                } else {
                    store.pin(tabID, toParent: target.folderID, atIndex: modelIndex, in: target.spaceID)
                }
                return node
            }

        case .pinnedFolder(let folderID):
            guard let sourceSpace = BookmarkTreeProjection.space(containingPinnedNode: folderID, in: store.state),
                  store.folder(folderID, in: sourceSpace.id) != nil
            else { throw BookmarkMutationError(BookmarkErrors.noNode) }
            let fallback = currentParent(of: folderID, in: sourceSpace)
            let destination = try parentIdentifier(requestedParent, fallback: fallback, store: store)
            switch destination {
            case .root, .space:
                throw BookmarkMutationError(BookmarkErrors.modifySpecial)
            case .favorite, .pinnedTab:
                throw BookmarkMutationError(BookmarkErrors.invalidParent)
            case .favorites:
                throw BookmarkMutationError(BookmarkErrors.favoritesCannotContainFolders)
            case .pinned, .pinnedFolder:
                let target = try pinnedDestination(destination, store: store)
                guard target.spaceID == sourceSpace.id else {
                    throw BookmarkMutationError(BookmarkErrors.folderBetweenSpaces)
                }
                if let parentFolderID = target.folderID,
                   PinnedNodeTree.isDescendant(parentFolderID, ofOrEqualTo: folderID, in: sourceSpace.pinned) {
                    throw BookmarkMutationError(BookmarkErrors.invalidMoveDestination)
                }
                let modelIndex = try resolvedIndex(
                    index, moving: folderID, in: target.siblings,
                    sameParent: destination == fallback, store: store
                )
                store.moveNode(folderID, toParent: target.folderID, atIndex: modelIndex, in: target.spaceID)
                return node
            }

        case .root, .space, .favorites, .pinned:
            throw BookmarkMutationError(BookmarkErrors.modifySpecial)
        }
    }

    // MARK: - update

    private static func update(_ args: [String: Any], store: BrowserStore) throws -> BookmarkNodeID {
        let node = try identifier(args)
        guard !node.isPermanent else { throw BookmarkMutationError(BookmarkErrors.modifySpecial) }
        let title = string(args, "title")
        let urlString = string(args, "url")

        switch node {
        case .favorite(let favoriteID):
            guard let space = BookmarkTreeProjection.space(containingFavorite: favoriteID, in: store.state) else {
                throw BookmarkMutationError(BookmarkErrors.noNode)
            }
            let url = try urlString.map { try parseURL($0) }
            store.mutateSpace(space.id) { space in
                guard let index = space.favorites.firstIndex(where: { $0.id == favoriteID }) else { return }
                if let url { space.favorites[index].url = url }
                if let title { space.favorites[index].title = title }
            }
            return node

        case .pinnedTab(let tabID):
            guard let tab = store.state.tabs[tabID], tab.section == .pinned else {
                throw BookmarkMutationError(BookmarkErrors.noNode)
            }
            let url = try urlString.map { try parseURL($0) }
            if let url { store.setPinnedURL(tabID, to: url) }
            if let title { store.renameTab(tabID, to: title) }
            return node

        case .pinnedFolder(let folderID):
            guard let space = BookmarkTreeProjection.space(containingPinnedNode: folderID, in: store.state),
                  store.folder(folderID, in: space.id) != nil
            else { throw BookmarkMutationError(BookmarkErrors.noNode) }
            guard urlString == nil else { throw BookmarkMutationError(BookmarkErrors.cannotSetURLOfFolder) }
            if let title { store.renameFolder(folderID, to: title, in: space.id) }
            return node

        case .root, .space, .favorites, .pinned:
            throw BookmarkMutationError(BookmarkErrors.modifySpecial)
        }
    }

    // MARK: - remove / removeTree

    private static func remove(_ args: [String: Any], store: BrowserStore, recursive: Bool) throws -> BookmarkNodeID {
        let node = try identifier(args)
        guard !node.isPermanent else { throw BookmarkMutationError(BookmarkErrors.modifySpecial) }

        switch node {
        case .favorite(let favoriteID):
            guard let space = BookmarkTreeProjection.space(containingFavorite: favoriteID, in: store.state) else {
                throw BookmarkMutationError(BookmarkErrors.noNode)
            }
            store.removeFavorite(favoriteID, from: space.id)
            return node

        case .pinnedTab(let tabID):
            guard let tab = store.state.tabs[tabID], tab.section == .pinned else {
                throw BookmarkMutationError(BookmarkErrors.noNode)
            }
            store.removeBookmark(tabID)
            return node

        case .pinnedFolder(let folderID):
            guard let space = BookmarkTreeProjection.space(containingPinnedNode: folderID, in: store.state),
                  let folder = store.folder(folderID, in: space.id)
            else { throw BookmarkMutationError(BookmarkErrors.noNode) }
            guard recursive else {
                guard folder.children.isEmpty else { throw BookmarkMutationError(BookmarkErrors.folderNotEmpty) }
                store.deleteFolder(folderID, in: space.id)
                return node
            }
            removeChildren(of: folder, in: space.id, store: store)
            store.deleteFolder(folderID, in: space.id)
            return node

        case .root, .space, .favorites, .pinned:
            throw BookmarkMutationError(BookmarkErrors.modifySpecial)
        }
    }

    private static func removeChildren(of folder: Folder, in spaceID: SpaceID, store: BrowserStore) {
        for child in folder.children {
            switch child {
            case .tab(let tabID):
                guard store.state.tabs[tabID]?.section == .pinned else { continue }
                store.removeBookmark(tabID)
            case .folder(let child):
                removeChildren(of: child, in: spaceID, store: store)
                store.deleteFolder(child.id, in: spaceID)
            }
        }
    }

    // MARK: - Shared

    private struct PinnedDestination {
        let spaceID: SpaceID
        let folderID: FolderID?
        let siblings: [SidebarNode]
    }

    private static func pinnedDestination(_ parent: BookmarkNodeID, store: BrowserStore) throws -> PinnedDestination {
        switch parent {
        case .pinned(let spaceID):
            guard let space = store.space(spaceID) else { throw BookmarkMutationError(BookmarkErrors.noParent) }
            return PinnedDestination(spaceID: spaceID, folderID: nil, siblings: space.pinned)
        case .pinnedFolder(let folderID):
            guard let space = BookmarkTreeProjection.space(containingPinnedNode: folderID, in: store.state),
                  let folder = store.folder(folderID, in: space.id)
            else { throw BookmarkMutationError(BookmarkErrors.noParent) }
            return PinnedDestination(spaceID: space.id, folderID: folderID, siblings: folder.children)
        default:
            throw BookmarkMutationError(BookmarkErrors.invalidParent)
        }
    }

    private static func currentParent(of nodeID: UUID, in space: Space) -> BookmarkNodeID {
        guard let folderID = PinnedNodeTree.parentFolderID(of: nodeID, in: space.pinned) else {
            return .pinned(space.id)
        }
        return .pinnedFolder(folderID)
    }

    private static func parentIdentifier(
        _ raw: String?, fallback: BookmarkNodeID, store: BrowserStore
    ) throws -> BookmarkNodeID {
        guard let raw else { return fallback }
        guard let parent = BookmarkNodeID(rawValue: raw) else { throw BookmarkMutationError(BookmarkErrors.noParent) }
        if let spaceID = parent.spaceID, store.space(spaceID) == nil {
            throw BookmarkMutationError(BookmarkErrors.noParent)
        }
        return parent
    }

    private static func identifier(_ args: [String: Any]) throws -> BookmarkNodeID {
        guard let raw = string(args, "id"), let node = BookmarkNodeID(rawValue: raw) else {
            throw BookmarkMutationError(BookmarkErrors.invalidID)
        }
        return node
    }

    // Chrome reads the index against the list with the node still in it (BookmarkModel::Move),
    // while moveNode removes first, so a downward move within one parent needs the decrement.
    private static func resolvedIndex(
        _ index: Int?, moving nodeID: UUID, in siblings: [SidebarNode], sameParent: Bool, store: BrowserStore
    ) throws -> Int {
        let state = store.state
        try checkBounds(index, count: BookmarkTreeProjection.projectedChildCount(of: siblings, state: state))
        guard var index else { return Int.max }
        if sameParent,
           let current = BookmarkTreeProjection.projectedIndex(of: nodeID, in: siblings, state: state),
           index > current {
            index -= 1
        }
        return BookmarkTreeProjection.modelIndex(forProjectedIndex: index, in: siblings, state: state)
    }

    private static func checkBounds(_ index: Int?, count: Int) throws {
        guard let index else { return }
        guard index >= 0, index <= count else { throw BookmarkMutationError(BookmarkErrors.invalidIndex) }
    }

    private static func parseURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty, !url.absoluteString.isEmpty else {
            throw BookmarkMutationError(BookmarkErrors.invalidURL)
        }
        return url
    }

    private static func string(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    private static func int(_ args: [String: Any], _ key: String) -> Int? {
        (args[key] as? NSNumber)?.intValue
    }
}
