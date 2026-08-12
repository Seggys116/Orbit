//  Pure model coverage for OrbitContextMenuEntry/OrbitContextMenuItem, independent
//  of AppKit presentation (OrbitContextMenuPresenterTests) and web-content wiring.

import XCTest
@testable import Orbit

final class OrbitContextMenuModelTests: XCTestCase {

    // MARK: - flattenedItems

    func test_flattenedItems_skipsDividersAndSectionHeaders_keepsRealItems() {
        let entries: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: "One")),
            .divider(),
            .section(title: "Group", entries: [
                .item(OrbitContextMenuItem(title: "Two")),
                .item(OrbitContextMenuItem(title: "Three")),
            ]),
        ]
        XCTAssertEqual(entries.flattenedItems.map(\.title), ["One", "Two", "Three"])
    }

    func test_flattenedItems_recursesIntoSubmenus() {
        let entries: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: "Parent", submenu: [
                .item(OrbitContextMenuItem(title: "Child A")),
                .item(OrbitContextMenuItem(title: "Child B")),
            ])),
        ]
        XCTAssertEqual(entries.flattenedItems.map(\.title), ["Parent", "Child A", "Child B"])
    }

    func test_first_titled_findsAnItemNestedInsideASection() {
        let entries: [OrbitContextMenuEntry] = [
            .section(title: "Group", entries: [
                .item(OrbitContextMenuItem(title: "Nested Target")),
            ]),
        ]
        XCTAssertNotNil(entries.first(titled: "Nested Target"))
        XCTAssertNil(entries.first(titled: "Not Present"))
    }

    // MARK: - hasSubmenu

    func test_hasSubmenu_isFalseForAnEmptyOrMissingSubmenuArray() {
        XCTAssertFalse(OrbitContextMenuItem(title: "No submenu").hasSubmenu)
        XCTAssertFalse(OrbitContextMenuItem(title: "Empty submenu", submenu: []).hasSubmenu)
    }

    func test_hasSubmenu_isTrueWhenSubmenuHasEntries() {
        XCTAssertTrue(
            OrbitContextMenuItem(title: "Has submenu", submenu: [.item(OrbitContextMenuItem(title: "Child"))]).hasSubmenu
        )
    }

    // MARK: - Defaults

    func test_item_defaultsToEnabledAndNonDestructive() {
        let item = OrbitContextMenuItem(title: "Plain")
        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(item.isDestructive)
        XCTAssertNil(item.tooltip)
        XCTAssertNil(item.shortcut)
    }

    // MARK: - Every distinct .divider()/.section(...) call gets its own identity

    func test_repeatedDividerCalls_haveDistinctIdentities() {
        let first = OrbitContextMenuEntry.divider()
        let second = OrbitContextMenuEntry.divider()
        XCTAssertNotEqual(first.id, second.id, "Two dividers in the same menu must not collide as the same Identifiable id in a ForEach.")
    }

    // MARK: - Action wiring

    func test_itemAction_isInvokedExactlyOnceWhenCalled() {
        var callCount = 0
        let item = OrbitContextMenuItem(title: "Counted") { callCount += 1 }
        item.action?()
        XCTAssertEqual(callCount, 1)
    }
}
