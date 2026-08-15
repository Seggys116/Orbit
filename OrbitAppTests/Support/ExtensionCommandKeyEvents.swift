//  Real keyDown NSEvents for the accelerators extensions bind, built the way
//  AppKit builds them so ChromiumAccelerator resolves them exactly as it would
//  a typed key.

import AppKit

enum ExtensionCommandKeyEvents {

    /// `character` is what -charactersIgnoringModifiers reports, i.e. the
    /// unshifted key, and `keyCode` is the macOS virtual key code for it.
    static func keyDown(
        character: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        in window: NSWindow? = nil
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("ExtensionCommandKeyEvents.keyDown: NSEvent.keyEvent returned nil for \(character)")
        }
        return event
    }

    /// ⇧⌘Y, which a manifest spells "Ctrl+Shift+Y" — on macOS Chromium
    /// normalises manifest Ctrl to Command.
    static func commandShiftY(in window: NSWindow? = nil) -> NSEvent {
        keyDown(character: "y", keyCode: 16, modifiers: [.command, .shift], in: window)
    }
}
