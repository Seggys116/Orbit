import AppKit

@MainActor
@Observable
final class LinkPreviewHoverMonitor {

    static let shared = LinkPreviewHoverMonitor()

    init() {}

    private(set) var isShiftDown = false

    private var monitor: Any?

    var isMonitoring: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.isShiftDown = Self.isShiftDown(in: event.modifierFlags)
            return event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        isShiftDown = false
    }

    static func isShiftDown(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.shift)
    }
}
