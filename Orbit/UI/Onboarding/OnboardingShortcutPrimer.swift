import AppKit
import Foundation

// Bindings are always read from the registry, so a remapped shortcut is shown and recognised as the user has it, never as a hardcoded default.

struct OnboardingKeycap: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case modifier(UInt)
        case key
    }

    var label: String
    var kind: Kind
    var spokenName: String
}

// Main-actor by the module default: KeyBinding's display members are main-actor isolated.
enum OnboardingKeycaps {

    static func caps(for binding: KeyBinding) -> [OnboardingKeycap] {
        let flags = binding.modifierFlags
        let modifiers: [(NSEvent.ModifierFlags, String, String)] = [
            (.control, "⌃", "Control"),
            (.option, "⌥", "Option"),
            (.shift, "⇧", "Shift"),
            (.command, "⌘", "Command"),
        ]
        var caps: [OnboardingKeycap] = []
        var modifierSymbolCount = 0
        for (flag, symbol, name) in modifiers where flags.contains(flag) {
            caps.append(OnboardingKeycap(label: symbol, kind: .modifier(flag.rawValue), spokenName: name))
            modifierSymbolCount += 1
        }
        let keyLabel = String(binding.displayString.dropFirst(modifierSymbolCount))
        caps.append(OnboardingKeycap(label: keyLabel, kind: .key, spokenName: keyLabel))
        return caps
    }
}

struct OnboardingShortcutPrimer: Equatable {
    static let taughtCommands: [ShortcutCommandID] = [
        .newTabCommandBar,
        .toggleSidebar,
        .jumpToSpace1,
        .findOnPage,
    ]

    let commands: [ShortcutCommandID]
    private(set) var tried: Set<ShortcutCommandID> = []

    init(commands: [ShortcutCommandID] = OnboardingShortcutPrimer.taughtCommands) {
        self.commands = commands
    }

    var triedCount: Int { commands.filter { tried.contains($0) }.count }
    var isComplete: Bool { !commands.isEmpty && triedCount == commands.count }

    var progress: Double {
        commands.isEmpty ? 0 : Double(triedCount) / Double(commands.count)
    }

    func hasTried(_ command: ShortcutCommandID) -> Bool { tried.contains(command) }

    @discardableResult
    mutating func record(_ command: ShortcutCommandID) -> Bool {
        guard commands.contains(command) else { return false }
        return tried.insert(command).inserted
    }
}
