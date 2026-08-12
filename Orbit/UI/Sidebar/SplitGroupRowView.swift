// Grouping only happens among siblings at the same level, not into folder children (SidebarNodeRow's own recursion), so a split pair split across a folder or the Pinned/Today divide renders as two ordinary rows.

import SwiftUI

// MARK: - Grouping

enum SidebarSplitRowGroup<Element>: Identifiable {
    case single(Element)
    case split(SplitGroup, [Tab])

    var id: String {
        switch self {
        case .single(let element):
            if let tab = element as? Tab { return "single-tab-\(tab.id)" }
            if let node = element as? SidebarNode { return "single-node-\(node.id)" }
            return "single-\(String(describing: element))"
        case .split(let group, _):
            return "split-\(group.id)"
        }
    }
}

func groupedSidebarRows(_ tabs: [Tab], splitGroup: (TabID) -> SplitGroup?) -> [SidebarSplitRowGroup<Tab>] {
    var result: [SidebarSplitRowGroup<Tab>] = []
    var index = 0
    while index < tabs.count {
        let tab = tabs[index]
        if let group = splitGroup(tab.id), group.tabIDs.count > 1 {
            var members = [tab]
            var lookahead = index + 1
            while lookahead < tabs.count, splitGroup(tabs[lookahead].id)?.id == group.id {
                members.append(tabs[lookahead])
                lookahead += 1
            }
            if members.count > 1 {
                result.append(.split(group, members))
                index = lookahead
                continue
            }
        }
        result.append(.single(tab))
        index += 1
    }
    return result
}

func groupedSidebarRows(
    _ nodes: [SidebarNode],
    tab tabLookup: (TabID) -> Tab?,
    splitGroup: (TabID) -> SplitGroup?
) -> [SidebarSplitRowGroup<SidebarNode>] {
    var result: [SidebarSplitRowGroup<SidebarNode>] = []
    var index = 0
    while index < nodes.count {
        let node = nodes[index]
        if case .tab(let tabID) = node, let currentTab = tabLookup(tabID),
           let group = splitGroup(tabID), group.tabIDs.count > 1 {
            var members = [currentTab]
            var lookahead = index + 1
            while lookahead < nodes.count,
                  case .tab(let nextTabID) = nodes[lookahead],
                  splitGroup(nextTabID)?.id == group.id,
                  let nextTab = tabLookup(nextTabID) {
                members.append(nextTab)
                lookahead += 1
            }
            if members.count > 1 {
                result.append(.split(group, members))
                index = lookahead
                continue
            }
        }
        result.append(.single(node))
        index += 1
    }
    return result
}

// MARK: - Joined row

struct SplitGroupRowView: View {
    @Environment(AppEnvironment.self) private var env
    var group: SplitGroup
    var tabs: [Tab]
    var depth: Int = 0
    var theme: SpaceTheme

    @State private var hoveredPaneID: TabID?

    private var isGroupActive: Bool { tabs.contains { $0.id == env.activeTabID } }

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarSplitGroupInnerInset) {
            ForEach(tabs) { tab in
                paneSegment(tab)
            }
        }
        .padding(.horizontal, OrbitMetrics.sidebarSplitGroupInnerInset)
        .padding(.vertical, OrbitMetrics.sidebarRowPillVerticalInset + OrbitMetrics.sidebarSplitGroupInnerInset)
        .padding(.leading, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset + CGFloat(depth) * OrbitMetrics.sidebarIndentPerDepth)
        .padding(.trailing, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
        .frame(height: OrbitMetrics.sidebarRowHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                .fill(
                    theme.readableForeground.opacity(
                        isGroupActive
                            ? OrbitMetrics.sidebarActiveRowOpacity
                            : OrbitMetrics.sidebarSplitGroupContainerOpacity
                    )
                )
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
                .padding(.vertical, OrbitMetrics.sidebarRowPillVerticalInset)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            // The pointer can exit through a pill's own edge fast enough that the pill's own onHover(false) never fires, stranding an x visible over an unhovered row.
            if !hovering { hoveredPaneID = nil }
        }
        .contextMenu {
            Button("Separate All Tabs") { env.separateAllTabs(group.id) }
            Divider()
            ForEach(tabs) { tab in
                Button("Close \(tab.displayTitle)") { env.closeTab(tab.id) }
            }
            Button("Close Split", role: .destructive) {
                for tab in tabs { env.closeTab(tab.id) }
            }
        }
    }

    private func paneSegment(_ tab: Tab) -> some View {
        let isActive = tab.id == env.activeTabID
        let isPaneHovered = hoveredPaneID == tab.id
        return HStack(spacing: OrbitMetrics.sidebarSplitGroupContentSpacing) {
            FaviconView(url: tab.faviconURL, host: tab.url.host() ?? tab.url.absoluteString)
                .frame(width: OrbitMetrics.faviconSize, height: OrbitMetrics.faviconSize)
                .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius))
            Text(tab.displayTitle)
                .font(isActive ? OrbitFont.sidebarRowActive : OrbitFont.sidebarRow)
                .foregroundStyle(
                    theme.readableForeground.opacity(
                        isActive ? OrbitMetrics.sidebarRowLabelOpacityActive : OrbitMetrics.sidebarRowLabelOpacityInactive
                    )
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(
                            colors: [.black, isPaneHovered ? .clear : .black],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: OrbitMetrics.sidebarCloseButtonSize)
                    }
                )
        }
        .padding(.horizontal, OrbitMetrics.sidebarSplitGroupInnerInset)
        // An overlay, not a reserved-width close control or one inserted only on hover: either of those reflows the pane on hover, which can land the very click that arrives on a button that just moved.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
        // After both .frames, deliberately: an overlay attached before them would anchor to the title's intrinsic width rather than the pane's own trailing edge.
        .overlay(alignment: .trailing) {
            paneCloseControl(tab)
                .opacity(isPaneHovered ? 1 : 0)
                .padding(.trailing, OrbitMetrics.sidebarSplitGroupInnerInset)
        }
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.sidebarSplitGroupPaneCornerRadius)
                .fill(
                    theme.readableForeground.opacity(
                        isActive
                            ? OrbitMetrics.sidebarActiveRowOpacity
                            : (isPaneHovered ? OrbitMetrics.sidebarSplitGroupPaneHoverOpacity : OrbitMetrics.sidebarSplitGroupPaneOpacity)
                    )
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredPaneID = tab.id
            } else if hoveredPaneID == tab.id {
                hoveredPaneID = nil
            }
        }
        .onTapGesture { env.activateTab(tab.id) }
    }

    private func paneCloseControl(_ tab: Tab) -> some View {
        OrbitNSActionButton(action: { env.closeTab(tab.id) }) {
            Image(systemName: "xmark")
                .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .bold))
                .frame(width: OrbitMetrics.sidebarCloseButtonSize, height: OrbitMetrics.sidebarCloseButtonSize)
        }
        .foregroundStyle(theme.readableSecondaryForeground)
        .orbitTooltip("Close \(tab.displayTitle)")
    }
}
