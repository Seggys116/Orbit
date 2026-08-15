import Foundation

/// One chrome.contextMenus item id. Ids are per-extension: two extensions can
/// each own an item called "translate" without colliding. Exactly one of `uid`
/// (the renderer's generated integer) and `stringUID` is meaningful.
nonisolated public struct ExtensionContextMenuItemID: Sendable, Hashable, Decodable {
    public var extensionID: String
    public var uid: Int32?
    public var stringUID: String

    public init(extensionID: String, uid: Int32? = nil, stringUID: String = "") {
        self.extensionID = extensionID
        self.uid = uid
        self.stringUID = stringUID
    }

    private enum CodingKeys: String, CodingKey {
        case extensionID = "extensionId"
        case uid
        case stringUID = "stringUid"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extensionID = try container.decode(String.self, forKey: .extensionID)
        uid = try container.decodeIfPresent(Int32.self, forKey: .uid)
        stringUID = try container.decodeIfPresent(String.self, forKey: .stringUID) ?? ""
    }
}

/// A single already-matched, already-visible menu item. The engine has done the
/// contexts/documentUrlPatterns/targetUrlPatterns filtering and the %s title
/// substitution before this reaches Swift; nothing here needs re-checking.
nonisolated public struct ExtensionContextMenuItem: Sendable, Decodable {
    public enum Kind: String, Sendable, Decodable {
        case normal, checkbox, radio, separator
    }

    public var id: ExtensionContextMenuItemID
    public var title: String
    public var type: Kind
    public var isChecked: Bool
    public var isEnabled: Bool
    public var children: [ExtensionContextMenuItem]

    public init(
        id: ExtensionContextMenuItemID,
        title: String,
        type: Kind = .normal,
        isChecked: Bool = false,
        isEnabled: Bool = true,
        children: [ExtensionContextMenuItem] = []
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.isChecked = isChecked
        self.isEnabled = isEnabled
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, type
        case isChecked = "checked"
        case isEnabled = "enabled"
        case children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ExtensionContextMenuItemID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try container.decodeIfPresent(Kind.self, forKey: .type) ?? .normal
        isChecked = try container.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        children = try container.decodeIfPresent([ExtensionContextMenuItem].self, forKey: .children) ?? []
    }
}

/// Every matching top-level item contributed by one extension.
nonisolated public struct ExtensionContextMenuGroup: Sendable, Decodable {
    public var extensionID: String
    public var extensionName: String
    public var items: [ExtensionContextMenuItem]

    public init(extensionID: String, extensionName: String, items: [ExtensionContextMenuItem]) {
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case extensionID = "extensionId"
        case extensionName
        case items
    }

    /// A malformed payload contributes no items rather than throwing: a broken
    /// extension must not stop the user's own context menu appearing.
    public static func decode(json: String) -> [ExtensionContextMenuGroup] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ExtensionContextMenuGroup].self, from: data)) ?? []
    }
}
