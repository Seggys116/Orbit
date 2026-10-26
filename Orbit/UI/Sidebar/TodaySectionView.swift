import SwiftUI

@MainActor
enum SidebarNewTabRowAction {
    static func perform(in env: AppEnvironment) {
        env.openNewTabPage()
    }
}

struct TodaySectionView: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var theme: SpaceTheme

    // Every Today tab, listed or not: drop math indexes the store's own list.
    private var tabs: [Tab] { env.todayTabs(in: spaceID) }

    private var listedTabs: [Tab] { NewTabPageModel.listed(tabs) }

    private var isNewTabPageActive: Bool { env.isNewTabPageActive(in: spaceID) }

    private var tidyPhase: TidyTabsCoordinator.Phase {
        TidyTabsCoordinator.shared.phase(for: spaceID)
    }

    var body: some View {
        VStack(spacing: OrbitMetrics.sidebarRowSpacing) {
            if case .failed(let message) = tidyPhase {
                tidyErrorRow(message)
            }

            newTabRow

            VStack(spacing: OrbitMetrics.sidebarRowSpacing) {
                ForEach(tidyGroupedTodayItems(listedTabs, splitGroup: env.splitGroup(for:))) { item in
                    switch item {
                    case .header(let name):
                        TidyGroupHeaderRow(
                            name: name,
                            theme: theme,
                            onRemoveHeader: { env.removeTidyGroup(named: name, in: spaceID) },
                            onConvertToFolder: { env.convertTidyGroupToFolder(named: name, in: spaceID) },
                            onCloseGroup: { env.closeTidyGroup(named: name, in: spaceID) }
                        )
                    case .rows(.single(let tab)):
                        SidebarDropTarget(
                            payload: SidebarDragPayload(nodeID: tab.id, kind: .todayTab, spaceID: spaceID),
                            rowID: tab.id,
                            isFolder: false,
                            accentColor: theme.readableForeground,
                            bodyDropIntent: splitIntent,
                            dragLabel: tab.displayTitle,
                            onDrop: handleInsertion
                        ) {
                            TabRowView(tab: tab, theme: theme)
                        }
                    case .rows(.split(let group, let members)):
                        SidebarDropTarget(
                            payload: SidebarDragPayload(nodeID: members[0].id, kind: .todayTab, spaceID: spaceID),
                            rowID: members[0].id,
                            isFolder: false,
                            accentColor: theme.readableForeground,
                            bodyDropIntent: splitIntent(extending: group),
                            rejectDropIDs: Set(members.map(\.id)),
                            ownsDragSource: false,
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
        }
        .orbitRightClickMenu {
            [.item(OrbitContextMenuItem(title: "Clear All Today Tabs", systemImage: "trash") {
                env.clearTodayTabs(in: spaceID)
            })]
        }
        .onAppear { env.sweepAbandonedNewTabPages(in: spaceID) }
    }

    private func tidyErrorRow(_ message: String) -> some View {
        OrbitNSActionButton {
            TidyTabsCoordinator.shared.dismissError()
        } label: {
            HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                    .frame(width: OrbitMetrics.faviconSize, height: OrbitMetrics.faviconSize)
                Text(message)
                    .font(OrbitFont.sidebarSectionHeader)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
            .padding(.bottom, OrbitMetrics.sidebarInterSectionGap)
            .contentShape(Rectangle())
        }
        .foregroundStyle(theme.readableForeground.opacity(OrbitMetrics.sidebarRowLabelOpacityInactive))
        .orbitTooltip("Tidy Tabs could not run. Click to dismiss.")
    }

    private var newTabRow: some View {
        OrbitNSActionButton {
            SidebarNewTabRowAction.perform(in: env)
        } label: {
            HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
                Image(systemName: "plus")
                    .font(.system(size: OrbitMetrics.sidebarRowFontSize, weight: .medium))
                    .frame(width: OrbitMetrics.faviconSize, height: OrbitMetrics.faviconSize)
                Text("New Tab")
                    .font(OrbitFont.sidebarNewTabRow)
                Spacer(minLength: 0)
            }
            .padding(.leading, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
            .padding(.trailing, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
            .frame(height: OrbitMetrics.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                    .fill(isNewTabPageActive ? theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity) : .clear)
                    .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
                    .padding(.vertical, OrbitMetrics.sidebarRowPillVerticalInset)
            )
            .contentShape(Rectangle())
        }
        .foregroundStyle(theme.readableForeground.opacity(
            isNewTabPageActive ? OrbitMetrics.sidebarRowLabelOpacityActive : OrbitMetrics.sidebarNewTabRowOpacity
        ))
        .orbitTooltip("New Tab")
    }

    private var splitIntent: SidebarRowBodyDropIntent {
        .createSplit(env.preferredSplitOrientation())
    }

    private func splitIntent(extending group: SplitGroup) -> SidebarRowBodyDropIntent {
        guard group.tabIDs.count < SplitGroup.maximumPanes else { return .reorderOnly }
        return .createSplit(group.axis)
    }

    // OrbitMotion.quick, not .interactive: interactiveSpring is tuned for tracking a pointer that is still moving, and a drop is a settle. It left rows lagging behind the release.
    private func handleInsertion(_ payload: SidebarDragPayload, _ insertion: DropInsertion) {
        withAnimation(OrbitMotion.quick) {
            // A .favorite payload's nodeID is a Favorite.id, never a TabID; resolvedTab(forFavorite:in:) resolves it.
            let resolvedNodeID: TabID
            var needsUnpin = false
            switch payload.kind {
            case .pinnedNode:
                resolvedNodeID = payload.nodeID
                needsUnpin = true
            case .favorite:
                guard let tabID = env.resolvedTab(forFavorite: payload.nodeID, in: spaceID) else { return }
                resolvedNodeID = tabID
                needsUnpin = env.tab(tabID)?.section == .pinned
            case .todayTab:
                resolvedNodeID = payload.nodeID
            }

            let ids = tabs.map(\.id)
            let draggedIndex = needsUnpin ? nil : ids.firstIndex(of: resolvedNodeID)

            @MainActor func apply(toIndex index: Int) {
                if needsUnpin {
                    env.unpinTab(resolvedNodeID, toIndex: index, in: spaceID)
                } else {
                    env.moveTodayTab(resolvedNodeID, toIndex: index, in: spaceID)
                }
            }

            switch insertion {
            case .before(let targetID):
                guard let anchorIndex = ids.firstIndex(of: targetID) else { return }
                let index = SidebarReorderMath.insertionIndex(before: anchorIndex, draggedIndex: draggedIndex)
                apply(toIndex: index)
            // Today has no folders, so .insideFolder falls back to the same "insert after" as the row's own bottom strip.
            case .after(let targetID), .insideFolder(let targetID):
                guard let anchorIndex = ids.firstIndex(of: targetID) else { return }
                let index = SidebarReorderMath.insertionIndex(after: anchorIndex, draggedIndex: draggedIndex)
                apply(toIndex: index)
            case .groupingWithSibling(let targetID, let droppedEdge):
                guard let anchorIndex = ids.firstIndex(of: targetID) else { return }
                if env.splitGroup(for: targetID)?.tabIDs.contains(resolvedNodeID) == true { return }
                // Position first, split second: groupedSidebarRows only collapses adjacent same-group tabs into one joined row, so panes left apart in the list would render as two ordinary rows sharing a pane.
                let index = SidebarReorderMath.insertionIndex(after: anchorIndex, draggedIndex: draggedIndex)
                apply(toIndex: index)

                let edge: SplitEdge
                if let droppedEdge {
                    edge = droppedEdge
                } else if let existing = env.splitGroup(for: targetID) {
                    edge = existing.axis == .vertical ? .bottom : .right
                } else {
                    edge = env.preferredSplitEdge()
                }
                env.createSplit(existingTabID: targetID, newTabID: resolvedNodeID, edge: edge)
            }
        }
    }
}
