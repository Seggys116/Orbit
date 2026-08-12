import SwiftUI

struct SpaceEditPopover: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var onDone: () -> Void

    @State private var draftName: String = ""
    @State private var showIconChooser = false
    @State private var showThemeEditor = false

    private var space: Space? { env.space(spaceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Space").font(.system(size: 14, weight: .semibold))

            HStack(spacing: 10) {
                Button {
                    showIconChooser = true
                } label: {
                    iconPreview
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showIconChooser, arrowEdge: .bottom) {
                    SpaceIconChooserView { icon in
                        env.store.setIcon(icon, forSpace: spaceID)
                        showIconChooser = false
                    }
                }

                TextField("Space name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitRename)
            }

            Button {
                showThemeEditor = true
            } label: {
                Label("Edit Theme…", systemImage: "paintpalette")
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showThemeEditor, arrowEdge: .trailing) {
                if let space {
                    ThemeEditorView(
                        theme: Binding(
                            get: { env.space(spaceID)?.theme ?? space.theme },
                            set: { env.updateSpaceTheme(spaceID, theme: $0) }
                        ),
                        spaceID: spaceID,
                        onDone: { showThemeEditor = false }
                    )
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    commitRename()
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { draftName = space?.name ?? "" }
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let space {
            SpaceIconView(icon: space.resolvedIcon, size: 16, foregroundColor: .primary)
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        env.renameSpace(spaceID, to: trimmed)
    }
}
