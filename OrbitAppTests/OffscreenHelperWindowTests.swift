//  The window WebKit composites background pages in must never be seen. A fullscreen video showed it as a blank grey box
//  because it was opaque and marked as a fullscreen auxiliary, which brings it into the Space and onto the screen.

import AppKit
import XCTest
@testable import Orbit

@MainActor
final class OffscreenHelperWindowTests: XCTestCase {

    private func makeWindow() -> OffscreenHelperWindow {
        OffscreenHelperWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600))
    }

    func test_theWindowCannotBeSeenIfItIsEverOnScreen() {
        let window = makeWindow()
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, NSColor.clear)
        XCTAssertLessThan(window.alphaValue, 0.05)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.hasShadow)
    }

    func test_theWindowIsNotBroughtIntoFullscreenSpaces() {
        let window = makeWindow()
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.transient))
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle))
    }

    func test_theWindowStaysWhereItIsParked() {
        let window = makeWindow()
        let parked = NSRect(x: -20000, y: -20000, width: 800, height: 600)
        let screen = NSScreen.screens.first
        XCTAssertEqual(window.constrainFrameRect(parked, to: screen), parked)
    }

    func test_theWindowNeverTakesFocus() {
        let window = makeWindow()
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
    }
}
