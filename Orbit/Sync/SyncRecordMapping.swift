//  On-disk format: one `CKRecord` per entity in the private zone `OrbitState`; `recordName` is the entity's own UUID, except `TodayEntry`'s composite "today-<spaceID>-<tabID>".
//  Conflict resolution: scalar fields are last-writer-wins on `clientModifiedAt`/`updatedAt`; ordered collections (Pinned siblings, Today, Favorites) merge via `SyncMerge.mergeOrderedIDs` below.

import AppKit
import CloudKit
import Foundation

// MARK: - Record type & zone constants

public enum SyncRecordType {
    public static let zoneName = "OrbitState"

    public static let profile = "Profile"
    public static let space = "Space"
    public static let favorite = "Favorite"
    public static let sidebarNode = "SidebarNode"
    public static let todayEntry = "TodayEntry"
    public static let tab = "Tab"
    public static let boost = "Boost"
    public static let easel = "Easel"
    public static let note = "Note"
    public static let routingRule = "RoutingRule"

    public static let all: [String] = [
        profile, space, favorite, sidebarNode, todayEntry, tab, boost, easel, note, routingRule,
    ]
}

public enum TodayEntryRecordName {
    public static func make(spaceID: SpaceID, tabID: TabID) -> String {
        "today-\(spaceID.uuidString)-\(tabID.uuidString)"
    }

    public static func parse(_ recordName: String) -> (spaceID: SpaceID, tabID: TabID)? {
        guard recordName.hasPrefix("today-") else { return nil }
        let remainder = recordName.dropFirst("today-".count)
        guard remainder.count == 73 else { return nil } // 36 + 1 ("-") + 36
        let spaceIDString = String(remainder.prefix(36))
        let tabIDString = String(remainder.suffix(36))
        guard let spaceID = UUID(uuidString: spaceIDString),
              let tabID = UUID(uuidString: tabIDString)
        else { return nil }
        return (spaceID, tabID)
    }
}

// MARK: - Scalar field bundles

public struct SpaceScalarFields: Sendable, Hashable {
    public var id: SpaceID
    public var name: String
    public var icon: String
    public var iconIsEmoji: Bool
    public var iconKind: SpaceIconKind?
    public var iconImageID: SpaceIconImageID?
    public var theme: SpaceTheme
    public var profileID: ProfileID
    public var order: Int
    public var createdAt: Date

    public init(from space: Space) {
        id = space.id
        name = space.name
        icon = space.icon
        iconIsEmoji = space.iconIsEmoji
        iconKind = space.iconKind
        iconImageID = space.iconImageID
        theme = space.theme
        profileID = space.profileID
        order = space.order
        createdAt = space.createdAt
    }

    public init(
        id: SpaceID, name: String, icon: String, iconIsEmoji: Bool,
        iconKind: SpaceIconKind? = nil, iconImageID: SpaceIconImageID? = nil,
        theme: SpaceTheme, profileID: ProfileID, order: Int, createdAt: Date
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
        self.createdAt = createdAt
    }

    public func applying(to space: inout Space) {
        space.name = name
        space.icon = icon
        space.iconIsEmoji = iconIsEmoji
        space.iconKind = iconKind
        space.iconImageID = iconImageID
        space.theme = theme
        space.profileID = profileID
        space.order = order
        space.createdAt = createdAt
    }
}

public struct FlatSidebarNode: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case tab
        case folder
    }

    public var id: UUID
    public var spaceID: SpaceID
    public var parentID: UUID?
    public var order: Int
    public var kind: Kind

    public var name: String?
    public var isExpanded: Bool?
    public var icon: String?
    public var iconIsEmoji: Bool?

    public init(
        id: UUID, spaceID: SpaceID, parentID: UUID?, order: Int, kind: Kind,
        name: String? = nil, isExpanded: Bool? = nil, icon: String? = nil, iconIsEmoji: Bool? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.parentID = parentID
        self.order = order
        self.kind = kind
        self.name = name
        self.isExpanded = isExpanded
        self.icon = icon
        self.iconIsEmoji = iconIsEmoji
    }
}

public struct FlatTodayEntry: Sendable, Hashable {
    public var spaceID: SpaceID
    public var tabID: TabID
    public var order: Int

    public init(spaceID: SpaceID, tabID: TabID, order: Int) {
        self.spaceID = spaceID
        self.tabID = tabID
        self.order = order
    }
}

public struct FlatFavorite: Sendable, Hashable {
    public var favorite: Favorite
    public var spaceID: SpaceID
    public var order: Int

    public init(favorite: Favorite, spaceID: SpaceID, order: Int) {
        self.favorite = favorite
        self.spaceID = spaceID
        self.order = order
    }
}

// MARK: - PinnedNodeTree flatten / unflatten

public enum SidebarTreeFlattening {

    public static func flatten(_ nodes: [SidebarNode], spaceID: SpaceID, parentID: UUID? = nil) -> [FlatSidebarNode] {
        var result: [FlatSidebarNode] = []
        for (index, node) in nodes.enumerated() {
            switch node {
            case .tab(let tabID):
                result.append(FlatSidebarNode(id: tabID, spaceID: spaceID, parentID: parentID, order: index, kind: .tab))
            case .folder(let folder):
                result.append(FlatSidebarNode(
                    id: folder.id, spaceID: spaceID, parentID: parentID, order: index, kind: .folder,
                    name: folder.name, isExpanded: folder.isExpanded, icon: folder.icon, iconIsEmoji: folder.iconIsEmoji
                ))
                result.append(contentsOf: flatten(folder.children, spaceID: spaceID, parentID: folder.id))
            }
        }
        return result
    }

    public static func unflatten(_ flat: [FlatSidebarNode], spaceID: SpaceID) -> [SidebarNode] {
        let rows = flat.filter { $0.spaceID == spaceID }
        let folderIDs = Set(rows.filter { $0.kind == .folder }.map(\.id))
        func build(parentID: UUID?) -> [SidebarNode] {
            rows
                .filter { row in
                    if let parentID {
                        return row.parentID == parentID
                    }
                    return row.parentID == nil || !folderIDs.contains(row.parentID!)
                }
                .sorted { $0.order < $1.order }
                .map { row -> SidebarNode in
                    switch row.kind {
                    case .tab:
                        return .tab(row.id)
                    case .folder:
                        let folder = Folder(
                            id: row.id,
                            name: row.name ?? "Folder",
                            isExpanded: row.isExpanded ?? true,
                            children: build(parentID: row.id),
                            icon: row.icon,
                            iconIsEmoji: row.iconIsEmoji ?? false
                        )
                        return .folder(folder)
                    }
                }
        }
        return build(parentID: nil)
    }
}

// MARK: - Ordered-collection merge

public enum SyncMerge {

    // Starts from remoteOrder, then reinserts each local-only id next to its nearest surviving local neighbour (or appends).
    public static func mergeOrderedIDs<ID: Hashable>(
        remoteOrder: [ID],
        localOrder: [ID],
        tombstoned: Set<ID> = []
    ) -> [ID] {
        var result = remoteOrder.filter { !tombstoned.contains($0) }
        let resultSet0 = Set(result)
        let localOnly = localOrder.filter { !resultSet0.contains($0) && !tombstoned.contains($0) }

        for id in localOnly {
            guard let localIndex = localOrder.firstIndex(of: id) else { continue }

            if let predecessor = localOrder[..<localIndex].reversed().first(where: { candidate in
                result.contains(candidate)
            }), let predecessorIndex = result.firstIndex(of: predecessor) {
                result.insert(id, at: predecessorIndex + 1)
                continue
            }

            if localIndex + 1 <= localOrder.count,
               let successor = localOrder[(localIndex + 1)...].first(where: { candidate in
                   result.contains(candidate)
               }), let successorIndex = result.firstIndex(of: successor) {
                result.insert(id, at: successorIndex)
                continue
            }

            result.append(id)
        }

        return result
    }
}

// MARK: - Tombstones

public struct SyncTombstoneLog: Codable, Sendable {
    public private(set) var deletedAt: [String: Date] = [:]

    public static let retention: TimeInterval = 90 * 24 * 3600

    public init() {}

    public mutating func record(_ recordName: String, at date: Date = Date()) {
        deletedAt[recordName] = date
    }

    public func contains(_ recordName: String) -> Bool {
        deletedAt[recordName] != nil
    }

    public mutating func forget(_ recordName: String) {
        deletedAt.removeValue(forKey: recordName)
    }

    public mutating func prune(now: Date = Date()) {
        deletedAt = deletedAt.filter { now.timeIntervalSince($0.value) < Self.retention }
    }
}

// MARK: - Stable content hashing

public enum StableHash {

    public static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    public static func hex(_ string: String) -> String {
        String(fnv1a(string), radix: 16, uppercase: false)
    }

    public static func contentHash(of record: CKRecord, excluding excludedKeys: Set<String> = ["clientModifiedAt", "updatedAt"]) -> String {
        let keys = record.allKeys().filter { !excludedKeys.contains($0) }.sorted()
        let pieces = keys.map { key -> String in
            let value = record[key]
            return "\(key)=\(describeForHash(value))"
        }
        return hex(pieces.joined(separator: "\u{1F}"))
    }

    private static func describeForHash(_ value: Any?) -> String {
        guard let value else { return "<nil>" }
        if let data = value as? Data { return data.base64EncodedString() }
        if let date = value as? Date { return String(date.timeIntervalSinceReferenceDate) }
        if let array = value as? [String] { return array.joined(separator: ",") }
        return String(describing: value)
    }
}

// MARK: - CKRecord field helpers

extension CKRecord {
    func setOptionalString(_ value: String?, forKey key: String) {
        self[key] = value as CKRecordValue?
    }

    func setOptionalDate(_ value: Date?, forKey key: String) {
        self[key] = value as CKRecordValue?
    }

    func setOptionalDouble(_ value: Double?, forKey key: String) {
        self[key] = value as CKRecordValue?
    }

    func setOptionalBool(_ value: Bool?, forKey key: String) {
        if let value {
            self[key] = value as CKRecordValue
        } else {
            self[key] = nil
        }
    }

    func setOptionalThemeColor(_ value: ThemeColor?, forKey key: String) {
        guard let value, let data = try? JSONEncoder.orbitSync.encode(value) else {
            self[key] = nil
            return
        }
        self[key] = data as CKRecordValue
    }
}

// MARK: - Model <-> CKRecord mapping

public enum SyncRecordMapping {

    // MARK: Profile

    public static func profileRecord(from profile: Profile, clientModifiedAt: Date, existing: CKRecord?) -> CKRecord {
        let record = existing ?? CKRecord(recordType: SyncRecordType.profile, recordID: CloudSyncEngine.recordID(SyncRecordType.profile, name: profile.id.uuidString))
        record["name"] = profile.name as CKRecordValue
        record["symbolName"] = profile.symbolName as CKRecordValue
        record["tintRed"] = profile.tint.red as CKRecordValue
        record["tintGreen"] = profile.tint.green as CKRecordValue
        record["tintBlue"] = profile.tint.blue as CKRecordValue
        record["tintAlpha"] = profile.tint.alpha as CKRecordValue
        record["isPersistent"] = profile.isPersistent as CKRecordValue
        record["createdAt"] = profile.createdAt as CKRecordValue
        record["archivePolicy"] = profile.archivePolicy.rawValue as CKRecordValue
        record["clientModifiedAt"] = clientModifiedAt as CKRecordValue
        return record
    }

    public static func profile(from record: CKRecord) -> Profile? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let name = record["name"] as? String,
              let symbolName = record["symbolName"] as? String,
              let tintRed = record["tintRed"] as? Double,
              let tintGreen = record["tintGreen"] as? Double,
              let tintBlue = record["tintBlue"] as? Double,
              let tintAlpha = record["tintAlpha"] as? Double,
              let isPersistent = record["isPersistent"] as? Bool,
              let createdAt = record["createdAt"] as? Date
        else { return nil }
        let archivePolicy = (record["archivePolicy"] as? String)
            .flatMap(ArchivePolicy.init(rawValue:)) ?? .after12Hours
        return Profile(
            id: id, name: name, symbolName: symbolName,
            tint: ThemeColor(red: tintRed, green: tintGreen, blue: tintBlue, alpha: tintAlpha),
            isPersistent: isPersistent, createdAt: createdAt,
            archivePolicy: archivePolicy
        )
    }

    // MARK: Preserving fields the record schema does not carry

    public static func merging(incoming: Profile, onto existing: Profile?) -> Profile {
        guard let existing else { return incoming }
        var merged = incoming
        merged.searchEngine = existing.searchEngine
        merged.includesSearchSuggestions = existing.includesSearchSuggestions
        return merged
    }

    public static func merging(incoming: Tab, onto existing: Tab?) -> Tab {
        guard let existing else { return incoming }
        var merged = incoming
        merged.pinnedURL = existing.pinnedURL
        merged.pinnedTitle = existing.pinnedTitle
        merged.tidiedTitle = existing.tidiedTitle
        merged.tidyGroup = existing.tidyGroup
        return merged
    }

    // MARK: Space (scalar fields only)

    public static func spaceRecord(from fields: SpaceScalarFields, clientModifiedAt: Date, existing: CKRecord?) -> CKRecord? {
        guard let themeData = try? JSONEncoder.orbitSync.encode(fields.theme) else { return nil }
        let record = existing ?? CKRecord(recordType: SyncRecordType.space, recordID: CloudSyncEngine.recordID(SyncRecordType.space, name: fields.id.uuidString))
        record["name"] = fields.name as CKRecordValue
        record["icon"] = fields.icon as CKRecordValue
        record["iconIsEmoji"] = fields.iconIsEmoji as CKRecordValue
        record.setOptionalString(fields.iconKind?.rawValue, forKey: "iconKind")
        record.setOptionalString(fields.iconImageID?.uuidString, forKey: "iconImageID")
        record["themeData"] = themeData as CKRecordValue
        record["profileID"] = fields.profileID.uuidString as CKRecordValue
        record["order"] = fields.order as CKRecordValue
        record["createdAt"] = fields.createdAt as CKRecordValue
        record["clientModifiedAt"] = clientModifiedAt as CKRecordValue
        return record
    }

    public static func spaceScalarFields(from record: CKRecord) -> SpaceScalarFields? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let name = record["name"] as? String,
              let icon = record["icon"] as? String,
              let iconIsEmoji = record["iconIsEmoji"] as? Bool,
              let themeData = record["themeData"] as? Data,
              let theme = try? JSONDecoder.orbitSync.decode(SpaceTheme.self, from: themeData),
              let profileIDString = record["profileID"] as? String,
              let profileID = UUID(uuidString: profileIDString),
              let order = record["order"] as? Int,
              let createdAt = record["createdAt"] as? Date
        else { return nil }
        let iconKind = (record["iconKind"] as? String).flatMap(SpaceIconKind.init(rawValue:))
        let iconImageID = (record["iconImageID"] as? String).flatMap(SpaceIconImageID.init(uuidString:))
        return SpaceScalarFields(
            id: id, name: name, icon: icon, iconIsEmoji: iconIsEmoji,
            iconKind: iconKind, iconImageID: iconImageID, theme: theme,
            profileID: profileID, order: order, createdAt: createdAt
        )
    }

    // MARK: Favorite

    public static func favoriteRecord(from flat: FlatFavorite, clientModifiedAt: Date, existing: CKRecord?) -> CKRecord {
        let favorite = flat.favorite
        let record = existing ?? CKRecord(recordType: SyncRecordType.favorite, recordID: CloudSyncEngine.recordID(SyncRecordType.favorite, name: favorite.id.uuidString))
        record["spaceID"] = flat.spaceID.uuidString as CKRecordValue
        record["order"] = flat.order as CKRecordValue
        record["url"] = favorite.url.absoluteString as CKRecordValue
        record["title"] = favorite.title as CKRecordValue
        record.setOptionalString(favorite.customIcon, forKey: "customIcon")
        record["customIconIsEmoji"] = favorite.customIconIsEmoji as CKRecordValue
        record.setOptionalString(favorite.liveTabID?.uuidString, forKey: "liveTabID")
        record["clientModifiedAt"] = clientModifiedAt as CKRecordValue
        return record
    }

    public static func favorite(from record: CKRecord) -> FlatFavorite? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let spaceIDString = record["spaceID"] as? String,
              let spaceID = UUID(uuidString: spaceIDString),
              let order = record["order"] as? Int,
              let urlString = record["url"] as? String,
              let url = URL(string: urlString),
              let title = record["title"] as? String,
              let customIconIsEmoji = record["customIconIsEmoji"] as? Bool
        else { return nil }
        let customIcon = record["customIcon"] as? String
        let liveTabID = (record["liveTabID"] as? String).flatMap(UUID.init(uuidString:))
        let favorite = Favorite(
            id: id, url: url, title: title, customIcon: customIcon,
            customIconIsEmoji: customIconIsEmoji, liveTabID: liveTabID
        )
        return FlatFavorite(favorite: favorite, spaceID: spaceID, order: order)
    }

    // MARK: SidebarNode (Pinned tree row — tab leaf or Folder)

    public static func sidebarNodeRecord(from node: FlatSidebarNode, clientModifiedAt: Date, existing: CKRecord?) -> CKRecord {
        let record = existing ?? CKRecord(recordType: SyncRecordType.sidebarNode, recordID: CloudSyncEngine.recordID(SyncRecordType.sidebarNode, name: node.id.uuidString))
        record["spaceID"] = node.spaceID.uuidString as CKRecordValue
        record.setOptionalString(node.parentID?.uuidString, forKey: "parentID")
        record["order"] = node.order as CKRecordValue
        record["kind"] = node.kind.rawValue as CKRecordValue
        record.setOptionalString(node.name, forKey: "name")
        record.setOptionalBool(node.isExpanded, forKey: "isExpanded")
        record.setOptionalString(node.icon, forKey: "icon")
        record.setOptionalBool(node.iconIsEmoji, forKey: "iconIsEmoji")
        record["clientModifiedAt"] = clientModifiedAt as CKRecordValue
        return record
    }

    public static func sidebarNode(from record: CKRecord) -> FlatSidebarNode? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let spaceIDString = record["spaceID"] as? String,
              let spaceID = UUID(uuidString: spaceIDString),
              let order = record["order"] as? Int,
              let kindRaw = record["kind"] as? String,
              let kind = FlatSidebarNode.Kind(rawValue: kindRaw)
        else { return nil }
        let parentID = (record["parentID"] as? String).flatMap(UUID.init(uuidString:))
        return FlatSidebarNode(
            id: id, spaceID: spaceID, parentID: parentID, order: order, kind: kind,
            name: record["name"] as? String,
            isExpanded: record["isExpanded"] as? Bool,
            icon: record["icon"] as? String,
            iconIsEmoji: record["iconIsEmoji"] as? Bool
        )
    }

    // MARK: TodayEntry

    public static func todayEntryRecord(from entry: FlatTodayEntry, clientModifiedAt: Date, existing: CKRecord?) -> CKRecord {
        let name = TodayEntryRecordName.make(spaceID: entry.spaceID, tabID: entry.tabID)
        let record = existing ?? CKRecord(recordType: SyncRecordType.todayEntry, recordID: CloudSyncEngine.recordID(SyncRecordType.todayEntry, name: name))
        record["spaceID"] = entry.spaceID.uuidString as CKRecordValue
        record["tabID"] = entry.tabID.uuidString as CKRecordValue
        record["order"] = entry.order as CKRecordValue
        record["clientModifiedAt"] = clientModifiedAt as CKRecordValue
        return record
    }

    public static func todayEntry(from record: CKRecord) -> FlatTodayEntry? {
        guard let spaceIDString = record["spaceID"] as? String,
              let spaceID = UUID(uuidString: spaceIDString),
              let tabIDString = record["tabID"] as? String,
              let tabID = UUID(uuidString: tabIDString),
              let order = record["order"] as? Int
        else { return nil }
        return FlatTodayEntry(spaceID: spaceID, tabID: tabID, order: order)
    }

    // MARK: Tab

    public static func tabRecord(from tab: Tab, clientModifiedAt: Date, existing: CKRecord?) -> CKRecord {
        let record = existing ?? CKRecord(recordType: SyncRecordType.tab, recordID: CloudSyncEngine.recordID(SyncRecordType.tab, name: tab.id.uuidString))
        record["spaceID"] = tab.spaceID.uuidString as CKRecordValue
        record["section"] = tab.section.rawValue as CKRecordValue
        record["url"] = tab.url.absoluteString as CKRecordValue
        record["title"] = tab.title as CKRecordValue
        record.setOptionalString(tab.customTitle, forKey: "customTitle")
        record.setOptionalString(tab.faviconURL?.absoluteString, forKey: "faviconURL")
        record["lastAccessedAt"] = tab.lastAccessedAt as CKRecordValue
        record["createdAt"] = tab.createdAt as CKRecordValue
        record.setOptionalDate(tab.archivedAt, forKey: "archivedAt")
        record["isUnloaded"] = tab.isUnloaded as CKRecordValue
        record["isMuted"] = tab.isMuted as CKRecordValue
        record.setOptionalDouble(tab.zoomFactor, forKey: "zoomFactor")
        record.setOptionalString(tab.splitGroupID?.uuidString, forKey: "splitGroupID")
        record["splitIndex"] = tab.splitIndex as CKRecordValue
        record["clientModifiedAt"] = clientModifiedAt as CKRecordValue
        return record
    }

    public static func tab(from record: CKRecord) -> Tab? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let spaceIDString = record["spaceID"] as? String,
              let spaceID = UUID(uuidString: spaceIDString),
              let sectionRaw = record["section"] as? String,
              let section = TabSection(rawValue: sectionRaw),
              let urlString = record["url"] as? String,
              let url = URL(string: urlString),
              let title = record["title"] as? String,
              let lastAccessedAt = record["lastAccessedAt"] as? Date,
              let createdAt = record["createdAt"] as? Date,
              let isUnloaded = record["isUnloaded"] as? Bool,
              let isMuted = record["isMuted"] as? Bool,
              let splitIndex = record["splitIndex"] as? Int
        else { return nil }
        let faviconURL = (record["faviconURL"] as? String).flatMap(URL.init(string:))
        let splitGroupID = (record["splitGroupID"] as? String).flatMap(UUID.init(uuidString:))
        return Tab(
            id: id, spaceID: spaceID, section: section, url: url, title: title,
            customTitle: record["customTitle"] as? String, faviconURL: faviconURL,
            lastAccessedAt: lastAccessedAt, createdAt: createdAt,
            archivedAt: record["archivedAt"] as? Date, isUnloaded: isUnloaded, isMuted: isMuted,
            zoomFactor: record["zoomFactor"] as? Double, splitGroupID: splitGroupID, splitIndex: splitIndex
        )
    }

    // MARK: Boost (uses its own `updatedAt` as the LWW clock)

    public static func boostRecord(from boost: Boost, existing: CKRecord?) -> CKRecord {
        let record = existing ?? CKRecord(recordType: SyncRecordType.boost, recordID: CloudSyncEngine.recordID(SyncRecordType.boost, name: boost.id.uuidString))
        record["name"] = boost.name as CKRecordValue
        record["host"] = boost.host as CKRecordValue
        record["isEnabled"] = boost.isEnabled as CKRecordValue
        record["zappedSelectors"] = boost.zappedSelectors as CKRecordValue
        record["customCSS"] = boost.customCSS as CKRecordValue
        record["customJavaScript"] = boost.customJavaScript as CKRecordValue
        record.setOptionalString(boost.fontFamily, forKey: "fontFamily")
        record.setOptionalThemeColor(boost.backgroundColor, forKey: "backgroundColor")
        record.setOptionalThemeColor(boost.textColor, forKey: "textColor")
        record.setOptionalThemeColor(boost.accentColor, forKey: "accentColor")
        record["createdAt"] = boost.createdAt as CKRecordValue
        record["updatedAt"] = boost.updatedAt as CKRecordValue
        return record
    }

    public static func boost(from record: CKRecord) -> Boost? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let name = record["name"] as? String,
              let host = record["host"] as? String,
              let isEnabled = record["isEnabled"] as? Bool,
              let zappedSelectors = record["zappedSelectors"] as? [String],
              let customCSS = record["customCSS"] as? String,
              let customJavaScript = record["customJavaScript"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date
        else { return nil }
        let backgroundColor = (record["backgroundColor"] as? Data).flatMap { try? JSONDecoder.orbitSync.decode(ThemeColor.self, from: $0) }
        let textColor = (record["textColor"] as? Data).flatMap { try? JSONDecoder.orbitSync.decode(ThemeColor.self, from: $0) }
        let accentColor = (record["accentColor"] as? Data).flatMap { try? JSONDecoder.orbitSync.decode(ThemeColor.self, from: $0) }
        return Boost(
            id: id, name: name, host: host, isEnabled: isEnabled, zappedSelectors: zappedSelectors,
            customCSS: customCSS, customJavaScript: customJavaScript,
            backgroundColor: backgroundColor, textColor: textColor, accentColor: accentColor,
            fontFamily: record["fontFamily"] as? String, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    // MARK: Easel (uses its own `updatedAt` as the LWW clock)

    public static func easelRecord(from easel: Easel, existing: CKRecord?) -> CKRecord? {
        guard let itemsData = try? JSONEncoder.orbitSync.encode(easel.items) else { return nil }
        let record = existing ?? CKRecord(recordType: SyncRecordType.easel, recordID: CloudSyncEngine.recordID(SyncRecordType.easel, name: easel.id.uuidString))
        record["title"] = easel.title as CKRecordValue
        record["itemsData"] = itemsData as CKRecordValue
        record["createdAt"] = easel.createdAt as CKRecordValue
        record["updatedAt"] = easel.updatedAt as CKRecordValue
        record["viewportOriginX"] = Double(easel.viewportOrigin.x) as CKRecordValue
        record["viewportOriginY"] = Double(easel.viewportOrigin.y) as CKRecordValue
        record["viewportZoom"] = easel.viewportZoom as CKRecordValue
        return record
    }

    public static func easel(from record: CKRecord) -> Easel? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let title = record["title"] as? String,
              let itemsData = record["itemsData"] as? Data,
              let items = try? JSONDecoder.orbitSync.decode([EaselItem].self, from: itemsData),
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date,
              let originX = record["viewportOriginX"] as? Double,
              let originY = record["viewportOriginY"] as? Double,
              let zoom = record["viewportZoom"] as? Double
        else { return nil }
        return Easel(
            id: id, title: title, items: items, createdAt: createdAt, updatedAt: updatedAt,
            viewportOrigin: CGPoint(x: originX, y: originY), viewportZoom: zoom
        )
    }

    // MARK: Note (uses its own `updatedAt` as the LWW clock; body via CKAsset)

    public static func writeNoteAssetFile(_ data: Data, noteID: UUID) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitSync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("note-\(noteID.uuidString)-\(UUID().uuidString).body")
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func noteRecord(from note: Note, assetFileURL: URL, existing: CKRecord?) -> CKRecord {
        let record = existing ?? CKRecord(recordType: SyncRecordType.note, recordID: CloudSyncEngine.recordID(SyncRecordType.note, name: note.id.uuidString))
        record["title"] = note.title as CKRecordValue
        record["bodyAsset"] = CKAsset(fileURL: assetFileURL)
        record["createdAt"] = note.createdAt as CKRecordValue
        record["updatedAt"] = note.updatedAt as CKRecordValue
        return record
    }

    public static func note(from record: CKRecord) -> Note? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let title = record["title"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date
        else { return nil }
        var bodyData = Data()
        if let asset = record["bodyAsset"] as? CKAsset, let fileURL = asset.fileURL,
           let data = try? Data(contentsOf: fileURL) {
            bodyData = data
        }
        return Note(id: id, title: title, bodyData: bodyData, createdAt: createdAt, updatedAt: updatedAt)
    }

    // MARK: RoutingRule

    public static func routingRuleRecord(from rule: RoutingRule, clientModifiedAt: Date, existing: CKRecord?) -> CKRecord {
        let record = existing ?? CKRecord(recordType: SyncRecordType.routingRule, recordID: CloudSyncEngine.recordID(SyncRecordType.routingRule, name: rule.id.uuidString))
        record["pattern"] = rule.pattern as CKRecordValue
        record["isEnabled"] = rule.isEnabled as CKRecordValue
        switch rule.destination {
        case .space(let id):
            record["destinationKind"] = "space" as CKRecordValue
            record["destinationValue"] = id.uuidString as CKRecordValue
        case .profile(let id):
            record["destinationKind"] = "profile" as CKRecordValue
            record["destinationValue"] = id.uuidString as CKRecordValue
        case .application(let bundleID):
            record["destinationKind"] = "application" as CKRecordValue
            record["destinationValue"] = bundleID as CKRecordValue
        case .littleOrbit:
            record["destinationKind"] = "littleOrbit" as CKRecordValue
            record["destinationValue"] = nil
        case .mostRecentSpace:
            record["destinationKind"] = "mostRecentSpace" as CKRecordValue
            record["destinationValue"] = nil
        }
        record["clientModifiedAt"] = clientModifiedAt as CKRecordValue
        return record
    }

    public static func routingRule(from record: CKRecord) -> RoutingRule? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let pattern = record["pattern"] as? String,
              let isEnabled = record["isEnabled"] as? Bool,
              let destinationKind = record["destinationKind"] as? String
        else { return nil }
        let destinationValue = record["destinationValue"] as? String
        let destination: RoutingRule.Destination
        switch destinationKind {
        case "space":
            guard let value = destinationValue, let spaceID = UUID(uuidString: value) else { return nil }
            destination = .space(spaceID)
        case "profile":
            guard let value = destinationValue, let profileID = UUID(uuidString: value) else { return nil }
            destination = .profile(profileID)
        case "application":
            guard let value = destinationValue else { return nil }
            destination = .application(bundleID: value)
        case "littleOrbit":
            destination = .littleOrbit
        case "mostRecentSpace":
            destination = .mostRecentSpace
        default:
            return nil
        }
        return RoutingRule(id: id, pattern: pattern, destination: destination, isEnabled: isEnabled)
    }
}

// MARK: - Shared coders

extension JSONEncoder {
    static let orbitSync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let orbitSync: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
