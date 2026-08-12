import XCTest
import AppKit

@MainActor
final class OrbitNSMenuButtonTests: XCTestCase {

    private func mouseDownEvent(at point: NSPoint = NSPoint(x: 5, y: 5)) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // MARK: - The click genuinely fires the action (the user's exact complaint)

    func test_mouseDown_invokesMenuProvider() {
        let view = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var providerCallCount = 0
        view.menuProvider = { providerCallCount += 1; return NSMenu() }
        view.presentMenu = { _, _ in } // isolate: don't actually run AppKit's modal menu-tracking loop

        view.mouseDown(with: mouseDownEvent())

        XCTAssertEqual(providerCallCount, 1, "A click must invoke the menu provider exactly once — this is the control's action actually firing.")
    }

    func test_mouseDown_presentsTheExactMenuTheProviderReturns() {
        let expectedMenu = NSMenu()
        expectedMenu.addItem(withTitle: "Split Right", action: nil, keyEquivalent: "")
        expectedMenu.addItem(withTitle: "Split Left", action: nil, keyEquivalent: "")

        let view = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        view.menuProvider = { expectedMenu }

        var presentedMenu: NSMenu?
        var presentedIn: NSView?
        view.presentMenu = { menu, presentingView in
            presentedMenu = menu
            presentedIn = presentingView
        }

        view.mouseDown(with: mouseDownEvent())

        XCTAssertTrue(presentedMenu === expectedMenu, "The exact NSMenu instance menuProvider() returned must be what gets presented.")
        XCTAssertEqual(presentedMenu?.items.map(\.title), ["Split Right", "Split Left"], "Menu content must reach presentation unmodified.")
        XCTAssertTrue(presentedIn === view, "The menu must be presented relative to the control that was clicked.")
    }

    func test_mouseDown_withNoMenuProvider_doesNothingAndDoesNotCrash() {
        let view = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var presented = false
        view.presentMenu = { _, _ in presented = true }

        view.mouseDown(with: mouseDownEvent())

        XCTAssertFalse(presented, "With no menuProvider wired up, a click must not call presentMenu.")
    }

    // MARK: - Hit testing: this view must always claim its own bounds

    func test_hitTest_claimsPointsInsideBounds() {
        let view = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertTrue(view.hitTest(NSPoint(x: 10, y: 10)) === view)
        XCTAssertTrue(view.hitTest(NSPoint(x: 0, y: 0)) === view)
    }

    func test_hitTest_returnsNilOutsideBounds() {
        let view = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertNil(view.hitTest(NSPoint(x: -5, y: -5)))
        XCTAssertNil(view.hitTest(NSPoint(x: 25, y: 25)))
    }

    // MARK: - First click after window activation must not be wasted

    func test_acceptsFirstMouse_isTrue() {
        let view = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertTrue(view.acceptsFirstMouse(for: nil), "A click on this control that also activates a background window must not be wasted — matches SidebarResizeHandleNSView's own acceptsFirstMouse.")
    }

    // MARK: - Never a window-drag handle (interaction fix, this round)

    func test_clickCatcher_isNeverAWindowDragHandle() {
        let view = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "An OrbitMenuButtonClickCatchingView must never report itself as a window-drag handle — that is precisely what let AppKit swallow its mouseDown to move/zoom the window before menuProvider() could ever run, matching the user's 'whole bar drags, buttons are dead' report."
        )
    }
}
