import AppKit

@MainActor
final class GlobalKeyEventMonitor {
    static let shared = GlobalKeyEventMonitor()

    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Resolved per event, not captured once — the frontmost window's
            // environment can change between key presses.
            GlobalKeyEventMonitor.handle(event, in: .frontmost)
        }
    }

    /// Returns nil to consume the event, or the event itself to pass it on.
    ///
    /// Orbit's own shortcuts get first refusal, and a key either the registry or
    /// the main menu owns is published to the embedder as reserved, so a
    /// clashing extension command is inactive there too and can never reach the
    /// lookup below.
    static func handle(_ event: NSEvent, in environment: AppEnvironment) -> NSEvent? {
        if let commandID = ShortcutRegistry.shared.command(matching: event),
           environment.perform(commandID) {
            return nil
        }
        if ExtensionCommandRegistry.shared.handle(event, in: environment) { return nil }
        return event
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
