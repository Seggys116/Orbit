import AppKit

@MainActor
final class TextFinderMenuItem: NSMenuItem {

    let command: ShortcutCommandID

    // Target stays nil deliberately: routes to the first responder and lets AppKit disable the row when nothing in the chain responds.
    init(title: String, action: Selector, tag: NSTextFinder.Action, command: ShortcutCommandID) {
        self.command = command
        super.init(title: title, action: action, keyEquivalent: "")
        self.target = nil
        self.tag = tag.rawValue
        refreshBinding()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Cannot use validateMenuItem(_:) itself since target is nil; ShortcutRefreshingMenu.update() calls this instead, right before the menu displays.
    func refreshBinding() {
        let binding = ShortcutRegistry.shared.binding(for: command)
        let equivalent = binding?.menuKeyEquivalent ?? ""
        if keyEquivalent != equivalent { keyEquivalent = equivalent }
        let flags = binding?.modifierFlags ?? []
        if keyEquivalentModifierMask != flags { keyEquivalentModifierMask = flags }
    }
}

@MainActor
final class ShortcutRefreshingMenu: NSMenu {

    override func update() {
        for case let item as TextFinderMenuItem in items {
            item.refreshBinding()
        }
        super.update()
    }
}
