import Foundation

public enum PinnedNodeTree {

    // MARK: - Lookup

    public static func path(to id: UUID, in nodes: [SidebarNode]) -> [Int]? {
        for (index, node) in nodes.enumerated() {
            if node.id == id { return [index] }
            if case .folder(let folder) = node, let sub = path(to: id, in: folder.children) {
                return [index] + sub
            }
        }
        return nil
    }

    public static func node(at path: [Int], in nodes: [SidebarNode]) -> SidebarNode? {
        guard let head = path.first, nodes.indices.contains(head) else { return nil }
        if path.count == 1 { return nodes[head] }
        guard case .folder(let folder) = nodes[head] else { return nil }
        return node(at: Array(path.dropFirst()), in: folder.children)
    }

    public static func find(_ id: UUID, in nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if node.id == id { return node }
            if case .folder(let folder) = node, let found = find(id, in: folder.children) {
                return found
            }
        }
        return nil
    }

    public static func findFolder(_ id: FolderID, in nodes: [SidebarNode]) -> Folder? {
        for node in nodes {
            if case .folder(let folder) = node {
                if folder.id == id { return folder }
                if let found = findFolder(id, in: folder.children) { return found }
            }
        }
        return nil
    }

    public static func parentFolderID(of id: UUID, in nodes: [SidebarNode]) -> FolderID? {
        for node in nodes {
            guard case .folder(let folder) = node else { continue }
            if folder.children.contains(where: { $0.id == id }) { return folder.id }
            if let found = parentFolderID(of: id, in: folder.children) { return found }
        }
        return nil
    }

    public static func isDescendant(_ candidateID: UUID, ofOrEqualTo nodeID: UUID, in nodes: [SidebarNode]) -> Bool {
        guard let node = find(nodeID, in: nodes) else { return false }
        return containsID(candidateID, in: [node])
    }

    private static func containsID(_ id: UUID, in nodes: [SidebarNode]) -> Bool {
        for node in nodes {
            if node.id == id { return true }
            if case .folder(let folder) = node, containsID(id, in: folder.children) { return true }
        }
        return false
    }

    // MARK: - Folder preview / peek

    public static func peekedTabID(inCollapsedFolder folder: Folder, activeTabID: TabID?) -> TabID? {
        guard !folder.isExpanded, let activeTabID else { return nil }
        guard folder.children.flatMap(\.allTabIDs).contains(activeTabID) else { return nil }
        return activeTabID
    }

    // MARK: - Path-based mutation

    public static func inserting(_ node: SidebarNode, at path: [Int], into nodes: [SidebarNode]) -> [SidebarNode] {
        guard let head = path.first else {
            var result = nodes
            result.insert(node, at: 0)
            return result
        }
        if path.count == 1 {
            var result = nodes
            let clamped = max(0, min(head, result.count))
            result.insert(node, at: clamped)
            return result
        }
        guard nodes.indices.contains(head), case .folder(var folder) = nodes[head] else { return nodes }
        var result = nodes
        folder.children = inserting(node, at: Array(path.dropFirst()), into: folder.children)
        result[head] = .folder(folder)
        return result
    }

    public static func removing(at path: [Int], from nodes: [SidebarNode]) -> (forest: [SidebarNode], removed: SidebarNode?) {
        guard let head = path.first, nodes.indices.contains(head) else { return (nodes, nil) }
        var result = nodes
        if path.count == 1 {
            let removed = result.remove(at: head)
            return (result, removed)
        }
        guard case .folder(var folder) = result[head] else { return (nodes, nil) }
        let (childForest, removed) = removing(at: Array(path.dropFirst()), from: folder.children)
        guard removed != nil else { return (nodes, nil) }
        folder.children = childForest
        result[head] = .folder(folder)
        return (result, removed)
    }

    public static func moving(from sourcePath: [Int], to destinationPath: [Int], in nodes: [SidebarNode]) -> [SidebarNode] {
        guard let sourceNode = node(at: sourcePath, in: nodes) else { return nodes }
        if case .folder = sourceNode {
            if let destinationParentID = folderID(containingInsertionPath: destinationPath, in: nodes),
               isDescendant(destinationParentID, ofOrEqualTo: sourceNode.id, in: nodes) {
                return nodes
            }
        }
        let (forest, removed) = removing(at: sourcePath, from: nodes)
        guard let removed else { return nodes }
        return inserting(removed, at: destinationPath, into: forest)
    }

    private static func folderID(containingInsertionPath path: [Int], in nodes: [SidebarNode]) -> FolderID? {
        guard path.count > 1, let head = path.first, nodes.indices.contains(head) else { return nil }
        guard case .folder(let folder) = nodes[head] else { return nil }
        if path.count == 2 { return folder.id }
        return folderID(containingInsertionPath: Array(path.dropFirst()), in: folder.children)
    }

    // MARK: - ID-based mutation (what `BrowserStore` calls)

    public static func removing(_ id: UUID, from nodes: [SidebarNode]) -> (forest: [SidebarNode], removed: SidebarNode?) {
        guard let path = path(to: id, in: nodes) else { return (nodes, nil) }
        return removing(at: path, from: nodes)
    }

    public static func inserting(
        _ node: SidebarNode,
        parentFolderID: FolderID?,
        at index: Int,
        into nodes: [SidebarNode]
    ) -> [SidebarNode] {
        guard let parentFolderID else {
            var result = nodes
            let clamped = max(0, min(index, result.count))
            result.insert(node, at: clamped)
            return result
        }
        return nodes.map { current in
            switch current {
            case .tab:
                return current
            case .folder(var folder):
                if folder.id == parentFolderID {
                    let clamped = max(0, min(index, folder.children.count))
                    folder.children.insert(node, at: clamped)
                    return .folder(folder)
                }
                folder.children = inserting(node, parentFolderID: parentFolderID, at: index, into: folder.children)
                return .folder(folder)
            }
        }
    }

    public static func moveNode(
        _ id: UUID,
        toParent parentFolderID: FolderID?,
        atIndex index: Int,
        in nodes: [SidebarNode]
    ) -> [SidebarNode] {
        if let parentFolderID, parentFolderID == id { return nodes }
        if let parentFolderID, isDescendant(parentFolderID, ofOrEqualTo: id, in: nodes) { return nodes }

        let (forest, removed) = removing(id, from: nodes)
        guard let removed else { return nodes }
        return inserting(removed, parentFolderID: parentFolderID, at: index, into: forest)
    }

    public static func updatingFolder(_ id: FolderID, in nodes: [SidebarNode], _ transform: (inout Folder) -> Void) -> [SidebarNode] {
        nodes.map { node in
            switch node {
            case .tab:
                return node
            case .folder(var folder):
                if folder.id == id {
                    transform(&folder)
                    return .folder(folder)
                }
                folder.children = updatingFolder(id, in: folder.children, transform)
                return .folder(folder)
            }
        }
    }

    public static func hoistingChildren(ofFolder id: FolderID, in nodes: [SidebarNode]) -> [SidebarNode] {
        guard let originalPath = path(to: id, in: nodes),
              let originalNode = node(at: originalPath, in: nodes),
              case .folder(let folder) = originalNode else { return nodes }
        let (forest, removed) = removing(at: originalPath, from: nodes)
        guard removed != nil else { return nodes }
        var result = forest
        let parentPath = Array(originalPath.dropLast())
        var insertionIndex = originalPath.last ?? 0
        for child in folder.children {
            result = inserting(child, at: parentPath + [insertionIndex], into: result)
            insertionIndex += 1
        }
        return result
    }
}
