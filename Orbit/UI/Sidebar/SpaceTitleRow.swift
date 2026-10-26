//  The Space icon must stay identity-only, never re-wrapped in a Button — collapse/rename/icon controls live on this row's own context menu instead. Profile ▸ is deliberately absent from that menu: Profiles belong to Settings, not any Space surface.

import SwiftUI

struct SpaceTitleRow: View {
    @Environment(AppEnvironment.self) private var env
    var space: Space

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var fieldFocused: Bool
    @State private var showThemeEditor = false
    @State private var showIconPicker = false

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            spaceIconDisplay
            if isRenaming {
                TextField("Space name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(OrbitFont.sidebarSpaceName)
                    .foregroundStyle(space.theme.readableForeground)
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                Text(space.name)
                    .font(OrbitFont.sidebarSpaceName)
                    .foregroundStyle(space.theme.readableForeground.opacity(OrbitMetrics.sidebarRowLabelOpacityActive))
                    .lineLimit(1)
                    .overlay { chromeDragSurface(onDoubleClick: beginRename) }
            }
            Spacer()
        }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
        .frame(height: OrbitMetrics.sidebarSpaceNameRowHeight)
        .background { chromeDragSurface(onDoubleClick: nil) }
        .orbitRightClickMenu { menuEntries }
        .popover(isPresented: $showThemeEditor, arrowEdge: .top) {
            ThemeEditorView(
                theme: Binding(
                    get: { env.space(space.id)?.theme ?? space.theme },
                    set: { env.updateSpaceTheme(space.id, theme: $0) }
                ),
                spaceID: space.id,
                onDone: { showThemeEditor = false }
            )
        }
        .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
            SpaceIconPickerView(space: space)
        }
    }

    // Hit-testable SwiftUI in front of a drag surface takes its click, so the icon opts out.
    @ViewBuilder
    private func chromeDragSurface(onDoubleClick: (() -> Void)?) -> some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            Color.clear.allowsHitTesting(false)
        } else {
            SidebarChromeDragSurface(onDoubleClick: onDoubleClick)
        }
        #else
        SidebarChromeDragSurface(onDoubleClick: onDoubleClick)
        #endif
    }

    private var spaceIconDisplay: some View {
        SpaceIconView(
            icon: space.resolvedIcon,
            size: OrbitMetrics.sidebarSpaceIconSize,
            foregroundColor: space.theme.readableForeground.opacity(OrbitMetrics.sidebarRowLabelOpacityActive)
        )
        .frame(width: OrbitMetrics.sidebarSpaceIconSize, height: OrbitMetrics.sidebarSpaceIconSize)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var menuEntries: [OrbitContextMenuEntry] {
        let liveFolder = gitHubLiveFolderItem
        return [
            .item(OrbitContextMenuItem(title: "New Folder", systemImage: "folder.badge.plus") {
                env.createFolder(name: "New Folder", in: space.id)
            }),
            .item(OrbitContextMenuItem(title: "Paste as New Tab", systemImage: "doc.on.clipboard") { pasteAsNewTab() }),
            .divider(),
            .item(OrbitContextMenuItem(title: "Rename Space", systemImage: "pencil") { beginRename() }),
            .item(OrbitContextMenuItem(title: "Change Icon…", systemImage: "face.smiling") { showIconPicker = true }),
            .item(OrbitContextMenuItem(title: "Theme…", systemImage: "paintpalette") { showThemeEditor = true }),
            .item(OrbitContextMenuItem(
                title: space.isPinnedSectionCollapsed ? "Expand Pinned" : "Collapse Pinned",
                systemImage: space.isPinnedSectionCollapsed ? "chevron.down" : "chevron.up"
            ) {
                withAnimation(OrbitMotion.standard) {
                    env.store.mutateSpace(space.id) { $0.isPinnedSectionCollapsed.toggle() }
                }
            }),
            .item(OrbitContextMenuItem(title: GitHubLiveFolderCopy.spaceMenuLiveFolders, systemImage: "tray.full", submenu: [
                .item(OrbitContextMenuItem(
                    title: liveFolder.title,
                    isEnabled: liveFolder.isActionable,
                    isChecked: isGitHubLiveFolderEnabled
                ) {
                    toggleGitHubLiveFolder()
                }),
            ])),
            .divider(),
            .item(OrbitContextMenuItem(title: "New Space", systemImage: "plus.square.on.square") { presentNewSpaceFlow() }),
            .item(OrbitContextMenuItem(title: "Manage Spaces…", systemImage: "square.grid.2x2") { presentManageSpaces() }),
            .divider(),
            .item(OrbitContextMenuItem(title: "Delete Space", systemImage: "trash", isDestructive: true) {
                env.deleteSpace(space.id)
            }),
        ]
    }

    // MARK: - Live Folders ▸ GitHub

    private var isGitHubLiveFolderEnabled: Bool {
        (env.space(space.id) ?? space).githubLiveFolder?.isEnabled ?? false
    }

    private var gitHubLiveFolderItem: (title: String, isActionable: Bool) {
        let store = GitHubLiveFolderStore.shared
        return GitHubLiveFolderCopy.spaceMenuItem(
            login: store.login,
            hasLiveData: store.hasLiveData,
            isEnabled: isGitHubLiveFolderEnabled
        )
    }

    // Writes GitHubLiveFolderStore's mirror of the config too — hasLiveData gates on the store's own copy, not the Space's.
    private func toggleGitHubLiveFolder() {
        let enable = !isGitHubLiveFolderEnabled
        var updated: GitHubLiveFolderConfig?
        env.store.mutateSpace(space.id) { space in
            var config = space.githubLiveFolder ?? GitHubLiveFolderConfig()
            config.enabled = enable
            space.githubLiveFolder = config
            updated = config
        }
        if let updated { GitHubLiveFolderStore.shared.config = updated }
    }

    private func pasteAsNewTab() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let url = URL(string: string)
            ?? URL(string: "https://www.google.com/search?q=\(string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        guard let url else { return }
        env.openTab(url: url, in: space.id)
    }

    private func beginRename() {
        draftName = space.name
        isRenaming = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { env.renameSpace(space.id, to: trimmed) }
        isRenaming = false
    }

    private func presentNewSpaceFlow() {
        NotificationCenter.default.post(name: .orbitPresentNewSpaceFlow, object: nil)
    }

    private func presentManageSpaces() {
        LibraryWindowController.show(section: .spaces)
    }
}

struct SpaceIconPickerView: View {
    @Environment(AppEnvironment.self) private var env
    var space: Space
    @State private var emojiText = ""

    // sparkles deliberately dropped from this picker's choices; the bottom-bar switcher's default new-Space icon literal lives in Orbit/Models/BrowserStore.swift and Orbit/Models/ModelTypes.swift, not here.
    private static let symbolChoices = [
        "circle.grid.2x2", "briefcase", "book", "paintpalette",
        "airplane", "house", "leaf", "gamecontroller", "cart", "graduationcap", "music.note",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Space Icon").font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                ForEach(SpaceIconPickerView.symbolChoices, id: \.self) { symbol in
                    Button {
                        setIcon(symbol, isEmoji: false)
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack {
                TextField("Or type an emoji", text: $emojiText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button("Use") {
                    guard let first = emojiText.first else { return }
                    setIcon(String(first), isEmoji: true)
                }
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func setIcon(_ icon: String, isEmoji: Bool) {
        env.setSpaceIcon(space.id, icon: icon, isEmoji: isEmoji)
    }
}

extension Notification.Name {
    static let orbitPresentNewSpaceFlow = Notification.Name("OrbitPresentNewSpaceFlow")
}
