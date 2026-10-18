import AppKit
import XCTest
@testable import Orbit

// tearDown shuts down the demo environment's own engine; the shared live engine is never touched.
@MainActor
// Excluded on GitHub-hosted runners: hosts a real window and starts a real engine.
final class DockMenuNewTabTests: XCTestCase {

    private var scratchEnv: AppEnvironment?
    private var previousProcessRoot: AppEnvironment?
    private var previousCommandDispatch: ((_ extensionID: String, _ name: String) -> Bool)?

    private func closeAllOpenWindows() {
        for env in OrbitWindowController.openEnvironments {
            OrbitWindowController.controller(for: env)?.window?.close()
        }
    }

    override func setUp() {
        super.setUp()
        closeAllOpenWindows()
        // Scoped to a throwaway demo environment, not .shared, so the engine cannot bleed out.
        previousProcessRoot = AppEnvironment.processRoot
        previousCommandDispatch = ExtensionCommandRegistry.shared.dispatch
        let env = AppEnvironment.demo
        scratchEnv = env
        AppEnvironment.processRoot = env
    }

    override func tearDown() {
        closeAllOpenWindows()
        _ = scratchEnv?.shutdownEngine()
        scratchEnv = nil
        ExtensionCommandRegistry.shared.dispatch = previousCommandDispatch
        previousCommandDispatch = nil
        if let previousProcessRoot { AppEnvironment.processRoot = previousProcessRoot }
        super.tearDown()
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_newTabDockItem_withNoWindowOpen_opensARealWindow

    func test_newTabDockItem_withNoWindowOpen_opensARealWindow() throws {
        XCTAssertTrue(OrbitWindowController.openEnvironments.isEmpty, "test precondition: no window is open")

        let menu = OrbitAppDelegate.buildDockMenu()
        guard let newTabItem = menu.items.first(where: { $0.title == "New Tab" }) else {
            return XCTFail("test precondition: the dock menu has no 'New Tab' item")
        }
        guard let action = newTabItem.action else {
            return XCTFail("test precondition: 'New Tab' has no action")
        }

        // The real AppKit dispatch a menu click would use, not calling a Swift method directly.
        NSApp.sendAction(action, to: newTabItem.target, from: newTabItem)

        XCTAssertFalse(
            OrbitWindowController.openEnvironments.isEmpty,
            "The dock menu's New Tab item's own precondition (OrbitWindowController.activateBrowserWindow()) must open a window when none exists — invoking the item's real action left none open."
        )
    }
}
