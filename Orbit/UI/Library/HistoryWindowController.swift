import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController: NSWindowController {
    private static var shared: HistoryWindowController?

    @discardableResult
    static func show() -> HistoryWindowController {
        if let shared {
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            return shared
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.center()
        window.contentView = NSHostingView(rootView: HistoryWindowView().orbitEnvironment(AppEnvironment.processRoot))
        let controller = HistoryWindowController(window: window)
        shared = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }
}

struct HistoryWindowView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var searchText = ""
    @State private var entries: [HistoryEntry] = []

    private var groupedByDay: [(Date, [HistoryEntry])] {
        let filtered: [HistoryEntry]
        if searchText.isEmpty {
            filtered = entries
        } else {
            let lowered = searchText.lowercased()
            filtered = entries.filter { $0.title.lowercased().contains(lowered) || $0.url.absoluteString.lowercased().contains(lowered) }
        }
        let grouped = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.visitedAt) }
        return grouped.sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search history", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            List {
                ForEach(groupedByDay, id: \.0) { day, dayEntries in
                    Section(day.formatted(date: .complete, time: .omitted)) {
                        ForEach(dayEntries.sorted { $0.visitedAt > $1.visitedAt }) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 580, minHeight: 480)
        .task { await loadRecentHistory() }
    }

    private func loadRecentHistory() async {
        let range = Date().addingTimeInterval(-90 * 86_400)...Date()
        entries = await env.historyEntries(in: range)
    }
}

private struct HistoryRow: View {
    @Environment(AppEnvironment.self) private var env
    var entry: HistoryEntry

    var body: some View {
        Button {
            guard let spaceID = env.activeSpace?.id else { return }
            env.openTab(url: entry.url, in: spaceID)
        } label: {
            HStack {
                Image(systemName: "globe").foregroundStyle(.secondary).font(.system(size: 11))
                Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(entry.url.host() ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(entry.visitedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
