import AppKit

// Not a ShortcutRegistry binding: GlobalKeyEventMonitor would swallow the key app-wide with no handler.
@MainActor
final class JoinMeetingMenuItem: NSMenuItem, NSMenuItemValidation {

    private let open: (URL) -> Void
    private let store: LiveCalendarStore

    init(store: LiveCalendarStore = .shared, open: @escaping (URL) -> Void) {
        self.open = open
        self.store = store
        super.init(title: "Join Meeting", action: #selector(invoke), keyEquivalent: "j")
        self.keyEquivalentModifierMask = [.control, .command]
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var canJoin: Bool { store.joinURLForActiveMeeting() != nil }

    @objc private func invoke() {
        guard let url = store.joinURLForActiveMeeting() else { return }
        open(url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canJoin }
}
