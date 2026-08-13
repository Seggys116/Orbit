import XCTest
import SwiftUI
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class CommandBarOpeningFocusTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var spaceID: SpaceID!
    private var profileID: ProfileID!
    private var window: NSWindow?

    private let pageURL = URL(string: "https://www.wikipedia.org/wiki/Orbit")!

    override func setUp() {
        super.setUp()
        profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Focus",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
        env.state.activeSpaceID = spaceID
    }

    override func tearDown() {
        env.isCommandBarPresented = false
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func mountCommandBar(mode: CommandBarMode, settle: Bool = true) -> NSWindow {
        env.commandBarMode = mode
        env.isCommandBarPresented = true

        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: OrbitMetrics.commandBarWidth, height: 520),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let hosting = NSHostingView(rootView: AnyView(CommandBarView().environment(env)))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.setContentSize(NSSize(width: OrbitMetrics.commandBarWidth, height: 520))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        if settle { pump(seconds: 0.5) }
        return window
    }

    private func focusedFieldEditor(in window: NSWindow) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }

    private func assertFocused(_ window: NSWindow, _ message: String, file: StaticString = #filePath, line: UInt = #line) -> NSTextView? {
        guard let editor = focusedFieldEditor(in: window) else {
            XCTFail("""
            \(message)
            first responder: \(String(describing: window.firstResponder))
            """, file: file, line: line)
            return nil
        }
        return editor
    }

    private func type(_ character: String, keyCode: UInt16, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return XCTFail("Could not synthesise a key event for \(character).")
        }
        window.sendEvent(event)
        pump(seconds: 0.2)
    }

    // MARK: - The reported behaviour

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_openingOnAPageSelectsTheWholeURL

    func test_openingOnAPageSelectsTheWholeURL() {
        let window = mountCommandBar(mode: .editURL(pageURL))
        guard let editor = assertFocused(window, "The bar never took the keyboard, so nothing was selected either.") else { return }

        XCTAssertEqual(editor.string, pageURL.absoluteString, "The bar did not open pre-filled with the page's URL.")
        XCTAssertEqual(
            editor.selectedRange(),
            NSRange(location: 0, length: (editor.string as NSString).length),
            "The URL was not selected — the caret was placed in \(editor.string) at \(editor.selectedRange())."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theFirstKeystrokeReplacesTheWholeURL

    func test_theFirstKeystrokeReplacesTheWholeURL() {
        let window = mountCommandBar(mode: .editURL(pageURL))
        guard assertFocused(window, "The bar never took the keyboard, so the keystroke had nowhere to land.") != nil else { return }

        type("g", keyCode: 5, in: window)

        guard let editor = focusedFieldEditor(in: window) else {
            return XCTFail("The field stopped being first responder mid-keystroke.")
        }
        XCTAssertEqual(editor.string, "g", "Typing did not replace the address; the field holds \(editor.string).")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_openingBlankStillTakesTheKeyboard

    func test_openingBlankStillTakesTheKeyboard() {
        let window = mountCommandBar(mode: .newTab)
        guard let editor = assertFocused(window, "A new-tab bar opened without the keyboard; typing would have gone to the page.") else { return }
        XCTAssertEqual(editor.string, "", "The new-tab bar should open with an empty query.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_focusStolenWhileTheBarIsOpeningIsTakenBack

    func test_focusStolenWhileTheBarIsOpeningIsTakenBack() {
        let window = mountCommandBar(mode: .editURL(pageURL), settle: false)
        pump(seconds: 0.02)
        window.makeFirstResponder(nil)
        pump(seconds: 0.5)

        guard let editor = assertFocused(window, "Focus was taken during presentation and never reclaimed.") else { return }
        XCTAssertEqual(
            editor.selectedRange(),
            NSRange(location: 0, length: (editor.string as NSString).length),
            "Focus came back but the URL was left unselected: \(editor.string) at \(editor.selectedRange())."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_asecondOpeningGestureOverAnOpenBarReSeedsAndReSelects

    func test_asecondOpeningGestureOverAnOpenBarReSeedsAndReSelects() {
        let window = mountCommandBar(mode: .newTab)
        guard assertFocused(window, "The new-tab bar never took the keyboard.") != nil else { return }

        env.presentCommandBar(mode: .editURL(pageURL))
        pump(seconds: 0.5)

        guard let editor = assertFocused(window, "The bar lost the keyboard when it was re-presented.") else { return }
        XCTAssertEqual(editor.string, pageURL.absoluteString, "The second gesture did not re-seed the bar with the page's URL.")
        XCTAssertEqual(
            editor.selectedRange(),
            NSRange(location: 0, length: (editor.string as NSString).length),
            "The re-presented bar did not select its URL: \(editor.string) at \(editor.selectedRange())."
        )
    }
}
