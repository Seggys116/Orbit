import AppKit
import XCTest
@testable import Orbit

/// Cmd-V reaches a text field only through the Paste row of Orbit's own Edit menu. A long-running Orbit once ended up with SwiftUI's stock menu bar
/// (no Edit menu), so every native text field beeped. These tests need no window and never activate the app.
@MainActor
final class PasteIntoTextFieldTests: XCTestCase {

    private var previousMenu: NSMenu?

    override func setUp() async throws {
        previousMenu = NSApp.mainMenu
    }

    override func tearDown() async throws {
        GlobalKeyEventMonitor.shared.stop()
        if let previousMenu { MainMenuKeeper.shared.install(previousMenu) }
    }

    private func commandV() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        ))
    }

    private func editMenu(of main: NSMenu?) -> NSMenu? {
        main?.items.compactMap(\.submenu).first { $0.title == "Edit" }
    }

    func testOrbitsMenuBarHasAPasteRowOnCommandV() throws {
        let edit = try XCTUnwrap(editMenu(of: MainMenuBuilder.build()))
        let paste = try XCTUnwrap(edit.items.first { $0.title == "Paste" })
        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertEqual(paste.keyEquivalentModifierMask, [.command])
        XCTAssertNil(paste.target, "Paste must follow the responder chain to whichever field is editing")
        XCTAssertEqual(paste.action, #selector(NSText.paste(_:)))
    }

    func testNoShortcutOrExtensionCommandClaimsPlainCommandV() throws {
        let event = try commandV()
        XCTAssertNil(ShortcutRegistry.shared.command(matching: event), "A shortcut is bound to Cmd-V and would swallow every paste")
        XCTAssertNotNil(GlobalKeyEventMonitor.handle(event, in: .frontmost), "The global key monitor consumed Cmd-V")
    }

    // MARK: The menu bar is kept

    func testStockMenuSwappedInAfterLaunchIsReplacedWithoutAnyoneAskingTheKeeper() async throws {
        let ours = MainMenuBuilder.build()
        MainMenuKeeper.shared.install(ours)
        XCTAssertTrue(MainMenuKeeper.shared.isIntact)

        let stock = NSMenu(title: "Stock")
        stock.addItem(NSMenuItem(title: "View", action: nil, keyEquivalent: ""))
        NSApp.mainMenu = stock
        XCTAssertFalse(MainMenuKeeper.shared.isIntact)

        for _ in 0..<100 where NSApp.mainMenu !== ours { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(NSApp.mainMenu === ours)
        XCTAssertNotNil(editMenu(of: NSApp.mainMenu), "Orbit's Edit menu is missing after the stock menu was swapped in")
    }

    func testRowsRemovedFromTheInstalledMenuInPlaceAreRestored() throws {
        let ours = MainMenuBuilder.build()
        let titles = ours.items.map(\.title)
        MainMenuKeeper.shared.install(ours)

        // What SwiftUI may do when it edits the installed menu rather than replacing it: the menu object stays, its rows change.
        ours.removeAllItems()
        ours.addItem(NSMenuItem(title: "View", action: nil, keyEquivalent: ""))
        XCTAssertTrue(NSApp.mainMenu === ours, "Precondition: the menu object itself is unchanged, so an identity check cannot see this")
        XCTAssertFalse(MainMenuKeeper.shared.isIntact)

        MainMenuKeeper.shared.restoreIfReplaced()
        XCTAssertTrue(MainMenuKeeper.shared.isIntact)
        XCTAssertEqual(ours.items.map(\.title), titles)
        XCTAssertNotNil(editMenu(of: ours))
    }

    func testKeyboardMonitorRepairsTheMenuBarBeforeACommandKeyLooksForItsRow() throws {
        let ours = MainMenuBuilder.build()
        MainMenuKeeper.shared.install(ours)
        GlobalKeyEventMonitor.shared.stop()

        // Control: with no monitor installed, a delivered Cmd-V leaves a swapped-in stock menu in place, so the repair below is the monitor's and nothing else's.
        NSApp.mainMenu = NSMenu(title: "Stock")
        XCTAssertFalse(MainMenuKeeper.shared.isIntact)
        NSApp.sendEvent(try commandV())
        XCTAssertFalse(MainMenuKeeper.shared.isIntact, "Precondition: nothing but the key monitor repairs the menu bar while a key is delivered.")

        GlobalKeyEventMonitor.shared.start()
        NSApp.sendEvent(try commandV())
        XCTAssertTrue(MainMenuKeeper.shared.isIntact, "The installed key monitor did not put Orbit's menu bar back before the command key looked for its row.")
        XCTAssertTrue(NSApp.mainMenu === ours)
        XCTAssertNotNil(editMenu(of: NSApp.mainMenu)?.items.first { $0.title == "Paste" })
    }
}
