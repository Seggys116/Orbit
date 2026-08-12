//  Swift mirror of one extensions::ExtensionAction: per-tab with a global fallback,
//  a value set for a tab wins for that tab only.

import Foundation

nonisolated public struct ExtensionActionColor: Sendable, Equatable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    // Fully transparent is how extensions::ExtensionAction reports "never set"
    // -- it has no default entry for either badge colour, so GetValue returns a
    // value-initialised SkColor. Orbit substitutes its own badge palette then.
    public static let unset = ExtensionActionColor(red: 0, green: 0, blue: 0, alpha: 0)

    public var isUnset: Bool { alpha == 0 }

    // "#RRGGBBAA", the shape orbit_extension_action_dispatcher.cc writes.
    public init?(hexRGBA: String) {
        var text = Substring(hexRGBA)
        if text.hasPrefix("#") { text = text.dropFirst() }
        guard text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 24) & 0xFF),
            green: UInt8((value >> 16) & 0xFF),
            blue: UInt8((value >> 8) & 0xFF),
            alpha: UInt8(value & 0xFF)
        )
    }
}

nonisolated public struct ExtensionActionState: Sendable, Equatable {
    public var badgeText: String
    public var badgeBackgroundColor: ExtensionActionColor
    public var badgeTextColor: ExtensionActionColor
    public var title: String
    public var isEnabled: Bool
    public var popupURLString: String
    /// The bitmap an extension handed chrome.action.setIcon, PNG-encoded by the
    /// engine. nil means it never set one for this tab and the manifest's own
    /// declared icon file applies.
    public var iconPNG: Data?

    public init(
        badgeText: String = "",
        badgeBackgroundColor: ExtensionActionColor = .unset,
        badgeTextColor: ExtensionActionColor = .unset,
        title: String = "",
        isEnabled: Bool = true,
        popupURLString: String = "",
        iconPNG: Data? = nil
    ) {
        self.badgeText = badgeText
        self.badgeBackgroundColor = badgeBackgroundColor
        self.badgeTextColor = badgeTextColor
        self.title = title
        self.isEnabled = isEnabled
        self.popupURLString = popupURLString
        self.iconPNG = iconPNG
    }
}

/// Engine-resolved: each entry is already the value extensions::ExtensionAction
/// would report, so Swift never re-implements Chrome's fallback chain.
nonisolated public struct ExtensionActionSnapshot: Sendable, Equatable {
    public var extensionID: String
    public var defaults: ExtensionActionState
    public var perTab: [Int32: ExtensionActionState]

    public init(
        extensionID: String,
        defaults: ExtensionActionState = ExtensionActionState(),
        perTab: [Int32: ExtensionActionState] = [:]
    ) {
        self.extensionID = extensionID
        self.defaults = defaults
        self.perTab = perTab
    }

    public func state(forTabID tabID: Int32?) -> ExtensionActionState {
        guard let tabID, let tabState = perTab[tabID] else { return defaults }
        return tabState
    }
}

// MARK: - Wire format

extension ExtensionActionSnapshot {

    private struct WireState: Decodable {
        var tabId: Int32?
        var badgeText: String?
        var badgeBackgroundColor: String?
        var badgeTextColor: String?
        var title: String?
        var isEnabled: Bool?
        var popupUrl: String?
        var iconPNG: String?

        func asState() -> ExtensionActionState {
            ExtensionActionState(
                badgeText: badgeText ?? "",
                badgeBackgroundColor: badgeBackgroundColor.flatMap(ExtensionActionColor.init(hexRGBA:)) ?? .unset,
                badgeTextColor: badgeTextColor.flatMap(ExtensionActionColor.init(hexRGBA:)) ?? .unset,
                title: title ?? "",
                isEnabled: isEnabled ?? true,
                popupURLString: popupUrl ?? "",
                iconPNG: iconPNG.flatMap { Data(base64Encoded: $0) }
            )
        }
    }

    private struct Wire: Decodable {
        var extensionId: String
        var defaults: WireState
        var tabs: [WireState]?
    }

    /// One `{"extensionId":...,"defaults":{...},"tabs":[...]}` object, exactly
    /// as orbit_extension_action_dispatcher.cc writes it.
    public static func decode(json: String) -> ExtensionActionSnapshot? {
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data)
        else { return nil }
        return snapshot(from: wire)
    }

    /// A JSON array of the objects `decode(json:)` reads -- the full-state
    /// snapshot OrbitGetExtensionActionsJSON returns.
    public static func decodeAll(json: String) -> [ExtensionActionSnapshot] {
        guard let data = json.data(using: .utf8),
              let wires = try? JSONDecoder().decode([Wire].self, from: data)
        else { return [] }
        return wires.map(snapshot(from:))
    }

    private static func snapshot(from wire: Wire) -> ExtensionActionSnapshot {
        var perTab: [Int32: ExtensionActionState] = [:]
        for tab in wire.tabs ?? [] {
            guard let tabID = tab.tabId else { continue }
            perTab[tabID] = tab.asState()
        }
        return ExtensionActionSnapshot(
            extensionID: wire.extensionId,
            defaults: wire.defaults.asState(),
            perTab: perTab
        )
    }
}

// MARK: - Store

/// Every loaded extension's current action state, as last relayed by the
/// engine. Observable so the toolbar repaints the moment a background service
/// worker calls chrome.action.setBadgeText, with no polling.
@MainActor
@Observable
public final class ExtensionActionStateStore {

    /// The shared empty store every engine with no chrome.action relay reports.
    /// Never written to; `state(extensionID:tabID:)` on it always answers the
    /// plain enabled, unbadged default.
    public static let inert = ExtensionActionStateStore()

    public private(set) var snapshots: [String: ExtensionActionSnapshot] = [:]

    public init() {}

    public func apply(_ snapshot: ExtensionActionSnapshot) {
        snapshots[snapshot.extensionID] = snapshot
    }

    public func replaceAll(_ newSnapshots: [ExtensionActionSnapshot]) {
        snapshots = Dictionary(uniqueKeysWithValues: newSnapshots.map { ($0.extensionID, $0) })
    }

    public func remove(extensionID: String) {
        snapshots.removeValue(forKey: extensionID)
    }

    public func removeAll() {
        snapshots.removeAll()
    }

    /// The state `tabID` sees. An extension with no relayed state at all reads
    /// as a plain enabled action with no badge, which is exactly what a
    /// freshly loaded extension that never called chrome.action.* is.
    public func state(extensionID: String, tabID: Int32?) -> ExtensionActionState {
        snapshots[extensionID]?.state(forTabID: tabID) ?? ExtensionActionState()
    }
}
