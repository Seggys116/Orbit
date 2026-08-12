import AppKit

@MainActor
final class AppearanceMenuItem: NSMenuItem, NSMenuItemValidation {

    let appearance: AppearanceSettings.Appearance
    private let settings: AppearanceSettings

    init(_ appearance: AppearanceSettings.Appearance, settings: AppearanceSettings? = nil) {
        self.appearance = appearance
        let settings = settings ?? .shared
        self.settings = settings
        super.init(title: appearance.title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        self.state = settings.selection == appearance ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() {
        settings.choose(appearance)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let mark: NSControl.StateValue = settings.selection == appearance ? .on : .off
        if state != mark { state = mark }
        return true
    }
}
