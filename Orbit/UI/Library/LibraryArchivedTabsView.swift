import SwiftUI

struct LibraryArchivedTabsView: View {
    @Environment(AppEnvironment.self) private var env
    var searchQuery: String

    private var filtered: [Tab] {
        let all = env.archivedTabs()
        guard !searchQuery.isEmpty else { return all }
        let query = searchQuery.lowercased()
        return all.filter { tab in
            tab.displayTitle.lowercased().contains(query)
                || (tab.url.host()?.lowercased().contains(query) ?? false)
        }
    }

    private var groups: [LibraryDateGroup<Tab>] {
        LibraryDateGrouping.group(filtered, date: { $0.archivedAt ?? $0.lastAccessedAt })
    }

    var body: some View {
        if !groups.isEmpty {
            // Lazy, not VStack: with a few thousand archived tabs a plain VStack laid out every row up front on open.
            LazyVStack(alignment: .leading, spacing: LibraryModeMetrics.groupSpacing) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: OrbitSpacing.xs) {
                        LibraryDateSectionHeader(title: group.title)
                        LazyVStack(spacing: LibraryModeMetrics.rowSpacing) {
                            ForEach(ArchivedTabTreeBuilder.build(from: group.items)) { node in
                                ArchivedTreeNodeRow(node: node, depth: 0)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// ArchivedTabNode/ArchivedFolderNode/ArchivedTabTreeBuilder live in PinnedNodeTree.swift so OrbitTests can reach them; its target does not include this view file.

private enum ArchivedRowMetrics {
    // Same per-depth indent the sidebar uses for pinned folder nesting, so an Archive row lines up as it did in the sidebar.
    static let indentPerDepth = OrbitMetrics.sidebarIndentPerDepth
}

private struct ArchivedTreeNodeRow: View {
    var node: ArchivedTabNode
    var depth: Int

    var body: some View {
        switch node {
        case .tab(let tab):
            ArchivedTabRow(tab: tab, depth: depth)
        case .folder(let folder):
            ArchivedFolderRow(folder: folder, depth: depth)
        }
    }
}

private struct ArchivedFolderRow: View {
    var folder: ArchivedFolderNode
    var depth: Int

    @Environment(\.libraryStyle) private var style
    @State private var isExpanded = true
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: LibraryModeMetrics.rowSpacing) {
            Button {
                withOrbitAnimation(OrbitMotion.quick) { isExpanded.toggle() }
            } label: {
                HStack(spacing: OrbitSpacing.md) {
                    folderGlyph
                    Text(folder.name)
                        .font(OrbitFont.sidebarRowActive)
                        .foregroundStyle(style.foreground)
                        .lineLimit(1)
                    Spacer(minLength: OrbitSpacing.md)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(style.secondary)
                        .frame(width: 10, height: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LibraryModeMetrics.rowHorizontalPadding)
                .padding(.vertical, LibraryModeMetrics.rowVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous)
                        .fill(isHovering ? style.hoverFill : style.quietFill)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .orbitAnimation(OrbitMotion.quick, value: isHovering)
            .accessibilityLabel(folder.name)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .padding(.leading, CGFloat(depth) * ArchivedRowMetrics.indentPerDepth)

            if isExpanded {
                VStack(spacing: LibraryModeMetrics.rowSpacing) {
                    ForEach(folder.children) { child in
                        ArchivedTreeNodeRow(node: child, depth: depth + 1)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var folderGlyph: some View {
        if let icon = folder.icon, !icon.isEmpty, folder.iconIsEmoji || OrbitSymbolName.isResolvable(icon) {
            if folder.iconIsEmoji {
                Text(icon).font(.system(size: OrbitMetrics.sidebarRowFontSize))
            } else {
                Image(systemName: icon)
                    .font(.system(size: OrbitMetrics.sidebarRowFontSize - 1, weight: .medium))
                    .foregroundStyle(style.secondary)
                    .frame(width: OrbitMetrics.sidebarFolderToggleSize, height: OrbitMetrics.sidebarFolderToggleSize)
            }
        } else {
            FolderToggleGlyph(isOpen: isExpanded)
                .foregroundStyle(style.secondary)
        }
    }
}

private struct ArchivedTabRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.libraryStyle) private var style
    var tab: Tab
    var depth: Int = 0

    private var router: LibraryRouter { env.libraryRouter }

    private var spaceName: String? {
        env.spaces.first(where: { $0.id == tab.spaceID })?.name
    }

    private var isSelected: Bool {
        router.selection == .archivedTab(tab.id)
    }

    private var hostText: String { tab.url.host() ?? tab.url.absoluteString }

    private var subtitle: String {
        guard let spaceName else { return hostText }
        return "\(hostText) · \(spaceName)"
    }

    private var actions: [LibraryRowAction] {
        [LibraryRowAction(title: "Restore to Today", symbol: "arrow.uturn.backward") {
            env.restoreFromArchive(tab.id, section: .today)
        }]
    }

    var body: some View {
        LibraryRowCard(
            isSelected: isSelected,
            actions: actions,
            menu: {
                [
                    .item(OrbitContextMenuItem(title: "Restore to Today") { env.restoreFromArchive(tab.id, section: .today) }),
                    .item(OrbitContextMenuItem(title: "Restore to Pinned") { env.restoreFromArchive(tab.id, section: .pinned) }),
                ]
            }
        ) {
            FaviconView(url: tab.faviconURL, host: tab.url.host() ?? "")
                .frame(width: OrbitMetrics.faviconSize, height: OrbitMetrics.faviconSize)
                .clipShape(RoundedRectangle(cornerRadius: OrbitRadius.xs))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OrbitSpacing.xxs) {
                Text(tab.displayTitle)
                    .font(OrbitFont.sidebarRowActive)
                    .foregroundStyle(style.foreground)
                    .lineLimit(1)
                Text(subtitle)
                    .font(OrbitFont.commandBarRowSubtitle)
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * ArchivedRowMetrics.indentPerDepth)
        .contentShape(Rectangle())
        // Order matters: double-tap must be declared before single-tap.
        .onTapGesture(count: 2) {
            env.restoreFromArchive(tab.id, section: .today)
            env.activateTab(tab.id)
        }
        .onTapGesture {
            withOrbitAnimation(OrbitMotion.standard) { router.select(.archivedTab(tab.id)) }
        }
    }
}
