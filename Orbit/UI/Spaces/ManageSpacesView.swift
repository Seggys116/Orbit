import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let orbitManageSpacesPayload = UTType(exportedAs: "com.orbit.browser.manageSpacesPayload")
}

struct ManageSpacesDragPayload: Codable, Transferable, Equatable {
    enum Kind: String, Codable {
        case tab
        case space
    }

    var id: UUID
    var kind: Kind
    var originSpaceID: SpaceID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .orbitManageSpacesPayload)
    }
}

enum ManageSpacesMetrics {
    static let columnWidth: CGFloat = 236
    static let columnSpacing: CGFloat = 12
    static let columnCornerRadius: CGFloat = 12
    static let headerPadding: CGFloat = 10
    static let footerHeight: CGFloat = 34
    static let addButtonDiameter: CGFloat = 32
    // Same per-depth indent the sidebar and LibraryArchivedTabsView use for folder nesting.
    static let nodeIndentPerDepth: CGFloat = OrbitMetrics.sidebarIndentPerDepth
}

struct ManageSpacesColumnsView: View {
    @Environment(AppEnvironment.self) private var env

    var searchQuery: String = ""
    var onAddSpace: () -> Void

    @State private var orderedSpaceIDs: [SpaceID] = []
    @State private var columnDropTargetID: SpaceID?

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    private var dragSuppressed: Bool {
        #if DEBUG
        return screenshotModeDragDisabled
        #else
        return false
        #endif
    }

    private var visibleSpaceIDs: [SpaceID] {
        let known = orderedSpaceIDs.filter { env.space($0) != nil }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return known }
        return known.filter { env.space($0)?.name.lowercased().contains(trimmed) == true }
    }

    var body: some View {
        HStack(alignment: .top, spacing: ManageSpacesMetrics.columnSpacing) {
            ForEach(visibleSpaceIDs, id: \.self) { spaceID in
                if let space = env.space(spaceID) {
                    columnView(for: space)
                }
            }

            Button(action: onAddSpace) {
                Image(systemName: "plus")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .semibold))
                    .foregroundStyle(LibraryPalette.textPrimary)
                    .frame(
                        width: ManageSpacesMetrics.addButtonDiameter,
                        height: ManageSpacesMetrics.addButtonDiameter
                    )
                    .background(Circle().fill(LibraryPalette.cardFill))
                    .overlay(Circle().strokeBorder(LibraryPalette.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .orbitTooltip("New Space")
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.trailing, ManageSpacesMetrics.columnSpacing)
        .onAppear { syncOrder() }
        .onChange(of: env.spaces.map(\.id)) { _, _ in syncOrder() }
    }

    private func syncOrder() {
        let live = env.spaces.map(\.id)
        let kept = orderedSpaceIDs.filter(live.contains)
        let added = live.filter { !kept.contains($0) }
        orderedSpaceIDs = kept + added
    }

    // MARK: - Column

    private func columnView(for space: Space) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ManageSpacesColumnHeader(space: space)
                .manageSpacesDraggable(
                    ManageSpacesDragPayload(id: space.id, kind: .space, originSpaceID: space.id),
                    suppressed: dragSuppressed
                )

            columnScroller {
                VStack(alignment: .leading, spacing: 2) {
                    // The real pinned tree, not env.pinnedNodes(...).flatMap(\.allTabIDs): flattening
                    // spilled every tab inside a folder into the same list as the loose ones, losing
                    // the folder entirely. ManageSpacesNodeRow renders the tree as-is instead.
                    let pinnedNodes = env.pinnedNodes(in: space.id)
                    let today = env.todayTabs(in: space.id).map(\.id)

                    ForEach(pinnedNodes, id: \.id) { node in
                        ManageSpacesNodeRow(node: node, originSpaceID: space.id, depth: 0)
                    }
                    if !pinnedNodes.isEmpty || !today.isEmpty {
                        todayDivider(for: space.id)
                    }
                    ForEach(today, id: \.self) { tabID in
                        if let tab = env.tab(tabID) {
                            ManageSpacesTabRow(tab: tab, originSpaceID: space.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { env.selectSpace(space.id) }

            ManageSpacesColumnFooter(space: space, dragSuppressed: dragSuppressed)
        }
        .frame(width: ManageSpacesMetrics.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            SpaceGradientBlendView(theme: space.theme, opacity: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ManageSpacesMetrics.columnCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ManageSpacesMetrics.columnCornerRadius)
                .strokeBorder(
                    columnDropTargetID == space.id ? Color.accentColor : LibraryPalette.cardBorder,
                    lineWidth: columnDropTargetID == space.id ? 2 : 1
                )
        )
        .manageSpacesDropDestination(suppressed: dragSuppressed) { items in
            guard let item = items.first else { return false }
            handleDrop(item, ontoSpace: space.id)
            return true
        } isTargeted: { targeted in
            columnDropTargetID = targeted ? space.id : (columnDropTargetID == space.id ? nil : columnDropTargetID)
        }
    }

    @ViewBuilder
    private func columnScroller<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dragSuppressed {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content() }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func todayDivider(for spaceID: SpaceID) -> some View {
        TodayDividerRow(spaceID: spaceID, theme: env.space(spaceID)?.theme)
            .padding(.vertical, 2)
    }

    // MARK: - Drop handling

    private func handleDrop(_ payload: ManageSpacesDragPayload, ontoSpace destinationSpaceID: SpaceID) {
        withAnimation(OrbitMotion.interactive) {
            orderedSpaceIDs = ManageSpacesDropAction.perform(
                payload,
                ontoSpace: destinationSpaceID,
                currentOrder: orderedSpaceIDs,
                in: env
            )
        }
    }
}

@MainActor
enum ManageSpacesDropAction {
    static func perform(
        _ payload: ManageSpacesDragPayload,
        ontoSpace destinationSpaceID: SpaceID,
        currentOrder: [SpaceID],
        in env: AppEnvironment
    ) -> [SpaceID] {
        switch payload.kind {
        case .tab:
            guard payload.originSpaceID != destinationSpaceID else { return currentOrder }
            env.moveTab(payload.id, toSpace: destinationSpaceID, section: .today)
            return currentOrder
        case .space:
            guard let fromIndex = currentOrder.firstIndex(of: payload.id),
                  let toIndex = currentOrder.firstIndex(of: destinationSpaceID),
                  fromIndex != toIndex else { return currentOrder }
            var reordered = currentOrder
            let moved = reordered.remove(at: fromIndex)
            reordered.insert(moved, at: toIndex)
            env.reorderSpaces(reordered)
            return reordered
        }
    }
}

@MainActor
enum ManageSpacesAddSpaceAction {
    static func perform(
        activateBrowserWindow: @MainActor () -> Void = { OrbitWindowController.activateBrowserWindow() },
        notificationCenter: NotificationCenter = .default
    ) {
        activateBrowserWindow()
        notificationCenter.post(name: .orbitPresentNewSpaceFlow, object: nil)
    }
}

@MainActor
enum ManageSpacesOverflowMenu {
    struct Actions {
        var rename: () -> Void
        var changeIcon: () -> Void
        var editTheme: () -> Void
    }

    static func build(for space: Space, in env: AppEnvironment, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(ClosureMenuItem(title: "Rename Space", handler: actions.rename))
        menu.addItem(ClosureMenuItem(title: "Change Icon…", handler: actions.changeIcon))
        menu.addItem(ClosureMenuItem(title: "Theme…", handler: actions.editTheme))

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Delete Space", enabled: env.spaces.count > 1) {
            env.deleteSpace(space.id)
        })
        return menu
    }
}

// MARK: - Column header (icon + name + pencil)

private struct ManageSpacesColumnHeader: View {
    @Environment(AppEnvironment.self) private var env
    var space: Space

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var fieldFocused: Bool
    @State private var showIconChooser = false
    @State private var showThemeEditor = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showIconChooser = true
            } label: {
                SpaceIconView(icon: space.resolvedIcon, size: OrbitMetrics.iconFavicon)
                    .frame(width: OrbitMetrics.iconChrome, height: OrbitMetrics.iconChrome)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showIconChooser, arrowEdge: .bottom) {
                SpaceIconChooserView { icon in
                    env.store.setIcon(icon, forSpace: space.id)
                    showIconChooser = false
                }
            }

            if isRenaming {
                TextField("Space name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                Text(space.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginRename() }
            }

            Spacer(minLength: 4)

            Button {
                showThemeEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .orbitTooltip("Edit Space")
            .popover(isPresented: $showThemeEditor, arrowEdge: .bottom) {
                SpaceEditPopover(spaceID: space.id, onDone: { showThemeEditor = false })
            }
        }
        .padding(ManageSpacesMetrics.headerPadding)
        .contentShape(Rectangle())
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
}

// MARK: - Column footer (move handle + `…` overflow)

private struct ManageSpacesColumnFooter: View {
    @Environment(AppEnvironment.self) private var env
    var space: Space
    var dragSuppressed: Bool

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var fieldFocused: Bool
    @State private var showIconChooser = false
    @State private var showThemeEditor = false

    var body: some View {
        HStack {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize - 1, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .manageSpacesDraggable(
                    ManageSpacesDragPayload(id: space.id, kind: .space, originSpaceID: space.id),
                    suppressed: dragSuppressed
                )
                .orbitTooltip("Drag to reorder")

            Spacer()

            // SwiftUI's Menu does not present reliably in this app's hosting configuration.
            OrbitNSMenuButton(menu: {
                ManageSpacesOverflowMenu.build(
                    for: space,
                    in: env,
                    actions: .init(
                        rename: { beginRename() },
                        changeIcon: { showIconChooser = true },
                        editTheme: { showThemeEditor = true }
                    )
                )
            }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: OrbitMetrics.iconChrome, height: OrbitMetrics.iconChrome)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, ManageSpacesMetrics.headerPadding)
        .frame(height: ManageSpacesMetrics.footerHeight)
        .overlay(alignment: .leading) {
            if isRenaming {
                TextField("Space name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .padding(.horizontal, ManageSpacesMetrics.headerPadding)
            }
        }
        .popover(isPresented: $showIconChooser, arrowEdge: .top) {
            SpaceIconChooserView { icon in
                env.store.setIcon(icon, forSpace: space.id)
                showIconChooser = false
            }
        }
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
}

// MARK: - Pinned tree (folders + tabs)
//
// Renders env.pinnedNodes(in:) as the tree it actually is, instead of flattening it. Deliberately
// self-contained, mirroring LibraryArchivedTabsView's ArchivedFolderRow rather than SidebarNodeRow:
// expand/collapse is local @State here, not env.toggleFolderExpanded(folder.id, in:) — this column
// is a preview surface, not the sidebar, and must not mutate the real Folder.isExpanded (another
// agent hit exactly that coupling trap building the Archive view's own tree and had to back it out
// into local rows). For the same reason there is no folder-level .draggable here: only individual
// tabs (ManageSpacesTabRow, reused unchanged at every depth) can be dragged to another Space's
// column, exactly as before this file rendered a tree at all.

private struct ManageSpacesNodeRow: View {
    var node: SidebarNode
    var originSpaceID: SpaceID
    var depth: Int

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch node {
        case .tab(let tabID):
            if let tab = env.tab(tabID) {
                ManageSpacesTabRow(tab: tab, originSpaceID: originSpaceID)
                    .padding(.leading, CGFloat(depth) * ManageSpacesMetrics.nodeIndentPerDepth)
            }
        case .folder(let folder):
            ManageSpacesFolderRow(folder: folder, originSpaceID: originSpaceID, depth: depth)
        }
    }
}

// A click here toggles this row's own local expand/collapse only — it neither activates the
// folder's tabs nor selects the Space (the column's own background .onTapGesture does that; a
// Button here claims the tap first, which is the deliberate, existing behaviour ArchivedFolderRow
// already relies on).
private struct ManageSpacesFolderRow: View {
    var folder: Folder
    var originSpaceID: SpaceID
    var depth: Int

    @State private var isExpanded: Bool

    init(folder: Folder, originSpaceID: SpaceID, depth: Int) {
        self.folder = folder
        self.originSpaceID = originSpaceID
        self.depth = depth
        _isExpanded = State(initialValue: folder.isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LibraryPalette.textTertiary)
                        .frame(width: 10, height: 10)
                    folderGlyph
                    Text(folder.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LibraryPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Same TabRowView.swift PinnedFolderRowView.trailingControls model: children.count,
                    // an immediate-child count (tabs and subfolders each count as one), not a recursive
                    // tab total — so this row reads identically to the folder's own sidebar row.
                    Text("\(folder.children.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryPalette.textTertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.001)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(depth) * ManageSpacesMetrics.nodeIndentPerDepth)

            if isExpanded {
                ForEach(folder.children, id: \.id) { child in
                    ManageSpacesNodeRow(node: child, originSpaceID: originSpaceID, depth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private var folderGlyph: some View {
        if let icon = folder.icon, !icon.isEmpty, folder.iconIsEmoji || OrbitSymbolName.isResolvable(icon) {
            if folder.iconIsEmoji {
                Text(icon).font(.system(size: 12))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LibraryPalette.textSecondary)
                    .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)
            }
        } else {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LibraryPalette.textSecondary)
                .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)
        }
    }
}

// MARK: - Tab row (draggable across columns)

private struct ManageSpacesTabRow: View {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab
    var originSpaceID: SpaceID

    var body: some View {
        HStack(spacing: 6) {
            FaviconView(url: tab.faviconURL, host: tab.url.host() ?? tab.url.absoluteString)
                .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(tab.displayTitle)
                .font(.system(size: 11.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.001)))
        .contentShape(Rectangle())
        .draggable(ManageSpacesDragPayload(id: tab.id, kind: .tab, originSpaceID: originSpaceID)) {
            HStack(spacing: 6) {
                FaviconView(url: tab.faviconURL, host: tab.url.host() ?? tab.url.absoluteString)
                    .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)
                Text(tab.displayTitle).font(.system(size: 11.5))
            }
            .padding(6)
        }
    }
}

// MARK: - Screenshot-generation escape hatch

private extension View {
    @ViewBuilder
    func manageSpacesDraggable(_ payload: ManageSpacesDragPayload, suppressed: Bool) -> some View {
        if suppressed {
            self
        } else {
            self.draggable(payload)
        }
    }

    @ViewBuilder
    func manageSpacesDropDestination(
        suppressed: Bool,
        action: @escaping ([ManageSpacesDragPayload]) -> Bool,
        isTargeted: @escaping (Bool) -> Void
    ) -> some View {
        if suppressed {
            self
        } else {
            self.dropDestination(for: ManageSpacesDragPayload.self) { items, _ in
                action(items)
            } isTargeted: { targeted in
                isTargeted(targeted)
            }
        }
    }
}
