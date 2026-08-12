//  per_host_zoom_levels' zoom_level is Chromium's log-base-1.2 ZoomFactorToZoomLevel, not a percentage: zoomFactor = pow(1.2, zoomLevel).
//  content_settings' ContentSetting is 1=ALLOW, 2=BLOCK, 0/absent=undecided; integerSetting(_:) rejects CFBoolean so a telemetry dict's JSON bool can't misread as a permission.
//  default_search_provider.guid is empty on every Arc profile observed; an empty/unresolvable GUID yields nil, never a guessed default.

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Values

public struct ArcHostZoom: Sendable, Hashable {
    public var host: String
    public var zoomFactor: Double        // 1.0 == unzoomed

    public init(host: String, zoomFactor: Double) {
        self.host = host
        self.zoomFactor = zoomFactor
    }
}

public struct ArcSitePermission: Sendable, Hashable {
    public var origin: URL
    public var kind: ArcPermissionKind
    public var isAllowed: Bool           // false == explicitly blocked; undecided sites aren't represented at all

    public init(origin: URL, kind: ArcPermissionKind, isAllowed: Bool) {
        self.origin = origin
        self.kind = kind
        self.isAllowed = isAllowed
    }
}

public enum ArcPermissionKind: String, Sendable, Hashable, CaseIterable {
    case notifications, geolocation, camera, microphone, clipboardRead, automaticDownloads, localNetwork, durableStorage
}

public struct ArcSettings: Sendable, Hashable {
    public var searchEngineName: String?      // nil == Arc did not record one
    public var downloadDirectory: URL?
    public var hostZoomLevels: [ArcHostZoom]
    public var sitePermissions: [ArcSitePermission]
    /// nil when the pref was absent — must not read as false; Chromium omits the key until the toggle is touched.
    public var sendsDoNotTrack: Bool?
    public var preferredLanguages: [String]

    public init(
        searchEngineName: String? = nil,
        downloadDirectory: URL? = nil,
        hostZoomLevels: [ArcHostZoom] = [],
        sitePermissions: [ArcSitePermission] = [],
        sendsDoNotTrack: Bool? = nil,
        preferredLanguages: [String] = []
    ) {
        self.searchEngineName = searchEngineName
        self.downloadDirectory = downloadDirectory
        self.hostZoomLevels = hostZoomLevels
        self.sitePermissions = sitePermissions
        self.sendsDoNotTrack = sendsDoNotTrack
        self.preferredLanguages = preferredLanguages
    }
}

// MARK: - Reader

public enum ArcSettingsReader {

    static let zoomLevelBase: Double = 1.2
    static let contentSettingAllow = 1
    static let contentSettingBlock = 2

    /// local_network and loopback_network are Chromium's split of one former permission; both fold onto .localNetwork, deduplicated in sitePermissions.
    static let permissionKinds: [String: ArcPermissionKind] = [
        "notifications": .notifications,
        "geolocation": .geolocation,
        "media_stream_camera": .camera,
        "media_stream_mic": .microphone,
        "clipboard": .clipboardRead,
        "automatic_downloads": .automaticDownloads,
        "local_network": .localNetwork,
        "loopback_network": .localNetwork,
        "durable_storage": .durableStorage,
    ]

    public static func read(profileDirectory: URL, browser: ImportableBrowser) throws -> ArcSettings {
        let preferencesURL = profileDirectory.appendingPathComponent("Preferences", isDirectory: false)

        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            return ArcSettings()
        }

        let data: Data
        do {
            data = try Data(contentsOf: preferencesURL)
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(browser, path: preferencesURL.path)
            }
            throw BrowserImportError.unreadable(browser, reason: "Couldn't read the Preferences file: \(error.localizedDescription)")
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BrowserImportError.unreadable(browser, reason: "The Preferences file isn't valid JSON: \(error.localizedDescription)")
        }
        guard let root = json as? [String: Any] else {
            throw BrowserImportError.unreadable(browser, reason: "The Preferences file's root isn't a JSON object.")
        }

        return ArcSettings(
            searchEngineName: try searchEngineName(root: root, profileDirectory: profileDirectory, browser: browser),
            downloadDirectory: downloadDirectory(root: root),
            hostZoomLevels: hostZoomLevels(root: root),
            sitePermissions: sitePermissions(root: root),
            sendsDoNotTrack: root["enable_do_not_track"] as? Bool,
            preferredLanguages: preferredLanguages(root: root)
        )
    }

    // MARK: Download directory

    /// selectfile.last_directory is deliberately ignored — it's the last folder an open panel was pointed at, not a download destination.
    static func downloadDirectory(root: [String: Any]) -> URL? {
        let candidates = [
            (root["savefile"] as? [String: Any])?["default_directory"] as? String,
            (root["download"] as? [String: Any])?["default_directory"] as? String,
        ]
        for case let path? in candidates where !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    // MARK: Zoom

    /// Every partition is walked (not just Chromium's default "x") since an isolated app partition gets its own; first entry per host wins deterministically.
    static func hostZoomLevels(root: [String: Any]) -> [ArcHostZoom] {
        guard let partition = root["partition"] as? [String: Any],
              let partitions = partition["per_host_zoom_levels"] as? [String: Any]
        else { return [] }

        var factorsByHost: [String: Double] = [:]
        for partitionName in partitions.keys.sorted() {
            guard let hosts = partitions[partitionName] as? [String: Any] else { continue }
            for host in hosts.keys.sorted() {
                guard !host.isEmpty,
                      factorsByHost[host] == nil,
                      let entry = hosts[host] as? [String: Any],
                      let level = ArcSidebarDocument.double(entry["zoom_level"])
                else { continue }
                factorsByHost[host] = zoomFactor(fromLevel: level)
            }
        }

        return factorsByHost
            .map { ArcHostZoom(host: $0.key, zoomFactor: $0.value) }
            .sorted { $0.host < $1.host }
    }

    static func zoomFactor(fromLevel level: Double) -> Double {
        pow(zoomLevelBase, level)
    }

    // MARK: Content settings

    private struct PermissionKey: Hashable {
        var origin: URL
        var kind: ArcPermissionKind
    }

    static func sitePermissions(root: [String: Any]) -> [ArcSitePermission] {
        guard let profile = root["profile"] as? [String: Any],
              let contentSettings = profile["content_settings"] as? [String: Any],
              let exceptions = contentSettings["exceptions"] as? [String: Any]
        else { return [] }

        // A conflict between two categories folding onto the same key resolves to block.
        var decisions: [PermissionKey: Bool] = [:]

        for category in exceptions.keys.sorted() {
            guard let kind = permissionKinds[category] else { continue }
            guard let entries = exceptions[category] as? [String: Any] else { continue }

            for pattern in entries.keys.sorted() {
                guard let entry = entries[pattern] as? [String: Any],
                      let setting = integerSetting(entry["setting"]),
                      setting == contentSettingAllow || setting == contentSettingBlock,
                      let origin = origin(fromPattern: pattern)
                else { continue }

                let key = PermissionKey(origin: origin, kind: kind)
                let isAllowed = setting == contentSettingAllow
                decisions[key] = (decisions[key] ?? true) && isAllowed
            }
        }

        return decisions
            .map { ArcSitePermission(origin: $0.key.origin, kind: $0.key.kind, isAllowed: $0.value) }
            .sorted {
                $0.kind.rawValue == $1.kind.rawValue
                    ? $0.origin.absoluteString < $1.origin.absoluteString
                    : $0.kind.rawValue < $1.kind.rawValue
            }
    }

    /// A JSON boolean also arrives as NSNumber and would otherwise read as 1 (ALLOW) — the CFBoolean check is the only reliable way to exclude it.
    static func integerSetting(_ json: Any?) -> Int? {
        guard let number = json as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    /// Skips a per-embedder rule (secondary != "*"), a wildcard primary pattern, or a non-http(s) scheme — none of which map onto a concrete Orbit origin.
    static func origin(fromPattern pattern: String) -> URL? {
        let components = pattern.components(separatedBy: ",")
        guard components.count == 2, components[1] == "*" else { return nil }

        let primary = components[0]
        guard !primary.contains("*"),
              let url = URL(string: primary),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: Languages

    /// intl.selected_languages is comma-separated; intl.accept_languages (some Chromium builds) is an array — both accepted.
    static func preferredLanguages(root: [String: Any]) -> [String] {
        guard let intl = root["intl"] as? [String: Any] else { return [] }
        let raw = intl["selected_languages"] ?? intl["accept_languages"]

        let parts: [String]
        if let joined = raw as? String {
            parts = joined.components(separatedBy: ",")
        } else if let array = raw as? [Any] {
            parts = array.compactMap { $0 as? String }
        } else {
            return []
        }

        var seen: Set<String> = []
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Default search engine

    static func searchEngineName(root: [String: Any], profileDirectory: URL, browser: ImportableBrowser) throws -> String? {
        guard let provider = root["default_search_provider"] as? [String: Any],
              let guid = provider["guid"] as? String,
              !guid.isEmpty
        else { return nil }

        let webDataURL = profileDirectory.appendingPathComponent("Web Data", isDirectory: false)
        guard FileManager.default.fileExists(atPath: webDataURL.path) else { return nil }

        return try ImportSQLiteSnapshot.withReadOnlyCopy(of: webDataURL, browser: browser) { handle in
            try shortName(forGUID: guid, handle: handle, browser: browser)
        }
    }

    /// sqliteTransient is mandatory: without it SQLite keeps a pointer into a Swift String's temporary UTF-8 buffer, dead by the time sqlite3_step runs.
    static func shortName(forGUID guid: String, handle: OpaquePointer, browser: ImportableBrowser) throws -> String? {
        let sql = "SELECT short_name FROM keywords WHERE sync_guid = ? LIMIT 1;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            if let statement { sqlite3_finalize(statement) }
            throw BrowserImportError.unreadable(browser, reason: "Couldn't read the search engine database: \(message)")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_text(statement, 1, guid, -1, ImportSQLiteSnapshot.sqliteTransient) == SQLITE_OK else {
            throw BrowserImportError.unreadable(browser, reason: String(cString: sqlite3_errmsg(handle)))
        }

        let step = sqlite3_step(statement)
        guard step != SQLITE_DONE else { return nil }
        guard step == SQLITE_ROW else {
            throw BrowserImportError.unreadable(browser, reason: String(cString: sqlite3_errmsg(handle)))
        }

        guard let name = ImportSQLiteSnapshot.columnText(statement, 0), !name.isEmpty else { return nil }
        return name
    }
}
