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
            VStack(alignment: .leading, spacing: LibraryMetrics.dateGroupSpacing) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        LibraryDateSectionHeader(title: group.title)
                        VStack(spacing: LibraryMetrics.rowSpacing) {
                            ForEach(group.items) { tab in
                                ArchivedTabRow(tab: tab)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ArchivedTabRow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var router = LibraryRouter.shared
    var tab: Tab

    private var spaceName: String? {
        env.spaces.first(where: { $0.id == tab.spaceID })?.name
    }

    private var isSelected: Bool {
        router.selection == .archivedTab(tab.id)
    }

    var body: some View {
        LibraryRowCard(isSelected: isSelected) {
            HStack(spacing: 10) {
                FaviconView(url: tab.faviconURL, host: tab.url.host() ?? "")
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.displayTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LibraryPalette.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(tab.url.host() ?? tab.url.absoluteString)
                        if let spaceName {
                            Text("·")
                            Text(spaceName)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryPalette.textSecondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                LibraryActionButton(symbol: "arrow.uturn.backward", help: "Restore to Today") {
                    env.restoreFromArchive(tab.id, section: .today)
                }
            }
        }
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
