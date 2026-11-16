import AppKit

@MainActor
final class GlobalKeyEventMonitor {
    static let shared = GlobalKeyEventMonitor()

    private var monitor: Any?
    private var mouseMonitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Resolved per event, not captured once — the frontmost window's
            // environment can change between key presses.
            GlobalKeyEventMonitor.handle(event, in: .frontmost)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { event in
            MouseNavigationButton.handle(event)
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
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

/// The back and forward buttons on the side of a mouse. AppKit reports them as "other" buttons, numbered 3 and 4, and WKWebView does nothing with them.
enum MouseNavigationButton {
    enum Direction: Equatable {
        case back
        case forward
    }

    static func direction(forButtonNumber buttonNumber: Int) -> Direction? {
        switch buttonNumber {
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    /// Navigates on release, as other browsers do, and swallows both halves of the click so the page never sees an unpaired press. Clicks in windows that are not a browser window, such as Settings, pass through.
    @MainActor
    static func handle(_ event: NSEvent) -> NSEvent? {
        guard let direction = direction(forButtonNumber: event.buttonNumber), let window = event.window else { return event }
        guard let target = navigationTarget(in: window) else { return event }
        if event.type == .otherMouseUp { target(direction) }
        return nil
    }

    @MainActor
    private static func navigationTarget(in window: NSWindow) -> ((Direction) -> Void)? {
        if let tabID = LittleOrbitWindowController.tabID(forWindow: window) {
            return { direction in
                let contents = AppEnvironment.processRoot.webContents[tabID]
                if direction == .back { contents?.goBack() } else { contents?.goForward() }
            }
        }
        if let environment = OrbitWindowController.environment(forWindow: window) {
            return { direction in
                environment.perform(direction == .back ? .goBack : .goForward)
            }
        }
        return nil
    }
}
