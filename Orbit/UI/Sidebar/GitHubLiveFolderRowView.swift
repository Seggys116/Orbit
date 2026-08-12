import AppKit
import SwiftUI

// MARK: - Sourced copy

enum GitHubLiveFolderCopy {

    // MARK: The folder's own context menu (sourced from Arc)

    static let changeIcon = "Change Icon…"
    static let rename = "Rename"
    static let deleteLiveFolder = "Delete Live Folder"
    static let refresh = "Refresh"
    static let createdByMe = "Created by Me"
    static let reviewRequests = "Review Requests"

    static let defaultFolderName = "Pull Requests"

    static let folderFlyout = "GitHub"

    // MARK: The Space context menu (sourced from Arc)

    static let spaceMenuLiveFolders = "Live Folders"
    static let spaceMenuGitHub = "GitHub"

    static let spaceMenuSignedOut = "GitHub — Sign in to GitHub"
    static let spaceMenuNoPullRequests = "GitHub — No pull requests"

    // MARK: The toast (sourced verbatim from Arc)

    static let toastTitle = "Live Folder Created"
    static let toastBody = "Pull requests from you and your team will show up here automatically"

    // MARK: `Last fetch:` (the label is sourced; the wording of the staleness row is not)

    static func lastFetch(_ date: Date?, relativeTo now: Date = Date()) -> String {
        guard let date else { return "Last fetch: Never" }
        return "Last fetch: \(CommandBarRelativeTime.string(from: date, relativeTo: now))"
    }

    static func staleness(for status: GitHubLiveFolderStatus) -> String? {
        guard case .failed(let error, _) = status else { return nil }
        switch error {
        case .signedOut:
            return "Signed out of GitHub — showing last fetch"
        case .rateLimited:
            return "Rate limited — showing last fetch"
        case .network:
            return "Offline — showing last fetch"
        case .badResponse(let code):
            return "GitHub returned \(code) — showing last fetch"
        case .malformed:
            return "Unreadable response from GitHub — showing last fetch"
        }
    }

    static func spaceMenuItem(login: String?, hasLiveData: Bool, isEnabled: Bool) -> (title: String, isActionable: Bool) {
        if login == nil {
            return (spaceMenuSignedOut, false)
        }
        if !hasLiveData && !isEnabled {
            return (spaceMenuNoPullRequests, false)
        }
        return (spaceMenuGitHub, true)
    }
}

// MARK: - The gate

@MainActor
enum GitHubLiveFolderVisibility {

    static func shouldRender(config: GitHubLiveFolderConfig?, store: GitHubLiveFolderStore) -> Bool {
        guard let config, config.isEnabled else { return false }
        // hasFetchedContents, not hasLiveData: hasLiveData also applies the store's filters, which belong to whichever Space last activated it.
        guard store.hasFetchedContents else { return false }
        return !pullRequests(config: config, store: store).isEmpty
    }

    static func pullRequests(config: GitHubLiveFolderConfig?, store: GitHubLiveFolderStore) -> [GitHubPullRequest] {
        guard let config else { return [] }
        var seen = Set<String>()
        var result: [GitHubPullRequest] = []
        if config.includesCreatedByMe {
            for pullRequest in store.createdByMe where seen.insert(pullRequest.id).inserted {
                result.append(pullRequest)
            }
        }
        if config.includesReviewRequests {
            for pullRequest in store.reviewRequests where seen.insert(pullRequest.id).inserted {
                result.append(pullRequest)
            }
        }
        return result.sorted(by: GitHubLiveFolderVisibility.isNewer)
    }

    private static func isNewer(_ lhs: GitHubPullRequest, _ rhs: GitHubPullRequest) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case (let left?, let right?):
            if left != right { return left > right }
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            break
        }
        if lhs.number != rhs.number { return lhs.number > rhs.number }
        return lhs.id > rhs.id
    }
}

// MARK: - Derived metrics

enum GitHubLiveFolderMetrics {
    static let badgeSize: CGFloat = OrbitMetrics.iconFavicon / 2
    static let badgeOverhang: CGFloat = badgeSize / 3
    static let badgeHalo: CGFloat = badgeSize / 4
}

// MARK: - The folder, and its children

@MainActor
struct GitHubLiveFolderRowView: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var theme: SpaceTheme
    var depth: Int = 0

    var store: GitHubLiveFolderStore = .shared

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var focused: Bool

    private var config: GitHubLiveFolderConfig? {
        env.space(spaceID)?.githubLiveFolder
    }

    var shouldRender: Bool {
        GitHubLiveFolderVisibility.shouldRender(config: config, store: store)
    }

    private var pullRequests: [GitHubPullRequest] {
        GitHubLiveFolderVisibility.pullRequests(config: config, store: store)
    }

    var body: some View {
        if shouldRender, let config {
            VStack(alignment: .leading, spacing: OrbitMetrics.sidebarRowSpacing) {
                folderRow(config)
                if config.isExpandedOrDefault {
                    ForEach(pullRequests) { pullRequest in
                        GitHubPullRequestRowView(
                            pullRequest: pullRequest,
                            spaceID: spaceID,
                            theme: theme,
                            depth: depth + 1
                        )
                    }
                }
            }
        }
    }

    // MARK: The folder row

    private func folderRow(_ config: GitHubLiveFolderConfig) -> some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            // OrbitNSActionButton, not a plain Button: a plain Button is not OrbitClickCatching and misses OrbitWindowContentView's click-recovery pass.
            OrbitNSActionButton(action: toggleExpanded) {
                badgedFolderGlyph(config)
            }
            .orbitTooltip(config.isExpandedOrDefault ? "Collapse" : "Expand")

            if isRenaming {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(OrbitFont.sidebarRow)
                    .focused($focused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                Text(config.displayName)
                    .font(OrbitFont.sidebarRow)
                    .foregroundStyle(theme.readableForeground)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginRename() }
            }

            Spacer(minLength: OrbitMetrics.sidebarPinnedSlashSpacing)

            Text("\(pullRequests.count)")
                .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize))
                .foregroundStyle(theme.readableSecondaryForeground)
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
        .onHover { isHovering = $0 }
        .contextMenu { folderContextMenu(config) }
    }

    private func badgedFolderGlyph(_ config: GitHubLiveFolderConfig) -> some View {
        baseGlyph(config)
            .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)
            .overlay(alignment: .bottomTrailing) {
                if GitHubMarkShape.isDrawable {
                    GitHubMarkShape()
                        .fill(theme.readableForeground)
                        .frame(width: GitHubLiveFolderMetrics.badgeSize, height: GitHubLiveFolderMetrics.badgeSize)
                        .padding(GitHubLiveFolderMetrics.badgeHalo)
                        .background(Circle().fill(Color(theme.primary.nsColor)))
                        .offset(
                            x: GitHubLiveFolderMetrics.badgeOverhang,
                            y: GitHubLiveFolderMetrics.badgeOverhang
                        )
                }
            }
    }

    // An unresolvable stored symbol name renders nothing at all (no other symptom); the custom-icon branch is only taken once validated.
    @ViewBuilder
    private func baseGlyph(_ config: GitHubLiveFolderConfig) -> some View {
        if let icon = config.icon, !icon.isEmpty, config.isIconEmoji || OrbitSymbolName.isResolvable(icon) {
            if config.isIconEmoji {
                Text(icon).font(.system(size: OrbitMetrics.iconChrome))
            } else {
                Image(systemName: icon)
                    .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                    .foregroundStyle(theme.readableForeground)
            }
        } else {
            FolderToggleGlyph(isOpen: config.isExpandedOrDefault)
                .foregroundStyle(theme.readableForeground.opacity(0.75))
        }
    }

    // MARK: The folder's context menu

    // A nested Menu inside a .contextMenu presents correctly here; a Menu used as a click-to-open button does not.
    @ViewBuilder
    private func folderContextMenu(_ config: GitHubLiveFolderConfig) -> some View {
        Button(GitHubLiveFolderCopy.changeIcon) { promptToChangeIcon(config) }
        Button(GitHubLiveFolderCopy.rename) { beginRename() }
        Button(GitHubLiveFolderCopy.deleteLiveFolder, role: .destructive) { setEnabled(false) }

        Menu(GitHubLiveFolderCopy.folderFlyout) {
            Button(GitHubLiveFolderCopy.lastFetch(store.lastSuccessfulFetch)) {}
                .disabled(true)

            if let staleness = GitHubLiveFolderCopy.staleness(for: store.status) {
                Button(staleness) {}
                    .disabled(true)
            }

            Button(GitHubLiveFolderCopy.refresh) { Task { await store.refresh() } }

            Divider()

            Button {
                setFilter(createdByMe: !config.includesCreatedByMe)
            } label: {
                if config.includesCreatedByMe {
                    Label(GitHubLiveFolderCopy.createdByMe, systemImage: "checkmark")
                } else {
                    Text(GitHubLiveFolderCopy.createdByMe)
                }
            }

            Button {
                setFilter(reviewRequests: !config.includesReviewRequests)
            } label: {
                if config.includesReviewRequests {
                    Label(GitHubLiveFolderCopy.reviewRequests, systemImage: "checkmark")
                } else {
                    Text(GitHubLiveFolderCopy.reviewRequests)
                }
            }
        }
    }

    // MARK: Mutations

    // Writes the Space's persisted config and the store's mirror of it; leaving the mirror stale desyncs the store's gate from this view's row list.
    private func mutateConfig(_ transform: (inout GitHubLiveFolderConfig) -> Void) {
        var updated: GitHubLiveFolderConfig?
        env.store.mutateSpace(spaceID) { space in
            guard var config = space.githubLiveFolder else { return }
            transform(&config)
            space.githubLiveFolder = config
            updated = config
        }
        if let updated { store.config = updated }
    }

    private func toggleExpanded() {
        let expanded = config?.isExpandedOrDefault ?? true
        withAnimation(OrbitMotion.standard) {
            mutateConfig { $0.isExpanded = !expanded }
        }
    }

    private func setEnabled(_ enabled: Bool) {
        mutateConfig { $0.enabled = enabled }
    }

    private func setFilter(createdByMe: Bool) {
        mutateConfig { $0.showsCreatedByMe = createdByMe }
    }

    private func setFilter(reviewRequests: Bool) {
        mutateConfig { $0.showsReviewRequests = reviewRequests }
    }

    private func beginRename() {
        draftName = config?.displayName ?? GitHubLiveFolderCopy.defaultFolderName
        isRenaming = true
        DispatchQueue.main.async { focused = true }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { mutateConfig { $0.name = trimmed } }
        isRenaming = false
    }

    // NSAlert with an accessory NSTextField, not a SwiftUI sheet: a context-menu action runs after the menu tears down, and a SwiftUI presentation triggered from there can silently fail to appear.
    private func promptToChangeIcon(_ config: GitHubLiveFolderConfig) {
        let alert = NSAlert()
        alert.messageText = GitHubLiveFolderCopy.changeIcon
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
        field.stringValue = config.icon ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch FolderIconInput.resolve(typed: field.stringValue) {
        case .clearToDefault:
            mutateConfig {
                $0.icon = nil
                $0.iconIsEmoji = nil
            }
        case .emoji(let value):
            mutateConfig {
                $0.icon = value
                $0.iconIsEmoji = true
            }
        case .symbol(let value):
            mutateConfig {
                $0.icon = value
                $0.iconIsEmoji = false
            }
        case .unchanged:
            break
        }
    }
}

// MARK: - A pull request row

@MainActor
struct GitHubPullRequestRowView: View {
    @Environment(AppEnvironment.self) private var env
    var pullRequest: GitHubPullRequest
    var spaceID: SpaceID
    var theme: SpaceTheme
    var depth: Int

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
                GitHubMarkShape()
                    .fill(theme.readableForeground.opacity(pullRequest.isDraft ? 0.5 : 0.9))
                    .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)

                Text(pullRequest.title)
                    .font(OrbitFont.sidebarRow)
                    .foregroundStyle(theme.readableForeground.opacity(pullRequest.isDraft ? OrbitMetrics.sidebarRowLabelOpacityInactive : OrbitMetrics.sidebarRowLabelOpacityActive))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: OrbitMetrics.sidebarPinnedSlashSpacing)

                Text("#\(pullRequest.number)")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize))
                    .foregroundStyle(theme.readableSecondaryForeground)
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
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .orbitTooltip(helpText)
        .contextMenu {
            Button("Open in New Tab") { open() }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.url.absoluteString, forType: .string)
            }
        }
    }

    private var helpText: String {
        var text = "\(pullRequest.repositorySlug) #\(pullRequest.number) by \(pullRequest.authorLogin)"
        if pullRequest.isDraft { text += " (draft)" }
        if pullRequest.isMerged { text += " (merged)" }
        return text
    }

    private func open() {
        _ = env.openTab(url: pullRequest.url, in: spaceID)
    }
}
