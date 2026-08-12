import AppKit

// Held as a singleton: NSMenu.delegate is weak, so a controller created inside a menu builder function would be deallocated before the user ever opened the menu.
@MainActor
final class ImportSubmenuController: NSObject, NSMenuDelegate {

    static let shared = ImportSubmenuController()

    private let runner = ImportFlowRunner.shared

    private override init() {
        super.init()
    }

    // A new NSMenu per call, not one shared instance: NSMenu has a single supermenu, and this submenu is carried in two places at once.
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Import from Another Browser", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Import from Another Browser")
        submenu.delegate = self
        item.submenu = submenu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if runner.isImporting {
            menu.addItem(disabledItem("Importing…"))
            return
        }

        let available = runner.availableBrowsers()
        guard !available.isEmpty else {
            menu.addItem(disabledItem("No other browser's data found on this Mac"))
            return
        }

        for browser in available {
            menu.addItem(ClosureMenuItem(title: browser.displayName) { [weak self] in
                self?.runner.run(browser)
            })
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        // ClosureMenuItem answers validateMenuItem(_:) itself, so enabled: false genuinely greys the row out — a plain NSMenuItem.isEnabled = false does not survive AppKit's auto-enabling.
        ClosureMenuItem(title: title, enabled: false) {}
    }
}
