import SwiftUI

struct LibraryEaselsNotesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var router = LibraryRouter.shared
    var searchQuery: String

    private var notes: [NoteIndexEntry] {
        filter(env.noteStore.index) { $0.title }
    }

    private var easels: [EaselIndexEntry] {
        filter(env.easelStore.index) { $0.title }
    }

    private func filter<Item>(_ items: [Item], title: (Item) -> String) -> [Item] {
        guard !searchQuery.isEmpty else { return items }
        let query = searchQuery.lowercased()
        return items.filter { title($0).lowercased().contains(query) }
    }

    var body: some View {
        if !notes.isEmpty || !easels.isEmpty {
            // Only worth spreading into columns once the list isn't squeezed down to make room
            // for the preview pane (see LibraryRootView.showsPreview).
            let isWide = router.selection == nil
            VStack(spacing: LibraryMetrics.rowSpacing) {
                ForEach(notes) { note in
                    EntryRow(
                        symbol: "note.text",
                        title: note.title,
                        updatedAt: note.updatedAt,
                        isSelected: router.selection == .note(note.id),
                        isWide: isWide,
                        select: { router.select(.note(note.id)) },
                        open: { open(url: URL(string: "orbit://note/\(note.id.uuidString)")) }
                    )
                }
                ForEach(easels) { easel in
                    EntryRow(
                        symbol: "scribble.variable",
                        title: easel.title,
                        subtitle: "\(easel.itemCount) item\(easel.itemCount == 1 ? "" : "s")",
                        updatedAt: easel.updatedAt,
                        isSelected: router.selection == .easel(easel.id),
                        isWide: isWide,
                        select: { router.select(.easel(easel.id)) },
                        open: { open(url: URL(string: "orbit://easel/\(easel.id.uuidString)")) },
                        exportAsImage: { EaselExporter.presentExportPanel(for: easel.id, store: env.easelStore) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func open(url: URL?) {
        guard let spaceID = env.activeSpace?.id, let url else { return }
        env.openTab(url: url, in: spaceID, section: .pinned)
    }
}

private struct EntryRow: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var updatedAt: Date
    var isSelected: Bool
    var isWide: Bool
    var select: () -> Void
    var open: () -> Void
    var exportAsImage: (() -> Void)?

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: open)
            .onTapGesture(perform: select)
            .contextMenu {
                Button("Open") { open() }
                if let exportAsImage {
                    Button("Export as Image…") { exportAsImage() }
                }
            }
    }

    private var content: some View {
        LibraryRowCard(isSelected: isSelected) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(LibraryPalette.accent)
                    .frame(width: LibraryMetrics.rowIconSize, height: LibraryMetrics.rowIconSize)

                if isWide {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LibraryPalette.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LibraryColumnText(text: subtitle ?? "", width: LibraryMetrics.rowSecondaryColumnWidth)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LibraryPalette.textPrimary)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(LibraryPalette.textSecondary)
                        }
                    }

                    Spacer(minLength: 8)
                }

                Text(updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryPalette.textTertiary)
                    .lineLimit(1)
                    .frame(width: isWide ? LibraryMetrics.rowDateColumnWidth + 30 : nil, alignment: .trailing)
            }
        }
    }
}
