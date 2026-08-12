import SwiftUI

struct FolderHoverPreviewView: View {
    var state: FolderPreviewState
    var onSelect: (TabID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.title)
                .font(OrbitFont.spaceTitle)
                .lineLimit(1)
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
                .padding(.vertical, OrbitMetrics.sidebarRowContentSpacing / 2)

            Divider()

            ScrollView {
                FolderHoverPreviewList(items: state.allPossibleChildren, onSelect: onSelect)
            }
            .frame(maxHeight: OrbitMetrics.folderPreviewMaxHeight)
        }
        .frame(width: OrbitMetrics.folderPreviewWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.popoverCornerRadius))
    }
}

struct FolderHoverPreviewList: View {
    var items: [FolderPreviewItem]
    var onSelect: (TabID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                FolderHoverPreviewRow(item: item, onSelect: onSelect)
            }
        }
    }
}

struct FolderHoverPreviewRow: View {
    @Environment(AppEnvironment.self) private var env
    var item: FolderPreviewItem
    var onSelect: (TabID) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            FaviconView(url: item.faviconURL, host: item.url.host ?? "")
                .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(OrbitFont.commandBarRowTitle)
                    .lineLimit(1)
                Text(Self.relativeVisitDescription(for: item.lastVisitedAt))
                    .font(OrbitFont.commandBarRowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        .frame(height: OrbitMetrics.commandBarRowHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                .fill(isHovering ? Color.primary.opacity(OrbitMetrics.sidebarHoverRowOpacity) : .clear)
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding / 2)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect(item.tabID) }
        .contextMenu {
            if let tab = env.tab(item.tabID) {
                TabContextMenu(tab: tab)
            }
        }
    }

    static func relativeVisitDescription(for date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
