import AppKit

enum KeyEventFixtures {

    private static func symbolicKeyCode(for key: String) -> UInt16? {
        switch key {
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        case "return": return 36
        case "delete": return 51
        case "escape": return 53
        case "tab": return 48
        case "space": return 49
        case "f12": return 111
        default: return nil
        }
    }

    static func keyDownEvent(for binding: KeyBinding) -> NSEvent {
        let keyCode = symbolicKeyCode(for: binding.key) ?? 0
        let characters = symbolicKeyCode(for: binding.key) != nil ? "" : binding.key
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: binding.modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("KeyEventFixtures.keyDownEvent: NSEvent.keyEvent returned nil for binding \(binding)")
        }
        return event
    }
}
