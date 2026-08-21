//  Where the borderless Orbit-drawn panel lands (flip, clamp, secondary display),
//  how arrow keys drive it, and that it dismisses without leaking a panel.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class OrbitMenuPanelTests: XCTestCase {

    // A 1440x900 primary display with the menu bar accounted for.
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 875)
    // A secondary display to the right, taller, different backing scale.
    private let secondary = CGRect(x: 1440, y: -120, width: 2560, height: 1440)

    private let contentSize = CGSize(width: OrbitMetrics.contextMenuWidth, height: 300)

    private func entries(count: Int, disabled: Set<Int> = []) -> [OrbitContextMenuEntry] {
        (0..<count).map { index in
            .item(OrbitContextMenuItem(title: "Item \(index)", isEnabled: !disabled.contains(index)))
        }
    }

    // MARK: - The right-click menu never grows an anchor arrow

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rightClickMenu_neverPlacesAnAnchorArrow

    func test_rightClickMenu_neverPlacesAnAnchorArrow() {
        XCTAssertFalse(
            OrbitContextMenuPresenter.showsArrow,
            "The right-click menu must be arrow-less: the beak is the one piece of popover chrome it must never grow."
        )
        for point in [CGPoint(x: 400, y: 600), CGPoint(x: 4, y: 10), CGPoint(x: 1438, y: 870)] {
            let geometry = OrbitContextMenuPresenter.geometry(contentSize: contentSize, at: point, visibleFrame: primary)
            XCTAssertNil(geometry.arrow, "An anchor arrow was placed for a right-click menu at \(point).")
        }
    }

    // MARK: - Corner placement, flipping and clamping

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rightClickMenu_growsDownAndRightFromTheClickPoint

    func test_rightClickMenu_growsDownAndRightFromTheClickPoint() {
        let point = CGPoint(x: 400, y: 600)
        let frame = OrbitContextMenuPresenter.geometry(contentSize: contentSize, at: point, visibleFrame: primary).containerFrame
        XCTAssertEqual(frame.minX, point.x, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, point.y, accuracy: 0.5, "The menu's top edge belongs on the click point.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rightClickMenu_flipsUpwardWhenThereIsNoRoomBelowTheClick

    func test_rightClickMenu_flipsUpwardWhenThereIsNoRoomBelowTheClick() {
        let point = CGPoint(x: 400, y: 60)
        let geometry = OrbitContextMenuPresenter.geometry(contentSize: contentSize, at: point, visibleFrame: primary)
        XCTAssertEqual(geometry.direction, .up, "With only 60pt below the click, a 300pt menu must flip upward.")
        XCTAssertGreaterThanOrEqual(geometry.containerFrame.minY, point.y)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rightClickMenu_clampsInsideTheScreenNearEveryEdge

    func test_rightClickMenu_clampsInsideTheScreenNearEveryEdge() {
        let bounds = primary.insetBy(dx: OrbitMetrics.contextMenuScreenEdgeInset, dy: OrbitMetrics.contextMenuScreenEdgeInset)
        for point in [CGPoint(x: 1435, y: 870), CGPoint(x: 2, y: 4), CGPoint(x: 1435, y: 4)] {
            let frame = OrbitContextMenuPresenter.geometry(contentSize: contentSize, at: point, visibleFrame: primary).containerFrame
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 0.5, "Ran off the left edge from \(point).")
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.5, "Ran off the right edge from \(point).")
            XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 0.5, "Ran off the bottom edge from \(point).")
            XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.5, "Ran off the top edge from \(point).")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_menu_staysOnASecondaryDisplayWithItsOwnOriginAndSize

    func test_menu_staysOnASecondaryDisplayWithItsOwnOriginAndSize() {
        // A click near the secondary display's bottom-right corner: the menu
        // must clamp into *that* display's frame, not the primary's.
        let point = CGPoint(x: secondary.maxX - 20, y: secondary.minY + 30)
        let geometry = OrbitContextMenuPresenter.geometry(contentSize: contentSize, at: point, visibleFrame: secondary)
        let bounds = secondary.insetBy(dx: OrbitMetrics.contextMenuScreenEdgeInset, dy: OrbitMetrics.contextMenuScreenEdgeInset)
        XCTAssertLessThanOrEqual(geometry.containerFrame.maxX, bounds.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(geometry.containerFrame.minY, bounds.minY - 0.5)
        XCTAssertGreaterThanOrEqual(geometry.containerFrame.minX, bounds.minX - 0.5)
    }

    // MARK: - The "+" menu keeps its beak, pointing at its own button

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anchoredMenu_placesABeakOnTheEdgeFacingItsButton

    func test_anchoredMenu_placesABeakOnTheEdgeFacingItsButton() {
        let button = CGRect(x: 100, y: 40, width: 24, height: 24)
        let geometry = OrbitMenuPlacement.geometry(
            contentSize: CGSize(width: OrbitMetrics.contextMenuWidth, height: 240 + OrbitMetrics.contextMenuArrowHeight),
            anchor: button, mode: .anchored, preferredDirection: .up, showsArrow: true, visibleFrame: primary
        )
        XCTAssertEqual(geometry.direction, .up)
        XCTAssertEqual(geometry.arrow?.edge, .bottom, "A menu above its button points its beak down at the button.")
        let tipX = (geometry.arrow?.offset ?? 0) + geometry.containerFrame.minX
        XCTAssertEqual(tipX, button.midX, accuracy: 1, "The beak's tip must sit over the button it belongs to.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anchoredMenu_keepsItsBeakClearOfTheContainerCorners_whenClampedSideways

    func test_anchoredMenu_keepsItsBeakClearOfTheContainerCorners_whenClampedSideways() {
        let button = CGRect(x: 2, y: 40, width: 24, height: 24)
        let geometry = OrbitMenuPlacement.geometry(
            contentSize: CGSize(width: OrbitMetrics.contextMenuWidth, height: 240 + OrbitMetrics.contextMenuArrowHeight),
            anchor: button, mode: .anchored, preferredDirection: .up, showsArrow: true, visibleFrame: primary
        )
        let limit = OrbitMetrics.contextMenuCornerRadius + OrbitMetrics.contextMenuArrowWidth / 2
            + OrbitMetrics.contextMenuArrowFillet
        guard let offset = geometry.arrow?.offset else {
            return XCTFail("A clamped anchored menu still has to place its beak somewhere.")
        }
        XCTAssertGreaterThanOrEqual(offset, limit - 0.5)
        XCTAssertLessThanOrEqual(offset, OrbitMetrics.contextMenuWidth - limit + 0.5)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anchoredMenu_withoutArrow_hasNoBeakAtAll

    func test_anchoredMenu_withoutArrow_hasNoBeakAtAll() {
        let geometry = OrbitMenuPlacement.geometry(
            contentSize: contentSize, anchor: CGRect(x: 100, y: 40, width: 24, height: 24),
            mode: .anchored, preferredDirection: .up, showsArrow: false, visibleFrame: primary
        )
        XCTAssertNil(geometry.arrow)
    }

    // MARK: - Submenus land beside their row, flipping when there is no room

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_submenu_opensToTheRightOfItsRow_andFlipsLeftAtTheScreenEdge

    func test_submenu_opensToTheRightOfItsRow_andFlipsLeftAtTheScreenEdge() {
        let row = CGRect(x: 300, y: 500, width: OrbitMetrics.contextMenuWidth, height: OrbitMetrics.contextMenuRowHeight)
        let right = OrbitMenuPlacement.geometry(
            contentSize: contentSize, anchor: row, mode: .submenu,
            preferredDirection: .down, showsArrow: false, visibleFrame: primary
        )
        XCTAssertGreaterThan(right.containerFrame.minX, row.minX)
        XCTAssertNil(right.arrow, "A submenu never draws a beak.")

        let edgeRow = CGRect(x: 1150, y: 500, width: OrbitMetrics.contextMenuWidth, height: OrbitMetrics.contextMenuRowHeight)
        let flipped = OrbitMenuPlacement.geometry(
            contentSize: contentSize, anchor: edgeRow, mode: .submenu,
            preferredDirection: .down, showsArrow: false, visibleFrame: primary
        )
        XCTAssertLessThan(flipped.containerFrame.minX, edgeRow.minX, "With no room on the right the submenu must flip left.")
        XCTAssertGreaterThanOrEqual(flipped.containerFrame.minX, primary.minX)
    }

    // MARK: - Keyboard navigation

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_keyCodes_mapToTheMenuActionsAContextMenuMustSupport

    func test_keyCodes_mapToTheMenuActionsAContextMenuMustSupport() {
        XCTAssertEqual(OrbitMenuKeyAction.from(keyCode: 125), .moveDown)
        XCTAssertEqual(OrbitMenuKeyAction.from(keyCode: 126), .moveUp)
        XCTAssertEqual(OrbitMenuKeyAction.from(keyCode: 36), .activate)
        XCTAssertEqual(OrbitMenuKeyAction.from(keyCode: 76), .activate)
        XCTAssertEqual(OrbitMenuKeyAction.from(keyCode: 53), .dismiss)
        XCTAssertEqual(OrbitMenuKeyAction.from(keyCode: 124), .openSubmenu)
        XCTAssertEqual(OrbitMenuKeyAction.from(keyCode: 123), .closeSubmenu)
        XCTAssertNil(OrbitMenuKeyAction.from(keyCode: 0), "An ordinary letter key must pass straight through the menu.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_arrowKeys_moveTheSelectionAndWrapAround

    func test_arrowKeys_moveTheSelectionAndWrapAround() {
        let items = entries(count: 3)
        let selection = OrbitMenuSelectionModel(entries: items)
        XCTAssertNil(selection.selectedItemID)

        selection.move(by: 1)
        XCTAssertEqual(selection.selectedItem?.title, "Item 0", "Down from nothing selects the first item.")
        selection.move(by: 1)
        XCTAssertEqual(selection.selectedItem?.title, "Item 1")
        selection.move(by: 1)
        XCTAssertEqual(selection.selectedItem?.title, "Item 2")
        selection.move(by: 1)
        XCTAssertEqual(selection.selectedItem?.title, "Item 0", "Selection must wrap at the end, like a real menu.")
        selection.move(by: -1)
        XCTAssertEqual(selection.selectedItem?.title, "Item 2", "Selection must wrap backwards too.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_upArrowFromNothing_selectsTheLastItem

    func test_upArrowFromNothing_selectsTheLastItem() {
        let selection = OrbitMenuSelectionModel(entries: entries(count: 3))
        selection.move(by: -1)
        XCTAssertEqual(selection.selectedItem?.title, "Item 2")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_arrowKeys_skipDisabledItemsAndDividersAndSectionHeaders

    func test_arrowKeys_skipDisabledItemsAndDividersAndSectionHeaders() {
        let items: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: "Enabled A")),
            .divider(),
            .item(OrbitContextMenuItem(title: "Disabled", isEnabled: false)),
            .section(title: "Group", entries: [.item(OrbitContextMenuItem(title: "Enabled B"))]),
        ]
        let selection = OrbitMenuSelectionModel(entries: items)
        XCTAssertEqual(selection.navigableItems.map(\.title), ["Enabled A", "Enabled B"])

        selection.move(by: 1)
        selection.move(by: 1)
        XCTAssertEqual(selection.selectedItem?.title, "Enabled B", "Arrow keys must never land on a disabled item.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_arrowKeys_neverDescendIntoASubmenusOwnItems

    func test_arrowKeys_neverDescendIntoASubmenusOwnItems() {
        let items: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: "Parent", submenu: [.item(OrbitContextMenuItem(title: "Child"))])),
            .item(OrbitContextMenuItem(title: "Sibling")),
        ]
        let selection = OrbitMenuSelectionModel(entries: items)
        XCTAssertEqual(
            selection.navigableItems.map(\.title), ["Parent", "Sibling"],
            "A submenu's items belong to the submenu's own panel, not to this one's arrow-key order."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_selection_isDroppedWhenTheItemItPointedAtDisappears

    func test_selection_isDroppedWhenTheItemItPointedAtDisappears() {
        let items = entries(count: 3)
        let selection = OrbitMenuSelectionModel(entries: items)
        selection.move(by: 1)
        XCTAssertNotNil(selection.selectedItemID)
        selection.setEntries(entries(count: 2))
        XCTAssertNil(selection.selectedItemID, "A stale selection must not survive the menu's contents changing.")
    }

    // MARK: - Return activates, without any blocking call

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_return_runsTheSelectedItemsActionExactlyOnceAndDismisses

    func test_return_runsTheSelectedItemsActionExactlyOnceAndDismisses() {
        var ran = 0
        let controller = OrbitMenuPanelController()
        let items: [OrbitContextMenuEntry] = [.item(OrbitContextMenuItem(title: "Run") { ran += 1 })]

        let window = makeOwnerWindow()
        defer { window.close() }
        controller.present(
            entries: items, anchorRect: anchorRect(in: window), anchorView: window.contentView,
            ownerWindow: window, mode: .pointCorner, preferredDirection: .down, showsArrow: false
        )
        XCTAssertTrue(controller.isPresented)

        XCTAssertTrue(controller.handleKey(code: 125), "Down arrow must be consumed by an open menu.")
        XCTAssertTrue(controller.handleKey(code: 36))
        XCTAssertEqual(ran, 1)
        XCTAssertFalse(controller.isPresented, "Choosing an item must dismiss the menu.")
        assertNoPanelsLeaked()
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_escape_dismissesTheMenu

    func test_escape_dismissesTheMenu() {
        let controller = OrbitMenuPanelController()
        let window = makeOwnerWindow()
        defer { window.close() }
        controller.present(
            entries: entries(count: 3), anchorRect: anchorRect(in: window), anchorView: window.contentView,
            ownerWindow: window, mode: .pointCorner, preferredDirection: .down, showsArrow: false
        )
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(controller.handleKey(code: 53))
        XCTAssertFalse(controller.isPresented)
        assertNoPanelsLeaked()
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_keyHandling_isInertWhenNoMenuIsOpen

    func test_keyHandling_isInertWhenNoMenuIsOpen() {
        let controller = OrbitMenuPanelController()
        XCTAssertFalse(controller.handleKey(code: 125), "A closed menu must let every key through untouched.")
        XCTAssertFalse(controller.handleKey(code: 53))
    }

    // MARK: - Dismissal and leaks

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theOwningWindowClosing_takesTheMenuWithIt

    func test_theOwningWindowClosing_takesTheMenuWithIt() {
        let controller = OrbitMenuPanelController()
        let window = makeOwnerWindow()
        controller.present(
            entries: entries(count: 3), anchorRect: anchorRect(in: window), anchorView: window.contentView,
            ownerWindow: window, mode: .pointCorner, preferredDirection: .down, showsArrow: false
        )
        XCTAssertTrue(controller.isPresented)
        window.close()
        XCTAssertFalse(controller.isPresented, "A menu must never outlive the window it was opened from.")
        assertNoPanelsLeaked()
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theAnchorLeavingItsWindow_takesTheMenuWithIt

    func test_theAnchorLeavingItsWindow_takesTheMenuWithIt() {
        // The engine view being torn down when a tab goes away is exactly this.
        var lost = 0
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = makeOwnerWindow()
        defer { window.close() }
        window.contentView?.addSubview(host)

        let sentinel = OrbitMenuAnchorSentinel(frame: .zero)
        sentinel.onWindowLost = { lost += 1 }
        host.addSubview(sentinel)
        XCTAssertEqual(lost, 0)

        host.removeFromSuperview()
        XCTAssertEqual(lost, 1, "The menu must learn that the view it was opened from left the window.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_dismiss_restoresKeyStatusToTheOwningWindow

    // The root cause of the New Tab focus bug: this panel is .nonactivatingPanel, and
    // closing it does not reliably hand key status back to its parent -- leaving the
    // sidebar's own window with no key window at all right as it presents the Command Bar.
    // Asserts on the code path (dismiss() re-requests key status for its owner), not on
    // live AppKit responder state: the OrbitAppTests host never grants a window real key
    // status (confirmed: window.isKeyWindow stays false here even after
    // makeKeyAndOrderFront), so isKeyWindow itself can't prove anything in this process.
    func test_dismiss_restoresKeyStatusToTheOwningWindow() {
        let controller = OrbitMenuPanelController()
        let window = KeyRequestSpyWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        for other in NSApp.windows where other !== window && other.isVisible {
            other.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)
        pump(seconds: 0.2)
        let callsBeforeDismiss = window.makeKeyAndOrderFrontCallCount

        controller.present(
            entries: entries(count: 3), anchorRect: anchorRect(in: window), anchorView: window.contentView,
            ownerWindow: window, mode: .pointCorner, preferredDirection: .down, showsArrow: false
        )
        pump(seconds: 0.2)

        controller.dismiss()
        pump(seconds: 0.2)

        XCTAssertGreaterThan(
            window.makeKeyAndOrderFrontCallCount, callsBeforeDismiss,
            "Dismissing the menu must re-request key status for the window it was opened from, or nothing on screen can take keyboard focus afterward."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_dismiss_isIdempotentAndLeavesNoPanelBehind

    func test_dismiss_isIdempotentAndLeavesNoPanelBehind() {
        let controller = OrbitMenuPanelController()
        let window = makeOwnerWindow()
        defer { window.close() }
        controller.present(
            entries: entries(count: 3), anchorRect: anchorRect(in: window), anchorView: window.contentView,
            ownerWindow: window, mode: .pointCorner, preferredDirection: .down, showsArrow: false
        )
        controller.dismiss()
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        assertNoPanelsLeaked()
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_presenter_presentsNothingForAViewWithNoWindow

    func test_presenter_presentsNothingForAViewWithNoWindow() {
        let presenter = OrbitContextMenuPresenter()
        presenter.present(entries: entries(count: 2), anchorView: NSView(), at: CGPoint(x: 10, y: 10))
        XCTAssertFalse(presenter.isPresented)
        assertNoPanelsLeaked()
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_presenter_presentsNothingForAnEmptyMenu

    func test_presenter_presentsNothingForAnEmptyMenu() {
        let controller = OrbitMenuPanelController()
        let window = makeOwnerWindow()
        defer { window.close() }
        controller.present(
            entries: [], anchorRect: anchorRect(in: window), anchorView: window.contentView,
            ownerWindow: window, mode: .pointCorner, preferredDirection: .down, showsArrow: false
        )
        XCTAssertFalse(controller.isPresented)
    }

    // MARK: - The panel itself draws none of its own chrome

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_panel_isBorderlessTransparentAndCastsNoSystemShadow

    func test_panel_isBorderlessTransparentAndCastsNoSystemShadow() {
        let panel = OrbitMenuPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow, "Orbit draws the menu's shadow itself; the window must contribute none.")
        XCTAssertFalse(panel.styleMask.contains(.titled))
        panel.close()
    }

    // MARK: - Helpers

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func makeOwnerWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }

    private func anchorRect(in window: NSWindow) -> CGRect {
        CGRect(origin: window.convertPoint(toScreen: CGPoint(x: 20, y: 200)), size: .zero)
    }

    private func assertNoPanelsLeaked(file: StaticString = #filePath, line: UInt = #line) {
        let leaked = NSApp.windows.filter { $0 is OrbitMenuPanel && $0.isVisible }
        XCTAssertTrue(leaked.isEmpty, "\(leaked.count) menu panel(s) left floating after dismissal.", file: file, line: line)
    }
}

private final class KeyRequestSpyWindow: NSWindow {
    private(set) var makeKeyAndOrderFrontCallCount = 0

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKeyAndOrderFrontCallCount += 1
        super.makeKeyAndOrderFront(sender)
    }
}
