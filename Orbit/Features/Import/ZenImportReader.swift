//  Zen keeps its own state beside the Firefox profile files. zen-sessions.jsonlz4 (mozLz4 JSON: spaces, tabs, groups) is current; recovery.jsonlz4 carries the same tab fields per window; zen_workspaces and zen_pins in places.sqlite are the older store. Each source is optional and a missing or unparseable one is skipped.

import Compression
import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - What comes out

public struct ZenColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
}

public struct ZenWorkspaceTheme: Sendable, Hashable {
    public var colors: [ZenColor]
    public var rotation: Double?
    public var texture: Double
}

public struct ZenWorkspace: Sendable, Hashable, Identifiable {
    public var uuid: String
    public var name: String
    public var emoji: String?
    public var theme: ZenWorkspaceTheme?

    public var id: String { uuid }
}

public struct ZenFolder: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var workspaceUUID: String?
    public var isCollapsed: Bool
}

public struct ZenTab: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case essential
        case pinned
        case open
    }

    public var url: URL
    public var title: String
    public var kind: Kind
    public var workspaceUUID: String?
    public var folderID: String?
    public var lastAccessedAt: Date?
}

public struct ZenStructure: Sendable, Hashable {
    public var workspaces: [ZenWorkspace] = []
    public var folders: [ZenFolder] = []
    public var tabs: [ZenTab] = []

    public var isEmpty: Bool { workspaces.isEmpty && tabs.isEmpty }

    func appending(_ other: ZenStructure) -> ZenStructure {
        ZenStructure(
            workspaces: workspaces + other.workspaces.filter { new in !workspaces.contains { $0.uuid == new.uuid } },
            folders: folders + other.folders.filter { new in !folders.contains { $0.id == new.id } },
            tabs: tabs + other.tabs
        )
    }
}

// MARK: - mozLz4

enum MozLz4 {

    private static let magic = Array("mozLz40\0".utf8)
    private static let headerSize = 12
    private static let maximumDecodedSize = 512 * 1024 * 1024

    /// mozLz4 is an 8-byte magic, a little-endian UInt32 decoded size, then one raw LZ4 block.
    static func decode(_ data: Data) -> Data? {
        guard data.count > headerSize, Array(data.prefix(magic.count)) == magic else { return nil }
        let sizeBytes = Array(data[data.startIndex + 8 ..< data.startIndex + headerSize])
        let size = sizeBytes.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard size > 0, size <= maximumDecodedSize else { return nil }

        let payload = Data(data.dropFirst(headerSize))
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase, size, sourceBase, payload.count, nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        return written == size ? output : nil
    }
}

// MARK: - Reader

enum ZenImportReader {

    private static let sessionFile = "zen-sessions.jsonlz4"
    private static let recoveryFiles = ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4"]

    static func read(profile: FirefoxProfile) throws -> ZenStructure {
        let session = try readState(at: profile.directory.appendingPathComponent(sessionFile))
        let legacy = try readLegacyPlaces(in: profile.directory)

        var workspaces = session?.workspaces ?? []
        if workspaces.isEmpty { workspaces = legacy.workspaces }

        var folders = session?.folders ?? []
        var tabs = session?.tabs ?? []
        if !tabs.contains(where: { $0.kind != .open }) {
            let legacyPins = legacy.tabs.filter { $0.kind != .open }
            tabs.append(contentsOf: legacyPins)
            folders.append(contentsOf: legacy.folders.filter { new in !folders.contains { $0.id == new.id } })
        }

        if !tabs.contains(where: { $0.kind == .open }) {
            for file in recoveryFiles {
                guard let recovered = try readState(at: profile.directory.appendingPathComponent(file)) else { continue }
                let open = recovered.tabs.filter { $0.kind == .open }
                guard !open.isEmpty else { continue }
                tabs.append(contentsOf: open)
                if workspaces.isEmpty { workspaces = recovered.workspaces }
                break
            }
        }

        return ZenStructure(workspaces: workspaces, folders: folders, tabs: dedupedPins(tabs))
    }

    private static func dedupedPins(_ tabs: [ZenTab]) -> [ZenTab] {
        var seen: Set<String> = []
        return tabs.filter { tab in
            guard tab.kind != .open else { return true }
            let key = "\(tab.kind.rawValue)|\(tab.workspaceUUID ?? "")|\(tab.url.absoluteString)"
            return seen.insert(key).inserted
        }
    }

    // MARK: Session JSON

    private static func readState(at url: URL) throws -> ZenStructure? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(.zen, path: url.path)
            }
            return nil
        }
        let json = MozLz4.decode(raw) ?? raw
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        return parseState(root)
    }

    static func parseState(_ root: [String: Any]) -> ZenStructure {
        let containers: [[String: Any]]
        if let windows = root["windows"] as? [[String: Any]] {
            containers = windows
        } else {
            containers = [root]
        }

        var structure = ZenStructure()
        for container in containers {
            let folders = parseFolders(container["groups"] ?? container["folders"])
            let tabs = ((container["tabs"] as? [[String: Any]]) ?? []).compactMap(parseTab)
            structure = structure.appending(ZenStructure(
                workspaces: parseWorkspaces(container["spaces"]),
                folders: folders,
                tabs: tabs
            ))
        }
        return structure
    }

    private static func parseWorkspaces(_ value: Any?) -> [ZenWorkspace] {
        guard let raw = value as? [[String: Any]] else { return [] }
        let indexed = raw.enumerated().map { (offset: $0.offset, position: number($0.element["position"]), raw: $0.element) }
        let ordered = indexed.sorted {
            ($0.position ?? Double($0.offset)) < ($1.position ?? Double($1.offset))
        }
        var seen: Set<String> = []
        return ordered.compactMap { item in
            guard let uuid = string(item.raw["uuid"]), seen.insert(uuid).inserted else { return nil }
            let name = string(item.raw["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ZenWorkspace(
                uuid: uuid,
                name: (name?.isEmpty == false ? name : nil) ?? "Space",
                emoji: emoji(from: string(item.raw["icon"])),
                theme: parseTheme(item.raw["theme"])
            )
        }
    }

    private static func emoji(from icon: String?) -> String? {
        guard let icon = icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = icon.unicodeScalars.first,
              first.value > 0x7F, first.properties.isEmoji
        else { return nil }
        return String(icon.first ?? Character(first))
    }

    private static func parseTheme(_ value: Any?) -> ZenWorkspaceTheme? {
        guard let theme = value as? [String: Any] else { return nil }
        var colorEntries = theme["gradientColors"] as? [Any] ?? []
        if colorEntries.isEmpty, let encoded = theme["colors"] as? String,
           let data = encoded.data(using: .utf8),
           let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            colorEntries = decoded
        }
        let colors = colorEntries.compactMap { entry -> ZenColor? in
            guard let components = (entry as? [String: Any])?["c"] as? [Any], components.count >= 3,
                  let red = number(components[0]), let green = number(components[1]), let blue = number(components[2])
            else { return nil }
            return ZenColor(red: clamp(red / 255), green: clamp(green / 255), blue: clamp(blue / 255))
        }
        guard !colors.isEmpty else { return nil }
        return ZenWorkspaceTheme(
            colors: Array(colors.prefix(4)),
            rotation: number(theme["rotation"]),
            texture: clamp(number(theme["texture"]) ?? 0)
        )
    }

    private static func parseFolders(_ value: Any?) -> [ZenFolder] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let id = string(item["id"]) else { return nil }
            return ZenFolder(
                id: id,
                name: string(item["name"]) ?? string(item["label"]) ?? "Folder",
                parentID: string(item["parentId"]) ?? string(item["parentID"]),
                workspaceUUID: string(item["workspaceId"]) ?? string(item["workspaceUUID"]),
                isCollapsed: item["collapsed"] == nil ? true : flag(item["collapsed"])
            )
        }
    }

    private static func parseTab(_ raw: [String: Any]) -> ZenTab? {
        if flag(raw["zenIsEmpty"]) { return nil }

        let entries = (raw["entries"] as? [[String: Any]]) ?? []
        var active: [String: Any]?
        if !entries.isEmpty {
            let index = Int(number(raw["index"]) ?? Double(entries.count))
            active = entries[min(max(index, 1), entries.count) - 1]
        }

        let isEssential = flag(raw["zenEssential"]) || flag(raw["_zenIsEssential"])
        let isPinned = flag(raw["pinned"]) || isEssential
        let kind: ZenTab.Kind = isEssential ? .essential : (isPinned ? .pinned : .open)

        let pinnedEntry = (raw["_zenPinnedInitialState"] as? [String: Any])?["entry"] as? [String: Any]
        let candidates = (isPinned ? [pinnedEntry, active] : [active]).compactMap { $0 }
        guard let entry = candidates.first(where: { string($0["url"]).flatMap(FirefoxImportReader.importableURL) != nil }),
              let url = string(entry["url"]).flatMap(FirefoxImportReader.importableURL)
        else { return nil }

        let title = (isPinned ? string(raw["zenStaticLabel"]) : nil) ?? string(entry["title"]) ?? ""
        return ZenTab(
            url: url,
            title: title,
            kind: kind,
            workspaceUUID: string(raw["zenWorkspace"]),
            folderID: isPinned ? string(raw["groupId"]) : nil,
            lastAccessedAt: number(raw["lastAccessed"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // MARK: places.sqlite (older Zen)

    private static func readLegacyPlaces(in directory: URL) throws -> ZenStructure {
        let url = directory.appendingPathComponent("places.sqlite", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return ZenStructure() }

        return try ImportSQLiteSnapshot.withReadOnlyCopy(of: url, browser: .zen) { handle in
            let workspaceRows = try rows(of: "zen_workspaces", orderedBy: "position", in: handle)
            let pinRows = try rows(of: "zen_pins", orderedBy: "position", in: handle)

            let workspaces = parseWorkspaces(workspaceRows.map { row -> [String: Any] in
                var item = row
                item["theme"] = [
                    "colors": row["theme_colors"] as Any,
                    "rotation": row["theme_rotation"] as Any,
                    "texture": row["theme_texture"] as Any,
                ]
                return item
            })

            var folders: [ZenFolder] = []
            var tabs: [ZenTab] = []
            for row in pinRows {
                let parent = string(row["folder_parent_uuid"]) ?? string(row["parent_uuid"])
                if flag(row["is_group"]) {
                    guard let id = string(row["uuid"]) else { continue }
                    folders.append(ZenFolder(
                        id: id,
                        name: string(row["title"]) ?? "Folder",
                        parentID: parent,
                        workspaceUUID: string(row["workspace_uuid"]),
                        isCollapsed: row["is_folder_collapsed"] == nil ? true : flag(row["is_folder_collapsed"])
                    ))
                    continue
                }
                guard let pinURL = string(row["url"]).flatMap(FirefoxImportReader.importableURL) else { continue }
                tabs.append(ZenTab(
                    url: pinURL,
                    title: string(row["edited_title"]) ?? string(row["title"]) ?? "",
                    kind: flag(row["is_essential"]) ? .essential : .pinned,
                    workspaceUUID: string(row["workspace_uuid"]),
                    folderID: parent,
                    lastAccessedAt: nil
                ))
            }
            return ZenStructure(workspaces: workspaces, folders: folders, tabs: tabs)
        }
    }

    /// Every column is read by name, so a Zen release that adds or drops columns still yields whatever this reader understands.
    private static func rows(of table: String, orderedBy column: String, in handle: OpaquePointer) throws -> [[String: Any]] {
        let exists = try ImportSQLiteSnapshot.query(
            handle,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(table)';",
            browser: .zen
        ) { _ -> Bool? in true }
        guard !exists.isEmpty else { return [] }

        let columns = try ImportSQLiteSnapshot.query(
            handle,
            sql: "PRAGMA table_info(\(table));",
            browser: .zen
        ) { statement -> String? in ImportSQLiteSnapshot.columnText(statement, 1) }
        let order = columns.contains(column) ? " ORDER BY \(column)" : ""

        return try ImportSQLiteSnapshot.query(
            handle,
            sql: "SELECT * FROM \(table)\(order);",
            browser: .zen
        ) { statement -> [String: Any]? in
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, index).map({ String(cString: $0) }) else { continue }
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, index)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT: row[name] = ImportSQLiteSnapshot.columnText(statement, index)
                default: continue
                }
            }
            return row
        }
    }

    // MARK: Value helpers

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func flag(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
