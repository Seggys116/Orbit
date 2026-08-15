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
            // Lazy, not VStack: with a few thousand archived tabs a plain VStack built and laid
            // out every row up front, on open, before any of it was scrolled into view.
            LazyVStack(alignment: .leading, spacing: LibraryMetrics.dateGroupSpacing) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        LibraryDateSectionHeader(title: group.title)
                        LazyVStack(spacing: LibraryMetrics.rowSpacing) {
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

// MARK: - Row rendering
// ArchivedTabNode/ArchivedFolderNode/ArchivedTabTreeBuilder live in PinnedNodeTree.swift, next to
// the ArchivedFolderCrumb trail they rebuild from — model-layer, not view-layer, and they need to
// be reachable from OrbitTests, whose target membership does not include this view file.

private enum ArchivedRowMetrics {
    // Same per-depth indent the sidebar uses for pinned folder nesting, so a tab's Archive row
    // lines up visually the way it would have in the sidebar.
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

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: LibraryMetrics.rowSpacing) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    folderGlyph
                    Text(folder.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LibraryPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LibraryPalette.textTertiary)
                        .frame(width: 10, height: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LibraryMetrics.rowHorizontalPadding)
                .padding(.vertical, LibraryMetrics.rowVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: LibraryMetrics.rowCornerRadius)
                        .fill(LibraryPalette.cardFill)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(depth) * ArchivedRowMetrics.indentPerDepth)

            if isExpanded {
                VStack(spacing: LibraryMetrics.rowSpacing) {
                    ForEach(folder.children) { child in
                        ArchivedTreeNodeRow(node: child, depth: depth + 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var folderGlyph: some View {
        if let icon = folder.icon, !icon.isEmpty, folder.iconIsEmoji || OrbitSymbolName.isResolvable(icon) {
            if folder.iconIsEmoji {
                Text(icon).font(.system(size: 13))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LibraryPalette.textSecondary)
                    .frame(width: OrbitMetrics.sidebarFolderToggleSize, height: OrbitMetrics.sidebarFolderToggleSize)
            }
        } else {
            FolderToggleGlyph(isOpen: isExpanded)
                .foregroundStyle(LibraryPalette.textSecondary)
        }
    }
}

private struct ArchivedTabRow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var router = LibraryRouter.shared
    var tab: Tab
    var depth: Int = 0

    private var spaceName: String? {
        env.spaces.first(where: { $0.id == tab.spaceID })?.name
    }

    private var isSelected: Bool {
        router.selection == .archivedTab(tab.id)
    }

    // Only worth spreading into columns once the list isn't squeezed down to make room for the
    // preview pane (see LibraryRootView.showsPreview).
    private var isWide: Bool { router.selection == nil }

    private var hostText: String { tab.url.host() ?? tab.url.absoluteString }

    private var archivedTimeText: String {
        (tab.archivedAt ?? tab.lastAccessedAt).formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        LibraryRowCard(isSelected: isSelected) {
            HStack(spacing: 10) {
                FaviconView(url: tab.faviconURL, host: tab.url.host() ?? "")
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if isWide {
                    Text(tab.displayTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LibraryPalette.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LibraryColumnText(text: hostText, width: LibraryMetrics.rowMetaColumnWidth)
                    LibraryColumnText(text: spaceName ?? "", width: LibraryMetrics.rowSecondaryColumnWidth)
                    LibraryColumnText(text: archivedTimeText, width: LibraryMetrics.rowDateColumnWidth, alignment: .trailing, color: LibraryPalette.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tab.displayTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LibraryPalette.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(hostText)
                            if let spaceName {
                                Text("·")
                                Text(spaceName)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryPalette.textSecondary)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                LibraryActionButton(symbol: "arrow.uturn.backward", help: "Restore to Today") {
                    env.restoreFromArchive(tab.id, section: .today)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * ArchivedRowMetrics.indentPerDepth)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Restore to Today") { env.restoreFromArchive(tab.id, section: .today) }
            Button("Restore to Pinned") { env.restoreFromArchive(tab.id, section: .pinned) }
        }
        // Order matters: double-tap must be declared before single-tap.
        .onTapGesture(count: 2) {
            env.restoreFromArchive(tab.id, section: .today)
            env.activateTab(tab.id)
        }
        .onTapGesture { router.select(.archivedTab(tab.id)) }
    }
}
