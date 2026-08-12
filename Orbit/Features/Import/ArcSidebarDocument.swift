//  StorableSidebar.json's sidebar.containers items/spaces, and Space.containerIDs, are ALTERNATING
//  arrays ([id, object, id, object, ...]); decoding as a plain object list silently drops every other element.
//  createdAt/timeLastActiveAt/archivedAt are CFAbsoluteTime (2001 epoch), NOT Chromium's 1601-microsecond
//  epoch used by ChromiumImportReader. newContainerIDs is the newer wrapped-key encoding of containerIDs,
//  read as a fallback. iconType emoji_v2 is preferred over the legacy single-scalar emoji form.
//  Tree structure comes from ordered childrenIds, never parentID; dangling ids are sync tombstones and
//  are skipped deliberately, not faulted.

import Foundation

// MARK: - Values

public struct ArcColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public var colorSpace: String

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1, colorSpace: String = "extendedSRGB") {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.colorSpace = colorSpace
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any],
              let red = ArcSidebarDocument.double(object["red"]),
              let green = ArcSidebarDocument.double(object["green"]),
              let blue = ArcSidebarDocument.double(object["blue"])
        else { return nil }
        self.init(
            red: red,
            green: green,
            blue: blue,
            alpha: ArcSidebarDocument.double(object["alpha"]) ?? 1,
            colorSpace: (object["colorSpace"] as? String) ?? "extendedSRGB"
        )
    }
}

public enum ArcIcon: Sendable, Hashable {
    case emoji(String)
    case materialSymbol(String)

    init?(iconTypeJSON: Any?) {
        guard let object = iconTypeJSON as? [String: Any] else { return nil }
        if let emoji = object["emoji_v2"] as? String, !emoji.isEmpty {
            self = .emoji(emoji)
            return
        }
        if let name = object["icon"] as? String, !name.isEmpty {
            self = .materialSymbol(name)
            return
        }
        // Range check before UInt32(_:), since UInt32(_: Double) traps on an out-of-range value rather than clamping.
        if let scalarValue = ArcSidebarDocument.double(object["emoji"]),
           scalarValue >= 0, scalarValue <= Double(UInt32.max),
           let scalar = Unicode.Scalar(UInt32(scalarValue)) {
            self = .emoji(String(Character(scalar)))
            return
        }
        return nil
    }
}

public struct ArcSpaceTheme: Sendable, Hashable {
    public var baseColors: [ArcColor]
    public var overlayColors: [ArcColor]
    public var noiseFactor: Double
    public var intensityFactor: Double
    public var overlayTexture: String?
    /// nil when the document did not say — must not be read as "light".
    public var prefersDarkContent: Bool?
    public var primaryShaded: ArcColor?

    public init(
        baseColors: [ArcColor],
        overlayColors: [ArcColor] = [],
        noiseFactor: Double = 0,
        intensityFactor: Double = 1,
        overlayTexture: String? = nil,
        prefersDarkContent: Bool? = nil,
        primaryShaded: ArcColor? = nil
    ) {
        self.baseColors = baseColors
        self.overlayColors = overlayColors
        self.noiseFactor = noiseFactor
        self.intensityFactor = intensityFactor
        self.overlayTexture = overlayTexture
        self.prefersDarkContent = prefersDarkContent
        self.primaryShaded = primaryShaded
    }
}

public struct ArcTab: Sendable, Hashable {
    public var arcID: UUID
    public var url: URL
    public var title: String
    public var customTitle: String?
    public var createdAt: Date
    public var lastActiveAt: Date?
    public var isMuted: Bool

    public init(
        arcID: UUID,
        url: URL,
        title: String,
        customTitle: String? = nil,
        createdAt: Date,
        lastActiveAt: Date? = nil,
        isMuted: Bool = false
    ) {
        self.arcID = arcID
        self.url = url
        self.title = title
        self.customTitle = customTitle
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.isMuted = isMuted
    }
}

public struct ArcFolder: Sendable, Hashable {
    public var arcID: UUID
    public var name: String
    public var icon: ArcIcon?
    public var children: [ArcSidebarItem]
    public var createdAt: Date

    public init(arcID: UUID, name: String, icon: ArcIcon? = nil, children: [ArcSidebarItem] = [], createdAt: Date) {
        self.arcID = arcID
        self.name = name
        self.icon = icon
        self.children = children
        self.createdAt = createdAt
    }
}

public indirect enum ArcSidebarItem: Sendable, Hashable {
    case tab(ArcTab)
    case folder(ArcFolder)

    public var arcID: UUID {
        switch self {
        case .tab(let tab): return tab.arcID
        case .folder(let folder): return folder.arcID
        }
    }

    public var allTabs: [ArcTab] {
        switch self {
        case .tab(let tab): return [tab]
        case .folder(let folder): return folder.children.flatMap(\.allTabs)
        }
    }

    public var allFolders: [ArcFolder] {
        switch self {
        case .tab: return []
        case .folder(let folder): return [folder] + folder.children.flatMap(\.allFolders)
        }
    }
}

public struct ArcSpace: Sendable, Hashable {
    public var arcID: UUID
    public var title: String
    public var icon: ArcIcon?
    public var theme: ArcSpaceTheme?
    public var pinned: [ArcSidebarItem]
    public var today: [ArcSidebarItem]

    public init(
        arcID: UUID,
        title: String,
        icon: ArcIcon? = nil,
        theme: ArcSpaceTheme? = nil,
        pinned: [ArcSidebarItem] = [],
        today: [ArcSidebarItem] = []
    ) {
        self.arcID = arcID
        self.title = title
        self.icon = icon
        self.theme = theme
        self.pinned = pinned
        self.today = today
    }
}

public struct ArcSidebarDocument: Sendable, Hashable {
    public var spaces: [ArcSpace]
    /// topApps is per-profile, not per-Space — returned once for the whole document.
    public var topApps: [ArcTab]

    public init(spaces: [ArcSpace], topApps: [ArcTab] = []) {
        self.spaces = spaces
        self.topApps = topApps
    }
}

// MARK: - Parsing

extension ArcSidebarDocument {

    public static func parse(data: Data, browser: ImportableBrowser) throws -> ArcSidebarDocument {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BrowserImportError.unreadable(browser, reason: "StorableSidebar.json isn't valid JSON: \(error.localizedDescription)")
        }
        guard let root = json as? [String: Any] else {
            throw BrowserImportError.unreadable(browser, reason: "StorableSidebar.json's root isn't a JSON object.")
        }
        guard let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any]
        else {
            throw BrowserImportError.unreadable(browser, reason: "StorableSidebar.json has no sidebar.containers array.")
        }

        // Found by shape, not by index, so a document that drops or reorders the leading {"global": {}} marker still imports.
        guard let container = containers.lazy.compactMap({ $0 as? [String: Any] }).first(where: { $0["items"] != nil }) else {
            throw BrowserImportError.unreadable(browser, reason: "StorableSidebar.json has no container with an items array.")
        }

        let items = objects(in: container["items"])
        let spaceObjects = objects(in: container["spaces"])

        var itemsByID: [String: [String: Any]] = [:]
        itemsByID.reserveCapacity(items.count)
        for item in items {
            guard let id = item["id"] as? String else { continue }
            itemsByID[id] = item
        }

        let spaces = spaceObjects.compactMap { space(from: $0, itemsByID: itemsByID) }
        let topApps = topAppTabs(container: container, itemsByID: itemsByID)
        return ArcSidebarDocument(spaces: spaces, topApps: topApps)
    }

    // MARK: Alternating arrays

    static func objects(in json: Any?) -> [[String: Any]] {
        guard let array = json as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    static func pairs(in json: Any?) -> [String: String] {
        guard let array = json as? [Any] else { return [:] }
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < array.count {
            defer { index += 2 }
            guard let key = array[index] as? String, let value = array[index + 1] as? String else { continue }
            result[key] = value
        }
        return result
    }

    static func wrappedPairs(in json: Any?) -> [String: String] {
        guard let array = json as? [Any] else { return [:] }
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < array.count {
            defer { index += 2 }
            guard let keyObject = array[index] as? [String: Any],
                  let key = keyObject.keys.first,
                  let value = array[index + 1] as? String
            else { continue }
            result[key] = value
        }
        return result
    }

    // MARK: Spaces

    private static func space(from object: [String: Any], itemsByID: [String: [String: Any]]) -> ArcSpace? {
        guard let idString = object["id"] as? String, let id = UUID(uuidString: idString) else { return nil }

        let customInfo = object["customInfo"] as? [String: Any]
        var containers = pairs(in: object["containerIDs"])
        for (key, value) in wrappedPairs(in: object["newContainerIDs"]) where containers[key] == nil {
            containers[key] = value
        }

        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ArcSpace(
            arcID: id,
            title: title.isEmpty ? "Untitled Space" : title,
            icon: ArcIcon(iconTypeJSON: customInfo?["iconType"]),
            theme: theme(from: customInfo?["windowTheme"]),
            pinned: children(ofContainer: containers["pinned"], itemsByID: itemsByID),
            today: children(ofContainer: containers["unpinned"], itemsByID: itemsByID)
        )
    }

    private static func topAppTabs(container: [String: Any], itemsByID: [String: [String: Any]]) -> [ArcTab] {
        var containerIDs: [String] = []
        if let array = container["topAppsContainerIDs"] as? [Any] {
            containerIDs = array.compactMap { $0 as? String }
        }
        return containerIDs.flatMap { children(ofContainer: $0, itemsByID: itemsByID).flatMap(\.allTabs) }
    }

    // MARK: Tree walk

    private static func children(ofContainer containerID: String?, itemsByID: [String: [String: Any]]) -> [ArcSidebarItem] {
        guard let containerID, let container = itemsByID[containerID] else { return [] }
        return children(of: container, itemsByID: itemsByID, visited: [containerID])
    }

    private static func children(
        of item: [String: Any],
        itemsByID: [String: [String: Any]],
        visited: Set<String>
    ) -> [ArcSidebarItem] {
        guard let childIDs = item["childrenIds"] as? [Any] else { return [] }

        var result: [ArcSidebarItem] = []
        for case let childID as String in childIDs {
            guard !visited.contains(childID), let child = itemsByID[childID] else { continue }
            guard let node = node(from: child, itemsByID: itemsByID, visited: visited.union([childID])) else { continue }
            result.append(node)
        }
        return result
    }

    private static func node(
        from item: [String: Any],
        itemsByID: [String: [String: Any]],
        visited: Set<String>
    ) -> ArcSidebarItem? {
        guard let idString = item["id"] as? String, let id = UUID(uuidString: idString) else { return nil }
        guard let data = item["data"] as? [String: Any] else { return nil }

        let createdAt = ImportSQLiteSnapshot.dateFromCFAbsoluteTime(double(item["createdAt"]) ?? 0)
        let renamed = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = (renamed?.isEmpty ?? true) ? nil : renamed

        if let tabData = data["tab"] as? [String: Any] {
            guard let urlString = tabData["savedURL"] as? String,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "file"
            else { return nil }

            let savedTitle = (tabData["savedTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .tab(ArcTab(
                arcID: id,
                url: url,
                title: savedTitle.isEmpty ? (url.host() ?? urlString) : savedTitle,
                customTitle: customTitle,
                createdAt: createdAt,
                lastActiveAt: double(tabData["timeLastActiveAt"]).map(ImportSQLiteSnapshot.dateFromCFAbsoluteTime),
                isMuted: (tabData["savedMuteStatus"] as? String) == "muted"
            ))
        }

        if let listData = data["list"] as? [String: Any] {
            let customInfo = listData["customInfo"] as? [String: Any]
            return .folder(ArcFolder(
                arcID: id,
                name: customTitle ?? "Folder",
                icon: ArcIcon(iconTypeJSON: customInfo?["iconType"]),
                children: children(of: item, itemsByID: itemsByID, visited: visited),
                createdAt: createdAt
            ))
        }

        return nil
    }

    // MARK: Theme

    static func theme(from json: Any?) -> ArcSpaceTheme? {
        guard let windowTheme = json as? [String: Any] else { return nil }

        let primaryShaded = (windowTheme["primaryColorPalette"] as? [String: Any]).flatMap { ArcColor(json: $0["shaded"]) }
        let single = ((windowTheme["background"] as? [String: Any])?["single"] as? [String: Any])?["_0"] as? [String: Any]

        var prefersDark: Bool?
        if let appearance = single?["contentOverBackgroundAppearance"] as? String {
            prefersDark = appearance == "dark"
        }

        let color = ((single?["style"] as? [String: Any])?["color"] as? [String: Any])?["_0"] as? [String: Any]

        var baseColors: [ArcColor] = []
        var overlayColors: [ArcColor] = []
        var modifiers: [String: Any]?

        if let gradient = (color?["blendedGradient"] as? [String: Any])?["_0"] as? [String: Any] {
            baseColors = (gradient["baseColors"] as? [Any] ?? []).compactMap { ArcColor(json: $0) }
            overlayColors = (gradient["overlayColors"] as? [Any] ?? []).compactMap { ArcColor(json: $0) }
            modifiers = gradient["modifiers"] as? [String: Any]
        } else if let solid = (color?["blendedSingleColor"] as? [String: Any])?["_0"] as? [String: Any] {
            if let single = ArcColor(json: solid["color"]) { baseColors = [single] }
            modifiers = solid["modifiers"] as? [String: Any]
        }

        if baseColors.isEmpty, let primaryShaded {
            baseColors = [primaryShaded]
        }
        guard !baseColors.isEmpty else { return nil }

        return ArcSpaceTheme(
            baseColors: baseColors,
            overlayColors: overlayColors,
            noiseFactor: double(modifiers?["noiseFactor"]) ?? 0,
            intensityFactor: double(modifiers?["intensityFactor"]) ?? 1,
            overlayTexture: modifiers?["overlay"] as? String,
            prefersDarkContent: prefersDark,
            primaryShaded: primaryShaded
        )
    }

    // MARK: JSON helpers

    static func double(_ json: Any?) -> Double? {
        if let number = json as? NSNumber { return number.doubleValue }
        if let value = json as? Double { return value }
        if let value = json as? Int { return Double(value) }
        return nil
    }
}

// MARK: - Archive

public struct ArcArchivedTab: Sendable, Hashable {
    public var tab: ArcTab
    public var archivedAt: Date
    public var reason: String?
    public var sourceSpaceID: UUID?

    public init(tab: ArcTab, archivedAt: Date, reason: String? = nil, sourceSpaceID: UUID? = nil) {
        self.tab = tab
        self.archivedAt = archivedAt
        self.reason = reason
        self.sourceSpaceID = sourceSpaceID
    }
}

/// StorableArchiveItems.json: same alternating-array encoding as the sidebar, but each object wraps a whole sidebar item: {sidebarItem, reason, archivedAt, source: {space: {_0: <spaceID>}}}. Archived folders are flattened to their tabs.
public enum ArcArchiveDocument {

    public static func parse(data: Data, browser: ImportableBrowser, limit: Int? = nil) throws -> [ArcArchivedTab] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BrowserImportError.unreadable(browser, reason: "StorableArchiveItems.json isn't valid JSON: \(error.localizedDescription)")
        }
        guard let root = json as? [String: Any] else {
            throw BrowserImportError.unreadable(browser, reason: "StorableArchiveItems.json's root isn't a JSON object.")
        }

        var archived: [ArcArchivedTab] = []
        for entry in ArcSidebarDocument.objects(in: root["items"]) {
            guard let itemJSON = entry["sidebarItem"] as? [String: Any] else { continue }
            guard let archivedAt = ArcSidebarDocument.double(entry["archivedAt"]) else { continue }

            var sourceSpaceID: UUID?
            if let space = (entry["source"] as? [String: Any])?["space"] as? [String: Any],
               let idString = space["_0"] as? String {
                sourceSpaceID = UUID(uuidString: idString)
            }

            guard let node = ArcSidebarDocument.archivedNode(from: itemJSON) else { continue }
            for tab in node.allTabs {
                archived.append(ArcArchivedTab(
                    tab: tab,
                    archivedAt: ImportSQLiteSnapshot.dateFromCFAbsoluteTime(archivedAt),
                    reason: entry["reason"] as? String,
                    sourceSpaceID: sourceSpaceID
                ))
            }
        }

        archived.sort { $0.archivedAt > $1.archivedAt }
        if let limit, archived.count > limit {
            archived = Array(archived.prefix(max(limit, 0)))
        }
        return archived
    }
}

extension ArcSidebarDocument {
    static func archivedNode(from item: [String: Any]) -> ArcSidebarItem? {
        node(from: item, itemsByID: [:], visited: [])
    }
}
