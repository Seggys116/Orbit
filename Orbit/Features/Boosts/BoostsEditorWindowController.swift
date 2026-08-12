import AppKit
import SwiftUI

@MainActor
final class BoostsEditorWindowController: NSWindowController {

    private static var openWindows: [String: BoostsEditorWindowController] = [:]

    private static var notificationObserver: NSObjectProtocol?

    static func startObservingPresentationRequests() {
        guard notificationObserver == nil else { return }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .orbitPresentBoostsEditor,
            object: nil,
            queue: .main
        ) { notification in
            let host = (notification.object as? String)
                ?? AppEnvironment.processRoot.activeTab?.url.host()
            guard let host, !host.isEmpty else { return }
            Task { @MainActor in
                BoostsEditorWindowController.show(host: host)
            }
        }
    }

    @discardableResult
    static func show(host: String) -> BoostsEditorWindowController {
        if let existing = openWindows[host] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Boosts — \(host)"
        window.contentView = NSHostingView(rootView: BoostsEditorView(host: host).orbitEnvironment(AppEnvironment.processRoot))
        window.center()
        let controller = BoostsEditorWindowController(window: window)
        openWindows[host] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.delegate = self
    }
}

extension BoostsEditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        BoostsEditorWindowController.openWindows = BoostsEditorWindowController.openWindows.filter { $0.value !== self }
    }
}
