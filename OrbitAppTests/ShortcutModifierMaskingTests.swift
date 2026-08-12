import AppKit
import XCTest
@testable import Orbit

@MainActor
final class ShortcutModifierMaskingTests: XCTestCase {

    private var defaultsSuiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "OrbitAppTests-ShortcutModifierMasking-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: defaultsSuiteName)
        ShortcutRegistry.defaults = scratchDefaults
        ShortcutRegistry.shared.resetToDefaults()
    }

    override func tearDown() {
        ShortcutRegistry.shared.resetToDefaults()
        scratchDefaults.removePersistentDomain(forName: defaultsSuiteName)
        ShortcutRegistry.defaults = .standard
        ShortcutRegistry.shared.reloadOverridesFromStore()
        super.tearDown()
    }

    // MARK: - Event synthesis

    private func keyDownEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// `\u{F701}` is `NSDownArrowFunctionKey`, key code 125 is ↓.
    private func optionCommandDownArrowEvent() -> NSEvent {
        keyDownEvent(
            characters: "\u{F701}",
            keyCode: 125,
            modifiers: [.command, .option, .function, .numericPad]
        )
    }

    // MARK: - Caps Lock

    func testCommandTWithCapsLockAlsoSetStillMatchesTheNewTabCommandBarBinding() {
        let plain = keyDownEvent(characters: "t", keyCode: 17, modifiers: [.command])
        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: plain), .newTabCommandBar,
            "Test precondition: plain ⌘T must resolve to .newTabCommandBar, or the Caps Lock assertion below proves nothing."
        )

        let withCapsLock = keyDownEvent(characters: "t", keyCode: 17, modifiers: [.command, .capsLock])
        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: withCapsLock), .newTabCommandBar,
            """
            ⌘T stopped resolving the moment Caps Lock was on. `.capsLock` is a keyboard-state bit, \
            not part of the chord the user typed, so keeping it in the comparison switches every \
            shortcut in Orbit off for as long as the light is on.
            """
        )
    }

    func testCapsLockIsIrrelevantToEveryBindingTheRegistryShips() {
        var brokenByCapsLock: [String] = []

        for command in ShortcutCommandID.allCases {
            guard let binding = ShortcutRegistry.shared.binding(for: command) else { continue }
            // Symbolic keys (arrows etc.) need their own key codes; covered separately below.
            guard binding.key.count == 1, let scalar = binding.key.unicodeScalars.first, scalar.isASCII else { continue }

            let expected = ShortcutRegistry.shared.command(
                matching: keyDownEvent(characters: binding.key, keyCode: 0, modifiers: binding.modifierFlags)
            )
            let withCapsLock = ShortcutRegistry.shared.command(
                matching: keyDownEvent(
                    characters: binding.key,
                    keyCode: 0,
                    modifiers: binding.modifierFlags.union(.capsLock)
                )
            )
            if expected != withCapsLock {
                brokenByCapsLock.append("\(command.rawValue) (\(binding.displayString)): \(String(describing: expected)) -> \(String(describing: withCapsLock))")
            }
        }

        XCTAssertTrue(
            brokenByCapsLock.isEmpty,
            """
            Turning Caps Lock on changed which command these bindings resolve to: \
            \(brokenByCapsLock.joined(separator: "; ")). Caps Lock must not participate in shortcut \
            matching at all — see KeyBinding.significantModifiers.
            """
        )
    }

    // MARK: - Arrow keys

    func testOptionCommandDownArrowMatchesNextTabDespiteFunctionAndNumericPadFlags() {
        let event = optionCommandDownArrowEvent()
        XCTAssertTrue(
            event.modifierFlags.contains(.function) && event.modifierFlags.contains(.numericPad),
            "Test precondition: the synthesised arrow event must carry the same .function/.numericPad bits real macOS arrow events do."
        )

        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: event), .nextTab,
            """
            ⌥⌘↓ did not resolve to .nextTab. macOS sets .function and .numericPad on every arrow \
            event, so comparing them against a stored ⌥⌘ binding makes all four arrow defaults \
            (.previousTab/.nextTab, .nextSpace/.previousSpace) permanently unreachable.
            """
        )
    }

    func testEveryArrowKeyDefaultResolvesToItsCommand() {
        let cases: [(command: ShortcutCommandID, characters: String, keyCode: UInt16)] = [
            (.previousTab, "\u{F700}", 126),
            (.nextTab, "\u{F701}", 125),
            (.previousSpace, "\u{F702}", 123),
            (.nextSpace, "\u{F703}", 124),
        ]

        for testCase in cases {
            let event = keyDownEvent(
                characters: testCase.characters,
                keyCode: testCase.keyCode,
                modifiers: [.command, .option, .function, .numericPad]
            )
            XCTAssertEqual(
                ShortcutRegistry.shared.command(matching: event), testCase.command,
                "The arrow key bound to \(testCase.command.rawValue) did not dispatch to it."
            )
        }
    }

    // MARK: - Recording and dispatch must agree

    func testRecordingWithCapsLockDownProducesTheSameBindingAsWithItUp() {
        let plain = KeyBinding(recording: keyDownEvent(characters: "k", keyCode: 40, modifiers: [.command, .control, .shift]))
        let capsLocked = KeyBinding(recording: keyDownEvent(characters: "k", keyCode: 40, modifiers: [.command, .control, .shift, .capsLock]))

        XCTAssertEqual(
            plain, capsLocked,
            "The recorder captured Caps Lock as part of the chord, so the binding it stores can never be matched by a dispatched event."
        )
    }

    /// ⌃⇧⌘↓ rather than ⌥⌘↓, which is `.nextTab`'s own factory binding.
    func testRecordingAnArrowKeyRoundTripsThroughDispatch() {
        let event = keyDownEvent(
            characters: "\u{F701}",
            keyCode: 125,
            modifiers: [.command, .control, .shift, .function, .numericPad]
        )
        guard let recorded = KeyBinding(recording: event) else {
            return XCTFail("The recorder refused a ⌃⇧⌘↓ key-down, which a user can plainly press.")
        }
        XCTAssertEqual(
            recorded.key, "down",
            "The recorder stored something other than the symbolic name dispatch resolves an arrow to."
        )
        XCTAssertEqual(
            recorded.modifierFlags, [.command, .control, .shift],
            "The recorded binding kept a keyboard-state bit; it must store only the chord the user typed."
        )

        ShortcutRegistry.shared.setBinding(recorded, for: .jumpToSelection)

        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: event), .jumpToSelection,
            "An arrow-key shortcut the recorder accepted did not dispatch back to its command."
        )
    }

    func testDecodingAPersistedBindingStripsKeyboardStateBits() throws {
        let legacyPayload = #"{"key":"j","modifiers":\#(NSEvent.ModifierFlags([.command, .capsLock, .function]).rawValue)}"#
        let decoded = try JSONDecoder().decode(KeyBinding.self, from: Data(legacyPayload.utf8))

        XCTAssertEqual(
            decoded, KeyBinding(key: "j", modifiers: .command),
            "A binding persisted by an older build decoded with its .capsLock/.function bits intact, which no dispatched event can ever match."
        )
    }
}
