import SwiftUI

struct SidebarNodeRow: View {
    @Environment(AppEnvironment.self) private var env
    var node: SidebarNode
    var spaceID: SpaceID
    var theme: SpaceTheme
    var depth: Int
    var onInsertion: (SidebarDragPayload, DropInsertion) -> Void

    var body: some View {
        switch node {
        case .tab(let tabID):
            if let tab = env.tab(tabID) {
                SidebarDropTarget(
                    payload: SidebarDragPayload(nodeID: tabID, kind: .pinnedNode, spaceID: spaceID),
                    rowID: tabID,
                    isFolder: false,
                    accentColor: theme.readableForeground,
                    onDrop: onInsertion
                ) {
                    TabRowView(tab: tab, depth: depth, theme: theme)
                }
            }
        case .folder(let folder):
            VStack(spacing: OrbitMetrics.sidebarRowSpacing) {
                SidebarDropTarget(
                    payload: SidebarDragPayload(nodeID: folder.id, kind: .pinnedNode, spaceID: spaceID),
                    rowID: folder.id,
                    isFolder: true,
                    accentColor: theme.readableForeground,
                    onDrop: onInsertion
                ) {
                    PinnedFolderRowView(folder: folder, spaceID: spaceID, theme: theme, depth: depth)
                }

                if folder.isExpanded {
                    ForEach(folder.children) { child in
                        SidebarNodeRow(node: child, spaceID: spaceID, theme: theme, depth: depth + 1, onInsertion: onInsertion)
                    }
                } else if let peeked = PinnedNodeTree.peekedTabID(inCollapsedFolder: folder, activeTabID: env.activeTabID),
                          let tab = env.tab(peeked) {
                    TabRowView(tab: tab, depth: depth + 1, theme: theme)
                }
            }
        }
    }
}
