// navigationState/mediaState are read from AppEnvironment's reactive mirrors, not WebContents directly: WebContents is not @Observable, so reading it inside body registers no dependency and the row freezes on its last re-render.

import AppKit
import SwiftUI

@MainActor
@Observable
final class TabTitleRename {
    private(set) var isEditing = false

    var draft = ""

    func begin(from currentTitle: String) {
        draft = currentTitle
        isEditing = true
    }

    func cancel() {
        isEditing = false
    }

    @discardableResult
    func commit(tabID: TabID, in env: AppEnvironment) -> Bool {
        defer { isEditing = false }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            env.resetTabName(tabID)
            return false
        }
        env.renameTab(tabID, to: trimmed)
        return true
    }
}

enum TabRowTrailingAction: Equatable {
    case closeTabKeepingBookmark
    case removeBookmark
    case closeTab

    static func resolve(section: TabSection, isOpen: Bool) -> TabRowTrailingAction {
        guard section == .pinned else { return .closeTab }
        return isOpen ? .closeTabKeepingBookmark : .removeBookmark
    }

    var systemImage: String {
        switch self {
        case .closeTabKeepingBookmark: return "minus"
        case .removeBookmark, .closeTab: return "xmark"
        }
    }

    var help: String {
        switch self {
        case .closeTabKeepingBookmark: return "Close Tab — keeps the bookmark"
        case .removeBookmark: return "Remove Bookmark"
        case .closeTab: return "Close Tab"
        }
    }
}

struct TabRowView: View {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab
    var depth: Int = 0
    var theme: SpaceTheme

    @State private var isHovering: Bool
    @State private var rename = TabTitleRename()
    @FocusState private var titleFieldFocused: Bool
    @State private var previewTask: Task<Void, Never>?
    @State private var previewImage: NSImage?
    @State private var showPreview = false

    // ImageRenderer has no pointer, so a genuinely hovered row (close button visible, title
    // narrowed) could never be captured otherwise — see SidebarMiniPlayerView's alwaysExpanded.
    init(tab: Tab, depth: Int = 0, theme: SpaceTheme, forcesHoveredAppearanceForTesting: Bool = false) {
        self.tab = tab
        self.depth = depth
        self.theme = theme
        _isHovering = State(initialValue: forcesHoveredAppearanceForTesting)
    }

    private var isActive: Bool { env.activeTabID == tab.id }

    private var isRenameable: Bool { tab.section == .pinned }

    private var renameHint: String { isRenameable ? "Double-click to rename" : "" }

    private var renameAction: (() -> Void)? {
        guard isRenameable else { return nil }
        return { beginRename() }
    }

    private var contents: (any WebContents)? { env.webContents[tab.id] }
    private var navigationState: NavigationState { env.navigationStates[tab.id] ?? .empty }
    private var mediaState: MediaState { env.mediaStates[tab.id] ?? .idle }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
                HStack(
                    spacing: showsPinnedSlash
                        ? OrbitMetrics.sidebarPinnedSlashSpacing
                        : OrbitMetrics.sidebarRowContentSpacing
                ) {
                    favicon
                    if showsPinnedSlash { pinnedSlash }
                    titleLabel
                }
                Spacer(minLength: 4)
                if PeekState.shared.activePreview?.sourceTabID == tab.id {
                    Image(systemName: "eye.fill")
                        .font(.system(size: OrbitMetrics.sidebarRowFontSize - 1))
                        .foregroundStyle(theme.readableSecondaryForeground)
                        .orbitTooltip("Peeking a link")
                        .accessibilityLabel("Peeking a link")
                }
                if tab.isMuted || mediaState.isAudible {
                    OrbitNSActionButton(action: { env.muteTab(tab.id, muted: !tab.isMuted) }) {
                        Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: OrbitMetrics.sidebarRowFontSize))
                            .foregroundStyle(theme.readableSecondaryForeground)
                    }
                }
            }
            // Trailing padding, not a permanently reserved flow slot: the title gets the row's full width until
            // the close control is actually visible, at which point this makes exactly as much room as it needs.
            .padding(.trailing, isHovering ? trailingCloseControlReservedWidth : 0)
            .animation(OrbitMotion.quick, value: isHovering)
            // .overlay, not a ZStack sibling: a sibling's flexible frame feeds back into the
            // ZStack's sizing pass. An AppKit catcher, not .onTapGesture: SwiftUI gestures and
            // AppKit mouseDown are independent, so both fired and a tab reactivated as its own
            // "-" closed it.
            .overlay(rowActivationCatcher)

            // Overlay, opacity-only: the control sits at a fixed trailing position and never inserts/removes, so
            // it is exactly as hit-testable the instant it's visible as it is once fully faded in, and a click
            // aimed at the row body can't land on it just because the layout shifted underneath the pointer.
            trailingCloseControl
                .opacity(isHovering ? 1 : 0)
                .animation(OrbitMotion.quick, value: isHovering)
        }
        .padding(.leading, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset + CGFloat(depth) * OrbitMetrics.sidebarIndentPerDepth)
        .padding(.trailing, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
        .frame(height: OrbitMetrics.sidebarRowHeight)
        .background(rowBackground)
        .overlay {
            if navigationState.isLoading { loadingProgressBar }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            handleHoverPreview(hovering)
        }
        .contextMenu { TabContextMenu(tab: tab, onRename: renameAction) }
        // orbitHoverPopover, not .popover: a plain SwiftUI .popover is .transient and installs an event monitor that eats the very next mouse-down outside it, which would eat the click that follows a dwell-triggered preview.
        .orbitHoverPopover(isPresented: $showPreview, preferredEdge: .maxX) {
            if let previewImage {
                TabHoverPreviewView(tab: tab, image: previewImage)
            }
        }
        .sidebarRecentPagesPreview(tab: tab)
    }

    // Behind trailingCloseControl in child order, so AppKit's hit test gives the overlap to it.
    private var rowActivationCatcher: some View {
        OrbitNSActionButton(action: {
            guard !rename.isEditing else { return }
            env.activateTab(tab.id)
        }) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Trailing close control (and what a bookmarked row's one is)

    private var trailingCloseControlReservedWidth: CGFloat {
        OrbitMetrics.sidebarCloseButtonSize + OrbitMetrics.sidebarRowContentSpacing
    }

    private var trailingCloseControl: some View {
        let action = TabRowTrailingAction.resolve(section: tab.section, isOpen: env.isTabOpen(tab.id))
        return OrbitNSActionButton(action: { perform(action) }) {
            Image(systemName: action.systemImage)
                .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .bold))
                .frame(width: OrbitMetrics.sidebarCloseButtonSize, height: OrbitMetrics.sidebarCloseButtonSize)
        }
        .foregroundStyle(theme.readableSecondaryForeground)
        .orbitTooltip(action.help)
    }

    private func perform(_ action: TabRowTrailingAction) {
        switch action {
        case .closeTabKeepingBookmark: env.closeTabKeepingBookmark(tab.id)
        case .removeBookmark: env.removeBookmark(tab.id)
        case .closeTab: env.closeTab(tab.id)
        }
    }

    // Padded .horizontal because this pill sits inside body's own already-padded frame; without it the highlight would run edge-to-edge while the favicon/title stay inset.
    // Inset by sidebarRowContentInset less than the row's own content padding — that difference is the pill's internal margin.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
            .fill(
                isActive
                    ? theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity)
                    : (isHovering ? theme.readableForeground.opacity(OrbitMetrics.sidebarHoverRowOpacity) : .clear)
            )
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .padding(.vertical, OrbitMetrics.sidebarRowPillVerticalInset)
    }

    // progress is clamped, not trusted: an unclamped negative value produces a negative width, which is not a valid frame.
    private var loadingProgressBar: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(theme.readableForeground.opacity(0.55))
                .frame(
                    width: proxy.size.width * min(max(navigationState.progress, 0), 1),
                    height: OrbitMetrics.sidebarRowLoadingBarHeight
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .animation(.linear(duration: 0.15), value: navigationState.progress)
        }
        .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius))
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        .padding(.vertical, OrbitMetrics.sidebarRowPillVerticalInset)
        .allowsHitTesting(false)
    }

    // MARK: - Pinned-tab reset ("Resetting" a Pinned Tab)

    // Never fires by itself — do not add a timer, an onAppear or an activation hook that resets a pinned tab.

    private var hasNavigatedAwayFromPinnedURL: Bool { tab.hasNavigatedAwayFromPinnedURL }

    private var showsPinnedSlash: Bool {
        hasNavigatedAwayFromPinnedURL && !isHovering && !rename.isEditing
    }

    private var showsPinnedResetPreview: Bool {
        hasNavigatedAwayFromPinnedURL && isHovering && !rename.isEditing
    }

    private var pinnedOriginName: String {
        if let pinnedTitle = tab.pinnedTitle, !pinnedTitle.isEmpty { return pinnedTitle }
        guard let pinnedURL = tab.pinnedURL else { return "" }
        return pinnedURL.host() ?? pinnedURL.absoluteString
    }

    static func shouldOpenPriorURLInNewTab(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.command)
    }

    private var faviconHint: String {
        guard hasNavigatedAwayFromPinnedURL else { return "" }
        return "Reset to \(pinnedOriginName) — hold Command to also open this page in a new tab"
    }

    private var favicon: some View {
        FaviconView(url: tab.faviconURL, host: tab.url.host() ?? tab.url.absoluteString)
            .frame(width: OrbitMetrics.faviconSize, height: OrbitMetrics.faviconSize)
            .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius))
            .contentShape(Rectangle())
            .onTapGesture {
                guard !rename.isEditing else { return }
                guard hasNavigatedAwayFromPinnedURL else {
                    env.activateTab(tab.id)
                    return
                }
                env.resetPinnedTab(
                    tab.id,
                    openingPriorURLInNewTab: Self.shouldOpenPriorURLInNewTab(modifiers: NSEvent.modifierFlags)
                )
            }
            .orbitTooltip(faviconHint)
    }

    private var pinnedSlash: some View {
        Text(verbatim: "/")
            .font(OrbitFont.sidebarRow)
            .foregroundStyle(theme.readableSecondaryForeground)
            .accessibilityLabel("Showing a different page than the one pinned")
    }

    @ViewBuilder
    private var titleLabel: some View {
        if rename.isEditing {
            TextField("", text: $rename.draft)
                .textFieldStyle(.plain)
                .font(isActive ? OrbitFont.sidebarRowActive : OrbitFont.sidebarRow)
                .foregroundStyle(theme.readableForeground)
                .focused($titleFieldFocused)
                .onSubmit { rename.commit(tabID: tab.id, in: env) }
                .onExitCommand { rename.cancel() }
        } else if showsPinnedResetPreview {
            pinnedResetPreviewText
        } else if isRenameable {
            titleText
                .onTapGesture(count: 2) { beginRename() }
                .orbitTooltip(renameHint)
        } else {
            titleText
        }
    }

    private var pinnedResetPreviewText: some View {
        (Text("Back to ") + Text(pinnedOriginName).fontWeight(.semibold))
            .font(isActive ? OrbitFont.sidebarRowActive : OrbitFont.sidebarRow)
            .foregroundStyle(
                theme.readableForeground.opacity(
                    isActive ? OrbitMetrics.sidebarRowLabelOpacityActive : OrbitMetrics.sidebarRowLabelOpacityInactive
                )
            )
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var titleText: some View {
        Text(tab.displayTitle)
            .font(isActive ? OrbitFont.sidebarRowActive : OrbitFont.sidebarRow)
            .foregroundStyle(
                theme.readableForeground.opacity(
                    isActive ? OrbitMetrics.sidebarRowLabelOpacityActive : OrbitMetrics.sidebarRowLabelOpacityInactive
                )
            )
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func beginRename() {
        guard isRenameable else { return }
        rename.begin(from: tab.displayTitle)
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    // .backgroundSnapshots is excluded defensively, not because hovering fails; capturePreview itself is the real per-tab gate (returns nil on no frame), so this must never widen into a capability check that switches the feature off entirely.
    static func shouldAttemptHoverPreview(section: TabSection) -> Bool {
        section != .archived
    }

    private func handleHoverPreview(_ hovering: Bool) {
        previewTask?.cancel()
        guard hovering,
              Self.shouldAttemptHoverPreview(section: tab.section),
              SidebarRecentPagesPreviewController.service(for: tab) == nil,
              let contents else {
            showPreview = false
            return
        }
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }

            // Bounded: capturePreview awaits a DevTools round trip a renderer with no live surface can never answer, and an unbounded await here would leave one suspended task per hovered row.
            let image = await withTaskGroup(of: NSImage?.self) { group in
                group.addTask {
                    await contents.capturePreview(
                        rect: nil,
                        size: CGSize(width: OrbitMetrics.tabPreviewWidth * 2, height: OrbitMetrics.tabPreviewHeight * 2)
                    )
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }

            guard !Task.isCancelled, let image else { return }
            previewImage = image
            showPreview = true
        }
    }
}

struct TabContextMenu: View {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab

    var onRename: (() -> Void)?

    var body: some View {
        if let onRename {
            Button("Rename Tab", action: onRename)
            Divider()
        }
        Button(tab.section == .pinned ? "Unpin Tab" : "Pin Tab") {
            env.togglePin(tab.id)
        }
        Button("Add to Favorites") {
            // Must read the outcome, not discard it: an already-favourited tab or a Space at capacity needs to say why, not silently do nothing.
            guard let outcome = env.promoteTabToFavorite(tab.id) else { return }
            switch outcome {
            case .added:
                break
            case .alreadyExists:
                FavoritesToastPresenter.shared.announceAlreadyFavorite()
            case .atCapacity:
                FavoritesToastPresenter.shared.announceAtCapacity()
            }
        }
        if tab.section == .pinned {
            Menu("Edit Pinned Page") {
                Button("Replace Pinned URL with Current") { env.replacePinnedURLWithCurrent(tab.id) }
                Button("Edit...") { promptToEditPinnedURL() }
            }
        }
        Divider()
        Menu("Add Split View") {
            Button("Split Right") { splitWithNewTab(edge: .right) }
            Button("Split Left") { splitWithNewTab(edge: .left) }
            Button("Split Up") { splitWithNewTab(edge: .top) }
            Button("Split Down") { splitWithNewTab(edge: .bottom) }
        }
        if env.splitGroup(for: tab.id) != nil {
            Button("Separate All Tabs") {
                if let groupID = env.splitGroup(for: tab.id)?.id { env.separateAllTabs(groupID) }
            }
        }
        Divider()
        MoveTabToSpaceMenu(tabID: tab.id, currentSection: tab.section)
        Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { env.muteTab(tab.id, muted: !tab.isMuted) }
        Divider()
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
        }
        Divider()
        if tab.section == .archived {
            Button("Restore Tab") { env.restoreFromArchive(tab.id) }
        } else {
            Button("Archive Tab") { env.archiveTab(tab.id) }
        }
        if tab.section == .pinned {
            // "Close Tab" is absent on a pinned row on purpose: closeTab(_:) on a pinned tab is already an unpin, offered here by its own name as "Unpin Tab" above.
            Button("Close Tab (Keep Bookmark)") { env.closeTabKeepingBookmark(tab.id) }
                .disabled(!env.isTabOpen(tab.id))
            Button("Remove Bookmark", role: .destructive) { env.removeBookmark(tab.id) }
        } else {
            Button("Close Tab", role: .destructive) { env.closeTab(tab.id) }
        }
    }

    // NSAlert with an accessory NSTextField, not a SwiftUI sheet: a context-menu action runs after the menu tears down, with no view left to attach a sheet/alert to.
    private func promptToEditPinnedURL() {
        let alert = NSAlert()
        alert.messageText = "Edit Pinned Page"
        alert.informativeText = "Clicking this tab's favicon returns it to this URL."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(
            frame: NSRect(
                x: 0,
                y: 0,
                width: OrbitMetrics.alertAccessoryFieldWidth,
                height: OrbitMetrics.alertAccessoryFieldHeight
            )
        )
        field.stringValue = (tab.pinnedURL ?? tab.url).absoluteString
        field.placeholderString = "https://example.com/page"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let url = URL(string: typed), url.scheme != nil else { return }
        env.setPinnedURL(tab.id, to: url)
    }

    private func splitWithNewTab(edge: SplitEdge) {
        guard let spaceID = env.activeSpace?.id else { return }
        let newTabID = env.openTab(url: URL(string: "orbit://new-tab")!, in: spaceID, section: .today, activate: false)
        env.createSplit(existingTabID: tab.id, newTabID: newTabID, edge: edge)
    }
}

// MARK: - Pinned folder row

struct PinnedFolderRowView: View {
    @Environment(AppEnvironment.self) private var env
    var folder: Folder
    var spaceID: SpaceID
    var theme: SpaceTheme
    var depth: Int

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var focused: Bool

    // Deferred, not toggle-then-revert: a row re-renders within tens of ms of folder.isExpanded changing, well inside a real double click's inter-click gap, so toggling on the first click would flash the folder open/closed on every rename.
    // Holds the Task the first click schedules so a second click can cancel it before it runs.
    @State private var pendingNameLabelToggleTask: Task<Void, Never>?

    @State private var previewState: FolderPreviewState?
    @State private var showPreview = false
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            OrbitNSActionButton(action: { env.toggleFolderExpanded(folder.id, in: spaceID) }) {
                folderGlyph
            }
            .orbitTooltip(folder.isExpanded ? "Collapse" : "Expand")

            if isRenaming {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(OrbitFont.sidebarRow)
                    .focused($focused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                OrbitNSActionButton(onClickCount: { handleNameLabelClick(clickCount: $0) }) {
                    Text(folder.name)
                        .font(OrbitFont.sidebarRow)
                        .foregroundStyle(theme.readableForeground)
                        .lineLimit(1)
                }
                .orbitTooltip("Click to collapse/expand — double-click to rename")
            }

            OrbitNSActionButton(action: { env.toggleFolderExpanded(folder.id, in: spaceID) }) {
                Spacer(minLength: 4)
            }

            trailingControls
        }
        .padding(.leading, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset + CGFloat(depth) * OrbitMetrics.sidebarIndentPerDepth)
        .padding(.trailing, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
        .frame(height: OrbitMetrics.sidebarRowHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                .fill(isHovering ? theme.readableForeground.opacity(OrbitMetrics.sidebarHoverRowOpacity) : .clear)
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
                .padding(.vertical, OrbitMetrics.sidebarRowPillVerticalInset)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            handleHoverPreview(hovering)
        }
        .orbitHoverPopover(isPresented: $showPreview, preferredEdge: .maxX) {
            if let previewState {
                FolderHoverPreviewView(state: previewState) { tabID in
                    env.activateTab(tabID)
                    showPreview = false
                }
            }
        }
        .contextMenu {
            Button("Change Icon…") { promptToChangeIcon() }
            if folder.icon != nil {
                Button("Reset to Default Icon") {
                    env.setFolderIcon(nil, isEmoji: false, forFolder: folder.id, in: spaceID)
                }
            }
            Button("Rename Folder") { beginRename() }
            Button(folder.isExpanded ? "Collapse" : "Expand") { env.toggleFolderExpanded(folder.id, in: spaceID) }
            Button("New Folder Inside") {
                env.createFolder(name: "New Folder", in: spaceID, parent: folder.id)
                if !folder.isExpanded { env.toggleFolderExpanded(folder.id, in: spaceID) }
            }
            Divider()
            Button("Ungroup (Keep Tabs)") { env.deleteFolder(folder.id, in: spaceID, keepingChildren: true) }
            Button("Delete Folder and Tabs", role: .destructive) { env.deleteFolder(folder.id, in: spaceID, keepingChildren: false) }
        }
    }

    @ViewBuilder
    private var folderGlyph: some View {
        Group {
            if let icon = folder.icon, !icon.isEmpty, folder.iconIsEmoji || OrbitSymbolName.isResolvable(icon) {
                if folder.iconIsEmoji {
                    Text(icon)
                        .font(.system(size: OrbitMetrics.sidebarFolderToggleSize * OrbitMetrics.spaceIconEmojiScaleFraction))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                        .foregroundStyle(theme.readableForeground)
                }
            } else {
                FolderToggleGlyph(isOpen: folder.isExpanded)
                    .foregroundStyle(theme.readableForeground.opacity(0.75))
            }
        }
        .frame(width: OrbitMetrics.sidebarFolderToggleSize, height: OrbitMetrics.sidebarFolderToggleSize)
        .clipped()
    }

    private var trailingControls: some View {
        HStack(spacing: 4) {
            OrbitNSActionButton(action: {
                env.createFolder(name: "New Folder", in: spaceID, parent: folder.id)
                if !folder.isExpanded { env.toggleFolderExpanded(folder.id, in: spaceID) }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .bold))
                    .frame(width: OrbitMetrics.sidebarCloseButtonSize, height: OrbitMetrics.sidebarCloseButtonSize)
            }
            .foregroundStyle(theme.readableSecondaryForeground)
            .opacity(isHovering ? 1 : 0)
            .orbitTooltip("New Folder Inside")

            Text("\(folder.children.count)")
                .font(.system(size: 12))
                .foregroundStyle(theme.readableSecondaryForeground)
        }
    }

    private func beginRename() {
        pendingNameLabelToggleTask?.cancel()
        pendingNameLabelToggleTask = nil
        draftName = folder.name
        isRenaming = true
        DispatchQueue.main.async { focused = true }
    }

    private func handleNameLabelClick(clickCount: Int) {
        switch PinnedFolderNameLabelClick.resolve(clickCount: clickCount) {
        case .scheduleDeferredToggle:
            pendingNameLabelToggleTask?.cancel()
            pendingNameLabelToggleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(NSEvent.doubleClickInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                env.toggleFolderExpanded(folder.id, in: spaceID)
            }
        case .cancelPendingToggleAndBeginRename:
            pendingNameLabelToggleTask?.cancel()
            pendingNameLabelToggleTask = nil
            guard !isRenaming else { return }
            beginRename()
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { env.renameFolder(folder.id, to: trimmed, in: spaceID) }
        isRenaming = false
    }

    private func promptToChangeIcon() {
        let alert = NSAlert()
        alert.messageText = "Change Icon…"
        alert.informativeText = "Type an emoji, or the name of an SF Symbol such as \"tray.full\". Leave it empty to go back to the folder glyph."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(
            frame: NSRect(
                x: 0,
                y: 0,
                width: OrbitMetrics.alertAccessoryFieldWidth,
                height: OrbitMetrics.alertAccessoryFieldHeight
            )
        )
        field.stringValue = folder.icon ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch FolderIconInput.resolve(typed: field.stringValue) {
        case .clearToDefault:
            env.setFolderIcon(nil, isEmoji: false, forFolder: folder.id, in: spaceID)
        case .emoji(let value):
            env.setFolderIcon(value, isEmoji: true, forFolder: folder.id, in: spaceID)
        case .symbol(let value):
            env.setFolderIcon(value, isEmoji: false, forFolder: folder.id, in: spaceID)
        case .unchanged:
            break
        }
    }

    static func shouldPresentFolderPreview(state: FolderPreviewState?, isRenaming: Bool, isExpanded: Bool) -> Bool {
        guard !isRenaming, !isExpanded, let state else { return false }
        return state.hasContent
    }

    private func handleHoverPreview(_ hovering: Bool) {
        previewTask?.cancel()
        guard hovering else {
            showPreview = false
            return
        }
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(OrbitMetrics.folderPreviewHoverDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let state = FolderPreviewState.make(
                folderID: folder.id,
                in: env.pinnedNodes(in: spaceID),
                resolveTab: env.tab
            )
            guard Self.shouldPresentFolderPreview(state: state, isRenaming: isRenaming, isExpanded: folder.isExpanded) else { return }
            previewState = state
            showPreview = true
        }
    }
}

// MARK: - Pinned folder row: name-label click arbitration

enum PinnedFolderNameLabelClick: Equatable {
    case scheduleDeferredToggle
    case cancelPendingToggleAndBeginRename

    static func resolve(clickCount: Int) -> PinnedFolderNameLabelClick {
        clickCount >= 2 ? .cancelPendingToggleAndBeginRename : .scheduleDeferredToggle
    }
}

// MARK: - SF Symbol name resolvability

// Image(systemName:) fails silently for an unresolvable name: no placeholder, no reserved ink, just a blank slot.
// Cached because NSImage(systemSymbolName:) allocates on every call and this is asked from body on rows that re-render often.
@MainActor
enum OrbitSymbolName {
    private static var resolvable: [String: Bool] = [:]

    static func isResolvable(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let cached = resolvable[name] { return cached }
        let answer = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        resolvable[name] = answer
        return answer
    }
}

// MARK: - Folder icon prompt parsing

enum FolderIconInput: Equatable {
    case clearToDefault
    case emoji(String)
    case symbol(String)
    case unchanged

    static func resolve(typed: String) -> FolderIconInput {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .clearToDefault }
        if let first = trimmed.unicodeScalars.first, first.properties.isEmoji, first.value > 0x238C {
            return .emoji(String(trimmed.prefix(1)))
        }
        guard NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil else { return .unchanged }
        return .symbol(trimmed)
    }
}
