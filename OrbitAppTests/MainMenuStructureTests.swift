import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class MainMenuStructureTests: XCTestCase {

    // MARK: Traversal

    private func walk(_ menu: NSMenu, prefix: [String] = []) -> [(path: [String], item: NSMenuItem)] {
        var out: [(path: [String], item: NSMenuItem)] = []
        for item in menu.items {
            guard !item.isSeparatorItem else { continue }
            let path = prefix + [item.title]
            out.append((path, item))
            if let submenu = item.submenu {
                out.append(contentsOf: walk(submenu, prefix: path))
            }
        }
        return out
    }

    private func topLevelMenus() -> [NSMenu] {
        MainMenuBuilder.build().items.compactMap(\.submenu)
    }

    private func menu(_ title: String) throws -> NSMenu {
        try XCTUnwrap(
            topLevelMenus().first { $0.title == title },
            "No top-level menu titled \(title). Menu bar is: \(topLevelMenus().map(\.title))"
        )
    }

    private func row(_ path: [String]) throws -> NSMenuItem {
        let all = topLevelMenus().flatMap { walk($0, prefix: [$0.title]) }
        return try XCTUnwrap(
            all.first { $0.path == path }?.item,
            "No row at \(path.joined(separator: " > ")). Rows under \(path.dropLast().joined(separator: " > ")): "
                + all.filter { $0.path.dropLast() == path.dropLast() }.map { $0.path.last ?? "" }.description
        )
    }

    // MARK: The bar itself

    func testMenuBarIsArcsTenMenusInArcsOrder() {
        XCTAssertEqual(
            topLevelMenus().map(\.title),
            ["Orbit", "File", "Edit", "View", "Spaces", "Tabs", "Archive", "Extensions", "Window", "Help"]
        )
    }

    // MARK: The two rows this work was asked for by name

    /// Asserted through the command rather than the title alone: a
    /// correctly-titled row was once wired to the wrong destination
    /// (`Show Archived Tabs` opened Downloads).
    func testArchiveMenuCarriesViewHistoryBoundToTheHistoryCommand() throws {
        let item = try row(["Archive", "View History"])
        XCTAssertEqual(item.keyEquivalent, "y")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertNotNil(item.action, "View History must be wired to something")
    }

    func testFileMenuCarriesBothCaptureRows() throws {
        let capture = try row(["File", "Capture…"])
        XCTAssertEqual(capture.keyEquivalent, "2")
        XCTAssertEqual(capture.keyEquivalentModifierMask, [.command, .shift])
        _ = try row(["File", "Capture Full Page"])
    }

    // MARK: Nesting Arc uses

    func testDeveloperRowsAreNestedUnderViewDeveloper() throws {
        for title in ["View Source", "Inspect Element", "JavaScript Console", "Toggle Developer Mode"] {
            _ = try row(["View", "Developer", title])
        }
        let flat = walk(try menu("View"), prefix: ["View"]).filter { $0.path.count == 2 }
        XCTAssertFalse(
            flat.contains { $0.path.last == "Inspect Element" },
            "Developer rows must not also appear flat in View"
        )
    }

    func testFindRowsAreNestedUnderEditFind() throws {
        for title in ["Find or Ask", "Find Next", "Find Previous", "Find and Replace"] {
            _ = try row(["Edit", "Find", title])
        }
    }

    func testAppearanceSubmenuMatchesArcsShape() throws {
        let caption = try row(["View", "Appearance", AppearanceSettings.captionTitle])
        XCTAssertNil(caption.action, "The caption row is a label and must not be actionable")
        for title in ["Automatic", "Light", "Dark"] {
            XCTAssertNotNil(try row(["View", "Appearance", title]).action)
        }
    }

    // MARK: Nothing was dropped

    func testEveryPreRestructureRowStillExists() throws {
        let survivors = [
            "About Orbit", "Settings…", "Hide Orbit", "Hide Others", "Show All", "Quit Orbit",
            "New Tab", "New Window", "New Incognito Window", "New Little Orbit",
            "Open Tab in Little Orbit", "New Note", "New Easel", "Close Tab / Window",
            "Reopen Last Closed Tab", "Save Page As…", "Print…",
            "Copy URL", "Copy URL as Markdown", "Paste and Match Style",
            "Find or Ask", "Find Next", "Find Previous", "Find and Replace",
            "Show/Hide Sidebar", "Reload", "Hard Refresh", "Stop",
            "Zoom In", "Zoom Out", "Actual Size", "Add Split", "Close Split",
            "Toggle Developer Mode", "View Source", "Inspect Element", "JavaScript Console",
            "Toggle Full Screen",
            "Clear All Today Tabs", "Pin / Unpin Current Tab", "Show Archived Tabs",
            "View History",       // was "History"
            "View Downloads",     // was "Downloads"
            "Import from Another Browser",
            "Next Space", "Previous Space", "New Space…", "Manage Spaces…",
            "Minimize", "Zoom", "Bring All to Front",
            "Keybinds", "Restore Data", "Troubleshooting", "Open Task Manager",
        ]
        let present = Set(topLevelMenus().flatMap { walk($0, prefix: [$0.title]) }.map { $0.path.last ?? "" })
        let missing = survivors.filter { !present.contains($0) }
        XCTAssertTrue(missing.isEmpty, "Rows lost in the restructure: \(missing)")
    }

    func testToolbarAndJoinMeetingRowsSurvivedAsTheirOwnTypes() throws {
        let allItems = topLevelMenus().flatMap { walk($0, prefix: [$0.title]) }.map(\.item)
        XCTAssertTrue(allItems.contains { $0 is ToolbarVisibilityMenuItem })
        let tabs = walk(try menu("Tabs"), prefix: ["Tabs"]).map(\.item)
        XCTAssertTrue(tabs.contains { $0 is JoinMeetingMenuItem })
    }

    // MARK: No dead rows

    func testNoRowInTheMenuBarIsInert() {
        var inert: [String] = []
        for menu in topLevelMenus() {
            let rows: [(path: [String], item: NSMenuItem)] = walk(menu, prefix: [menu.title])
            for row in rows {
                guard row.item.action == nil, row.item.submenu == nil else { continue }
                guard row.path.last != AppearanceSettings.captionTitle else { continue }
                inert.append(row.path.joined(separator: " > "))
            }
        }
        XCTAssertTrue(inert.isEmpty, "Dead menu rows: \(inert)")
    }

    // MARK: About Orbit — folded into Settings, reached from three doors

    // The command bar's "about" action (CommandBarModel.swift) also calls
    // SettingsWindowController.show(pane: .general); these two menu rows
    // must route to the same place.
    // By controller, not by hosting-view generic: the root view is wrapped in
    // .orbitEnvironment(), so NSHostingView<SettingsRootView> never matches.
    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.windowController is SettingsWindowController }
    }

    func testAboutOrbitRowsAreClosureItemsNotAppKitsStandardPanel() throws {
        let standardAboutSelector = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        for path in [["Orbit", "About Orbit"], ["Help", "About Orbit"]] {
            let item = try row(path)
            let label = path.joined(separator: " > ")
            XCTAssertTrue(item is ClosureMenuItem, "\(label) must be Orbit's own closure-routed row.")
            XCTAssertNotEqual(item.action, standardAboutSelector, "\(label) must never fall back to AppKit's standard About panel.")
            XCTAssertTrue(
                item.target === item,
                "\(label) must target itself, never nil — a nil target falls through the responder chain to AppKit's standard About panel."
            )
        }
    }

    func testNoRowInTheMenuBarUsesAppKitsStandardAboutPanel() {
        let standardAboutSelector = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        let allItems = topLevelMenus().flatMap { walk($0, prefix: [$0.title]) }.map(\.item)
        XCTAssertFalse(
            allItems.contains { $0.action == standardAboutSelector },
            "No row in the menu bar may route to AppKit's standard About panel; Orbit has its own About surface."
        )
    }

    func testAboutOrbitRowsFromBothMenusOpenSettingsOnTheGeneralPane() throws {
        let orbitItem = try row(["Orbit", "About Orbit"])
        let orbitAction = try XCTUnwrap(orbitItem.action)
        NSApp.sendAction(orbitAction, to: orbitItem.target, from: orbitItem)
        let first = try XCTUnwrap(settingsWindow(), "About Orbit must open Orbit's Settings window.")
        XCTAssertEqual(SettingsRouter.shared.selectedPane, .general, "About Orbit must land on the General pane.")

        let helpItem = try row(["Help", "About Orbit"])
        let helpAction = try XCTUnwrap(helpItem.action)
        NSApp.sendAction(helpAction, to: helpItem.target, from: helpItem)
        let second = try XCTUnwrap(settingsWindow())

        XCTAssertIdentical(first, second, "Help's About Orbit must reuse the same Settings window the Orbit menu opened, not a second copy.")
        XCTAssertEqual(SettingsRouter.shared.selectedPane, .general)
        first.close()
    }

    // MARK: Menu bar is kept

    // The SwiftUI App scene installs its own View/Window/Help menu at times Orbit does not control.
    func testMainMenuIsPutBackWhenSomethingReplacesIt() async throws {
        let previous = NSApp.mainMenu
        defer {
            if let previous { MainMenuKeeper.shared.install(previous) }
        }
        let ours = NSMenu(title: "Ours")
        let stock = NSMenu(title: "Stock")

        MainMenuKeeper.shared.install(ours)
        XCTAssertTrue(NSApp.mainMenu === ours)

        NSApp.mainMenu = stock
        MainMenuKeeper.shared.restoreIfReplaced()
        XCTAssertTrue(NSApp.mainMenu === ours, "An explicit check must put Orbit's menu back.")

        // With no check called: the observation alone has to repair it.
        NSApp.mainMenu = stock
        for _ in 0..<50 where NSApp.mainMenu !== ours {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(NSApp.mainMenu === ours, "A replacement that nobody checks for must still be undone.")
    }

    // MARK: Dock menu

    func testDockMenuOffersNewWindowIncognitoAndNewTab() {
        let items = OrbitAppDelegate.buildDockMenu(windows: []).items
        XCTAssertEqual(items.map(\.title), ["New Window", "New Incognito Window", "New Tab"])
    }

    func testDockMenuListsEachOpenWindowBelowTheCommands() {
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let menu = OrbitAppDelegate.buildDockMenu(windows: [
            DockWindowEntry(window: first, title: "Apple"),
            DockWindowEntry(window: second, title: "Incognito: Example"),
        ])

        XCTAssertEqual(
            menu.items.map(\.title),
            ["New Window", "New Incognito Window", "New Tab", "", "Apple", "Incognito: Example"]
        )
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        let rows = menu.items.compactMap { $0 as? DockWindowMenuItem }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNotNil(row.target, "A window row with no target would fall through the empty responder chain of a Dock menu click.")
            XCTAssertNotNil(row.action)
        }
    }

    func testDockWindowRowTitlesAreSingleLineAndBounded() {
        XCTAssertEqual(DockWindowMenuItem.displayTitle("  Apple\nStore  "), "Apple Store")
        XCTAssertEqual(DockWindowMenuItem.displayTitle(""), "Untitled")
        let long = String(repeating: "a", count: 200)
        let shown = DockWindowMenuItem.displayTitle(long)
        XCTAssertEqual(shown.count, DockWindowMenuItem.maximumTitleLength)
        XCTAssertTrue(shown.hasSuffix("\u{2026}"))
    }

    func testDockMenuItemsAreAllTargetedAndActionable() {
        for item in OrbitAppDelegate.buildDockMenu(windows: []).items {
            XCTAssertNotNil(item.target, "Dock row \(item.title) has a nil target and would fall through the responder chain, which is empty for a Dock menu click.")
            XCTAssertNotNil(item.action, "Dock row \(item.title) must be wired to something")
        }
    }

    // Structural, not invoked: proves the Dock rows carry the identical
    // ShortcutCommandID the File menu's own rows dispatch through, so the two
    // surfaces can never drift apart.
    func testDockMenuReusesTheSameCommandsAsTheFileMenu() throws {
        let dockItems = OrbitAppDelegate.buildDockMenu(windows: []).items.compactMap { $0 as? DockCommandMenuItem }
        XCTAssertEqual(dockItems.count, 3, "Every Dock row must be a DockCommandMenuItem")

        let newWindowRow = try row(["File", "New Window"]) as? CommandMenuItem
        let incognitoRow = try row(["File", "New Incognito Window"]) as? CommandMenuItem
        let newTabRow = try row(["File", "New Tab"]) as? CommandMenuItem

        XCTAssertEqual(dockItems.first { $0.title == "New Window" }?.command, newWindowRow?.command)
        XCTAssertEqual(dockItems.first { $0.title == "New Incognito Window" }?.command, incognitoRow?.command)
        XCTAssertEqual(dockItems.first { $0.title == "New Tab" }?.command, newTabRow?.command)

        XCTAssertEqual(dockItems.first { $0.title == "New Window" }?.command, .newWindow)
        XCTAssertEqual(dockItems.first { $0.title == "New Incognito Window" }?.command, .newIncognitoWindow)
        XCTAssertEqual(dockItems.first { $0.title == "New Tab" }?.command, .newTabCommandBar)
    }

    func testDockClickOpensAWindowWhenTheOnlyWindowIsOffScreen() {
        let helper = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        helper.isReleasedWhenClosed = false
        helper.setFrame(NSRect(x: -20000, y: -20000, width: 800, height: 600), display: false)
        helper.orderFrontRegardless()
        defer { helper.orderOut(nil) }

        XCTAssertTrue(helper.isVisible, "The helper is ordered front, which is what makes AppKit report a visible window.")
        XCTAssertNil(helper.screen, "It sits on no display, so it is not a window the user can click.")
        guard case .openNewWindow = OrbitAppDelegate.dockReopenAction(windows: [helper]) else {
            return XCTFail("A dock click with no on-screen window must open one. Trusting hasVisibleWindows here is why the click did nothing.")
        }
    }

    func testDockClickRevealsAWindowThatIsActuallyOnScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(
            contentRect: NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        guard case .revealExisting = OrbitAppDelegate.dockReopenAction(windows: [window]) else {
            return XCTFail("A window on a display must be brought forward, not replaced.")
        }
    }

    func testOrbitDelegateSuppliesTheDockMenu() {
        let delegate = OrbitAppDelegate()
        let menu = delegate.applicationDockMenu(NSApp)
        XCTAssertEqual(menu?.items.map(\.title), ["New Window", "New Incognito Window", "New Tab"])
    }

    private struct MenuRow: Equatable, CustomStringConvertible {
        let title: String
        let key: String
        let mask: NSEvent.ModifierFlags
        var description: String { "\(title) [\(key) \(mask.rawValue)]" }
    }

    private func rows(of menu: NSMenu) -> [MenuRow] {
        let significant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return menu.items.filter { !$0.isSeparatorItem }.map { item in
            MenuRow(
                title: item is ToolbarVisibilityMenuItem ? "<toolbar visibility>" : item.title,
                key: item.keyEquivalent,
                mask: item.keyEquivalent.isEmpty ? [] : item.keyEquivalentModifierMask.intersection(significant)
            )
        }
    }

    func testEveryMenuHoldsExactlyTheRowsAndShortcutsOfArcsBar() throws {
        typealias Mods = NSEvent.ModifierFlags
        let c: Mods = [.command], cs: Mods = [.command, .shift], co: Mods = [.command, .option]
        let cos: Mods = [.command, .option, .shift], ctrl: Mods = [.control]
        let ctrlShift: Mods = [.control, .shift], ctrlOption: Mods = [.control, .option]
        let left = "\u{F702}", right = "\u{F703}", up = "\u{F700}", down = "\u{F701}"
        func r(_ title: String, _ key: String = "", _ mask: Mods = []) -> MenuRow {
            MenuRow(title: title, key: key, mask: mask)
        }

        let expected: [String: [MenuRow]] = [
            "Orbit": [
                r("About Orbit"), r("Settings…", ",", c), r("Set as Default Browser"), r("Import from Another Browser"),
                r("Services"), r("Hide Orbit", "h", c), r("Hide Others", "h", cs), r("Show All"), r("Quit Orbit", "q", c),
            ],
            "File": [
                r("New Tab", "t", c), r("New Window", "n", c), r("New Incognito Window", "n", cs),
                r("New Little Orbit", "n", co), r("Open Tab in Little Orbit", "n", cos), r("Reopen Last Closed Tab", "t", cs),
                r("Open Command Bar", "l", c), r("New Boost"), r("Edit Boost"),
                r("New Note", "n", ctrl), r("New Note (in Split)", "n", ctrlOption), r("New Easel", "l", ctrlShift),
                r("Close Tab / Window", "w", c), r("Share…"), r("Capture…", "2", cs), r("Capture Full Page"),
                r("Save Page As…", "s", cs), r("Print…", "p", c),
            ],
            "Edit": [
                r("Undo", "z", c), r("Redo", "Z", cs), r("Cut", "x", c), r("Copy", "c", c),
                r("Copy URL", "c", cs), r("Copy URL as Markdown", "c", cos), r("Paste", "v", c),
                r("Paste and Match Style", "v", cos), r("Delete"), r("Select All", "a", c), r("Find"),
                r("Spelling and Grammar"), r("Substitutions"), r("Transformations"), r("Speech"), r("Format"),
            ],
            "View": [
                r("Appearance"), r("Show/Hide Sidebar", "s", c), r("<toolbar visibility>", "d", cs),
                r("Expand Pinned Section"), r("Collapse Pinned Section"),
                r("Stop", ".", c), r("Reload", "r", c), r("Hard Refresh", "r", cs),
                r("Clear Cookies and Refresh"), r("Clear Cache for This Site and Refresh"),
                r("Add Split", "=", ctrlShift), r("Close Split", "-", ctrlShift),
                r("Separate Page from Split View"), r("Expand Current Split"),
                r("Actual Size", "0", c), r("Zoom In", "=", c), r("Zoom Out", "-", c),
                r("Developer"), r("Toggle Full Screen", "f", [.command, .control]),
            ],
            "Spaces": [
                r("New Space…"), r("Edit Theme…"), r("Rename Space"), r("Change Profile"),
                r("Next Space", right, co), r("Previous Space", left, co), r("Manage Spaces…"),
            ],
            "Tabs": [
                r("New Tab", "t", c), r("Ask ChatGPT", "g", co), r("Join Meeting", "j", [.control, .command]),
                r("Pin / Unpin Current Tab", "d", c), r("New Folder…"), r("Duplicate"), r("Rename Current Item"),
                r("Collapse All Folders"), r("Expand All Folders"),
                r("Next Tab", down, co), r("Previous Tab", up, co), r("Cycle Recent Tabs", "\t", ctrl),
                r("Reveal Tab in Sidebar", " ", ctrl), r("Clear All Today Tabs", "k", cs), r("Reset Tab to Original URL"),
            ],
            "Archive": [
                r("Go Back", "[", c), r("Go Forward", "]", c), r("View History", "y", c),
                r("Show Archived Tabs"), r("Clear Archive"), r("Import from Another Browser"),
            ],
            "Extensions": [r("Add Extension…"), r("Manage Extensions…")],
            "Window": [
                r("Minimize", "m", c), r("Zoom"), r("View Library", "l", cs), r("View Downloads", "j", cs),
                r("View Easels & Notes"), r("View Media"), r("View Boosts"), r("Bring All to Front"),
            ],
            "Help": [r("Keybinds"), r("About Orbit"), r("Restore Data"), r("Troubleshooting")],
        ]

        let menus = topLevelMenus()
        XCTAssertEqual(menus.map(\.title).sorted(), expected.keys.sorted())
        for menu in menus {
            var actual = rows(of: menu)
            let want = try XCTUnwrap(expected[menu.title])
            if menu.title == "Window" {
                // AppKit appends one row per open window to the Window menu
                let owned = Set(want.map(\.title))
                actual = actual.filter { owned.contains($0.title) }
            }
            XCTAssertEqual(actual, want, "\(menu.title) menu rows differ")
        }

        XCTAssertEqual(rows(of: try XCTUnwrap(try row(["Help", "Troubleshooting"]).submenu)).map(\.title),
                       ["Open Task Manager", "Reveal Orbit Data", "Copy Orbit Info"])
        XCTAssertEqual(rows(of: try XCTUnwrap(try row(["Edit", "Find"]).submenu)).map(\.title),
                       ["Find or Ask", "Find and Replace", "Find Next", "Find Previous", "Jump to Selection"])
        XCTAssertEqual(rows(of: try XCTUnwrap(try row(["View", "Developer"]).submenu)).map(\.title),
                       ["View Source", "Inspect Element", "JavaScript Console", "Toggle Developer Mode", "Toggle Device Toolbar"])
    }
}
