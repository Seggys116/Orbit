//  Pure data model for OrbitContextMenuView, never NSMenu/NSMenuItem; presentation
//  (OrbitContextMenuPresenter) is a separate, testable concern.

import Foundation

enum OrbitContextMenuEntry: Identifiable {
    case item(OrbitContextMenuItem)
    case divider(id: UUID)
    case section(id: UUID, title: String, entries: [OrbitContextMenuEntry])

    // Enum cases cannot carry default argument values, hence these
    // no-argument overloads for the common "I don't care about the id" call.
    static func divider() -> OrbitContextMenuEntry { .divider(id: UUID()) }
    static func section(title: String, entries: [OrbitContextMenuEntry]) -> OrbitContextMenuEntry {
        .section(id: UUID(), title: title, entries: entries)
    }

    var id: AnyHashable {
        switch self {
        case .item(let item): return item.id
        case .divider(let id): return id
        case .section(let id, _, _): return id
        }
    }
}

struct OrbitContextMenuItem: Identifiable {
    var id = UUID()
    var title: String
    var systemImage: String?
    var shortcut: String?
    var isEnabled: Bool
    var isDestructive: Bool
    var tooltip: String?
    var submenu: [OrbitContextMenuEntry]?
    var action: (() -> Void)?

    init(
        title: String,
        systemImage: String? = nil,
        shortcut: String? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        tooltip: String? = nil,
        submenu: [OrbitContextMenuEntry]? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.tooltip = tooltip
        self.submenu = submenu
        self.action = action
    }

    var hasSubmenu: Bool { submenu?.isEmpty == false }
}

extension [OrbitContextMenuEntry] {
    /// Every real (non-divider, non-section-header) item, recursing into
    /// sections and submenus -- what a test asserts titles/actions against
    /// without caring how deep a particular item happens to be nested.
    var flattenedItems: [OrbitContextMenuItem] {
        flatMap { entry -> [OrbitContextMenuItem] in
            switch entry {
            case .item(let item):
                return [item] + (item.submenu?.flattenedItems ?? [])
            case .divider:
                return []
            case .section(_, _, let entries):
                return entries.flattenedItems
            }
        }
    }

    func first(titled title: String) -> OrbitContextMenuItem? {
        flattenedItems.first { $0.title == title }
    }
}
