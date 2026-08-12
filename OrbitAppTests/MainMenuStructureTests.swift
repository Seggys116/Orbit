import AppKit
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

    func testDumpMenuBarForComparisonWithArcsNib() {
        func emit(_ menu: NSMenu, _ depth: Int) {
            for item in menu.items {
                let pad: String = String(repeating: "  ", count: depth)
                let mods: UInt = item.keyEquivalentModifierMask.rawValue
                var key: String = ""
                if !item.keyEquivalent.isEmpty {
                    key = "  KEY[" + String(mods) + ":" + item.keyEquivalent + "]"
                }
                let title: String = item.isSeparatorItem ? "-----" : item.title
                print(pad + title + key)
                if let submenu = item.submenu { emit(submenu, depth + 1) }
            }
        }
        print("=== ORBIT MENU BAR ===")
        for menu in topLevelMenus() {
            print(menu.title)
            emit(menu, 1)
        }
    }
}
