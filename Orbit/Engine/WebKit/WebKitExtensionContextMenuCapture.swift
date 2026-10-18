import AppKit

/// Reads the extension items WebKit adds to its own proposed context menu. Unlike `menuItems(for:)`,
/// that menu is built for the real click, so link, selection, image, frame and editable items are in it
/// and carry the click's info when their action fires.
@MainActor
enum WebKitExtensionContextMenuCapture {
    struct Owner {
        var id: String
        var name: String
        /// Titles the submenu wrapper may carry: WebKit titles a multi-item extension's submenu after the extension.
        var wrapperTitles: Set<String>
        /// Titles of the tab-level items this extension offers, used to attribute a bare item.
        var tabTitles: Set<String>
    }

    struct Snapshot {
        var groups: [ExtensionContextMenuGroup] = []
        var actions: [ExtensionContextMenuItemID: NSMenuItem] = [:]
    }

    static let unattributedID = "orbit.unattributed-extension-items"

    static func capture(from menu: NSMenu, owners: [Owner]) -> Snapshot {
        var order: [String] = []
        var collected: [String: [NSMenuItem]] = [:]

        func append(_ id: String, _ items: [NSMenuItem]) {
            if collected[id] == nil { order.append(id) }
            collected[id, default: []].append(contentsOf: items)
        }

        // Classify in menu order, then attribute. WebKit contributes at most one top-level
        // item per extension, so a lone bare item can be named without building another menu.
        var pieces: [Piece] = []
        var claimed: Set<String> = []
        for item in menu.items where !item.isHidden && !item.isSeparatorItem {
            if let submenu = item.submenu, let owner = owners.first(where: { $0.wrapperTitles.contains(item.title) }) {
                pieces.append(.owned(owner.id, submenu.items))
                claimed.insert(owner.id)
            } else if isExtensionItem(item) {
                pieces.append(.bare(item))
            } else if item.tag == 0, let owner = owners.first(where: { $0.tabTitles.contains(item.title) }) {
                pieces.append(.owned(owner.id, [item]))
                claimed.insert(owner.id)
            }
        }

        let bareCount = pieces.reduce(into: 0) { count, piece in
            if case .bare = piece { count += 1 }
        }
        let unclaimed = owners.filter { !claimed.contains($0.id) }
        for piece in pieces {
            switch piece {
            case .owned(let id, let items):
                append(id, items)
            case .bare(let item):
                append(ownerID(of: item, owners: owners, unclaimed: unclaimed, bareCount: bareCount), [item])
            }
        }

        var snapshot = Snapshot()
        for (ordinal, id) in order.enumerated() {
            var actions: [ExtensionContextMenuItemID: NSMenuItem] = [:]
            let items = convert(collected[id] ?? [], extensionID: id, path: [ordinal], actions: &actions)
            guard !items.isEmpty else { continue }
            snapshot.actions.merge(actions) { first, _ in first }
            let name = owners.first { $0.id == id }?.name ?? "Extensions"
            snapshot.groups.append(ExtensionContextMenuGroup(extensionID: id, extensionName: name, items: items))
        }
        return snapshot
    }

    private enum Piece {
        case owned(String, [NSMenuItem])
        case bare(NSMenuItem)
    }

    private static func ownerID(of item: NSMenuItem, owners: [Owner], unclaimed: [Owner], bareCount: Int) -> String {
        if let owner = owners.first(where: { $0.tabTitles.contains(item.title) }) { return owner.id }
        if owners.count == 1 { return owners[0].id }
        if bareCount == 1, unclaimed.count == 1 { return unclaimed[0].id }
        return unattributedID
    }

    /// WebKit's extension items are driven by its own extension classes, never by the shared menu target the native items use.
    private static func isExtensionItem(_ item: NSMenuItem) -> Bool {
        let objects: [AnyObject?] = [item.target, item.representedObject as AnyObject?]
        if objects.contains(where: { $0.map { String(describing: type(of: $0)).localizedCaseInsensitiveContains("WebExtension") } ?? false }) {
            return true
        }
        return item.identifier?.rawValue.localizedCaseInsensitiveContains("WebExtension") ?? false
    }

    // The id is the item's place in the menu plus its title, so the click finds the same NSMenuItem again.
    private static func convert(
        _ items: [NSMenuItem],
        extensionID: String,
        path: [Int],
        actions: inout [ExtensionContextMenuItemID: NSMenuItem]
    ) -> [ExtensionContextMenuItem] {
        var result: [ExtensionContextMenuItem] = []
        for (index, item) in items.enumerated() where !item.isHidden {
            let itemPath = path + [index]
            let uid = "proposed:" + itemPath.map(String.init).joined(separator: ".") + "|" + item.title
            let id = ExtensionContextMenuItemID(extensionID: extensionID, stringUID: uid)
            if item.isSeparatorItem {
                result.append(ExtensionContextMenuItem(id: id, title: "", type: .separator))
                continue
            }
            let children = item.submenu.map { convert($0.items, extensionID: extensionID, path: itemPath, actions: &actions) } ?? []
            if children.isEmpty { actions[id] = item }
            result.append(ExtensionContextMenuItem(
                id: id,
                title: item.title,
                type: .normal,
                isChecked: item.state != .off,
                isEnabled: item.isEnabled,
                children: children
            ))
        }
        return result
    }
}
