import AppKit
import Foundation

struct ShortcutVisualizerState: Equatable {
    private(set) var heldModifiers: UInt = 0
    private(set) var key: String?
    private(set) var keyCode: UInt16?
    private(set) var matchedCommand: ShortcutCommandID?

    var isIdle: Bool { heldModifiers == 0 && key == nil }

    var hasChord: Bool { key != nil && heldModifiers != 0 }

    var caps: [OnboardingKeycap] {
        let flags = NSEvent.ModifierFlags(rawValue: heldModifiers)
        let held = OnboardingKeycaps.caps(for: KeyBinding(key: key ?? "", modifiers: flags))
        return key == nil ? held.filter { $0.kind != .key } : held
    }

    func isPressed(_ cap: OnboardingKeycap) -> Bool {
        switch cap.kind {
        case .modifier(let rawFlag): heldModifiers & rawFlag != 0
        case .key: key != nil
        }
    }

    func isPressed(_ cap: OnboardingKeycap, inRowFor command: ShortcutCommandID) -> Bool {
        switch cap.kind {
        case .modifier(let rawFlag): heldModifiers & rawFlag != 0
        case .key: key != nil && matchedCommand == command
        }
    }

    mutating func flagsChanged(modifiers: UInt) {
        let significant = modifiers & KeyBinding.significantModifiers.rawValue
        if significant & heldModifiers != heldModifiers {
            key = nil
            keyCode = nil
            matchedCommand = nil
        }
        heldModifiers = significant
    }

    mutating func keyDown(key: String, keyCode: UInt16, modifiers: UInt, matched: ShortcutCommandID?) {
        heldModifiers = modifiers & KeyBinding.significantModifiers.rawValue
        self.key = key
        self.keyCode = keyCode
        matchedCommand = matched
    }

    @discardableResult
    mutating func keyUp(keyCode: UInt16) -> Bool {
        guard self.keyCode == keyCode else { return false }
        key = nil
        self.keyCode = nil
        matchedCommand = nil
        return true
    }

    mutating func reset() {
        self = ShortcutVisualizerState()
    }
}
