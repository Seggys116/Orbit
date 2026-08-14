import AppKit
import Foundation

// MARK: - Identifiers

public typealias ProfileID = UUID
public typealias SpaceID = UUID
public typealias TabID = UUID
public typealias FolderID = UUID
public typealias SpaceIconImageID = UUID

// MARK: - Search engine

nonisolated public enum SearchEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    case google
    case bing
    case duckDuckGo
    case ecosia

    public var id: String { rawValue }

    public static let fallback: SearchEngine = .google

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        case .ecosia: return "Ecosia"
        }
    }

    public var queryTemplate: String {
        switch self {
        case .google: return "https://www.google.com/search?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .duckDuckGo: return "https://duckduckgo.com/?q=%s"
        case .ecosia: return "https://www.ecosia.org/search?q=%s"
        }
    }

    public var suggestionsTemplate: String {
        switch self {
        case .google: return "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
        case .bing: return "https://api.bing.com/osjson.aspx?query=%s"
        case .duckDuckGo: return "https://duckduckgo.com/ac/?q=%s&type=list"
        case .ecosia: return "https://ac.ecosia.org/autocomplete?q=%s&type=list"
        }
    }

    public func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: queryTemplate.replacingOccurrences(of: "%s", with: encoded))
    }

    public func suggestionsURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: suggestionsTemplate.replacingOccurrences(of: "%s", with: encoded))
    }
}

// MARK: - Profile

nonisolated public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public var id: ProfileID
    public var name: String
    public var symbolName: String
    public var tint: ThemeColor
    public var isPersistent: Bool
    public var createdAt: Date
    public var searchEngine: SearchEngine
    public var includesSearchSuggestions: Bool
    public var archivePolicy: ArchivePolicy

    public init(
        id: ProfileID = UUID(),
        name: String,
        symbolName: String = "person.crop.circle",
        tint: ThemeColor = ThemeColor(red: 0.45, green: 0.42, blue: 0.95),
        isPersistent: Bool = true,
        createdAt: Date = Date(),
        searchEngine: SearchEngine = .fallback,
        includesSearchSuggestions: Bool = true,
        archivePolicy: ArchivePolicy = .after12Hours
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.tint = tint
        self.isPersistent = isPersistent
        self.createdAt = createdAt
        self.searchEngine = searchEngine
        self.includesSearchSuggestions = includesSearchSuggestions
        self.archivePolicy = archivePolicy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, tint, isPersistent, createdAt
        case searchEngine, includesSearchSuggestions, archivePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProfileID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "person.crop.circle"
        tint = try container.decodeIfPresent(ThemeColor.self, forKey: .tint)
            ?? ThemeColor(red: 0.45, green: 0.42, blue: 0.95)
        isPersistent = try container.decodeIfPresent(Bool.self, forKey: .isPersistent) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        searchEngine = (try? container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine))
            .flatMap { $0 } ?? .fallback
        includesSearchSuggestions = try container.decodeIfPresent(Bool.self, forKey: .includesSearchSuggestions) ?? true
        archivePolicy = (try? container.decodeIfPresent(ArchivePolicy.self, forKey: .archivePolicy))
            .flatMap { $0 } ?? .after12Hours
    }

    public var sessionIdentifier: String { id.uuidString }
}

// MARK: - Colour & theme

nonisolated public struct ThemeColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        self.init(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent),
            alpha: Double(rgb.alphaComponent)
        )
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    public func composited(over base: ThemeColor) -> ThemeColor {
        let a = min(max(alpha, 0), 1)
        guard a < 1 else {
            return ThemeColor(red: red, green: green, blue: blue, alpha: 1)
        }
        return ThemeColor(
            red: red * a + base.red * (1 - a),
            green: green * a + base.green * (1 - a),
            blue: blue * a + base.blue * (1 - a),
            alpha: 1
        )
    }

    // MARK: - Contrast

    public var relativeLuminance: Double {
        func linearise(_ component: Double) -> Double {
            let c = min(max(component, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearise(red) + 0.7152 * linearise(green) + 0.0722 * linearise(blue)
    }

    public func contrastRatio(against other: ThemeColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public var opaque: ThemeColor {
        alpha >= 1 ? self : ThemeColor(red: red, green: green, blue: blue, alpha: 1)
    }

    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    public func withBrightness(_ brightness: Double, saturation: Double? = nil) -> ThemeColor {
        let current = hsb
        let color = NSColor(
            hue: CGFloat(current.hue),
            saturation: CGFloat(min(max(saturation ?? current.saturation, 0), 1)),
            brightness: CGFloat(min(max(brightness, 0), 1)),
            alpha: CGFloat(alpha)
        )
        return ThemeColor(color)
    }
}

nonisolated public struct ThemeStopPosition: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

nonisolated public struct SpaceTheme: Codable, Hashable, Sendable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        case solid
        case linear
        case mesh
    }

    public var style: Style
    public var colors: [ThemeColor]
    public var angle: Double
    public var grain: Double
    public var followsSystemAppearance: Bool
    public var prefersDarkContent: Bool
    public var stopPositions: [ThemeStopPosition]?

    public init(
        style: Style = .mesh,
        colors: [ThemeColor] = SpaceTheme.defaultPalette,
        angle: Double = 18,
        grain: Double = 0.5,
        followsSystemAppearance: Bool = true,
        prefersDarkContent: Bool = false,
        stopPositions: [ThemeStopPosition]? = nil
    ) {
        self.style = style
        self.colors = colors
        self.angle = angle
        self.grain = grain
        self.followsSystemAppearance = followsSystemAppearance
        self.prefersDarkContent = prefersDarkContent
        self.stopPositions = stopPositions
    }

    public static let defaultPalette: [ThemeColor] = [
        ThemeColor(red: 0.1725, green: 0.1569, blue: 0.2039),
        ThemeColor(red: 0.2078, green: 0.1804, blue: 0.2353),
    ]

    public var primary: ThemeColor { colors.first ?? SpaceTheme.defaultPalette[0] }

    public var resolvedStopPositions: [ThemeStopPosition] {
        let defaults = SpaceTheme.defaultStopPositions(count: colors.count)
        guard let stopPositions, !stopPositions.isEmpty else { return defaults }
        guard stopPositions.count != colors.count else { return stopPositions }
        return defaults.enumerated().map { index, fallback in
            index < stopPositions.count ? stopPositions[index] : fallback
        }
    }

    public static func defaultStopPositions(count: Int) -> [ThemeStopPosition] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [ThemeStopPosition(x: 0.5, y: 0.44)] }
        return (0..<count).map { i in
            let y = 0.26 + (0.56 * Double(i) / Double(count - 1))
            let x = 0.42 + 0.16 * sin(Double(i) * 1.9)
            return ThemeStopPosition(
                x: min(max(x, 0.12), 0.88),
                y: min(max(y, 0.12), 0.88)
            )
        }
    }

    public mutating func normalizeStopPositions() {
        guard let stopPositions, stopPositions.count != colors.count else { return }
        self.stopPositions = resolvedStopPositions
    }

    public static func clampedStopIndex(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }

    public mutating func applyPalette(_ palette: [ThemeColor]) {
        colors = palette
        stopPositions = nil
    }

    public mutating func setColor(_ color: ThemeColor, atStop index: Int) {
        guard colors.indices.contains(index) else { return }
        colors[index] = color
    }
}

// MARK: - Space icon

nonisolated public enum SpaceIconKind: String, Codable, Sendable, CaseIterable {
    case none
    case emoji
    case symbol
    case image
}

nonisolated public enum SpaceIcon: Hashable, Sendable {
    case none
    case emoji(String)
    case symbol(String)
    case image(SpaceIconImageID)
}

// MARK: - Space

nonisolated public struct Space: Identifiable, Codable, Hashable, Sendable {
    public var id: SpaceID
    public var name: String
    public var icon: String
    public var iconIsEmoji: Bool
    public var iconKind: SpaceIconKind?
    public var iconImageID: SpaceIconImageID?
    public var theme: SpaceTheme
    public var profileID: ProfileID
    public var order: Int
    public var favorites: [Favorite]
    public var pinned: [SidebarNode]
    public var today: [TabID]
    public var createdAt: Date

    public var legacyArchivePolicy: String?

    public var pinnedSectionCollapsed: Bool?

    public var isPinnedSectionCollapsed: Bool {
        get { pinnedSectionCollapsed ?? false }
        set { pinnedSectionCollapsed = newValue }
    }

    // Optional (nil == false), not a plain Bool, so a state.json written before this field existed still decodes.
    public var ephemeral: Bool?

    public var isEphemeral: Bool {
        get { ephemeral ?? false }
        set { ephemeral = newValue }
    }

    public var githubLiveFolder: GitHubLiveFolderConfig?

    public init(
        id: SpaceID = UUID(),
        name: String,
        icon: String = "circle.grid.2x2",
        iconIsEmoji: Bool = false,
        iconKind: SpaceIconKind? = nil,
        iconImageID: SpaceIconImageID? = nil,
        theme: SpaceTheme = SpaceTheme(),
        profileID: ProfileID,
        order: Int = 0,
        favorites: [Favorite] = [],
        pinned: [SidebarNode] = [],
        today: [TabID] = [],
        createdAt: Date = Date(),
        isEphemeral: Bool = false,
        legacyArchivePolicy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.iconIsEmoji = iconIsEmoji
        self.iconKind = iconKind
        self.iconImageID = iconImageID
        self.theme = theme
        self.profileID = profileID
        self.order = order
        self.favorites = favorites
        self.pinned = pinned
        self.today = today
        self.createdAt = createdAt
        self.ephemeral = isEphemeral ? true : nil
        self.legacyArchivePolicy = legacyArchivePolicy
    }

    // MARK: - The four-case icon model

    public var resolvedIcon: SpaceIcon {
        guard let iconKind else {
            return iconIsEmoji ? .emoji(icon) : .symbol(icon)
        }
        switch iconKind {
        case .none: return .none
        case .emoji: return .emoji(icon)
        case .symbol: return .symbol(icon)
        case .image:
            guard let iconImageID else {
                return .none
            }
            return .image(iconImageID)
        case nil:
            return iconIsEmoji ? .emoji(icon) : .symbol(icon)
        }
    }

    public mutating func setIcon(emoji: String) {
        icon = emoji
        iconIsEmoji = true
        iconKind = .emoji
        iconImageID = nil
    }

    public mutating func setIcon(symbol: String) {
        icon = symbol
        iconIsEmoji = false
        iconKind = .symbol
        iconImageID = nil
    }

    public mutating func setIconToNone() {
        iconKind = SpaceIconKind.none
        iconImageID = nil
    }

    public mutating func setIcon(imageID: SpaceIconImageID) {
        iconKind = .image
        self.iconImageID = imageID
    }

    public mutating func apply(_ icon: SpaceIcon) {
        switch icon {
        case .none: setIconToNone()
        case .emoji(let value): setIcon(emoji: value)
        case .symbol(let value): setIcon(symbol: value)
        case .image(let imageID): setIcon(imageID: imageID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, iconIsEmoji, iconKind, iconImageID, theme, profileID, order
        case favorites, pinned, today, createdAt
        case pinnedSectionCollapsed, ephemeral, githubLiveFolder
        case legacyArchivePolicy = "archivePolicy"
    }
}

nonisolated public enum ArchivePolicy: String, Codable, Sendable, CaseIterable {
    case never
    case after12Hours
    case after24Hours
    case after7Days
    case after30Days

    public var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .after12Hours: return 12 * 3600
        case .after24Hours: return 24 * 3600
        case .after7Days: return 7 * 24 * 3600
        case .after30Days: return 30 * 24 * 3600
        }
    }

    public var menuTitle: String {
        switch self {
        case .never: return "Never"
        case .after12Hours: return "After 12 Hours"
        case .after24Hours: return "After 24 Hours"
        case .after7Days: return "After 7 Days"
        case .after30Days: return "After 30 Days"
        }
    }
}

// MARK: - Favourites

nonisolated public struct Favorite: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var customIcon: String?
    public var customIconIsEmoji: Bool
    public var liveTabID: TabID?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        customIcon: String? = nil,
        customIconIsEmoji: Bool = false,
        liveTabID: TabID? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.customIcon = customIcon
        self.customIconIsEmoji = customIconIsEmoji
        self.liveTabID = liveTabID
    }
}

// MARK: - Sidebar tree

nonisolated public indirect enum SidebarNode: Identifiable, Codable, Hashable, Sendable {
    case tab(TabID)
    case folder(Folder)

    public var id: UUID {
        switch self {
        case .tab(let id): return id
        case .folder(let folder): return folder.id
        }
    }

    public var allTabIDs: [TabID] {
        switch self {
        case .tab(let id): return [id]
        case .folder(let folder): return folder.children.flatMap(\.allTabIDs)
        }
    }
}

// A snapshot of one ancestor folder's identity/name/icon, captured at archive time so the
// Archive view can rebuild the nesting a tab was in without needing the live pinned tree.
nonisolated public struct ArchivedFolderCrumb: Codable, Hashable, Sendable {
    public var id: FolderID
    public var name: String
    public var icon: String?
    public var iconIsEmoji: Bool

    public init(id: FolderID, name: String, icon: String? = nil, iconIsEmoji: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.iconIsEmoji = iconIsEmoji
    }
}

nonisolated public struct Folder: Identifiable, Codable, Hashable, Sendable {
    public var id: FolderID
    public var name: String
    public var isExpanded: Bool
    public var children: [SidebarNode]
    public var icon: String?
    public var iconIsEmoji: Bool

    public init(
        id: FolderID = UUID(),
        name: String,
        isExpanded: Bool = true,
        children: [SidebarNode] = [],
        icon: String? = nil,
        iconIsEmoji: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.children = children
        self.icon = icon
        self.iconIsEmoji = iconIsEmoji
    }

    public var allTabIDs: [TabID] {
        children.flatMap(\.allTabIDs)
    }

    public var allDescendantFolders: [Folder] {
        children.flatMap { node -> [Folder] in
            guard case .folder(let child) = node else { return [] }
            return [child] + child.allDescendantFolders
        }
    }
}

// MARK: - Tab

nonisolated public enum TabSection: String, Codable, Sendable {
    case favorite
    case pinned
    case today
    case archived
}

nonisolated public struct Tab: Identifiable, Codable, Hashable, Sendable {
    public var id: TabID
    public var spaceID: SpaceID
    public var section: TabSection

    public var url: URL
    public var title: String
    public var customTitle: String?
    public var faviconURL: URL?

    public var lastAccessedAt: Date
    public var createdAt: Date
    public var archivedAt: Date?

    public var isUnloaded: Bool
    public var isMuted: Bool
    public var zoomFactor: Double?

    public var splitGroupID: UUID?
    public var splitIndex: Int

    public var pinnedURL: URL?

    public var pinnedTitle: String?

    public var tidiedTitle: String?

    public var tidyGroup: String?

    // Root-to-parent chain of the pinned folder this tab lived in when archived, deepest last.
    // Empty/nil means it was a top-level or Today tab. Lets the Archive view rebuild folder
    // nesting even after the tab has been structurally removed from the live pinned tree.
    public var archivedFolderTrail: [ArchivedFolderCrumb]?

    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let tidiedTitle, !tidiedTitle.isEmpty { return tidiedTitle }
        if !title.isEmpty { return title }
        return url.host() ?? url.absoluteString
    }

    public var hasNavigatedAwayFromPinnedURL: Bool {
        guard section == .pinned, let pinnedURL else { return false }
        return Tab.normalizedForPinnedComparison(url) != Tab.normalizedForPinnedComparison(pinnedURL)
    }

    static func normalizedForPinnedComparison(_ url: URL) -> String {
        let absolute = url.absoluteString
        guard absolute.hasSuffix("/"), absolute.count > 1 else { return absolute }
        return String(absolute.dropLast())
    }

    public init(
        id: TabID = UUID(),
        spaceID: SpaceID,
        section: TabSection = .today,
        url: URL,
        title: String = "",
        customTitle: String? = nil,
        faviconURL: URL? = nil,
        lastAccessedAt: Date = Date(),
        createdAt: Date = Date(),
        archivedAt: Date? = nil,
        isUnloaded: Bool = false,
        isMuted: Bool = false,
        zoomFactor: Double? = nil,
        splitGroupID: UUID? = nil,
        splitIndex: Int = 0,
        pinnedURL: URL? = nil,
        pinnedTitle: String? = nil,
        tidiedTitle: String? = nil,
        tidyGroup: String? = nil,
        archivedFolderTrail: [ArchivedFolderCrumb]? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.section = section
        self.url = url
        self.title = title
        self.customTitle = customTitle
        self.faviconURL = faviconURL
        self.lastAccessedAt = lastAccessedAt
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.isUnloaded = isUnloaded
        self.isMuted = isMuted
        self.zoomFactor = zoomFactor
        self.splitGroupID = splitGroupID
        self.splitIndex = splitIndex
        self.pinnedURL = pinnedURL
        self.pinnedTitle = pinnedTitle
        self.tidiedTitle = tidiedTitle
        self.tidyGroup = tidyGroup
        self.archivedFolderTrail = archivedFolderTrail
    }

}

// MARK: - History

nonisolated public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var visitedAt: Date
    public var visitCount: Int
    public var profileID: ProfileID
    public var spaceID: SpaceID?
    public var wasTyped: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        visitedAt: Date = Date(),
        visitCount: Int = 1,
        profileID: ProfileID,
        spaceID: SpaceID? = nil,
        wasTyped: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.visitCount = visitCount
        self.profileID = profileID
        self.spaceID = spaceID
        self.wasTyped = wasTyped
    }
}

// MARK: - Downloads

nonisolated public struct DownloadItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceURL: URL
    public var destinationURL: URL
    public var suggestedFileName: String
    public var mimeType: String
    public var totalBytes: Int64
    public var receivedBytes: Int64
    public var state: DownloadState
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        destinationURL: URL,
        suggestedFileName: String,
        mimeType: String = "",
        totalBytes: Int64 = 0,
        receivedBytes: Int64 = 0,
        state: DownloadState = .pending,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.suggestedFileName = suggestedFileName
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

// MARK: - Boosts

nonisolated public enum BoostTextCase: String, Codable, Sendable, CaseIterable {
    case original
    case uppercase
    case lowercase
    case capitalize

    public var buttonLabel: String {
        switch self {
        case .original: return "Case"
        case .uppercase: return "AA"
        case .lowercase: return "aa"
        case .capitalize: return "Aa"
        }
    }

    public var next: BoostTextCase {
        let all = BoostTextCase.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

nonisolated public struct Boost: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var isEnabled: Bool

    public var zappedSelectors: [String]
    public var customCSS: String
    public var customJavaScript: String

    public var backgroundColor: ThemeColor?
    public var textColor: ThemeColor?
    public var accentColor: ThemeColor?
    public var fontFamily: String?

    // MARK: Arc's visual Boost controls

    public var invertLightness: Bool

    public var contrast: Double

    public var brightness: Double

    public var saturation: Double

    public var pageSizeScale: Double

    public var textCase: BoostTextCase

    public var createdAt: Date
    public var updatedAt: Date

    public static let pageSizeScaleLadder: [Double] = [0.9, 1.0, 1.1, 1.25, 1.5]

    public static let pageSizeScaleRange: ClosedRange<Double> = 0.9...1.5

    public static let colorAdjustmentRange: ClosedRange<Double> = 0...2

    public var nextPageSizeScale: Double {
        let ladder = Boost.pageSizeScaleLadder
        let currentIndex = ladder.indices.min(by: {
            abs(ladder[$0] - pageSizeScale) < abs(ladder[$1] - pageSizeScale)
        }) ?? 0
        return ladder[(currentIndex + 1) % ladder.count]
    }

    public var pageSizeButtonLabel: String {
        pageSizeScale == 1.0 ? "Size" : "\(Int((pageSizeScale * 100).rounded()))%"
    }

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        isEnabled: Bool = true,
        zappedSelectors: [String] = [],
        customCSS: String = "",
        customJavaScript: String = "",
        backgroundColor: ThemeColor? = nil,
        textColor: ThemeColor? = nil,
        accentColor: ThemeColor? = nil,
        fontFamily: String? = nil,
        invertLightness: Bool = false,
        contrast: Double = 1.0,
        brightness: Double = 1.0,
        saturation: Double = 1.0,
        pageSizeScale: Double = 1.0,
        textCase: BoostTextCase = .original,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.isEnabled = isEnabled
        self.zappedSelectors = zappedSelectors
        self.customCSS = customCSS
        self.customJavaScript = customJavaScript
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.accentColor = accentColor
        self.fontFamily = fontFamily
        self.invertLightness = invertLightness
        self.contrast = contrast
        self.brightness = brightness
        self.saturation = saturation
        self.pageSizeScale = pageSizeScale
        self.textCase = textCase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, isEnabled
        case zappedSelectors, customCSS, customJavaScript
        case backgroundColor, textColor, accentColor, fontFamily
        case invertLightness, contrast, brightness, saturation, pageSizeScale, textCase
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

        zappedSelectors = try container.decodeIfPresent([String].self, forKey: .zappedSelectors) ?? []
        customCSS = try container.decodeIfPresent(String.self, forKey: .customCSS) ?? ""
        customJavaScript = try container.decodeIfPresent(String.self, forKey: .customJavaScript) ?? ""

        backgroundColor = try container.decodeIfPresent(ThemeColor.self, forKey: .backgroundColor)
        textColor = try container.decodeIfPresent(ThemeColor.self, forKey: .textColor)
        accentColor = try container.decodeIfPresent(ThemeColor.self, forKey: .accentColor)
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)

        invertLightness = try container.decodeIfPresent(Bool.self, forKey: .invertLightness) ?? false
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1.0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        pageSizeScale = try container.decodeIfPresent(Double.self, forKey: .pageSizeScale) ?? 1.0
        textCase = try container.decodeIfPresent(BoostTextCase.self, forKey: .textCase) ?? .original

        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public var hasDefaultVisualAdjustments: Bool {
        !invertLightness
            && contrast == 1.0
            && brightness == 1.0
            && saturation == 1.0
            && backgroundColor == nil
            && textColor == nil
            && accentColor == nil
    }

    public mutating func resetToOriginalColors() {
        invertLightness = false
        contrast = 1.0
        brightness = 1.0
        saturation = 1.0
        backgroundColor = nil
        textColor = nil
        accentColor = nil
    }
}

// MARK: - Easel

nonisolated public struct Easel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var items: [EaselItem]
    public var createdAt: Date
    public var updatedAt: Date
    public var viewportOrigin: CGPoint
    public var viewportZoom: Double

    public init(
        id: UUID = UUID(),
        title: String = "Untitled Easel",
        items: [EaselItem] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        viewportOrigin: CGPoint = .zero,
        viewportZoom: Double = 1.0
    ) {
        self.id = id
        self.title = title
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.viewportOrigin = viewportOrigin
        self.viewportZoom = viewportZoom
    }
}

nonisolated public struct EaselItem: Identifiable, Codable, Hashable, Sendable {
    nonisolated public enum ShapeKind: String, Codable, Hashable, Sendable {
        case ellipse
        case rectangle
        case arrow
    }

    public enum Content: Codable, Hashable, Sendable {
        case text(String)
        case liveWebRegion(url: URL, selector: String?, cropRect: CGRect)
        case image(fileName: String)
        case drawing(points: [CGPoint], color: ThemeColor, width: Double)
        case link(url: URL, title: String)
        case shape(kind: ShapeKind, color: ThemeColor, lineWidth: Double, unitStart: CGPoint, unitEnd: CGPoint)
    }

    public var id: UUID
    public var frame: CGRect
    public var rotation: Double
    public var content: Content
    public var zIndex: Int

    public init(
        id: UUID = UUID(),
        frame: CGRect,
        rotation: Double = 0,
        content: Content,
        zIndex: Int = 0
    ) {
        self.id = id
        self.frame = frame
        self.rotation = rotation
        self.content = content
        self.zIndex = zIndex
    }
}

// MARK: - Notes

nonisolated public struct Note: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var bodyData: Data
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "Untitled Note",
        bodyData: Data = Data(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.bodyData = bodyData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Air Traffic Control

nonisolated public struct RoutingRule: Identifiable, Codable, Hashable, Sendable {
    public enum Destination: Codable, Hashable, Sendable {
        case space(SpaceID)
        case profile(ProfileID)
        case application(bundleID: String)
        case littleOrbit
        case mostRecentSpace
    }

    public var id: UUID
    public var pattern: String
    public var destination: Destination
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        pattern: String,
        destination: Destination,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.destination = destination
        self.isEnabled = isEnabled
    }
}

// MARK: - Split view

nonisolated public struct SplitGroup: Identifiable, Codable, Hashable, Sendable {
    public static let maximumPanes = 4

    public enum Axis: String, Codable, Sendable {
        case horizontal
        case vertical
    }

    public var id: UUID
    public var tabIDs: [TabID]
    public var fractions: [Double]
    public var axis: Axis

    public init(
        id: UUID = UUID(),
        tabIDs: [TabID],
        fractions: [Double]? = nil,
        axis: Axis = .horizontal
    ) {
        self.id = id
        self.tabIDs = tabIDs
        self.axis = axis
        let count = max(tabIDs.count, 1)
        self.fractions = fractions ?? Array(repeating: 1.0 / Double(count), count: count)
    }

    private enum CodingKeys: String, CodingKey {
        case id, tabIDs, fractions, axis
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tabIDs = try container.decode([TabID].self, forKey: .tabIDs)
        fractions = try container.decode([Double].self, forKey: .fractions)
        axis = try container.decodeIfPresent(Axis.self, forKey: .axis) ?? .horizontal
    }
}

// MARK: - Persisted root

nonisolated public struct OrbitState: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profiles: [Profile]
    public var spaces: [Space]
    public var tabs: [TabID: Tab]
    public var splitGroups: [UUID: SplitGroup]
    public var boosts: [Boost]
    public var easels: [Easel]
    public var notes: [Note]
    public var routingRules: [RoutingRule]
    public var activeSpaceID: SpaceID?
    public var activeTabBySpace: [SpaceID: TabID]

    public init(
        schemaVersion: Int = OrbitState.currentSchemaVersion,
        profiles: [Profile] = [],
        spaces: [Space] = [],
        tabs: [TabID: Tab] = [:],
        splitGroups: [UUID: SplitGroup] = [:],
        boosts: [Boost] = [],
        easels: [Easel] = [],
        notes: [Note] = [],
        routingRules: [RoutingRule] = [],
        activeSpaceID: SpaceID? = nil,
        activeTabBySpace: [SpaceID: TabID] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.spaces = spaces
        self.tabs = tabs
        self.splitGroups = splitGroups
        self.boosts = boosts
        self.easels = easels
        self.notes = notes
        self.routingRules = routingRules
        self.activeSpaceID = activeSpaceID
        self.activeTabBySpace = activeTabBySpace
    }
}

// MARK: - Ephemeral (Incognito) entities

public extension OrbitState {

    static func isEphemeral(_ profile: Profile) -> Bool { !profile.isPersistent }

    static func looksIncognitoSeeded(_ space: Space) -> Bool {
        space.name == "Incognito" && space.icon == "eyeglasses" && !space.iconIsEmoji
    }

    // Called at every persistence write; an ephemeral (Incognito) Profile/Space must never reach state.json. A Space not recognisably Incognito-seeded is reassigned, never deleted.
    func strippingEphemeralEntities() -> OrbitState {
        let ephemeralProfileIDs = Set(profiles.filter { OrbitState.isEphemeral($0) }.map(\.id))
        let spaceIDsToDrop = Set(
            spaces
                .filter { $0.isEphemeral || (ephemeralProfileIDs.contains($0.profileID) && OrbitState.looksIncognitoSeeded($0)) }
                .map(\.id)
        )
        guard !ephemeralProfileIDs.isEmpty || !spaceIDsToDrop.isEmpty else { return self }

        let replacementProfileID = profiles
            .filter { !OrbitState.isEphemeral($0) }
            .min(by: { $0.createdAt < $1.createdAt })?
            .id
        guard let replacementProfileID else { return self }

        var stripped = self
        stripped.profiles.removeAll { ephemeralProfileIDs.contains($0.id) }
        stripped.spaces.removeAll { spaceIDsToDrop.contains($0.id) }
        for index in stripped.spaces.indices where ephemeralProfileIDs.contains(stripped.spaces[index].profileID) {
            stripped.spaces[index].profileID = replacementProfileID
        }
        for index in stripped.spaces.indices where stripped.spaces[index].isEphemeral {
            stripped.spaces[index].ephemeral = nil
        }

        var droppedSplitGroupIDs: Set<UUID> = []
        for (tabID, tab) in tabs where spaceIDsToDrop.contains(tab.spaceID) {
            if let groupID = tab.splitGroupID { droppedSplitGroupIDs.insert(groupID) }
            stripped.tabs.removeValue(forKey: tabID)
        }
        for groupID in droppedSplitGroupIDs {
            stripped.splitGroups.removeValue(forKey: groupID)
        }
        for spaceID in spaceIDsToDrop {
            stripped.activeTabBySpace.removeValue(forKey: spaceID)
        }

        if let activeSpaceID, spaceIDsToDrop.contains(activeSpaceID) {
            stripped.activeSpaceID = stripped.spaces.min(by: { $0.order < $1.order })?.id
        }

        return stripped
    }
}

// MARK: - Sidebar membership repair

public extension OrbitState {

    /// The content pane renders `activeTabBySpace` while the sidebar renders `Space.today`, so a tab that falls out of `today` alone becomes a page with no row. Returns nil when nothing needed repairing.
    func repairingSidebarMembership() -> OrbitState? {
        var repaired = self
        var changed = false

        var todayTabsBySpace: [SpaceID: [Tab]] = [:]
        for tab in tabs.values where tab.section == .today {
            todayTabsBySpace[tab.spaceID, default: []].append(tab)
        }

        for index in repaired.spaces.indices {
            let spaceID = repaired.spaces[index].id
            var contained = Set(repaired.spaces[index].today)
                .union(repaired.spaces[index].pinned.flatMap(\.allTabIDs))

            let orphans = (todayTabsBySpace[spaceID] ?? [])
                .filter { !contained.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
            for orphan in orphans {
                repaired.spaces[index].today.append(orphan.id)
                contained.insert(orphan.id)
                changed = true
            }

            guard let activeID = repaired.activeTabBySpace[spaceID],
                  let active = repaired.tabs[activeID],
                  active.spaceID == spaceID,
                  !contained.contains(activeID)
            else { continue }
            repaired.tabs[activeID]?.section = .today
            repaired.tabs[activeID]?.archivedAt = nil
            repaired.tabs[activeID]?.isUnloaded = false
            repaired.spaces[index].today.append(activeID)
            changed = true
        }

        return changed ? repaired : nil
    }
}

// MARK: - Demo fixture

public extension OrbitState {

    static var demo: OrbitState {
        // MARK: Profiles
        let personal = Profile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Personal",
            symbolName: "person.crop.circle",
            tint: ThemeColor(red: 0.55, green: 0.40, blue: 0.92),
            isPersistent: true,
            createdAt: Date().addingTimeInterval(-3600 * 24 * 365),
            archivePolicy: .after12Hours
        )
        let work = Profile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Work",
            symbolName: "briefcase.fill",
            tint: ThemeColor(red: 0.20, green: 0.55, blue: 0.95),
            isPersistent: true,
            createdAt: Date().addingTimeInterval(-3600 * 24 * 200),
            archivePolicy: .after24Hours
        )
        let travel = Profile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Travel",
            symbolName: "airplane",
            tint: ThemeColor(red: 0.95, green: 0.55, blue: 0.20),
            isPersistent: true,
            createdAt: Date().addingTimeInterval(-3600 * 24 * 90),
            archivePolicy: .after30Days
        )

        // MARK: Tab UUIDs (deterministic)
        let githubPRTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let figmaFileTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let linearTicketTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let orbitNoteTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let orbitEaselTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        let httpsArticleTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        let archivedPersonalTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000007")!

        let readingArticle1ID = UUID(uuidString: "10000000-0000-0000-0000-000000000011")!
        let readingArticle2ID = UUID(uuidString: "10000000-0000-0000-0000-000000000012")!
        let readingArticle3ID = UUID(uuidString: "10000000-0000-0000-0000-000000000013")!

        let readingFolderChild1ID = UUID(uuidString: "10000000-0000-0000-0000-000000000021")!
        let readingFolderChild2ID = UUID(uuidString: "10000000-0000-0000-0000-000000000022")!
        let readingFolderChild3ID = UUID(uuidString: "10000000-0000-0000-0000-000000000023")!
        let readingFolderStandaloneID = UUID(uuidString: "10000000-0000-0000-0000-000000000024")!

        let workQ4Child1ID = UUID(uuidString: "10000000-0000-0000-0000-000000000031")!
        let workQ4Child2ID = UUID(uuidString: "10000000-0000-0000-0000-000000000032")!

        let workFigmaTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000041")!
        let workLinearTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000042")!
        let workNotionTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000043")!
        let workSlackTabID = UUID(uuidString: "10000000-0000-0000-0000-000000000044")!

        let travelArchive1ID = UUID(uuidString: "10000000-0000-0000-0000-000000000061")!

        // MARK: URLs
        let githubURL = URL(string: "https://github.com/anthropics/anthropic-sdk-python/pull/482")!
        let figmaURL = URL(string: "https://www.figma.com/file/OrbitDemo/Q4-Roadmap")!
        let linearURL = URL(string: "https://linear.app/orbit-demo/issue/ORB-1284")!
        let articleURL = URL(string: "https://developer.apple.com/documentation/swift/applying-macros")!
        let linearCycleURL = URL(string: "https://linear.app/orbit-demo/cycle/2024-Q4")!
        let notionDocURL = URL(string: "https://www.notion.so/orbit-demo/Launch-Checklist")!
        let slackURL = URL(string: "https://orbit-demo.slack.com/archives/C0GENERAL")!

        let readingArticle1URL = URL(string: "https://practicaltypography.com/typography-in-ten-minutes.html")!
        let readingArticle2URL = URL(string: "https://developer.mozilla.org/en-US/docs/Web/Performance/Guides/How_browsers_work")!
        let readingArticle3URL = URL(string: "https://css-tricks.com/the-lengths-of-css/")!

        let readingFolderChild1URL = URL(string: "https://www.thepunctuationguide.com/em-dash.html")!
        let readingFolderChild2URL = URL(string: "https://developer.apple.com/documentation/swiftui/layout")!
        let readingFolderChild3URL = URL(string: "https://en.wikipedia.org/wiki/Arrow_(symbol)")!
        let readingFolderStandaloneURL = URL(string: "https://www.smashingmagazine.com/design-systems-book/")!
        let archivedArticleURL = URL(string: "https://en.wikipedia.org/wiki/Aqua_(user_interface)")!

        let workQ4Child1URL = URL(string: "https://www.figma.com/file/OrbitDemo/Q4-Roadmap")!
        let workQ4Child2URL = URL(string: "https://linear.app/orbit-demo/issue/ORB-1200")!

        let airbnbURL = URL(string: "https://www.airbnb.com")!
        let googleMapsURL = URL(string: "https://maps.google.com")!
        let travelSearchURL = URL(string: "https://www.skyscanner.net")!
        let travelArchive1URL = URL(string: "https://www.airbnb.com/rooms/12345")!

        let orbitNoteID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let orbitEaselID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

        // MARK: Spaces
        let personalSpace = Space(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Personal",
            icon: "circle.grid.2x2",
            iconIsEmoji: false,
            theme: SpaceTheme(
                style: .mesh,
                colors: [
                    ThemeColor(red: 0.35, green: 0.20, blue: 0.55),
                    ThemeColor(red: 0.55, green: 0.30, blue: 0.75),
                    ThemeColor(red: 0.85, green: 0.50, blue: 0.85),
                ],
                angle: 18,
                grain: 0.35
            ),
            profileID: personal.id,
            order: 0,
            favorites: [
                Favorite(url: URL(string: "https://www.google.com")!, title: "Google", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://www.apple.com")!, title: "Apple", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://en.wikipedia.org")!, title: "Wikipedia", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://news.ycombinator.com")!, title: "Hacker News", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://www.reddit.com")!, title: "Reddit", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://www.nytimes.com")!, title: "NYTimes", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://www.youtube.com")!, title: "YouTube", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://mail.google.com")!, title: "Gmail", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
            ],
            pinned: [
                .folder(Folder(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                    name: "Reading",
                    isExpanded: true,
                    children: [
                        .tab(readingFolderChild1ID),
                        .tab(readingFolderChild2ID),
                        .tab(readingFolderChild3ID),
                    ],
                    icon: "books.vertical",
                    iconIsEmoji: false
                )),
                .tab(readingFolderStandaloneID),
            ],
            today: [githubPRTabID, figmaFileTabID, linearTicketTabID, orbitNoteTabID, orbitEaselTabID, httpsArticleTabID],
            createdAt: Date().addingTimeInterval(-3600 * 24 * 365)
        )

        let readingSpace = Space(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "Reading",
            icon: "book.closed",
            iconIsEmoji: false,
            theme: SpaceTheme(
                style: .solid,
                colors: [
                    ThemeColor(red: 0.85, green: 0.78, blue: 0.68),
                    ThemeColor(red: 0.62, green: 0.50, blue: 0.45),
                ],
                angle: 12,
                grain: 0.30
            ),
            profileID: personal.id,
            order: 1,
            favorites: [
                Favorite(url: readingArticle1URL, title: "Typography", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: readingArticle2URL, title: "MDN", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: readingFolderChild3URL, title: "Arrows", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: readingFolderStandaloneURL, title: "Smashing", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
            ],
            pinned: [],
            today: [readingArticle1ID, readingArticle2ID, readingArticle3ID],
            createdAt: Date().addingTimeInterval(-3600 * 24 * 300)
        )

        let workSpace = Space(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            name: "Work",
            icon: "briefcase.fill",
            iconIsEmoji: false,
            theme: SpaceTheme(
                style: .linear,
                colors: [
                    ThemeColor(red: 0.15, green: 0.50, blue: 0.95),
                    ThemeColor(red: 0.30, green: 0.85, blue: 0.95),
                ],
                angle: 160,
                grain: 0.20
            ),
            profileID: work.id,
            order: 2,
            favorites: [
                Favorite(url: URL(string: "https://mail.google.com")!, title: "Gmail", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://github.com")!, title: "GitHub", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://www.figma.com")!, title: "Figma", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://linear.app")!, title: "Linear", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://www.notion.so")!, title: "Notion", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: URL(string: "https://www.youtube.com")!, title: "YouTube", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
            ],
            pinned: [
                .folder(Folder(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                    name: "Q4 Launches",
                    isExpanded: true,
                    children: [
                        .tab(workQ4Child1ID),
                        .tab(workQ4Child2ID),
                    ],
                    icon: "paperplane.fill",
                    iconIsEmoji: false
                )),
            ],
            today: [workFigmaTabID, workLinearTabID, workNotionTabID, workSlackTabID],
            createdAt: Date().addingTimeInterval(-3600 * 24 * 200)
        )

        let travelSpace = Space(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000004")!,
            name: "Travel",
            icon: "airplane",
            iconIsEmoji: false,
            theme: SpaceTheme(
                style: .solid,
                colors: [
                    ThemeColor(red: 0.95, green: 0.55, blue: 0.20),
                    ThemeColor(red: 0.95, green: 0.35, blue: 0.20),
                ],
                angle: 24,
                grain: 0.25
            ),
            profileID: travel.id,
            order: 3,
            favorites: [
                Favorite(url: airbnbURL, title: "Airbnb", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: googleMapsURL, title: "Maps", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
                Favorite(url: travelSearchURL, title: "Skyscanner", customIcon: nil, customIconIsEmoji: false, liveTabID: nil),
            ],
            pinned: [],
            today: [],
            createdAt: Date().addingTimeInterval(-3600 * 24 * 90)
        )

        // MARK: Tabs
        var tabs: [TabID: Tab] = [:]

        tabs[githubPRTabID] = Tab(
            id: githubPRTabID,
            spaceID: personalSpace.id,
            section: .today,
            url: githubURL,
            title: "PR #482 — anthropic-sdk-python: streaming tool use",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 18),
            createdAt: Date().addingTimeInterval(-3600 * 30),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[figmaFileTabID] = Tab(
            id: figmaFileTabID,
            spaceID: personalSpace.id,
            section: .today,
            url: figmaURL,
            title: "Q4 Roadmap — Figma",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 2),
            createdAt: Date().addingTimeInterval(-3600 * 24),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[linearTicketTabID] = Tab(
            id: linearTicketTabID,
            spaceID: personalSpace.id,
            section: .today,
            url: linearURL,
            title: "ORB-1284 — Easel drawing tool: redo arrow key",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 4),
            createdAt: Date().addingTimeInterval(-3600 * 40),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[orbitNoteTabID] = Tab(
            id: orbitNoteTabID,
            spaceID: personalSpace.id,
            section: .today,
            url: URL(string: "orbit://note/\(orbitNoteID.uuidString)")!,
            title: "Onboarding checklist",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 6),
            createdAt: Date().addingTimeInterval(-3600 * 50),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[orbitEaselTabID] = Tab(
            id: orbitEaselTabID,
            spaceID: personalSpace.id,
            section: .today,
            url: URL(string: "orbit://easel/\(orbitEaselID.uuidString)")!,
            title: "Q4 Product Roadmap",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 8),
            createdAt: Date().addingTimeInterval(-3600 * 60),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[httpsArticleTabID] = Tab(
            id: httpsArticleTabID,
            spaceID: personalSpace.id,
            section: .today,
            url: articleURL,
            title: "Applying Macros — Apple Developer Documentation",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 10),
            createdAt: Date().addingTimeInterval(-3600 * 70),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[archivedPersonalTabID] = Tab(
            id: archivedPersonalTabID,
            spaceID: personalSpace.id,
            section: .archived,
            url: archivedArticleURL,
            title: "Aqua (user interface) — Wikipedia",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 24 * 3),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 7),
            archivedAt: Date().addingTimeInterval(-3600 * 24),
            isUnloaded: true,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[readingArticle1ID] = Tab(
            id: readingArticle1ID,
            spaceID: readingSpace.id,
            section: .today,
            url: readingArticle1URL,
            title: "Typography in ten minutes — Practical Typography",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 2),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 14),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[readingArticle2ID] = Tab(
            id: readingArticle2ID,
            spaceID: readingSpace.id,
            section: .today,
            url: readingArticle2URL,
            title: "How browsers work — MDN Web Docs",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 14),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 20),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[readingArticle3ID] = Tab(
            id: readingArticle3ID,
            spaceID: readingSpace.id,
            section: .today,
            url: readingArticle3URL,
            title: "The Lengths of CSS — CSS-Tricks",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 20),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 28),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[readingFolderChild1ID] = Tab(
            id: readingFolderChild1ID,
            spaceID: personalSpace.id,
            section: .pinned,
            url: readingFolderChild1URL,
            title: "The em dash — The Punctuation Guide",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 24 * 2),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 30),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[readingFolderChild2ID] = Tab(
            id: readingFolderChild2ID,
            spaceID: personalSpace.id,
            section: .pinned,
            url: readingFolderChild2URL,
            title: "Layout — SwiftUI | Apple Developer Documentation",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 24 * 4),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 40),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[readingFolderChild3ID] = Tab(
            id: readingFolderChild3ID,
            spaceID: personalSpace.id,
            section: .pinned,
            url: readingFolderChild3URL,
            title: "Arrow (symbol) — Wikipedia",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 24 * 6),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 60),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[readingFolderStandaloneID] = Tab(
            id: readingFolderStandaloneID,
            spaceID: personalSpace.id,
            section: .pinned,
            url: readingFolderStandaloneURL,
            title: "Design Systems — Smashing Magazine",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 24 * 8),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 80),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[workQ4Child1ID] = Tab(
            id: workQ4Child1ID,
            spaceID: workSpace.id,
            section: .pinned,
            url: workQ4Child1URL,
            title: "Q4 Roadmap — Figma",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 3),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 30),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[workQ4Child2ID] = Tab(
            id: workQ4Child2ID,
            spaceID: workSpace.id,
            section: .pinned,
            url: workQ4Child2URL,
            title: "ORB-1200 — Spec finalisation",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 5),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 32),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[workFigmaTabID] = Tab(
            id: workFigmaTabID,
            spaceID: workSpace.id,
            section: .today,
            url: figmaURL,
            title: "Q4 Roadmap — Figma",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 0.5),
            createdAt: Date().addingTimeInterval(-3600 * 24),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[workLinearTabID] = Tab(
            id: workLinearTabID,
            spaceID: workSpace.id,
            section: .today,
            url: linearCycleURL,
            title: "2024-Q4 cycle — Linear",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 1),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 2),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[workNotionTabID] = Tab(
            id: workNotionTabID,
            spaceID: workSpace.id,
            section: .today,
            url: notionDocURL,
            title: "Launch Checklist — Notion",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 2),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 3),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[workSlackTabID] = Tab(
            id: workSlackTabID,
            spaceID: workSpace.id,
            section: .today,
            url: slackURL,
            title: "#general — Slack",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 4),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 5),
            archivedAt: nil,
            isUnloaded: false,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        tabs[travelArchive1ID] = Tab(
            id: travelArchive1ID,
            spaceID: travelSpace.id,
            section: .archived,
            url: travelArchive1URL,
            title: "Coastal cabin — Airbnb",
            customTitle: nil,
            faviconURL: nil,
            lastAccessedAt: Date().addingTimeInterval(-3600 * 24 * 5),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 14),
            archivedAt: Date().addingTimeInterval(-3600 * 24 * 4),
            isUnloaded: true,
            isMuted: false,
            zoomFactor: nil,
            splitGroupID: nil,
            splitIndex: 0
        )

        // MARK: Boosts
        let boost = Boost(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            name: "Clean HN",
            host: "news.ycombinator.com",
            isEnabled: true,
            zappedSelectors: [".story-vote", ".voter", ".nav"],
            customCSS: "body { font-family: -apple-system }",
            customJavaScript: "",
            backgroundColor: nil,
            textColor: nil,
            accentColor: nil,
            fontFamily: nil,
            createdAt: Date().addingTimeInterval(-3600 * 24 * 30),
            updatedAt: Date().addingTimeInterval(-3600 * 24 * 2)
        )

        // MARK: Easel
        let easel = Easel(
            id: orbitEaselID,
            title: "Q4 Product Roadmap",
            items: [
                EaselItem(
                    id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
                    frame: CGRect(x: 40, y: 40, width: 280, height: 80),
                    rotation: 0,
                    content: .text("Brainstorm"),
                    zIndex: 0
                ),
                EaselItem(
                    id: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!,
                    frame: CGRect(x: 360, y: 60, width: 320, height: 56),
                    rotation: 0,
                    content: .link(url: figmaURL, title: "Q4 Roadmap"),
                    zIndex: 1
                ),
                EaselItem(
                    id: UUID(uuidString: "60000000-0000-0000-0000-000000000003")!,
                    frame: CGRect(x: 40, y: 180, width: 480, height: 240),
                    rotation: 0,
                    content: .liveWebRegion(url: linearCycleURL, selector: nil, cropRect: .zero),
                    zIndex: 2
                ),
                EaselItem(
                    id: UUID(uuidString: "60000000-0000-0000-0000-000000000004")!,
                    frame: CGRect(x: 560, y: 180, width: 220, height: 220),
                    rotation: 0,
                    content: .drawing(
                        points: [
                            CGPoint(x: 0, y: 0),
                            CGPoint(x: 40, y: 30),
                            CGPoint(x: 80, y: 90),
                            CGPoint(x: 130, y: 70),
                            CGPoint(x: 180, y: 110),
                            CGPoint(x: 220, y: 90),
                        ],
                        color: ThemeColor(red: 0.55, green: 0.30, blue: 0.85),
                        width: 2
                    ),
                    zIndex: 3
                ),
            ],
            createdAt: Date().addingTimeInterval(-3600 * 24 * 14),
            updatedAt: Date().addingTimeInterval(-3600 * 8),
            viewportOrigin: .zero,
            viewportZoom: 1.0
        )

        // MARK: Notes
        let note = Note(
            id: orbitNoteID,
            title: "Onboarding checklist",
            bodyData: Data(),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 5),
            updatedAt: Date().addingTimeInterval(-3600 * 6)
        )

        // MARK: Routing rule
        let routingRule = RoutingRule(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
            pattern: "figma.com",
            destination: .space(workSpace.id),
            isEnabled: true
        )

        // MARK: Active tab = the Figma file URL inside Work / Work
        let activeTabBySpace: [SpaceID: TabID] = [
            personalSpace.id: figmaFileTabID,
            readingSpace.id: readingArticle1ID,
            workSpace.id: workFigmaTabID,
            travelSpace.id: travelArchive1ID,
        ]

        return OrbitState(
            schemaVersion: OrbitState.currentSchemaVersion,
            profiles: [personal, work, travel],
            spaces: [personalSpace, readingSpace, workSpace, travelSpace],
            tabs: tabs,
            splitGroups: [:],
            boosts: [boost],
            easels: [easel],
            notes: [note],
            routingRules: [routingRule],
            activeSpaceID: workSpace.id,
            activeTabBySpace: activeTabBySpace
        )
    }
}
