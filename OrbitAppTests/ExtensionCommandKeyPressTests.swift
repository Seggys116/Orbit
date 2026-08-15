//  chrome.commands' Swift half, driven by real NSEvents posted at a real key
//  window: proves the installed local monitor resolves a key press to the
//  registered extension command, and that Orbit's own shortcuts win.
//  Never synthesize .leftMouseDragged in a suite like this: it starts an
//  uncompletable AppKit drag and hangs.

import AppKit
import XCTest
@testable import Orbit

@MainActor
final class ExtensionCommandKeyPressTests: XCTestCase {

    private var window: NSWindow?
    private var savedCommands: [ExtensionCommand] = []
    private var savedDispatch: ((String, String) -> Bool)?
    private var savedPublish: (([String]) -> Void)?

    override func setUp() {
        super.setUp()
        savedCommands = ExtensionCommandRegistry.shared.commands
        savedDispatch = ExtensionCommandRegistry.shared.dispatch
        savedPublish = ExtensionCommandRegistry.shared.publishReserved
    }

    override func tearDown() {
        ExtensionCommandRegistry.shared.replaceAll(savedCommands)
        ExtensionCommandRegistry.shared.dispatch = savedDispatch
        ExtensionCommandRegistry.shared.publishReserved = savedPublish
        GlobalKeyEventMonitor.shared.stop()
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    /// Drains NSApp's own queue rather than the run loop: -nextEventMatchingMask
    /// is where local monitors run, so a RunLoop.run pump would never reach the
    /// monitor at all. Returns the events the monitors did not consume.
    @discardableResult
    private func pumpAppEvents(seconds: TimeInterval) -> [NSEvent] {
        var passedThrough: [NSEvent] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.01),
                inMode: .default, dequeue: true
            ) else { continue }
            passedThrough.append(event)
            NSApp.sendEvent(event)
        }
        return passedThrough
    }

    private func makeKeyWindow() -> NSWindow {
        let window = UnconstrainedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        self.window = window
        return window
    }

    private func command(
        name: String, accelerator: String, isActive: Bool = true, isAction: Bool = false
    ) -> ExtensionCommand {
        ExtensionCommand(
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            name: name,
            commandDescription: "Test command",
            accelerator: accelerator,
            shortcut: isActive ? "⇧⌘Y" : "",
            isGlobal: false,
            isActive: isActive,
            isAction: isAction
        )
    }

    // MARK: - A real key press

    func test_aRealKeyPressPostedToTheAppReachesTheRegisteredExtensionCommand() {
        let window = makeKeyWindow()
        ExtensionCommandRegistry.shared.replaceAll([
            command(name: "toggle-feature", accelerator: "Command+Shift+Y")
        ])
        var dispatched: [(String, String)] = []
        ExtensionCommandRegistry.shared.dispatch = { extensionID, name in
            dispatched.append((extensionID, name))
            return true
        }
        GlobalKeyEventMonitor.shared.start()

        // Posted to the app's own queue, so the local monitor runs from
        // nextEventMatchingMask exactly as it does for a typed key. sendEvent
        // would bypass the monitor entirely and prove nothing.
        NSApp.postEvent(ExtensionCommandKeyEvents.commandShiftY(in: window), atStart: true)
        pumpAppEvents(seconds: 0.5)

        XCTAssertEqual(
            dispatched.map(\.1), ["toggle-feature"],
            "a real ⇧⌘Y through the installed monitor did not reach the extension command registered for it"
        )
        XCTAssertEqual(dispatched.first?.0, "abcdefghijklmnopabcdefghijklmnop")
        // Whether the event is then swallowed cannot be observed from here: an
        // explicit nextEvent hands the event back whatever a monitor returned,
        // and only NSApplication's own dispatch honours the nil. The return
        // contract is asserted directly below instead.
    }

    func test_theMonitorSwallowsTheEventOnlyWhenTheEmbedderDispatched() {
        ExtensionCommandRegistry.shared.replaceAll([
            command(name: "toggle-feature", accelerator: "Command+Shift+Y")
        ])
        let event = ExtensionCommandKeyEvents.commandShiftY()

        ExtensionCommandRegistry.shared.dispatch = { _, _ in true }
        XCTAssertNil(
            GlobalKeyEventMonitor.handle(event, in: .demo),
            "the embedder dispatched, so the key press must not also reach the page"
        )

        // Refused because the extension has no onCommand listener, exactly as
        // ExtensionKeybindingRegistry::ExecuteCommands refuses.
        ExtensionCommandRegistry.shared.dispatch = { _, _ in false }
        XCTAssertTrue(
            GlobalKeyEventMonitor.handle(event, in: .demo) === event,
            "the embedder refused, so the key press must still reach the page rather than vanishing"
        )
    }

    func test_anInactiveCommandIsNeverOffered() {
        ExtensionCommandRegistry.shared.replaceAll([
            command(name: "toggle-feature", accelerator: "Command+Shift+Y", isActive: false)
        ])
        var dispatched = false
        ExtensionCommandRegistry.shared.dispatch = { _, _ in dispatched = true; return true }

        let event = ExtensionCommandKeyEvents.commandShiftY()
        XCTAssertTrue(GlobalKeyEventMonitor.handle(event, in: .demo) === event)
        XCTAssertFalse(dispatched, "an inactive command was dispatched; getAll() reports it as having no shortcut")
    }

    // MARK: - Orbit wins

    func test_orbitsOwnShortcutIsPublishedAsReservedAndNeverOfferedToAnExtension() {
        let reserved = ExtensionCommandRegistry.reservedAccelerators(
            registry: ShortcutRegistry.shared, mainMenu: MainMenuBuilder.build())
        XCTAssertTrue(
            reserved.contains("Command+T"),
            "⌘T is New Tab; if the embedder is not told it is reserved, an extension binding Ctrl+T would take it. Reserved set was \(reserved)"
        )
        // The literal rows MainMenuBuilder spells out are not registry commands,
        // so only the menu walk catches them.
        XCTAssertTrue(reserved.contains("Command+C"), "the Edit menu's own ⌘C must be reserved too")
        XCTAssertTrue(reserved.contains("Command+Shift+D"), "ToolbarVisibilityMenuItem's ⇧⌘D is not a registry command and must still be reserved")
    }

    func test_anExtensionCannotStealAKeyOrbitPerforms() {
        // The embedder would already have marked this inactive from the reserved
        // set; asserting on the monitor as well pins the second line of defence.
        ExtensionCommandRegistry.shared.replaceAll([
            command(name: "steal-new-tab", accelerator: "Command+T")
        ])
        var dispatched = false
        ExtensionCommandRegistry.shared.dispatch = { _, _ in dispatched = true; return true }

        let event = ExtensionCommandKeyEvents.keyDown(
            character: "t", keyCode: 17, modifiers: .command)
        _ = GlobalKeyEventMonitor.handle(event, in: .demo)
        XCTAssertFalse(dispatched, "an extension was offered ⌘T, which Orbit owns as New Tab")
    }

    // MARK: - The wire format

    func test_theCanonicalSpellingMatchesChromiumsOwn() {
        XCTAssertEqual(
            ChromiumAccelerator.canonical(for: ExtensionCommandKeyEvents.commandShiftY()),
            "Command+Shift+Y"
        )
        XCTAssertEqual(
            ChromiumAccelerator.canonical(key: "y", modifiers: [.control, .option, .command, .shift]),
            "Ctrl+Alt+Command+Shift+Y",
            "modifier order is Chromium's own AcceleratorToString order, not AppKit's"
        )
        XCTAssertEqual(ChromiumAccelerator.canonical(key: ",", modifiers: .command), "Command+Comma")
        XCTAssertEqual(ChromiumAccelerator.canonical(key: "left", modifiers: .command), "Command+Left")
        // Chromium's accelerator grammar has no token for these, so an Orbit
        // binding on one can never collide with an extension command.
        XCTAssertNil(ChromiumAccelerator.canonical(key: "escape", modifiers: .command))
        XCTAssertNil(ChromiumAccelerator.canonical(key: "return", modifiers: .command))
        XCTAssertNil(ChromiumAccelerator.canonical(key: "f12", modifiers: []))
    }

    func test_theCommandTableDecodesTheEmbeddersPayload() {
        let json = """
        [{"extensionId":"abcdefghijklmnopabcdefghijklmnop","name":"_execute_action",
          "description":"","accelerator":"Command+Shift+E","shortcut":"⇧⌘E",
          "global":false,"active":true,"isAction":true}]
        """
        let decoded = ExtensionCommand.decodeAll(json: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name, "_execute_action")
        XCTAssertTrue(decoded.first?.isAction == true)
        XCTAssertTrue(decoded.first?.isActive == true)
    }
}
