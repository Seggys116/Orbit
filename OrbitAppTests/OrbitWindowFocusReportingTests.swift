//  What windowDidResignKey calls "Orbit lost focus": chrome.windows' focus push feeds
//  WINDOW_ID_CURRENT, so a popover inheriting key status from its parent still counts.

import AppKit
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class OrbitWindowFocusReportingTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            window.delegate = nil
        }
        windows.removeAll()
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anOrbitWindowItselfCountsAsOrbitHoldingFocus

    func test_anOrbitWindowItselfCountsAsOrbitHoldingFocus() {
        let orbitWindow = makeWindow()
        XCTAssertTrue(OrbitWindowController.isAttached(orbitWindow, toOneOf: [orbitWindow]))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aPopoverAttachedToAnOrbitWindowCountsAsOrbitHoldingFocus

    func test_aPopoverAttachedToAnOrbitWindowCountsAsOrbitHoldingFocus() {
        let orbitWindow = makeWindow()
        let popover = makeWindow()
        orbitWindow.addChildWindow(popover, ordered: .above)

        XCTAssertTrue(
            OrbitWindowController.isAttached(popover, toOneOf: [orbitWindow]),
            "a popover takes key status from the window it is attached to; Orbit has not lost focus"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aPopoverNestedInsideAnotherPopoverCountsAsOrbitHoldingFocus

    func test_aPopoverNestedInsideAnotherPopoverCountsAsOrbitHoldingFocus() {
        let orbitWindow = makeWindow()
        let siteControlPopover = makeWindow()
        let extensionActionPopup = makeWindow()
        orbitWindow.addChildWindow(siteControlPopover, ordered: .above)
        siteControlPopover.addChildWindow(extensionActionPopup, ordered: .above)

        XCTAssertTrue(
            OrbitWindowController.isAttached(extensionActionPopup, toOneOf: [orbitWindow]),
            """
            this is exactly how an extension action popup is hosted -- a popover on the site control \
            popover. Calling this "Orbit lost focus" is what left the popup's own worker unable to \
            resolve the active tab it was asked about
            """
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anUnrelatedWindowIsNotOrbitHoldingFocus

    func test_anUnrelatedWindowIsNotOrbitHoldingFocus() {
        let orbitWindow = makeWindow()
        let unrelated = makeWindow()
        XCTAssertFalse(OrbitWindowController.isAttached(unrelated, toOneOf: [orbitWindow]))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noKeyWindowAtAllIsNotOrbitHoldingFocus

    func test_noKeyWindowAtAllIsNotOrbitHoldingFocus() {
        let orbitWindow = makeWindow()
        XCTAssertFalse(OrbitWindowController.isAttached(nil, toOneOf: [orbitWindow]))
    }
}
