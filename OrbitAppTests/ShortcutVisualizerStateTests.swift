import AppKit
import XCTest
@testable import Orbit

@MainActor
final class ShortcutVisualizerStateTests: XCTestCase {

    private let command = NSEvent.ModifierFlags.command.rawValue
    private let shift = NSEvent.ModifierFlags.shift.rawValue

    func test_aFreshState_isIdleWithNoCaps() {
        let state = ShortcutVisualizerState()

        XCTAssertTrue(state.isIdle)
        XCTAssertFalse(state.hasChord)
        XCTAssertTrue(state.caps.isEmpty)
    }

    func test_holdingOnlyModifiers_showsOnlyModifierCaps_allPressed() {
        var state = ShortcutVisualizerState()
        state.flagsChanged(modifiers: command | shift)

        XCTAssertEqual(state.caps.map(\.label), ["⇧", "⌘"])
        XCTAssertTrue(state.caps.allSatisfy(state.isPressed))
        XCTAssertFalse(state.isIdle)
        XCTAssertFalse(state.hasChord)
    }

    func test_keyDown_addsTheKeyCapAfterTheModifiers_andRecordsTheMatch() {
        var state = ShortcutVisualizerState()
        state.keyDown(key: "t", keyCode: 17, modifiers: command, matched: .newTabCommandBar)

        XCTAssertEqual(state.caps.map(\.label), ["⌘", "T"])
        XCTAssertEqual(state.matchedCommand, .newTabCommandBar)
        XCTAssertTrue(state.hasChord)
        XCTAssertTrue(state.caps.allSatisfy(state.isPressed))
    }

    func test_keyUp_releasesTheKeyButKeepsHeldModifiers() {
        var state = ShortcutVisualizerState()
        state.flagsChanged(modifiers: command)
        state.keyDown(key: "t", keyCode: 17, modifiers: command, matched: .newTabCommandBar)

        XCTAssertTrue(state.keyUp(keyCode: 17))

        XCTAssertEqual(state.caps.map(\.label), ["⌘"])
        XCTAssertNil(state.matchedCommand)
    }

    func test_keyUp_ofADifferentKey_isIgnored() {
        var state = ShortcutVisualizerState()
        state.keyDown(key: "t", keyCode: 17, modifiers: command, matched: nil)

        XCTAssertFalse(state.keyUp(keyCode: 0))
        XCTAssertEqual(state.key, "t")
    }

    func test_releasingAModifierWhileTheKeyIsHeld_dropsTheKey() {
        var state = ShortcutVisualizerState()
        state.keyDown(key: "t", keyCode: 17, modifiers: command | shift, matched: nil)

        state.flagsChanged(modifiers: shift)

        XCTAssertNil(state.key)
        XCTAssertEqual(state.caps.map(\.label), ["⇧"])
    }

    func test_pressingAnotherModifierWhileTheKeyIsHeld_keepsTheKey() {
        var state = ShortcutVisualizerState()
        state.keyDown(key: "t", keyCode: 17, modifiers: command, matched: nil)

        state.flagsChanged(modifiers: command | shift)

        XCTAssertEqual(state.key, "t")
        XCTAssertEqual(state.caps.map(\.label), ["⇧", "⌘", "T"])
    }

    func test_nonSignificantModifierBits_areIgnored() {
        var state = ShortcutVisualizerState()
        state.flagsChanged(modifiers: NSEvent.ModifierFlags.capsLock.rawValue | NSEvent.ModifierFlags.function.rawValue)

        XCTAssertTrue(state.isIdle)
    }

    func test_reset_returnsToIdle() {
        var state = ShortcutVisualizerState()
        state.keyDown(key: "t", keyCode: 17, modifiers: command, matched: .newTabCommandBar)

        state.reset()

        XCTAssertEqual(state, ShortcutVisualizerState())
    }

    private func caps(_ flags: NSEvent.ModifierFlags, _ key: String) -> (modifier: OnboardingKeycap, key: OnboardingKeycap) {
        let all = OnboardingKeycaps.caps(for: KeyBinding(key: key, modifiers: flags))
        return (all.first { $0.kind != .key }!, all.first { $0.kind == .key }!)
    }

    func test_rowPressed_modifierCapPressesInEveryRowThatHasIt() {
        var state = ShortcutVisualizerState()
        state.flagsChanged(modifiers: command)
        let row = caps(.command, "t")

        XCTAssertTrue(state.isPressed(row.modifier, inRowFor: .newTabCommandBar))
        XCTAssertTrue(state.isPressed(row.modifier, inRowFor: .toggleSidebar))
        XCTAssertFalse(state.isPressed(row.key, inRowFor: .newTabCommandBar))
    }

    func test_rowPressed_modifierCapStaysUpWhenThatModifierIsNotHeld() {
        var state = ShortcutVisualizerState()
        state.flagsChanged(modifiers: shift)

        XCTAssertFalse(state.isPressed(caps(.command, "t").modifier, inRowFor: .newTabCommandBar))
        XCTAssertTrue(state.isPressed(caps(.shift, "t").modifier, inRowFor: .newTabCommandBar))
    }

    func test_rowPressed_fullMatchPressesOnlyThatRowsKeyCap() {
        var state = ShortcutVisualizerState()
        state.keyDown(key: "t", keyCode: 17, modifiers: command, matched: .newTabCommandBar)
        let key = caps(.command, "t").key

        XCTAssertTrue(state.isPressed(key, inRowFor: .newTabCommandBar))
        XCTAssertFalse(state.isPressed(key, inRowFor: .toggleSidebar))
    }

    func test_rowPressed_unmatchedChordPressesNoRowKeyCap() {
        var state = ShortcutVisualizerState()
        state.keyDown(key: "t", keyCode: 17, modifiers: command, matched: nil)

        XCTAssertFalse(state.isPressed(caps(.command, "t").key, inRowFor: .newTabCommandBar))
    }

    func test_rowPressed_releaseLiftsTheKeyCapAndModifierCaps() {
        var state = ShortcutVisualizerState()
        state.flagsChanged(modifiers: command)
        state.keyDown(key: "t", keyCode: 17, modifiers: command, matched: .newTabCommandBar)
        let row = caps(.command, "t")

        state.keyUp(keyCode: 17)
        XCTAssertFalse(state.isPressed(row.key, inRowFor: .newTabCommandBar))
        XCTAssertTrue(state.isPressed(row.modifier, inRowFor: .newTabCommandBar))

        state.flagsChanged(modifiers: 0)
        XCTAssertFalse(state.isPressed(row.modifier, inRowFor: .newTabCommandBar))
    }

    func test_namedKeys_useTheRegistryDisplayNames() {
        var state = ShortcutVisualizerState()
        state.keyDown(key: "left", keyCode: 123, modifiers: command, matched: nil)

        XCTAssertEqual(state.caps.map(\.label), ["⌘", "←"])
    }
}
