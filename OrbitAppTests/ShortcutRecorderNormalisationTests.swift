import AppKit
import XCTest
@testable import Orbit

@MainActor
final class ShortcutRecorderNormalisationTests: XCTestCase {

    private var defaultsSuiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "OrbitAppTests-ShortcutRecorder-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: defaultsSuiteName)
        ShortcutRegistry.defaults = scratchDefaults
    }

    override func tearDown() {
        ShortcutRegistry.shared.resetToDefaults()
        scratchDefaults.removePersistentDomain(forName: defaultsSuiteName)
        ShortcutRegistry.defaults = OrbitDefaults.standard
        ShortcutRegistry.shared.reloadOverridesFromStore()
        super.tearDown()
    }

    // MARK: - Event synthesis

    private func keyDownEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        return NSEvent.keyEvent(
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

    /// ⌃⇧⌘ deliberately: the registry ships ⌥⌘←/→ on .previousSpace/.nextSpace,
    /// so those modifiers would resolve to a different command.
    private func leftArrowEvent(modifiers: NSEvent.ModifierFlags = [.command, .control, .shift]) -> NSEvent {
        keyDownEvent(characters: "\u{F702}", keyCode: 123, modifiers: modifiers)
    }

    private func record(_ event: NSEvent) -> KeyBinding? {
        var captured: KeyBinding??
        let view = ShortcutRecorderCapture.RecorderView()
        view.onCapture = { captured = $0 }
        view.keyDown(with: event)
        return captured ?? nil
    }

    // MARK: - The defect

    func testRecordingAnArrowKeyStoresTheSymbolicNameDispatchLooksFor() {
        let binding = record(leftArrowEvent())
        XCTAssertEqual(
            binding?.key,
            "left",
            "The recorder stored the raw NSEvent character instead of the symbolic name ShortcutRegistry.command(matching:) resolves to."
        )
        XCTAssertNotEqual(
            binding?.key,
            "\u{F702}",
            "Storing the raw function-key character is the defect: dispatch looks up \"left\" and can never match it."
        )
    }

    func testDispatchMatchesWhatTheRecorderRecorded() {
        let event = leftArrowEvent()
        let recorded = record(event)
        let binding = try! XCTUnwrap(recorded)

        ShortcutRegistry.shared.setBinding(binding, for: .jumpToSelection)

        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: event),
            .jumpToSelection,
            "A shortcut the recorder accepted did not resolve back to its command — this is exactly the binding a user watches the app accept and which then never fires."
        )
    }

    func testABindingStoredAsTheRawCharacterCanNeverBeDispatched() {
        let event = leftArrowEvent()
        let legacyStyleBinding = KeyBinding(key: "\u{F702}", modifiers: event.modifierFlags)

        ShortcutRegistry.shared.setBinding(legacyStyleBinding, for: .jumpToSelection)

        XCTAssertNil(
            ShortcutRegistry.shared.command(matching: event),
            "If this resolves, the two sides agree on the raw character and this suite is not testing what it claims to."
        )
    }

    /// `escape` is excluded: key code 53 is the recorder's own cancel gesture,
    /// so it is not recordable by design.
    func testEverySymbolicKeyRoundTripsFromRecorderToDispatch() {
        let cases: [(name: String, characters: String, keyCode: UInt16)] = [
            ("left", "\u{F702}", 123),
            ("right", "\u{F703}", 124),
            ("down", "\u{F701}", 125),
            ("up", "\u{F700}", 126),
            ("return", "\r", 36),
            ("delete", "\u{8}", 51),
            ("tab", "\t", 48),
            ("space", " ", 49),
        ]

        for testCase in cases {
            let event = keyDownEvent(
                characters: testCase.characters,
                keyCode: testCase.keyCode,
                modifiers: [.command, .control, .shift]
            )
            let binding = record(event)
            XCTAssertEqual(binding?.key, testCase.name, "Recorder normalised \(testCase.name) wrongly.")

            ShortcutRegistry.shared.setBinding(binding, for: .jumpToSelection)
            XCTAssertEqual(
                ShortcutRegistry.shared.command(matching: event),
                .jumpToSelection,
                "\(testCase.name) recorded but did not dispatch."
            )
        }
    }

    func testOrdinaryCharacterKeysStillRecordAsTheirCharacter() {
        let event = keyDownEvent(characters: "k", keyCode: 40, modifiers: [.command, .control, .shift])
        let binding = record(event)
        XCTAssertEqual(binding?.key, "k")

        ShortcutRegistry.shared.setBinding(binding, for: .jumpToSelection)
        XCTAssertEqual(ShortcutRegistry.shared.command(matching: event), .jumpToSelection)
    }

    func testEscapeCancelsRecordingInsteadOfBindingItself() {
        var captureCount = 0
        var captured: KeyBinding?
        let view = ShortcutRecorderCapture.RecorderView()
        view.onCapture = { binding in
            captureCount += 1
            captured = binding
        }
        view.keyDown(with: keyDownEvent(characters: "\u{1B}", keyCode: 53, modifiers: []))

        XCTAssertEqual(captureCount, 1, "Escape must report back, so the row stops recording.")
        XCTAssertNil(captured, "Escape must cancel, not bind itself.")
    }
}
