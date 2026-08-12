import AppKit

@MainActor
final class CommandMenuItem: NSMenuItem, NSMenuItemValidation {

    let command: ShortcutCommandID
    private let isAvailable: () -> Bool

    init(title: String, command: ShortcutCommandID, isAvailable: @escaping () -> Bool = { true }) {
        self.command = command
        self.isAvailable = isAvailable
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        applyBinding()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // frontmost, not shared: an Incognito window has its own window-scoped environment, so dispatching to shared here would run the command against the wrong window.
    @objc private func invoke() {
        guard isAvailable() else { return }
        AppEnvironment.frontmost.perform(command)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        applyBinding()
        return isAvailable()
    }

    private func applyBinding() {
        let binding = ShortcutRegistry.shared.binding(for: command)
        let equivalent = binding?.menuKeyEquivalent ?? ""
        if keyEquivalent != equivalent { keyEquivalent = equivalent }
        let flags = binding?.modifierFlags ?? []
        if keyEquivalentModifierMask != flags { keyEquivalentModifierMask = flags }
    }
}
