import Foundation

nonisolated public enum BookmarkNodeID: Hashable {
    case root
    case space(SpaceID)
    case favorites(SpaceID)
    case pinned(SpaceID)
    case favorite(UUID)
    case pinnedFolder(FolderID)
    case pinnedTab(TabID)

    public var rawValue: String {
        switch self {
        case .root: return "0"
        case .space(let id): return "s:" + id.uuidString.lowercased()
        case .favorites(let id): return "f:" + id.uuidString.lowercased()
        case .pinned(let id): return "p:" + id.uuidString.lowercased()
        case .favorite(let id): return "b:" + id.uuidString.lowercased()
        case .pinnedFolder(let id): return "d:" + id.uuidString.lowercased()
        case .pinnedTab(let id): return "t:" + id.uuidString.lowercased()
        }
    }

    public init?(rawValue: String) {
        if rawValue == "0" {
            self = .root
            return
        }
        guard rawValue.count > 2 else { return nil }
        let prefix = rawValue.prefix(2)
        guard prefix.last == ":", let uuid = UUID(uuidString: String(rawValue.dropFirst(2))) else { return nil }
        switch prefix.first {
        case "s": self = .space(uuid)
        case "f": self = .favorites(uuid)
        case "p": self = .pinned(uuid)
        case "b": self = .favorite(uuid)
        case "d": self = .pinnedFolder(uuid)
        case "t": self = .pinnedTab(uuid)
        default: return nil
        }
    }

    public var isPermanent: Bool {
        switch self {
        case .root, .space, .favorites, .pinned: return true
        case .favorite, .pinnedFolder, .pinnedTab: return false
        }
    }

    public var spaceID: SpaceID? {
        switch self {
        case .space(let id), .favorites(let id), .pinned(let id): return id
        case .root, .favorite, .pinnedFolder, .pinnedTab: return nil
        }
    }
}

nonisolated public enum BookmarkTreeProjection {

    public static let favoritesTitle = "Favourites"
    public static let pinnedTitle = "Pinned"

    public static func treeJSON(for state: OrbitState) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: treeObject(for: state), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return #"{"children":[],"id":"0","permanent":true,"syncing":false,"title":""}"# }
        return json
    }

    public static func treeObject(for state: OrbitState) -> [String: Any] {
        var root: [String: Any] = [
            "id": BookmarkNodeID.root.rawValue,
            "title": "",
            "permanent": true,
            "syncing": false,
        ]
        root["children"] = orderedSpaces(in: state).enumerated().map { index, space in
            spaceNode(space, index: index, state: state)
        }
        return root
    }

    public static func orderedSpaces(in state: OrbitState) -> [Space] {
        state.spaces.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public static func space(containingFavorite favoriteID: UUID, in state: OrbitState) -> Space? {
        state.spaces.first { $0.favorites.contains { $0.id == favoriteID } }
    }

    public static func space(containingPinnedNode nodeID: UUID, in state: OrbitState) -> Space? {
        state.spaces.first { PinnedNodeTree.find(nodeID, in: $0.pinned) != nil }
    }

    // Projected and model indices differ once a pinned node's Tab has gone missing.
    public static func modelIndex(forProjectedIndex index: Int, in siblings: [SidebarNode], state: OrbitState) -> Int {
        var projected = 0
        for (modelIndex, node) in siblings.enumerated() {
            if case .tab(let tabID) = node, state.tabs[tabID] == nil { continue }
            if projected == index { return modelIndex }
            projected += 1
        }
        return siblings.count
    }

    public static func projectedIndex(of nodeID: UUID, in siblings: [SidebarNode], state: OrbitState) -> Int? {
        var projected = 0
        for node in siblings {
            if case .tab(let tabID) = node, state.tabs[tabID] == nil { continue }
            if node.id == nodeID { return projected }
            projected += 1
        }
        return nil
    }

    public static func projectedChildCount(of siblings: [SidebarNode], state: OrbitState) -> Int {
        siblings.reduce(into: 0) { count, node in
            if case .tab(let tabID) = node, state.tabs[tabID] == nil { return }
            count += 1
        }
    }

    // MARK: - Nodes

    private static func spaceNode(_ space: Space, index: Int, state: OrbitState) -> [String: Any] {
        var node = base(id: .space(space.id), parent: .root, index: index, title: space.name)
        node["permanent"] = true
        node["dateAdded"] = milliseconds(space.createdAt)
        node["children"] = [
            favoritesNode(space, index: 0),
            pinnedNode(space, index: 1, state: state),
        ]
        return node
    }

    private static func favoritesNode(_ space: Space, index: Int) -> [String: Any] {
        let id = BookmarkNodeID.favorites(space.id)
        var node = base(id: id, parent: .space(space.id), index: index, title: favoritesTitle)
        node["permanent"] = true
        node["children"] = space.favorites.enumerated().map { childIndex, favorite -> [String: Any] in
            var leaf = base(id: .favorite(favorite.id), parent: id, index: childIndex, title: favorite.title)
            leaf["url"] = favorite.url.absoluteString
            return leaf
        }
        return node
    }

    private static func pinnedNode(_ space: Space, index: Int, state: OrbitState) -> [String: Any] {
        let id = BookmarkNodeID.pinned(space.id)
        var node = base(id: id, parent: .space(space.id), index: index, title: pinnedTitle)
        node["permanent"] = true
        node["children"] = childNodes(space.pinned, parent: id, state: state)
        return node
    }

    private static func childNodes(_ nodes: [SidebarNode], parent: BookmarkNodeID, state: OrbitState) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for node in nodes {
            switch node {
            case .tab(let tabID):
                guard let tab = state.tabs[tabID] else { continue }
                var leaf = base(
                    id: .pinnedTab(tabID), parent: parent, index: result.count, title: tab.displayTitle
                )
                leaf["url"] = (tab.pinnedURL ?? tab.url).absoluteString
                leaf["dateAdded"] = milliseconds(tab.createdAt)
                result.append(leaf)
            case .folder(let folder):
                let id = BookmarkNodeID.pinnedFolder(folder.id)
                var branch = base(id: id, parent: parent, index: result.count, title: folder.name)
                branch["children"] = childNodes(folder.children, parent: id, state: state)
                result.append(branch)
            }
        }
        return result
    }

    private static func base(id: BookmarkNodeID, parent: BookmarkNodeID, index: Int, title: String) -> [String: Any] {
        [
            "id": id.rawValue,
            "parentId": parent.rawValue,
            "index": index,
            "title": title,
            "syncing": false,
        ]
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }
}
