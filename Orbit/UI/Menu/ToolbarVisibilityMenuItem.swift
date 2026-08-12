import AppKit

// Not a ShortcutCommandID: carries its own target/action, dispatched via the responder chain, so a user remapping another command onto Cmd-Shift-D in Settings > Shortcuts would claim the key first and this item would stop responding to it.
@MainActor
final class ToolbarVisibilityMenuItem: NSMenuItem, NSMenuItemValidation {

    private let settings: ToolbarSettings

    init(settings: ToolbarSettings? = nil) {
        let settings = settings ?? ToolbarSettings.shared
        self.settings = settings
        super.init(title: settings.visibilityMenuTitle, action: #selector(toggle), keyEquivalent: ToolbarSettings.visibilityKeyEquivalent)
        self.target = self
        self.keyEquivalentModifierMask = [.command, .shift]
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggle() {
        settings.toggleVisible()
        updateTitle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        updateTitle()
        return true
    }

    private func updateTitle() {
        let wanted = settings.visibilityMenuTitle
        guard title != wanted else { return }
        title = wanted
    }
}
