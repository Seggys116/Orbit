//  The Swift half of chrome.commands: holds what the embedder registered,
//  matches a real key press against it, and publishes the accelerators Orbit
//  itself owns so the embedder can mark a clashing extension command inactive.
//
//  Conflict policy: Orbit always wins. GlobalKeyEventMonitor gives Orbit's own
//  registry and the main menu first refusal, and every accelerator either of
//  them claims is published as reserved, so a clashing extension command is
//  reported by chrome.commands.getAll with a blank shortcut and is refused by
//  the embedder even if asked.

import AppKit

@MainActor
@Observable
final class ExtensionCommandRegistry {
    static let shared = ExtensionCommandRegistry()

    private(set) var commands: [ExtensionCommand] = []
    private var activeByAccelerator: [String: ExtensionCommand] = [:]

    /// Installed by ChromiumEngine; returns true when the embedder dispatched.
    @ObservationIgnored var dispatch: ((_ extensionID: String, _ name: String) -> Bool)?
    /// Installed by ChromiumEngine; hands the reserved set to the embedder.
    @ObservationIgnored var publishReserved: (([String]) -> Void)?

    private init() {
        NotificationCenter.default.addObserver(
            forName: ShortcutRegistry.bindingsChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ExtensionCommandRegistry.shared.publishOrbitReservedShortcuts()
            }
        }
    }

    func replaceAll(_ commands: [ExtensionCommand]) {
        self.commands = commands
        var table: [String: ExtensionCommand] = [:]
        for command in commands where command.isActive && !command.accelerator.isEmpty {
            table[command.accelerator] = command
        }
        activeByAccelerator = table
    }

    func commands(forExtension extensionID: String) -> [ExtensionCommand] {
        commands.filter { $0.extensionID == extensionID }
    }

    func command(matching event: NSEvent) -> ExtensionCommand? {
        guard let accelerator = ChromiumAccelerator.canonical(for: event) else { return nil }
        return activeByAccelerator[accelerator]
    }

    /// True when an extension owned the key press and the embedder dispatched
    /// it, which is the only case the NSEvent may be swallowed.
    func handle(_ event: NSEvent, in environment: AppEnvironment) -> Bool {
        guard let command = command(matching: event), let dispatch else { return false }
        // _execute_action comes back through the embedder synchronously inside
        // this call, so the environment the key press named is still current.
        dispatchingEnvironment = environment
        defer { dispatchingEnvironment = nil }
        return dispatch(command.extensionID, command.name)
    }

    /// The environment whose key press is being dispatched, falling back to the
    /// frontmost window's for any activation that did not start as one.
    var environmentForActivation: AppEnvironment { dispatchingEnvironment ?? .frontmost }

    @ObservationIgnored private var dispatchingEnvironment: AppEnvironment?

    func publishOrbitReservedShortcuts() {
        publishReserved?(Self.reservedAccelerators(
            registry: ShortcutRegistry.shared, mainMenu: NSApp?.mainMenu))
    }

    /// Every accelerator Orbit claims: the shortcut registry's effective
    /// bindings, plus every main-menu key equivalent, which is what catches the
    /// rows MainMenuBuilder spells out literally (the standard Edit verbs) and
    /// ToolbarVisibilityMenuItem, none of which are registry commands.
    static func reservedAccelerators(
        registry: ShortcutRegistry, mainMenu: NSMenu?
    ) -> [String] {
        var reserved: Set<String> = []
        for command in registry.commands {
            if let binding = registry.binding(for: command.id),
               let accelerator = ChromiumAccelerator.canonical(for: binding) {
                reserved.insert(accelerator)
            }
        }
        if let mainMenu {
            collectMenuAccelerators(mainMenu, into: &reserved)
        }
        return reserved.sorted()
    }

    private static func collectMenuAccelerators(_ menu: NSMenu, into reserved: inout Set<String>) {
        for item in menu.items {
            if !item.keyEquivalent.isEmpty,
               let key = menuKey(forEquivalent: item.keyEquivalent),
               let accelerator = ChromiumAccelerator.canonical(
                key: key, modifiers: item.keyEquivalentModifierMask) {
                reserved.insert(accelerator)
            }
            if let submenu = item.submenu {
                collectMenuAccelerators(submenu, into: &reserved)
            }
        }
    }

    /// NSMenuItem spells its key equivalent as the literal character, so the
    /// function-key sentinels have to come back to KeyBinding's vocabulary.
    private static func menuKey(forEquivalent equivalent: String) -> String? {
        guard let scalar = equivalent.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "left"
        case NSRightArrowFunctionKey: return "right"
        case NSUpArrowFunctionKey: return "up"
        case NSDownArrowFunctionKey: return "down"
        case NSHomeFunctionKey: return "home"
        case NSEndFunctionKey: return "end"
        case NSPageUpFunctionKey: return "pageup"
        case NSPageDownFunctionKey: return "pagedown"
        case NSInsertFunctionKey: return "insert"
        case NSDeleteFunctionKey: return "forwarddelete"
        default:
            // Uppercase means the mask already carries .shift, so lowercase it
            // and let the mask decide -- otherwise "Z" would reserve Shift+Z
            // and plain "z" separately.
            return equivalent.lowercased()
        }
    }
}
