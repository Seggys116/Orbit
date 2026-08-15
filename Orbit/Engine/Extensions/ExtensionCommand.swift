//  chrome.commands as it crosses the bridge, plus the one spelling both sides
//  agree on. Chromium's ui::Command::AcceleratorToString is the wire format;
//  ChromiumAccelerator is its Swift twin, so an Orbit binding and an extension's
//  suggested_key can be compared as strings without a keycode table.

import AppKit

nonisolated public struct ExtensionCommand: Equatable, Sendable {
    public let extensionID: String
    public let name: String
    public let commandDescription: String
    /// Chromium's canonical spelling, empty when the manifest suggested no key.
    public let accelerator: String
    /// Display form, empty unless `isActive`.
    public let shortcut: String
    public let isGlobal: Bool
    /// False when Orbit reserves the key, another extension claimed it first,
    /// or it is a media key Orbit's `.keyDown` monitor can never see.
    public let isActive: Bool
    /// One of the reserved `_execute_*` names, which trigger the extension's
    /// action instead of firing `commands.onCommand`.
    public let isAction: Bool

    public init(
        extensionID: String,
        name: String,
        commandDescription: String,
        accelerator: String,
        shortcut: String,
        isGlobal: Bool,
        isActive: Bool,
        isAction: Bool
    ) {
        self.extensionID = extensionID
        self.name = name
        self.commandDescription = commandDescription
        self.accelerator = accelerator
        self.shortcut = shortcut
        self.isGlobal = isGlobal
        self.isActive = isActive
        self.isAction = isAction
    }

    public static func decodeAll(json: String) -> [ExtensionCommand] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap(ExtensionCommand.init(entry:))
    }

    private init?(entry: [String: Any]) {
        guard let extensionID = entry["extensionId"] as? String, !extensionID.isEmpty,
              let name = entry["name"] as? String, !name.isEmpty
        else { return nil }
        self.extensionID = extensionID
        self.name = name
        self.commandDescription = entry["description"] as? String ?? ""
        self.accelerator = entry["accelerator"] as? String ?? ""
        self.shortcut = entry["shortcut"] as? String ?? ""
        self.isGlobal = entry["global"] as? Bool ?? false
        self.isActive = entry["active"] as? Bool ?? false
        self.isAction = entry["isAction"] as? Bool ?? false
    }
}

nonisolated enum ChromiumAccelerator {
    /// Modifier order is Chromium's, not AppKit's: Ctrl, Alt, Command, Shift.
    static func canonical(key: String, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let keyToken = token(forKey: key) else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.command) { parts.append("Command") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(keyToken)
        return parts.joined(separator: "+")
    }

    static func canonical(for binding: KeyBinding) -> String? {
        canonical(key: binding.key, modifiers: binding.modifierFlags)
    }

    /// Resolves the key the same way ShortcutRegistry.command(matching:) does,
    /// so Orbit and an extension never disagree about which key was pressed.
    static func canonical(for event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(KeyBinding.significantModifiers)
        let symbolic = ShortcutRegistry.symbolicKey(for: event)
        if let key = symbolic ?? event.charactersIgnoringModifiers?.lowercased(),
           let result = canonical(key: key, modifiers: modifiers) {
            return result
        }
        guard symbolic == nil,
              let ascii = ShortcutRegistry.asciiCapableCharacter(
                forKeyCode: event.keyCode, modifiers: event.modifierFlags)
        else { return nil }
        return canonical(key: ascii, modifiers: modifiers)
    }

    /// nil for keys Chromium's accelerator grammar cannot express at all, which
    /// therefore can never collide with an extension command: return, escape,
    /// backspace (Chromium's "Delete" is forward delete), F-keys, brackets and
    /// the rest of the punctuation Orbit binds.
    private static func token(forKey key: String) -> String? {
        switch key {
        case "left": return "Left"
        case "right": return "Right"
        case "up": return "Up"
        case "down": return "Down"
        case "space": return "Space"
        case "tab": return "Tab"
        case "home": return "Home"
        case "end": return "End"
        case "pageup": return "PageUp"
        case "pagedown": return "PageDown"
        case "insert": return "Insert"
        case "forwarddelete": return "Delete"
        case ",": return "Comma"
        case ".": return "Period"
        default:
            guard key.count == 1, let scalar = key.unicodeScalars.first else { return nil }
            if CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.uppercaseLetters.contains(scalar) {
                return key.uppercased()
            }
            if scalar.value >= 48, scalar.value <= 57 { return key }
            return nil
        }
    }
}
