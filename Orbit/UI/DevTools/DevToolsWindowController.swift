// Hosts one DevTools frontend WebContents in its own undocked window (Chrome's
// undocked mode, the counterpart to DevToolsDockedPane); not WebContentsHostView, same reasoning as ExtensionActionPopupHosting.swift's host view: the frontend is not a tab.

import AppKit

@MainActor
final class DevToolsWindowController: NSWindowController, NSWindowDelegate {

    private var frontend: (any WebContents)!

    /// This window's own host for the frontend's engine view, kept so the
    /// adoption can be re-asserted rather than being a one-shot at open time.
    private var frontendContainer: NSView?

    /// Set while the frontend is being handed back to a docked pane, so
    /// `windowWillClose` tears the window down without destroying an inspector
    /// that is not closing at all.
    private var isRelinquishingFrontend = false

    /// The inspector's own WebContents while the window is open, nil after it
    /// has closed. Reading the frontend directly is how the DevTools suite
    /// asserts on the real frontend document rather than on window existence.
    var frontendContents: (any WebContents)? { frontend }

    /// Fired once, from `windowWillClose`, regardless of whether the window
    /// closed because the user clicked the close button or because `close()`
    /// was called programmatically. Never fired for `relinquishFrontend()`.
    var onClose: (() -> Void)?

    static func open(frontend: any WebContents, inspectedTitle: String) -> DevToolsWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.setFrameAutosaveName("OrbitDevToolsWindow")
        window.minSize = NSSize(width: 480, height: 320)

        let container = NSView()
        let controller = DevToolsWindowController(window: window)
        controller.frontend = frontend
        controller.frontendContainer = container
        controller.updateTitle(inspectedTitle: inspectedTitle)
        controller.reassertFrontendHosting()
        window.contentView = container
        window.delegate = controller
        return controller
    }

    func show() {
        // Before ordering front, every time: this window and a docked pane host the same
        // engine view and whichever re-asserts last wins, so a window that lost it self-heals on the next reveal instead of showing empty.
        reassertFrontendHosting()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Idempotent: a no-op while this window already holds the frontend's view.
    private func reassertFrontendHosting() {
        guard !isRelinquishingFrontend, let frontend, let container = frontendContainer else { return }
        let view = frontend.view
        guard view.superview !== container else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
    }

    func updateTitle(inspectedTitle: String) {
        window?.title = inspectedTitle.isEmpty
            ? "Developer Tools"
            : "Developer Tools — \(inspectedTitle)"
    }

    /// Closes the window but leaves the inspector open, having first taken the
    /// frontend's view out of this window so the docked pane can adopt a view
    /// with no superview rather than one belonging to a window being released.
    func relinquishFrontend() {
        isRelinquishingFrontend = true
        frontend?.view.removeFromSuperview()
        frontend = nil
        frontendContainer = nil
        onClose = nil
        close()
    }

    // Runs whether close() was called on this controller or the user closed the window
    // directly -- the one teardown path for both; destroying the frontend handle is what closes the inspector for good.
    func windowWillClose(_ notification: Notification) {
        guard !isRelinquishingFrontend else { return }
        frontend?.close()
        frontend = nil
        frontendContainer = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
