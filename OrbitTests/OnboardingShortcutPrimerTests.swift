import AppKit
import XCTest

// OnboardingShortcutPrimer.swift and ShortcutRegistry.swift are compiled into the test bundle (see ORBIT_TESTS_REUSED_SOURCES).

final class OnboardingShortcutPrimerTests: XCTestCase {


    func test_aFreshPrimer_hasTriedNothing() {
        let primer = OnboardingShortcutPrimer()

        XCTAssertEqual(primer.triedCount, 0)
        XCTAssertEqual(primer.progress, 0)
        XCTAssertFalse(primer.isComplete)
    }

    func test_recording_ticksOffATaughtCommandOnce() {
        var primer = OnboardingShortcutPrimer()

        XCTAssertTrue(primer.record(.newTabCommandBar), "the first press of a taught command counts")
        XCTAssertFalse(primer.record(.newTabCommandBar), "a repeat press changes nothing")
        XCTAssertEqual(primer.triedCount, 1)
        XCTAssertTrue(primer.hasTried(.newTabCommandBar))
        XCTAssertFalse(primer.hasTried(.toggleSidebar))
    }

    func test_recording_ignoresCommandsTheMasterListDoesNotTeach() {
        var primer = OnboardingShortcutPrimer(commands: [.newTabCommandBar, .toggleSidebar])

        XCTAssertFalse(primer.record(.quit))
        XCTAssertEqual(primer.triedCount, 0)
    }

    func test_progress_reachesOneExactlyWhenEveryCommandIsTried() {
        var primer = OnboardingShortcutPrimer(commands: [.newTabCommandBar, .toggleSidebar, .jumpToSpace1])

        primer.record(.newTabCommandBar)
        XCTAssertEqual(primer.progress, 1.0 / 3.0, accuracy: 1e-12)
        primer.record(.toggleSidebar)
        XCTAssertFalse(primer.isComplete)
        primer.record(.jumpToSpace1)

        XCTAssertEqual(primer.progress, 1, accuracy: 1e-12)
        XCTAssertTrue(primer.isComplete)
    }

    func test_anEmptyPrimer_isNeverComplete() {
        let primer = OnboardingShortcutPrimer(commands: [])
        XCTAssertFalse(primer.isComplete)
        XCTAssertEqual(primer.progress, 0)
    }


    func test_keycaps_splitModifiersFromTheKey() {
        let caps = OnboardingKeycaps.caps(for: .cmd("t"))

        XCTAssertEqual(caps.map(\.label), ["⌘", "T"])
        XCTAssertEqual(caps.map(\.spokenName), ["Command", "T"])
        XCTAssertEqual(caps.first?.kind, .modifier(NSEvent.ModifierFlags.command.rawValue))
        XCTAssertEqual(caps.last?.kind, .key)
    }

    func test_keycaps_keepTheOrderTheRegistryPrints() {
        let caps = OnboardingKeycaps.caps(for: .cmdOptionShift("n"))
        XCTAssertEqual(caps.map(\.label), ["⌥", "⇧", "⌘", "N"])
    }

    func test_keycaps_handleNamedKeys() {
        XCTAssertEqual(OnboardingKeycaps.caps(for: KeyBinding(key: "left", modifiers: .command)).map(\.label), ["⌘", "←"])
        XCTAssertEqual(OnboardingKeycaps.caps(for: KeyBinding(key: "space", modifiers: [])).map(\.label), ["Space"])
    }

    func test_everyTaughtShortcut_isBoundInTheRegistry_andItsCapsMatchTheBinding() {
        // Read from the registry, never hardcoded: whatever the registry binds is what the caps show.
        let registry = ShortcutRegistry(inMemoryForTesting: true)

        for command in OnboardingShortcutPrimer.taughtCommands {
            guard let binding = registry.binding(for: command) else {
                return XCTFail("\(command) is taught by the primer but has no binding")
            }
            XCTAssertEqual(
                OnboardingKeycaps.caps(for: binding).map(\.label).joined(),
                binding.displayString,
                "\(command)"
            )
        }
    }

    func test_aRemappedShortcut_isWhatTheCapsShow() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        registry.setBinding(.cmdShift("k"), for: .newTabCommandBar)

        let binding = registry.binding(for: .newTabCommandBar)

        XCTAssertEqual(binding.map { OnboardingKeycaps.caps(for: $0).map(\.label) }, ["⇧", "⌘", "K"])
    }
}
