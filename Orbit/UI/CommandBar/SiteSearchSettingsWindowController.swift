import AppKit
import SwiftUI

@MainActor
final class SiteSearchSettingsWindowController: NSWindowController {
    private static var shared: SiteSearchSettingsWindowController?

    @discardableResult
    static func show() -> SiteSearchSettingsWindowController {
        if let shared {
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            return shared
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Site Search"
        window.center()
        window.contentView = NSHostingView(rootView: SiteSearchSettingsView().orbitEnvironment(AppEnvironment.processRoot))
        let controller = SiteSearchSettingsWindowController(window: window)
        shared = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }
}

// MARK: - Root view

struct SiteSearchSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var draft: SiteSearchDraft?

    private var store: SiteSearchStore { env.siteSearchStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                table
                triggerKeyControl
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 400)
        .sheet(item: $draft) { editing in
            SiteSearchEditorSheet(draft: editing) { saved in
                commit(saved)
                draft = nil
            } onCancel: {
                draft = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Site search")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 12)
                Button("Add") {
                    draft = SiteSearchDraft()
                }
            }
            Text("To search a specific site or part of Orbit, type its shortcut in the Command Bar, followed by your preferred trigger key.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Site or page")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Shortcut")
                    .frame(width: 140, alignment: .leading)
                Color.clear.frame(width: 64)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)

            Divider()

            ForEach(store.engines) { engine in
                SiteSearchSettingsRow(
                    engine: engine,
                    onEdit: { draft = SiteSearchDraft(engine: engine) },
                    onDelete: { store.deleteEngine(engine.id) }
                )
                Divider()
            }
        }
    }

    private var triggerKeyControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Trigger key", selection: Binding(
                get: { store.triggerKey },
                set: { store.setTriggerKey($0) }
            )) {
                Text("Tab").tag(SiteSearchTriggerKey.tab)
                Text("Space or Tab").tag(SiteSearchTriggerKey.spaceOrTab)
            }
            .pickerStyle(.inline)
            .fixedSize()
            Text("The key that turns a typed shortcut into a site search.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func commit(_ saved: SiteSearchDraft) {
        if let id = saved.existingID {
            store.updateEngine(id) { engine in
                engine.name = saved.name
                engine.shortcut = saved.shortcut
                engine.urlTemplate = saved.urlTemplate
            }
        } else {
            store.createEngine(name: saved.name, shortcut: saved.shortcut, urlTemplate: saved.urlTemplate)
        }
    }
}

// MARK: - One table row

private struct SiteSearchSettingsRow: View {
    var engine: SiteSearchEngine
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                FaviconView(url: nil, host: engine.host ?? engine.name.lowercased())
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(engine.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(engine.shortcut)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .orbitTooltip("Edit")

                Menu {
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Editor

struct SiteSearchDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var name: String = ""
    var shortcut: String = ""
    var urlTemplate: String = ""

    init() {}

    init(engine: SiteSearchEngine) {
        self.existingID = engine.id
        self.name = engine.name
        self.shortcut = engine.shortcut
        self.urlTemplate = engine.urlTemplate
    }

    var isSaveable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && urlTemplate.contains(SiteSearchEngine.queryPlaceholder)
    }
}

private struct SiteSearchEditorSheet: View {
    @State var draft: SiteSearchDraft
    var onSave: (SiteSearchDraft) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Search engine", text: $draft.name, prompt: "Twitter")
            field("Shortcut", text: $draft.shortcut, prompt: "tw")
            field("URL with %s in place of query", text: $draft.urlTemplate, prompt: "https://twitter.com/search?q=%s")

            if !draft.urlTemplate.isEmpty, !draft.urlTemplate.contains(SiteSearchEngine.queryPlaceholder) {
                Text("The URL must contain \(SiteSearchEngine.queryPlaceholder), which is replaced by what you type.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isSaveable)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
