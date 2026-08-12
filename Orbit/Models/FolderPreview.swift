import Foundation

nonisolated public struct FolderPreviewItem: Identifiable, Hashable, Sendable {
    public var tabID: TabID
    public var title: String
    public var url: URL
    public var faviconURL: URL?
    public var lastVisitedAt: Date

    public var id: TabID { tabID }

    public init(tabID: TabID, title: String, url: URL, faviconURL: URL?, lastVisitedAt: Date) {
        self.tabID = tabID
        self.title = title
        self.url = url
        self.faviconURL = faviconURL
        self.lastVisitedAt = lastVisitedAt
    }
}

nonisolated public struct FolderPreviewState: Hashable, Sendable {
    public var itemID: FolderID
    public var title: String
    public var allPossibleChildren: [FolderPreviewItem]

    public init(itemID: FolderID, title: String, allPossibleChildren: [FolderPreviewItem]) {
        self.itemID = itemID
        self.title = title
        self.allPossibleChildren = allPossibleChildren
    }

    public var hasContent: Bool { !allPossibleChildren.isEmpty }

    public static func make(
        folderID: FolderID,
        in nodes: [SidebarNode],
        resolveTab: (TabID) -> Tab?
    ) -> FolderPreviewState? {
        guard let folder = PinnedNodeTree.findFolder(folderID, in: nodes) else { return nil }
        let items = folder.children
            .flatMap(\.allTabIDs)
            .compactMap(resolveTab)
            .map {
                FolderPreviewItem(
                    tabID: $0.id,
                    title: $0.displayTitle,
                    url: $0.url,
                    faviconURL: $0.faviconURL,
                    lastVisitedAt: $0.lastAccessedAt
                )
            }
        return FolderPreviewState(itemID: folder.id, title: folder.name, allPossibleChildren: items)
    }
}
