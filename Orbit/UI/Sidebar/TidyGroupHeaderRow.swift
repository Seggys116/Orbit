import SwiftUI

enum TodayListItem: Identifiable {
    case header(String)
    case rows(SidebarSplitRowGroup<Tab>)

    var id: String {
        switch self {
        case .header(let name): return "tidy-header-\(name)"
        case .rows(let group): return "rows-\(group.id)"
        }
    }
}

// Driven off adjacency, not off a lookup of every tab with this name: a group split in two by a later drag draws two headers with the same name rather than silently reordering the list.
func tidyGroupedTodayItems(_ tabs: [Tab], splitGroup: (TabID) -> SplitGroup?) -> [TodayListItem] {
    var items: [TodayListItem] = []
    var currentGroup: String?

    for rowGroup in groupedSidebarRows(tabs, splitGroup: splitGroup) {
        let leadingTab: Tab
        switch rowGroup {
        case .single(let tab): leadingTab = tab
        case .split(_, let members): leadingTab = members[0]
        }

        let group = leadingTab.tidyGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (group?.isEmpty ?? true) ? nil : group
        if resolved != currentGroup {
            if let resolved { items.append(.header(resolved)) }
            currentGroup = resolved
        }
        items.append(.rows(rowGroup))
    }
    return items
}

struct TidyGroupHeaderRow: View {
    var name: String
    var theme: SpaceTheme
    var onRemoveHeader: () -> Void
    var onConvertToFolder: () -> Void
    var onCloseGroup: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
                .font(OrbitFont.sidebarSectionHeader)
                .foregroundStyle(theme.readableForeground.opacity(OrbitMetrics.sidebarNewTabRowOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
        .padding(.top, OrbitMetrics.sidebarInterSectionGap)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove Header", action: onRemoveHeader)
            Button("Convert to Folder", action: onConvertToFolder)
            Divider()
            Button("Close Tabs in Group", action: onCloseGroup)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tab group \(name)")
    }
}
