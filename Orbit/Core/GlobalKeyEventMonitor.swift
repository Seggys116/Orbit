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
    static func handle(_ event: NSEvent, in environment: AppEnvironment) -> NSEvent? {
        guard let commandID = ShortcutRegistry.shared.command(matching: event) else { return event }
        guard environment.perform(commandID) else { return event }
        return nil
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
