import SwiftUI
import AppKit

struct NotesEditorView: View {
    @Environment(AppEnvironment.self) private var env
    let noteID: UUID

    @State private var title: String = ""
    @State private var attributedText = NSAttributedString(string: "")
    @State private var controller = RichTextController()
    @State private var saveTask: Task<Void, Never>?
    @State private var showLinkPrompt = false
    @State private var linkURLString = ""
    @State private var saveStatusLabel = "Saved"

    // nil until load(for:) finishes for the current noteID; scheduleSave refuses to write unless it matches.
    @State private var loadedNoteID: UUID?

    // What load(for:) set title to; onChange(of: title) compares against this, not loadedNoteID alone,
    // so the load's own title assignment doesn't get mistaken for a keystroke and re-saved as a rename.
    @State private var loadedTitle: String = ""

    // Captured by value at edit time — never re-read from @State after the debounce, when noteID/attributedText may have moved on.
    @State private var pendingSave: PendingSave?

    // A fresh UUID, not noteID, so registration can't collide with another open note tab's own.
    @State private var flushRegistryToken = UUID()

    private struct PendingSave {
        let noteID: UUID
        let attributedString: NSAttributedString
    }

    #if DEBUG
    nonisolated(unsafe) static var controllerObserverForTests: ((RichTextController) -> Void)?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            TextField("Untitled Note", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 4)
                .onChange(of: title) { _, newValue in
                    guard loadedNoteID == noteID, newValue != loadedTitle else { return }
                    loadedTitle = newValue
                    env.noteStore.renameNote(noteID, to: newValue)
                }

            RichTextEditorView(
                attributedText: $attributedText,
                controller: controller,
                onEdit: { scheduleSave(for: noteID) }
            )
        }
        .background(Color(nsColor: OrbitInternalPageChrome.surfaceNSColor))
        .orbitDocumentAppearance()
        .task(id: noteID) { load(for: noteID) }
        .onAppear {
            DocumentEditorFlushRegistry.shared.register(flushRegistryToken) {
                flushPendingSaveIfNeeded()
            }
        }
        .onDisappear(perform: tearDown)
        .sheet(isPresented: $showLinkPrompt) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Link").font(.system(size: 14, weight: .semibold))
                TextField("https://example.com", text: $linkURLString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HStack {
                    Spacer()
                    Button("Cancel") { showLinkPrompt = false }
                    Button("Add") {
                        if let url = URL(string: linkURLString) {
                            controller.applyLink(url: url)
                        }
                        showLinkPrompt = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            OrbitNSMenuButton(menu: { NotesHeadingOption.buildNSMenu(for: controller) }) {
                Image(systemName: "textformat.size")
                    .frame(width: 34)
            }

            Divider().frame(height: 16)

            toolbarButton("bold") { controller.toggleBold() }
            toolbarButton("italic") { controller.toggleItalic() }
            toolbarButton("underline") { controller.toggleUnderline() }

            Divider().frame(height: 16)

            toolbarButton("list.bullet") { controller.toggleBulletList() }
            toolbarButton("link") { linkURLString = ""; showLinkPrompt = true }

            Spacer()
            Text(saveStatusLabel).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func toolbarButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
    }

    private func load(for id: UUID) {
        // Any edit still debounced for the previous note must land before this overwrites the state it lives in.
        flushPendingSaveIfNeeded()

        // controller.onChange -> this closure -> captured self -> _controller's storage -> controller is a
        // real reference cycle (RichTextController is a class, can't weak-capture value-type self); tearDown() breaks it.
        controller.onChange = { newValue in
            attributedText = newValue
            scheduleSave(for: id)
        }
        #if DEBUG
        NotesEditorView.controllerObserverForTests?(controller)
        #endif

        loadedNoteID = nil
        guard let note = env.noteStore.note(id) else {
            title = ""
            loadedTitle = ""
            attributedText = NSAttributedString(string: "")
            return
        }
        title = note.title
        loadedTitle = note.title
        attributedText = NotesEditorView.decode(note.bodyData) ?? NSAttributedString(string: "")
        loadedNoteID = id
    }

    private func scheduleSave(for id: UUID) {
        // Between noteID changing and .task(id:) running load(for:) a turn later, loadedNoteID still names the
        // previous note, so a keystroke in that single-cycle window is dropped rather than saved to the wrong note.
        guard loadedNoteID == id else { return }

        pendingSave = PendingSave(noteID: id, attributedString: attributedText)
        saveStatusLabel = "Saving…"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { flushPendingSaveIfNeeded() }
        }
    }

    // Called from the debounce timer, load(for:) (before switching notes), tearDown(), and
    // DocumentEditorFlushRegistry's app-termination flush — the one case .onDisappear can't guarantee.
    private func flushPendingSaveIfNeeded() {
        saveTask?.cancel()
        saveTask = nil
        guard let pending = pendingSave else { return }
        pendingSave = nil
        if let data = NotesEditorView.encode(pending.attributedString) {
            env.noteStore.setBody(data, forNote: pending.noteID)
        }
        saveStatusLabel = "Saved"
    }

    // Order matters: flush the pending edit, then deregister (its closure captures this state), then break the onChange cycle.
    private func tearDown() {
        flushPendingSaveIfNeeded()
        DocumentEditorFlushRegistry.shared.deregister(flushRegistryToken)
        controller.onChange = nil
    }

    // MARK: - Archiving

    static func encode(_ attributedString: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: attributedString, requiringSecureCoding: true)
    }

    static func decode(_ data: Data) -> NSAttributedString? {
        guard !data.isEmpty else { return nil }
        let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver?.requiresSecureCoding = true
        return unarchiver?.decodeObject(of: NSAttributedString.self, forKey: NSKeyedArchiveRootObjectKey)
    }
}

enum NotesHeadingOption: CaseIterable {
    case heading1, heading2, heading3, body

    var title: String {
        switch self {
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .body: return "Body"
        }
    }

    // nil is body text, matching RichTextController.applyHeading(_:)'s contract.
    var level: Int? {
        switch self {
        case .heading1: return 0
        case .heading2: return 1
        case .heading3: return 2
        case .body: return nil
        }
    }

    static func buildNSMenu(for controller: RichTextController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in NotesHeadingOption.allCases {
            menu.addItem(ClosureMenuItem(title: option.title) {
                controller.applyHeading(option.level)
            })
        }
        return menu
    }
}
