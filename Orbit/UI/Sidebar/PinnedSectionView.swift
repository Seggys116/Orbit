import SwiftUI

struct PinnedSectionView: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var theme: SpaceTheme

    private var nodes: [SidebarNode] { env.pinnedNodes(in: spaceID) }

    var body: some View {
        VStack(spacing: OrbitMetrics.sidebarRowSpacing) {
            GitHubLiveFolderRowView(spaceID: spaceID, theme: theme)

            ForEach(groupedSidebarRows(nodes, tab: env.tab, splitGroup: env.splitGroup(for:))) { item in
                switch item {
                case .single(let node):
                    SidebarNodeRow(node: node, spaceID: spaceID, theme: theme, depth: 0, onInsertion: handleInsertion)
                case .split(let group, let members):
                    // theme.readableForeground, not Color(theme.primary.nsColor), which is invisible against the sidebar's own background.
                    SidebarDropTarget(
                        payload: SidebarDragPayload(nodeID: members[0].id, kind: .pinnedNode, spaceID: spaceID),
                        rowID: members[0].id,
                        isFolder: false,
                        accentColor: theme.readableForeground,
                        onDrop: handleInsertion
                    ) {
                        SplitGroupRowView(
                            group: group,
                            tabs: members,
                            theme: theme
                        )
                    }
                }
            }
        }
        .contextMenu {
            Button("New Folder") { env.createFolder(name: "New Folder", in: spaceID) }
        }
    }

    private func handleInsertion(_ payload: SidebarDragPayload, _ insertion: DropInsertion) {
        withAnimation(OrbitMotion.interactive) {
            // A .favorite payload's nodeID is a Favorite.id, never a TabID; resolvedTab(forFavorite:in:) resolves it.
            let resolvedNodeID: UUID
            var needsPin = false
            switch payload.kind {
            case .todayTab:
                resolvedNodeID = payload.nodeID
                needsPin = true
            case .favorite:
                guard let tabID = env.resolvedTab(forFavorite: payload.nodeID, in: spaceID) else { return }
                resolvedNodeID = tabID
                needsPin = true
            case .pinnedNode:
                resolvedNodeID = payload.nodeID
                // moveNode is scoped to this spaceID's own tree; a payload.spaceID from a different Space silently no-ops unless routed through pinTab instead.
                needsPin = payload.spaceID != spaceID
            }

            let currentNodes = nodes
            let draggedLocation = needsPin ? nil : PinnedTreeLocation.locate(resolvedNodeID, in: currentNodes)

            @MainActor func apply(parent: FolderID?, atIndex index: Int) {
                if needsPin {
                    env.pinTab(resolvedNodeID, toParent: parent, atIndex: index, in: spaceID)
                } else {
                    env.moveNode(resolvedNodeID, toParent: parent, atIndex: index, in: spaceID)
                }
            }

            switch insertion {
            case .before(let targetID):
                let anchor = PinnedTreeLocation.locate(targetID, in: currentNodes) ?? (parent: nil, index: currentNodes.count)
                let index = SidebarReorderMath.insertionIndex(
                    before: anchor.index,
                    draggedIndex: draggedIndexInSameParent(draggedLocation, as: anchor)
                )
                apply(parent: anchor.parent, atIndex: index)
            case .after(let targetID):
                let anchor = PinnedTreeLocation.locate(targetID, in: currentNodes) ?? (parent: nil, index: currentNodes.count)
                let index = SidebarReorderMath.insertionIndex(
                    after: anchor.index,
                    draggedIndex: draggedIndexInSameParent(draggedLocation, as: anchor)
                )
                apply(parent: anchor.parent, atIndex: index)
            case .insideFolder(let folderID):
                apply(parent: folderID, atIndex: .max)
            case .groupingWithSibling(let targetID):
                // groupIntoNewFolder's moveNode no-ops on a node not yet in the tree, so an unpinned node must be pinned first.
                if needsPin {
                    env.pinTab(resolvedNodeID, toParent: nil, atIndex: .max, in: spaceID)
                }
                groupIntoNewFolder(dragging: resolvedNodeID, onto: targetID)
            }
        }
    }

    private func draggedIndexInSameParent(
        _ draggedLocation: (parent: FolderID?, index: Int)?,
        as anchor: (parent: FolderID?, index: Int)
    ) -> Int? {
        guard let draggedLocation, draggedLocation.parent == anchor.parent else { return nil }
        return draggedLocation.index
    }

    private func groupIntoNewFolder(dragging draggedID: UUID, onto targetID: UUID) {
        guard draggedID != targetID else { return }
        guard !PinnedNodeTree.isDescendant(targetID, ofOrEqualTo: draggedID, in: nodes) else { return }
        guard let location = PinnedTreeLocation.locate(targetID, in: nodes) else { return }

        env.groupIntoNewFolder(
            name: "New Folder",
            firstID: targetID,
            secondID: draggedID,
            parent: location.parent,
            atIndex: location.index,
            in: spaceID
        )
    }
}

struct PinnedSectionEmptyDropZone: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var theme: SpaceTheme

    @State private var isDropTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
            .fill(isDropTargeted ? theme.readableForeground.opacity(0.18) : .clear)
            // Padding applied before .frame(height:), not after, or this view's reported height grows past sidebarRowHeight and misaligns the offset(y:) callers position it with.
            .padding(.vertical, OrbitMetrics.sidebarRowPillVerticalInset)
            .frame(height: OrbitMetrics.sidebarRowHeight)
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .contentShape(Rectangle())
            // sidebarPayloadDropDestination, not dropDestination(for:), which forces AppKit's green + badge onto the drag image.
            .sidebarPayloadDropDestination { items, _ in
                guard let item = items.first else { return false }
                switch item.kind {
                case .todayTab:
                    env.pinTab(item.nodeID)
                case .favorite:
                    guard let tabID = env.resolvedTab(forFavorite: item.nodeID, in: spaceID) else { return false }
                    env.pinTab(tabID)
                case .pinnedNode:
                    break
                }
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .contextMenu {
                Button("New Folder") { env.createFolder(name: "New Folder", in: spaceID) }
            }
    }
}

struct PinnedSectionCollapsedDropZone: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var theme: SpaceTheme

    @State private var isDropTargeted = false
    @State private var expandTask: Task<Void, Never>?

    var body: some View {
        RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
            .fill(isDropTargeted ? theme.readableForeground.opacity(0.18) : .clear)
            .padding(.vertical, OrbitMetrics.sidebarRowPillVerticalInset)
            .frame(height: OrbitMetrics.sidebarRowHeight)
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .contentShape(Rectangle())
            .sidebarPayloadDropDestination { items, _ in
                expandTask?.cancel()
                guard let item = items.first else { return false }
                switch item.kind {
                case .todayTab:
                    env.pinTab(item.nodeID)
                case .favorite:
                    guard let tabID = env.resolvedTab(forFavorite: item.nodeID, in: spaceID) else { return false }
                    env.pinTab(tabID)
                case .pinnedNode:
                    env.moveNode(item.nodeID, toParent: nil, atIndex: .max, in: spaceID)
                }
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
                handleHoverExpand(targeted)
            }
    }

    private func handleHoverExpand(_ targeted: Bool) {
        expandTask?.cancel()
        guard targeted else { return }
        expandTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(OrbitMetrics.folderPreviewHoverDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            env.store.mutateSpace(spaceID) { $0.isPinnedSectionCollapsed = false }
        }
    }
}
