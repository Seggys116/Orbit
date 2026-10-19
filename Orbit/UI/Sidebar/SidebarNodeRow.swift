import SwiftUI

struct SidebarNodeRow: View {
    @Environment(AppEnvironment.self) private var env
    var node: SidebarNode
    var spaceID: SpaceID
    var theme: SpaceTheme
    var depth: Int
    var onInsertion: (SidebarDragPayload, DropInsertion) -> Void

    private static let childTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: -6)),
        removal: .opacity
    )

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
                        .equatable()
                }

                // The children fade and settle a few points down into place while the rows below them move out of the way, driven by the withAnimation in toggleFolderExpanded. Without a transition the rows simply appear and disappear.
                if folder.isExpanded {
                    ForEach(folder.children) { child in
                        SidebarNodeRow(node: child, spaceID: spaceID, theme: theme, depth: depth + 1, onInsertion: onInsertion)
                            .transition(Self.childTransition)
                    }
                } else if let peeked = PinnedNodeTree.peekedTabID(inCollapsedFolder: folder, activeTabID: env.activeTabID),
                          let tab = env.tab(peeked) {
                    TabRowView(tab: tab, depth: depth + 1, theme: theme)
                        .transition(Self.childTransition)
                }
            }
        }
    }
}
