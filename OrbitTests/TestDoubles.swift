import SwiftUI
import Observation

// MARK: - AppEnvironment double

@MainActor
@Observable
final class AppEnvironment {

    // A separate instance from the fixture a test builds and injects, so the folder
    // lookup behind it sees empty state and resolvesToFolder always answers false here.
    static let processRoot = AppEnvironment()

    var state = OrbitState()

    var webContents: [TabID: any WebContents] = [:]
    var navigationStates: [TabID: NavigationState] = [:]
    var mediaStates: [TabID: MediaState] = [:]
    var recentDownloads: [DownloadItem] = []
    var activeTabID: TabID?
    var siteControlPresentedTabID: TabID?

    var engineCapabilities: EngineCapabilities = []

    var sidebarWidth: CGFloat = OrbitMetrics.sidebarDefaultWidth

    var historyEntries: [HistoryEntry] = []

    private(set) var recordedActions: [String] = []

    init() {}

    // MARK: Derived read state

    var spaces: [Space] { state.spaces.sorted { $0.order < $1.order } }

    // This double has no window-scoping concept, so both always answer with the
    // ordinary-window branch; the torn-off/window-scoped branches are proven against
    // the real AppEnvironment in OrbitAppTests.
    var pagerSpaces: [Space] { spaces }

    var isTornOffWindow: Bool { false }

    var activeSpace: Space? {
        guard let id = state.activeSpaceID else { return spaces.first }
        return state.spaces.first { $0.id == id } ?? spaces.first
    }

    // Mirrors the real AppEnvironment's own derivation, which
    // CommandBarModel.createFolderOfLinks reads before fetching suggestions.
    var includesSearchSuggestions: Bool {
        let profileID = activeSpace?.profileID
        if let profileID, let profile = state.profiles.first(where: { $0.id == profileID }) {
            return profile.includesSearchSuggestions
        }
        return state.profiles.first?.includesSearchSuggestions ?? true
    }

    var activeTab: Tab? {
        guard let id = activeTabID else { return nil }
        return state.tabs[id]
    }

    func tab(_ id: TabID) -> Tab? { state.tabs[id] }

    func favorites(for spaceID: SpaceID) -> [Favorite] {
        state.spaces.first { $0.id == spaceID }?.favorites ?? []
    }

    func selectSpace(_ id: SpaceID) { state.activeSpaceID = id }

    // MARK: Actions (test doubles — see file header)

    func perform(_ command: ShortcutCommandID) { recordedActions.append("perform(\(command.rawValue))") }
    func muteTab(_ id: TabID, muted: Bool) { recordedActions.append("muteTab") }
    func closeTab(_ id: TabID) { recordedActions.append("closeTab") }
    func closeTabPreservingBookmark(_ id: TabID) { recordedActions.append("closeTabPreservingBookmark") }
    func activateTab(_ id: TabID) { recordedActions.append("activateTab") }

    // Not a recording stub: TabRowView reads this while rendering to pick between the
    // minus and the X on a bookmarked row, so a render test must drive both branches.
    func isTabOpen(_ id: TabID) -> Bool { webContents[id] != nil }

    func closeTabKeepingBookmark(_ id: TabID) { recordedActions.append("closeTabKeepingBookmark") }
    func removeBookmark(_ id: TabID) { recordedActions.append("removeBookmark") }
    func togglePin(_ id: TabID) { recordedActions.append("togglePin") }

    func renameTab(_ id: TabID, to customTitle: String) {
        recordedActions.append("renameTab")
        state.tabs[id]?.customTitle = customTitle
    }

    func resetTabName(_ id: TabID) {
        recordedActions.append("resetTabName")
        state.tabs[id]?.customTitle = nil
    }

    @discardableResult
    func promoteTabToFavorite(_ id: TabID) -> FavoriteAddOutcome? {
        recordedActions.append("promoteTabToFavorite")
        return nil
    }

    func splitGroup(for tabID: TabID) -> SplitGroup? { nil }
    func separateAllTabs(_ groupID: UUID) { recordedActions.append("separateAllTabs") }
    func restoreFromArchive(_ id: TabID, section: TabSection = .today) { recordedActions.append("restoreFromArchive") }
    func archiveTab(_ id: TabID) { recordedActions.append("archiveTab") }

    @discardableResult
    func openTab(url: URL, in spaceID: SpaceID, section: TabSection = .today, activate: Bool = true) -> TabID {
        recordedActions.append("openTab")
        return TabID()
    }

    @discardableResult
    func createSplit(existingTabID: TabID, newTabID: TabID, edge: SplitEdge) -> UUID? {
        recordedActions.append("createSplit")
        return nil
    }

    @discardableResult
    func createFolder(name: String, in spaceID: SpaceID, parent parentFolderID: FolderID? = nil, index: Int = .max) -> FolderID {
        recordedActions.append("createFolder")
        return FolderID()
    }

    // Really mutates state, not just a recordedActions note: FolderToggleGlyphRegressionGuardTests
    // needs a genuinely reactive pinnedNodes(in:) so a live-hosted PinnedFolderRowView re-diffs.
    func toggleFolderExpanded(_ id: FolderID, in spaceID: SpaceID) {
        recordedActions.append("toggleFolderExpanded")
        mutateFolder(id, in: spaceID) { $0.isExpanded.toggle() }
    }

    func setFolderIcon(_ icon: String?, isEmoji: Bool, forFolder id: FolderID, in spaceID: SpaceID) {
        recordedActions.append("setFolderIcon")
        mutateFolder(id, in: spaceID) {
            $0.icon = icon
            $0.iconIsEmoji = isEmoji
        }
    }

    private func mutateFolder(_ id: FolderID, in spaceID: SpaceID, _ transform: (inout Folder) -> Void) {
        guard let spaceIndex = state.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        func walk(_ nodes: inout [SidebarNode]) -> Bool {
            for index in nodes.indices {
                switch nodes[index] {
                case .folder(var folder):
                    if folder.id == id {
                        transform(&folder)
                        nodes[index] = .folder(folder)
                        return true
                    }
                    if walk(&folder.children) {
                        nodes[index] = .folder(folder)
                        return true
                    }
                case .tab:
                    continue
                }
            }
            return false
        }
        _ = walk(&state.spaces[spaceIndex].pinned)
    }

    func pinnedNodes(in spaceID: SpaceID) -> [SidebarNode] {
        state.spaces.first { $0.id == spaceID }?.pinned ?? []
    }

    // Mirrors the real isIncognito(_:) except its torn-off-window clause, which this double has no window to represent.
    func isIncognito(_ space: Space) -> Bool {
        if let profile = state.profiles.first(where: { $0.id == space.profileID }), OrbitState.isEphemeral(profile) {
            return true
        }
        return space.isEphemeral
    }

    func renameFolder(_ id: FolderID, to name: String, in spaceID: SpaceID) { recordedActions.append("renameFolder") }

    func deleteFolder(_ id: FolderID, in spaceID: SpaceID, keepingChildren: Bool) { recordedActions.append("deleteFolder") }

    func activateFavorite(_ favorite: Favorite, in spaceID: SpaceID) { recordedActions.append("activateFavorite") }
    func removeFavorite(_ favoriteID: UUID, from spaceID: SpaceID) { recordedActions.append("removeFavorite") }
    func reorderFavorites(_ ids: [UUID], in spaceID: SpaceID) { recordedActions.append("reorderFavorites") }
    func moveTab(_ id: TabID, toSpace destinationSpaceID: SpaceID, section: TabSection = .today) { recordedActions.append("moveTab") }

    func moveNode(_ nodeID: UUID, toParent parentFolderID: FolderID?, atIndex index: Int, in spaceID: SpaceID) {
        recordedActions.append("moveNode")
    }

    // Must mirror the real historyResults(matching:limit:)'s tokenised, every-term-anywhere match rule, or CommandBarRankingTests would assert against a rule the app no longer has.
    func historyResults(matching query: String, limit: Int = 50) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(historyEntries.prefix(limit)) }
        let terms = trimmed.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        var seen = Set<String>()
        var results: [HistoryEntry] = []
        for entry in historyEntries where AppEnvironment.historyEntryMatches(entry, terms: terms) {
            guard results.count < limit else { break }
            guard seen.insert(entry.url.absoluteString.lowercased()).inserted else { continue }
            results.append(entry)
        }
        return results
    }

    nonisolated static func historyEntryMatches(_ entry: HistoryEntry, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystacks = [entry.title.lowercased(), entry.url.absoluteString.lowercased()]
        return terms.allSatisfy { term in haystacks.contains { $0.contains(term) } }
    }

    func prepareHistorySearch(for query: String) async {}
}

// MARK: - SettingsWindowController / AboutWindowController doubles

enum SettingsPane {
    case general, profiles, links, shortcuts, extensions, adBlocker
}

enum SettingsWindowController {
    static func show(pane: SettingsPane = .general) {}
}

enum AboutWindowController {
    static func show() {}
}

// MARK: - TaskManagerWindowController double

enum TaskManagerWindowController {
    static func show() {}
}

// MARK: - DeveloperModeSettings double

// Must stay backed by its own in-memory flag, never UserDefaults.standard, so this double cannot reach through to a real user's disk-backed defaults.
enum DeveloperModeSettings {
    static var isEnabled = false
}

// MARK: - SplitEdge double

enum SplitEdge: Sendable {
    case left, right, top, bottom
}

// MARK: - SiteControlPopoverView double

struct SiteControlPopoverView: View {
    var body: some View { EmptyView() }
}

// MARK: - LibraryWindowController double

enum LibrarySection {
    case downloads
}

enum LibraryWindowController {
    static func show(section: LibrarySection) {}
}

// MARK: - SpaceSwitcherPagerView double

// Must reproduce just enough of the real view's layout and sizeScale(forSpaceCount:availableWidth:) so SidebarBottomBar's real, unmodified body type-checks and lays out correctly.
struct SpaceSwitcherPagerView: View {
    @Environment(AppEnvironment.self) private var env
    var theme: SpaceTheme
    var sizeScale: CGFloat = 1

    var body: some View {
        HStack(spacing: 6 * sizeScale) {
            ForEach(env.spaces) { space in
                Circle()
                    .fill(theme.readableForeground.opacity(space.id == env.activeSpace?.id ? 0.30 : 0.12))
                    .frame(width: 8 * sizeScale, height: 8 * sizeScale)
            }
        }
    }

    static func sizeScale(forSpaceCount count: Int, availableWidth: CGFloat) -> CGFloat {
        guard count > 0, availableWidth > 0 else { return 1 }
        let fullSizeWidth = idealWidth(forSpaceCount: count, scale: 1)
        guard fullSizeWidth > availableWidth else { return 1 }
        let scaleThatWouldExactlyFit = availableWidth / fullSizeWidth
        return max(OrbitMetrics.spacePagerMinimumSizeScale, scaleThatWouldExactlyFit)
    }

    static func idealWidth(forSpaceCount count: Int, scale: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let dotsWidth = CGFloat(count) * OrbitMetrics.spacePagerDotSize * scale
        let gapsWidth = CGFloat(max(0, count - 1)) * OrbitMetrics.spacePagerDotSpacing * scale
        let paddingWidth = OrbitMetrics.spacePagerContainerPadding * 2 * scale
        return dotsWidth + gapsWidth + paddingWidth
    }
}

// MARK: - Notification.Name double

extension Notification.Name {
    static let orbitPresentNewSpaceFlow = Notification.Name("OrbitPresentNewSpaceFlow")
}
