import Foundation

public extension BrowserStore {

    func pinnedNodes(in spaceID: SpaceID) -> [SidebarNode] {
        space(spaceID)?.pinned ?? []
    }

    func node(_ id: UUID, in spaceID: SpaceID) -> SidebarNode? {
        PinnedNodeTree.find(id, in: pinnedNodes(in: spaceID))
    }

    func folder(_ id: FolderID, in spaceID: SpaceID) -> Folder? {
        PinnedNodeTree.findFolder(id, in: pinnedNodes(in: spaceID))
    }

    func path(to nodeID: UUID, in spaceID: SpaceID) -> [Int]? {
        PinnedNodeTree.path(to: nodeID, in: pinnedNodes(in: spaceID))
    }

    func node(at path: [Int], in spaceID: SpaceID) -> SidebarNode? {
        PinnedNodeTree.node(at: path, in: pinnedNodes(in: spaceID))
    }

    // MARK: - Create

    @discardableResult
    func createFolder(name: String, in spaceID: SpaceID, parent parentFolderID: FolderID? = nil, at index: Int = .max) -> FolderID {
        let folder = Folder(name: name)
        mutateSpace(spaceID) { space in
            space.pinned = PinnedNodeTree.inserting(.folder(folder), parentFolderID: parentFolderID, at: index, into: space.pinned)
        }
        return folder.id
    }

    @discardableResult
    func createFolder(fromSelection tabIDs: [TabID], name: String, in spaceID: SpaceID, parent parentFolderID: FolderID? = nil) -> FolderID {
        let folderID = createFolder(name: name, in: spaceID, parent: parentFolderID)
        for tabID in tabIDs {
            if state.tabs[tabID]?.section != .pinned {
                pin(tabID)
            }
            moveNode(tabID, toParent: folderID, atIndex: .max, in: spaceID)
        }
        return folderID
    }

    // MARK: - Rename / icon

    func renameFolder(_ id: FolderID, to name: String, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            space.pinned = PinnedNodeTree.updatingFolder(id, in: space.pinned) { $0.name = name }
        }
    }

    func setFolderIcon(_ icon: String?, isEmoji: Bool, forFolder id: FolderID, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            space.pinned = PinnedNodeTree.updatingFolder(id, in: space.pinned) {
                $0.icon = icon
                $0.iconIsEmoji = isEmoji
            }
        }
    }

    // MARK: - Expand / collapse

    func setFolderExpanded(_ id: FolderID, expanded: Bool, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            space.pinned = PinnedNodeTree.updatingFolder(id, in: space.pinned) { $0.isExpanded = expanded }
        }
    }

    func toggleFolderExpanded(_ id: FolderID, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            space.pinned = PinnedNodeTree.updatingFolder(id, in: space.pinned) { $0.isExpanded.toggle() }
        }
    }

    // MARK: - Delete (always hoists children)

    func deleteFolder(_ id: FolderID, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            space.pinned = PinnedNodeTree.hoistingChildren(ofFolder: id, in: space.pinned)
        }
    }

    // MARK: - Move (drag-and-drop reparenting / reordering)

    func moveNode(_ nodeID: UUID, toParent parentFolderID: FolderID?, atIndex index: Int, in spaceID: SpaceID) {
        mutateSpace(spaceID) { space in
            space.pinned = PinnedNodeTree.moveNode(nodeID, toParent: parentFolderID, atIndex: index, in: space.pinned)
        }
    }
}
