import SwiftUI

struct LibraryEaselsNotesView: View {
    @Environment(AppEnvironment.self) private var env
    var searchQuery: String

    private var router: LibraryRouter { env.libraryRouter }

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
            LazyVStack(spacing: LibraryModeMetrics.rowSpacing) {
                ForEach(notes) { note in
                    EntryRow(
                        symbol: "note.text",
                        title: note.title,
                        updatedAt: note.updatedAt,
                        isSelected: router.selection == .note(note.id),
                        select: { withOrbitAnimation(OrbitMotion.standard) { router.select(.note(note.id)) } },
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
                        select: { withOrbitAnimation(OrbitMotion.standard) { router.select(.easel(easel.id)) } },
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
    var select: () -> Void
    var open: () -> Void
    var exportAsImage: (() -> Void)?

    @Environment(\.libraryStyle) private var style

    private var actions: [LibraryRowAction] {
        var result = [LibraryRowAction(title: "Open", symbol: "arrow.up.forward.app", action: open)]
        if let exportAsImage {
            result.append(LibraryRowAction(title: "Export as Image…", symbol: "square.and.arrow.up", action: exportAsImage))
        }
        return result
    }

    var body: some View {
        LibraryRowCard(isSelected: isSelected, actions: actions) {
            Image(systemName: symbol)
                .font(.system(size: OrbitMetrics.iconChrome - 4))
                .foregroundStyle(style.foreground)
                .frame(width: LibraryModeMetrics.rowIconSize, height: LibraryModeMetrics.rowIconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OrbitSpacing.xxs) {
                Text(title)
                    .font(OrbitFont.sidebarRowActive)
                    .foregroundStyle(style.foreground)
                    .lineLimit(1)
                Text(detail)
                    .font(OrbitFont.commandBarRowSubtitle)
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        // Order matters: double-tap must be declared before single-tap.
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
    }

    private var detail: String {
        let date = updatedAt.formatted(date: .abbreviated, time: .omitted)
        guard let subtitle else { return date }
        return "\(subtitle) · \(date)"
    }
}
