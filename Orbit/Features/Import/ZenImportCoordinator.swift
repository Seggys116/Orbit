import Foundation

struct ZenApplyResult: Sendable, Hashable {
    var spacesCreated = 0
    var foldersCreated = 0
    var pinnedTabsImported = 0
    var todayTabsImported = 0
    var favoritesImported = 0
}

@MainActor
enum ZenImportCoordinator {

    private static let maximumFolderDepth = 64

    /// `fallbackSpaceID` receives the pinned and open tabs only when Zen has no workspaces at all; otherwise every workspace becomes a new Space on the same Profile.
    static func apply(
        _ zen: ZenStructure,
        fallbackSpaceID: SpaceID,
        env: AppEnvironment
    ) -> ZenApplyResult {
        var result = ZenApplyResult()
        guard let fallbackSpace = env.store.space(fallbackSpaceID) else { return result }
        let profileID = fallbackSpace.profileID

        var targets: [(workspaceUUID: String?, spaceID: SpaceID, isNew: Bool)] = []
        for workspace in zen.workspaces {
            let spaceID = env.store.createSpace(
                name: ArcImportCoordinator.uniqueSpaceName(workspace.name, env: env),
                icon: workspace.emoji ?? "circle.grid.2x2",
                iconIsEmoji: workspace.emoji != nil,
                theme: spaceTheme(from: workspace.theme),
                profileID: profileID,
                activate: false
            )
            targets.append((workspace.uuid, spaceID, true))
            result.spacesCreated += 1
        }
        if targets.isEmpty {
            targets.append((nil, fallbackSpaceID, false))
        }

        let knownWorkspaces = Set(zen.workspaces.map(\.uuid))
        func belongs(_ tab: ZenTab, to index: Int) -> Bool {
            if let uuid = tab.workspaceUUID, knownWorkspaces.contains(uuid) {
                return uuid == targets[index].workspaceUUID
            }
            return index == 0
        }

        for (index, target) in targets.enumerated() {
            let spaceTabs = zen.tabs.filter { belongs($0, to: index) }
            var created: [TabID: Tab] = [:]

            let forest = pinnedForest(
                spaceTabs.filter { $0.kind == .pinned },
                folders: zen.folders,
                workspaceUUID: target.workspaceUUID,
                spaceID: target.spaceID,
                tabs: &created,
                foldersCreated: &result.foldersCreated
            )
            result.pinnedTabsImported += created.count

            var todayIDs: [TabID] = []
            for zenTab in spaceTabs where zenTab.kind == .open {
                let tab = makeTab(zenTab, spaceID: target.spaceID, section: .today)
                created[tab.id] = tab
                todayIDs.append(tab.id)
                result.todayTabsImported += 1
            }

            env.store.state.tabs.merge(created) { _, new in new }
            env.store.mutateSpace(target.spaceID) { space in
                if target.isNew {
                    space.pinned = forest
                    space.today = todayIDs
                } else {
                    space.pinned.append(contentsOf: forest)
                    space.today.append(contentsOf: todayIDs)
                }
            }
        }

        // Added once: BrowserStore already mirrors a favourite across every Space sharing a Profile.
        for essential in zen.tabs where essential.kind == .essential {
            if case .added = env.store.addFavorite(url: essential.url, title: essential.title, in: targets[0].spaceID) {
                result.favoritesImported += 1
            }
        }

        return result
    }

    static func spaceTheme(from theme: ZenWorkspaceTheme?) -> SpaceTheme? {
        guard let theme, !theme.colors.isEmpty else { return nil }
        let colors = theme.colors.prefix(4).map { ThemeColor(red: $0.red, green: $0.green, blue: $0.blue) }
        let style: SpaceTheme.Style
        switch colors.count {
        case 1: style = .solid
        case 2: style = .linear
        default: style = .mesh
        }
        return SpaceTheme(
            style: style,
            colors: Array(colors),
            angle: theme.rotation ?? 18,
            grain: theme.texture
        )
    }

    static func makeTab(_ zenTab: ZenTab, spaceID: SpaceID, section: TabSection) -> Tab {
        let accessed = zenTab.lastAccessedAt ?? Date()
        return Tab(
            spaceID: spaceID,
            section: section,
            url: zenTab.url,
            title: zenTab.title,
            lastAccessedAt: accessed,
            createdAt: accessed,
            isUnloaded: true,
            pinnedURL: section == .pinned ? zenTab.url : nil,
            pinnedTitle: section == .pinned ? zenTab.title : nil
        )
    }

    private static func pinnedForest(
        _ pinned: [ZenTab],
        folders: [ZenFolder],
        workspaceUUID: String?,
        spaceID: SpaceID,
        tabs: inout [TabID: Tab],
        foldersCreated: inout Int
    ) -> [SidebarNode] {
        let foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var needed: Set<String> = []
        func requireFolder(_ id: String?) {
            var current = id
            var depth = 0
            while let id = current, let folder = foldersByID[id], depth < maximumFolderDepth {
                guard needed.insert(id).inserted else { return }
                current = folder.parentID
                depth += 1
            }
        }
        for tab in pinned { requireFolder(tab.folderID) }
        if let workspaceUUID {
            for folder in folders where folder.workspaceUUID == workspaceUUID { requireFolder(folder.id) }
        }

        // A folder whose parent chain loops back on itself is surfaced at the top level so its tabs are not lost.
        func parent(of folder: ZenFolder) -> String? {
            guard let direct = folder.parentID, needed.contains(direct) else { return nil }
            var seen: Set<String> = [folder.id]
            var current: String? = direct
            while let id = current {
                guard seen.insert(id).inserted else { return nil }
                current = foldersByID[id]?.parentID
            }
            return direct
        }
        func container(of tab: ZenTab) -> String? {
            tab.folderID.flatMap { needed.contains($0) ? $0 : nil }
        }

        func nodes(inFolder id: String?, depth: Int, visited: Set<String>) -> [SidebarNode] {
            guard depth < maximumFolderDepth else { return [] }
            var result: [SidebarNode] = []
            for folder in folders where needed.contains(folder.id) && parent(of: folder) == id && !visited.contains(folder.id) {
                foldersCreated += 1
                result.append(.folder(Folder(
                    name: folder.name,
                    isExpanded: !folder.isCollapsed,
                    children: nodes(inFolder: folder.id, depth: depth + 1, visited: visited.union([folder.id]))
                )))
            }
            for zenTab in pinned where container(of: zenTab) == id {
                let tab = makeTab(zenTab, spaceID: spaceID, section: .pinned)
                tabs[tab.id] = tab
                result.append(.tab(tab.id))
            }
            return result
        }

        return nodes(inFolder: nil, depth: 0, visited: [])
    }
}
