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

    /// Installed by WebKitEngine; returns true when the engine dispatched the command.
    @ObservationIgnored var dispatch: ((_ extensionID: String, _ name: String) -> Bool)?

    private init() {}

    func replaceAll(_ commands: [ExtensionCommand]) {
        self.commands = commands
        var table: [String: ExtensionCommand] = [:]
        for command in commands where command.isActive && !command.accelerator.isEmpty {
            table[command.accelerator] = command
        }
        activeByAccelerator = table
    }

    /// Parses the manifest `commands` key. On macOS, `mac` beats `default`, and
    /// `Ctrl` means Command. A key Orbit already owns is registered but inactive,
    /// so getAll reports a blank shortcut and the key press never reaches it.
    func register(extensionID: String, manifestCommands: [String: Any]) {
        // Loading an extension is the earliest moment a sidebar bookmark edit can
        // be observed; the commands manifest is what every liveness fixture declares.
        ChromeExtensionAPI.ensureBookmarkRelay()
        let reserved = Set(Self.reservedAccelerators(
            registry: ShortcutRegistry.shared, mainMenu: NSApp?.mainMenu))
        var claimed = Set(
            commands.filter { $0.extensionID != extensionID && $0.isActive }.map(\.accelerator)
        )
        var parsed: [ExtensionCommand] = []
        for name in manifestCommands.keys.sorted() {
            let entry = manifestCommands[name] as? [String: Any] ?? [:]
            let accelerator = Self.macAccelerator(entry["suggested_key"])
            let taken = accelerator.isEmpty || reserved.contains(accelerator) || claimed.contains(accelerator)
            let active = !taken
            if active { claimed.insert(accelerator) }
            let shortcut = active ? Self.displayShortcut(accelerator) : ""
            parsed.append(ExtensionCommand(
                extensionID: extensionID,
                name: name,
                commandDescription: entry["description"] as? String ?? "",
                accelerator: accelerator,
                shortcut: shortcut,
                isGlobal: entry["global"] as? Bool ?? false,
                isActive: active,
                isAction: name.hasPrefix("_execute_")
            ))
        }
        let others = commands.filter { $0.extensionID != extensionID }
        replaceAll(others + parsed)
    }

    func unregister(_ extensionID: String) {
        replaceAll(commands.filter { $0.extensionID != extensionID })
    }

    /// Chrome's suggested_key on macOS: the `mac` string wins, then `default`.
    /// Ctrl is Command and MacCtrl is Control.
    private static func macAccelerator(_ value: Any?) -> String {
        let raw: String
        if let object = value as? [String: Any] {
            raw = (object["mac"] as? String) ?? (object["default"] as? String) ?? ""
        } else {
            raw = value as? String ?? ""
        }
        let parts = raw.split(separator: "+").map(String.init)
        guard let key = parts.last, !key.isEmpty, parts.count == parts.filter({ !$0.isEmpty }).count else { return "" }
        var modifiers: [String] = []
        for part in parts.dropLast() {
            switch part {
            case "MacCtrl": modifiers.append("Ctrl")
            case "Ctrl", "Command": modifiers.append("Command")
            case "Alt": modifiers.append("Alt")
            case "Shift": modifiers.append("Shift")
            default: return ""
            }
        }
        let order = ["Ctrl", "Alt", "Command", "Shift"]
        let sorted = order.filter { modifiers.contains($0) }
        return (sorted + [key]).joined(separator: "+")
    }

    private static func displayShortcut(_ accelerator: String) -> String {
        let parts = accelerator.split(separator: "+").map(String.init)
        guard let key = parts.last else { return "" }
        var flags = NSEvent.ModifierFlags()
        for part in parts.dropLast() {
            switch part {
            case "Ctrl": flags.insert(.control)
            case "Alt": flags.insert(.option)
            case "Command": flags.insert(.command)
            case "Shift": flags.insert(.shift)
            default: break
            }
        }
        return KeyBinding(key: key.lowercased(), modifiers: flags).displayString
    }

    func commands(forExtension extensionID: String) -> [ExtensionCommand] {
        commands.filter { $0.extensionID == extensionID }
    }

    func command(matching event: NSEvent) -> ExtensionCommand? {
        guard let accelerator = ExtensionCommandAccelerator.canonical(for: event) else { return nil }
        return activeByAccelerator[accelerator]
    }

    /// True when an extension owned the key press and the embedder dispatched
    /// it, which is the only case the NSEvent may be swallowed.
    func handle(_ event: NSEvent, in environment: AppEnvironment) -> Bool {
        guard let command = command(matching: event) else { return false }
        // _execute_action comes back synchronously inside
        // this call, so the environment the key press named is still current.
        dispatchingEnvironment = environment
        defer { dispatchingEnvironment = nil }
        if let engine = environment.engine as? WebKitEngine {
            ChromeExtensionAPI.remember(engine: engine)
            return deliver(command, through: engine, in: environment)
        }
        guard let dispatch else { return false }
        return dispatch(command.extensionID, command.name)
    }

    /// The engine that loaded the extension, not whichever engine last installed
    /// `dispatch`. A later engine's start() replaces that closure, and a dead
    /// weak capture returns false without ever reaching commands.onCommand.
    private func deliver(
        _ command: ExtensionCommand, through engine: WebKitEngine, in environment: AppEnvironment
    ) -> Bool {
        guard command.isActive else { return false }
        if command.isAction {
            return environment.activateExtensionAction(command.extensionID)
        }
        let tab = Self.tabArgument(in: environment, engine: engine)
        let args: [Any] = tab.isEmpty ? [command.name] : [command.name, tab]
        engine.services.deliver(namespace: "commands", event: "onCommand", args: args, to: command.extensionID)
        return true
    }

    /// Same shape as WebKitEngine.commandTabArgument: id -1 plus __orbitTab, which
    /// the wrapper swaps for the id chrome.tabs.get accepts.
    private static func tabArgument(in environment: AppEnvironment, engine: WebKitEngine) -> [String: Any] {
        guard let tabID = environment.activeTabID,
              let contents = environment.webContents[tabID] as? WebKitWebContents
        else { return [:] }
        var tab: [String: Any] = [
            "id": -1,
            "url": contents.navigationState.url?.absoluteString ?? "",
            "title": contents.navigationState.title,
            "active": true,
        ]
        if let reference = engine.extensionTabReference(for: contents) ?? engine.extensionTabReference(forTabID: tabID) {
            tab["__orbitTab"] = reference
        }
        return tab
    }

    /// The environment whose key press is being dispatched, falling back to the
    /// frontmost window's for any activation that did not start as one.
    var environmentForActivation: AppEnvironment { dispatchingEnvironment ?? .frontmost }

    @ObservationIgnored private var dispatchingEnvironment: AppEnvironment?

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
               let accelerator = ExtensionCommandAccelerator.canonical(for: binding) {
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
               let accelerator = ExtensionCommandAccelerator.canonical(
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
