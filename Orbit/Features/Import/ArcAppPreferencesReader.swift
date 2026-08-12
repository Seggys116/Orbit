//  Reads company.thebrowser.Browser's AppKit defaults plist and Storable{LinkRouting,Windows}.json;
//  macOS's cfprefsd caches preferences, so a very recent change may not yet be flushed to the plist.

import Foundation

// MARK: - Values

public enum ArcAutoArchiveThreshold: String, Sendable, Hashable, CaseIterable {
    case never
    case twelveHours
    case twentyFourHours
    case sevenDays
    case thirtyDays

    init?(arcRawValue: String) {
        switch arcRawValue.lowercased() {
        case "never", "off": self = .never
        case "twelvehours", "halfday": self = .twelveHours
        case "twentyfourhours", "oneday", "day": self = .twentyFourHours
        case "sevendays", "oneweek", "week": self = .sevenDays
        case "thirtydays", "onemonth", "month": self = .thirtyDays
        default: return nil
        }
    }
}

public enum ArcAppearance: Sendable, Hashable {
    case light
    case dark
    case system
}

public struct ArcRoutingRule: Sendable, Hashable {
    public enum Match: Sendable, Hashable {
        case contains(String)
        case equals(String)
        case startsWith(String)
        case endsWith(String)
        case unsupported(kind: String, pattern: String)

        public var pattern: String {
            switch self {
            case .contains(let value), .equals(let value), .startsWith(let value), .endsWith(let value):
                return value
            case .unsupported(_, let value):
                return value
            }
        }
    }

    public enum Destination: Sendable, Hashable {
        case space(UUID)
        case mostRecentSpace
        case application(bundleID: String)
        case littleArc
        case unsupported(String)
    }

    public var arcID: UUID
    public var match: Match
    public var destination: Destination

    public init(arcID: UUID, match: Match, destination: Destination) {
        self.arcID = arcID
        self.match = match
        self.destination = destination
    }
}

/// Plist/JSON key mapping: showsToolbar=topBarURLEnabled, showsFullURLs=toolbarShowFullURLsEnabledPreference, tidyTabsEnabled=tidyTabsEnabled, instantLinksEnabled=instantLinksEnabled; sidebarWidth/lastFocusedSpaceID from StorableWindows.json; routingRules/defaultRoutingDestination from StorableLinkRouting.json.
public struct ArcAppPreferences: Sendable, Hashable {
    public var autoArchiveThreshold: ArcAutoArchiveThreshold?
    public var unrecognisedAutoArchiveValue: String?
    public var appearance: ArcAppearance?
    public var showsToolbar: Bool?
    public var showsFullURLs: Bool?
    public var tidyTabsEnabled: Bool?
    public var instantLinksEnabled: Bool?
    public var sidebarWidth: Double?
    public var lastFocusedSpaceID: UUID?
    public var routingRules: [ArcRoutingRule]
    public var defaultRoutingDestination: ArcRoutingRule.Destination?

    public init(
        autoArchiveThreshold: ArcAutoArchiveThreshold? = nil,
        unrecognisedAutoArchiveValue: String? = nil,
        appearance: ArcAppearance? = nil,
        showsToolbar: Bool? = nil,
        showsFullURLs: Bool? = nil,
        tidyTabsEnabled: Bool? = nil,
        instantLinksEnabled: Bool? = nil,
        sidebarWidth: Double? = nil,
        lastFocusedSpaceID: UUID? = nil,
        routingRules: [ArcRoutingRule] = [],
        defaultRoutingDestination: ArcRoutingRule.Destination? = nil
    ) {
        self.autoArchiveThreshold = autoArchiveThreshold
        self.unrecognisedAutoArchiveValue = unrecognisedAutoArchiveValue
        self.appearance = appearance
        self.showsToolbar = showsToolbar
        self.showsFullURLs = showsFullURLs
        self.tidyTabsEnabled = tidyTabsEnabled
        self.instantLinksEnabled = instantLinksEnabled
        self.sidebarWidth = sidebarWidth
        self.lastFocusedSpaceID = lastFocusedSpaceID
        self.routingRules = routingRules
        self.defaultRoutingDestination = defaultRoutingDestination
    }
}

// MARK: - Reader

public enum ArcAppPreferencesReader {

    public static let preferencesDomain = "company.thebrowser.Browser"

    public static func preferencesURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Preferences/\(preferencesDomain).plist", isDirectory: false)
    }

    public static func read(homeDirectory: URL, browser: ImportableBrowser = .arc) throws -> ArcAppPreferences {
        var preferences = ArcAppPreferences()

        if let plist = try plist(at: preferencesURL(homeDirectory: homeDirectory), browser: browser) {
            if let raw = plist["autoArchiveTimeThreshold"] as? String {
                preferences.autoArchiveThreshold = ArcAutoArchiveThreshold(arcRawValue: raw)
                if preferences.autoArchiveThreshold == nil {
                    preferences.unrecognisedAutoArchiveValue = raw
                }
            }
            if let appearance = plist["appearance"] as? String {
                switch appearance {
                case "NSAppearanceNameDarkAqua": preferences.appearance = .dark
                case "NSAppearanceNameAqua": preferences.appearance = .light
                default: preferences.appearance = .system
                }
            }
            preferences.showsToolbar = bool(plist["topBarURLEnabled"])
            preferences.showsFullURLs = bool(plist["toolbarShowFullURLsEnabledPreference"])
            preferences.tidyTabsEnabled = bool(plist["tidyTabsEnabled"])
            preferences.instantLinksEnabled = bool(plist["instantLinksEnabled"])
        }

        let root = ArcImportReader.dataDirectory(homeDirectory: homeDirectory)

        if let windows = try json(at: root.appendingPathComponent("StorableWindows.json"), browser: browser) {
            if let sidebar = windows["sidebarViewPreferences"] as? [String: Any] {
                preferences.sidebarWidth = ArcSidebarDocument.double(sidebar["sidebarWidth"])
            }
            if let id = windows["lastFocusedSpaceID"] as? String {
                preferences.lastFocusedSpaceID = UUID(uuidString: id)
            }
        }

        if let routing = try json(at: root.appendingPathComponent("StorableLinkRouting.json"), browser: browser) {
            preferences.routingRules = rules(from: routing["rules"])
            preferences.defaultRoutingDestination = destination(from: routing["defaultDestination"])
        }

        return preferences
    }

    // MARK: Link routing

    /// Arc's rule shape: {id, destination: {space: {_0: {...}}}, sourceComponents: [{componentType: {urlMatch: {_0: <kind>, _1: <pattern>}}}]} — `_0`/`_1` are Swift's Codable encoding of an associated-value enum.
    /// A rule with several sourceComponents (Arc ANDs them) is split into several single-component Orbit rules sharing a destination.
    static func rules(from json: Any?) -> [ArcRoutingRule] {
        guard let array = json as? [Any] else { return [] }
        var result: [ArcRoutingRule] = []
        for case let object as [String: Any] in array {
            guard let idString = object["id"] as? String, let id = UUID(uuidString: idString) else { continue }
            let destination = destination(from: object["destination"]) ?? .unsupported("missing")
            for case let component as [String: Any] in (object["sourceComponents"] as? [Any] ?? []) {
                guard let componentType = component["componentType"] as? [String: Any],
                      let urlMatch = componentType["urlMatch"] as? [String: Any],
                      let pattern = urlMatch["_1"] as? String,
                      !pattern.isEmpty
                else { continue }
                let kind = (urlMatch["_0"] as? [String: Any])?.keys.first ?? "unknown"
                let match: ArcRoutingRule.Match
                switch kind {
                case "contains": match = .contains(pattern)
                case "equals", "exact": match = .equals(pattern)
                case "startsWith", "beginsWith", "prefix": match = .startsWith(pattern)
                case "endsWith", "suffix": match = .endsWith(pattern)
                default: match = .unsupported(kind: kind, pattern: pattern)
                }
                result.append(ArcRoutingRule(arcID: id, match: match, destination: destination))
            }
        }
        return result
    }

    static func destination(from json: Any?) -> ArcRoutingRule.Destination? {
        guard let object = json as? [String: Any], let key = object.keys.first else { return nil }
        let payload = (object[key] as? [String: Any])?["_0"]

        switch key {
        case "space":
            if let id = payload as? String, let uuid = UUID(uuidString: id) { return .space(uuid) }
            if let nested = payload as? [String: Any], nested["mostRecent"] != nil { return .mostRecentSpace }
            return .mostRecentSpace
        case "application", "app":
            if let bundleID = payload as? String { return .application(bundleID: bundleID) }
            return .unsupported(key)
        case "littleArc", "little":
            return .littleArc
        default:
            return .unsupported(key)
        }
    }

    // MARK: File helpers

    private static func plist(at url: URL, browser: ImportableBrowser) throws -> [String: Any]? {
        guard let data = try data(at: url, browser: browser) else { return nil }
        do {
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        } catch {
            throw BrowserImportError.unreadable(browser, reason: "\(url.lastPathComponent) isn't a valid property list: \(error.localizedDescription)")
        }
    }

    private static func json(at url: URL, browser: ImportableBrowser) throws -> [String: Any]? {
        guard let data = try data(at: url, browser: browser) else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            throw BrowserImportError.unreadable(browser, reason: "\(url.lastPathComponent) isn't valid JSON: \(error.localizedDescription)")
        }
    }

    private static func data(at url: URL, browser: ImportableBrowser) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(browser, path: url.path)
            }
            throw BrowserImportError.unreadable(browser, reason: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func bool(_ json: Any?) -> Bool? {
        if let value = json as? Bool { return value }
        if let number = json as? NSNumber { return number.boolValue }
        return nil
    }
}
