//  The list that opens under a sign-in field. A borderless panel Orbit paints itself, like the right-click menu, but one that never takes
//  keyboard focus: the page's own text field stays first responder, so typing keeps working while the list is up and the arrow keys,
//  Return and Escape are claimed by a local monitor only while it is showing.

import AppKit
import SwiftUI

final class OrbitSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a row must act at once, not first make the window key.
final class OrbitFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    deinit {}
}

@MainActor
final class PasswordSuggestionPresenter {

    /// A page can raise the list at any moment, for instance under the pointer just as the person is about to click. A click or Return on a row
    /// counts only this long after the list appeared.
    nonisolated static let activationDelay: TimeInterval = 0.4

    /// Set only by tests: replaces the real panel with a recorder of what would have been shown and where.
    var presentForTesting: ((_ entries: [OrbitContextMenuEntry], _ fieldScreenRect: CGRect) -> Void)?

    /// Seconds from any fixed point that only moves forward; a test replaces it to step through the delay without waiting.
    private let clock: () -> TimeInterval
    private var presentedAt: TimeInterval?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// False for the first `activationDelay` seconds after the list appeared, and while nothing is showing.
    var acceptsActivation: Bool {
        guard let presentedAt else { return false }
        return clock() - presentedAt >= Self.activationDelay
    }

    /// Called when the user closes the list with Escape, so the same field does not reopen it on the next focus report.
    var onEscape: ((_ token: String) -> Void)?

    private(set) var presentedToken: String?
    var isPresented: Bool { panel != nil }

    private var panel: OrbitSuggestionPanel?
    private var selection: OrbitMenuSelectionModel?
    private var containerSize: CGSize = .zero
    private weak var ownerWindow: NSWindow?
    private weak var anchorView: NSView?
    private var sentinel: OrbitMenuAnchorSentinel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func present(entries unguarded: [OrbitContextMenuEntry], token: String, fieldScreenRect: CGRect, anchorView: NSView) {
        let entries = guarded(unguarded)
        if let presentForTesting {
            presentedToken = token
            presentedAt = clock()
            self.selection = OrbitMenuSelectionModel(entries: entries)
            presentForTesting(entries, fieldScreenRect)
            return
        }
        dismiss()
        guard !entries.isEmpty, let window = anchorView.window else { return }

        let selection = OrbitMenuSelectionModel(entries: entries)
        let hosting = OrbitFirstMouseHostingView(rootView: content(entries: entries, selection: selection))
        let measured = hosting.fittingSize
        let size = CGSize(
            width: OrbitMetrics.contextMenuWidth,
            height: max(0, measured.height - 2 * OrbitMetrics.contextMenuShadowPadding)
        )

        let panel = OrbitSuggestionPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Password suggestions")
        panel.appearance = window.effectiveAppearance

        self.panel = panel
        self.selection = selection
        self.containerSize = size
        self.ownerWindow = window
        self.anchorView = anchorView
        self.presentedToken = token
        self.presentedAt = clock()

        let frame = Self.panelFrame(contentSize: size, field: fieldScreenRect, visibleFrame: visibleFrame(for: fieldScreenRect, window: window))
        panel.setFrame(frame, display: false)
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        let sentinel = OrbitMenuAnchorSentinel(frame: .zero)
        sentinel.onWindowLost = { [weak self] in self?.dismiss() }
        anchorView.addSubview(sentinel)
        self.sentinel = sentinel

        installMonitors(window: window)
    }

    /// The list follows its field when the page scrolls or lays out again.
    func move(to fieldScreenRect: CGRect) {
        guard let panel, let window = ownerWindow else { return }
        let frame = Self.panelFrame(contentSize: containerSize, field: fieldScreenRect, visibleFrame: visibleFrame(for: fieldScreenRect, window: window))
        panel.setFrame(frame, display: true)
    }

    func dismiss() {
        removeMonitors()
        sentinel?.onWindowLost = nil
        sentinel?.removeFromSuperview()
        sentinel = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panel = nil
        selection = nil
        ownerWindow = nil
        anchorView = nil
        presentedToken = nil
        presentedAt = nil
    }

    /// The same entries with every action held back until the list has been up for `activationDelay`, so a click that was meant for the page cannot choose a row.
    private func guarded(_ entries: [OrbitContextMenuEntry]) -> [OrbitContextMenuEntry] {
        entries.map { entry in
            switch entry {
            case .item(var item):
                if let action = item.action {
                    item.action = { [weak self] in
                        guard self?.acceptsActivation == true else { return }
                        action()
                    }
                }
                return .item(item)
            case .divider:
                return entry
            case .section(let id, let title, let children):
                return .section(id: id, title: title, entries: guarded(children))
            }
        }
    }

    // MARK: - Geometry

    /// The panel's frame: the drawn list sits just under the field, or above it when there is no room below.
    /// Screen coordinates, origin bottom-left; the panel is the list outset by its shadow padding.
    static func panelFrame(contentSize: CGSize, field: CGRect, visibleFrame: CGRect) -> CGRect {
        let gap: CGFloat = 2
        let below = OrbitMenuPlacement.geometry(
            contentSize: contentSize,
            anchor: CGRect(x: field.minX, y: field.minY - gap, width: 0, height: 0),
            mode: .pointCorner,
            preferredDirection: .down,
            showsArrow: false,
            visibleFrame: visibleFrame
        )
        var geometry = below
        if below.direction == .up {
            geometry = OrbitMenuPlacement.geometry(
                contentSize: contentSize,
                anchor: CGRect(x: field.minX, y: field.maxY + gap, width: 0, height: 0),
                mode: .pointCorner,
                preferredDirection: .up,
                showsArrow: false,
                visibleFrame: visibleFrame
            )
        }
        return geometry.containerFrame.insetBy(dx: -OrbitMetrics.contextMenuShadowPadding, dy: -OrbitMetrics.contextMenuShadowPadding)
    }

    private func visibleFrame(for field: CGRect, window: NSWindow) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: field.midX, y: field.midY)) }
            ?? window.screen
            ?? NSScreen.main
        return screen?.visibleFrame ?? field.insetBy(dx: -500, dy: -500)
    }

    private func content(entries: [OrbitContextMenuEntry], selection: OrbitMenuSelectionModel) -> OrbitMenuPanelContent {
        OrbitMenuPanelContent(
            entries: entries,
            arrow: nil,
            selection: selection,
            // Runs after a row's action: a click inside the activation delay did nothing, so it must not close the list either.
            onSelect: { [weak self] in
                guard self?.acceptsActivation == true else { return }
                self?.dismiss()
            },
            onRowActivate: { _, _ in }
        )
    }

    // MARK: - Keyboard and pointer

    /// True when the key was claimed. Return is claimed only once a row is highlighted and the list has been up for `activationDelay`,
    /// so Return still submits the page's form otherwise.
    @discardableResult
    func handleKey(code: UInt16) -> Bool {
        guard let selection, presentedToken != nil else { return false }
        switch code {
        case 125:
            selection.move(by: 1)
            return true
        case 126:
            selection.move(by: -1)
            return true
        case 36, 76:
            guard acceptsActivation, let item = selection.selectedItem, item.isEnabled else { return false }
            item.action?()
            dismiss()
            return true
        case 53:
            let token = presentedToken
            dismiss()
            if let token { onEscape?(token) }
            return true
        default:
            return false
        }
    }

    private func installMonitors(window: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresented, self.ownerWindow?.isKeyWindow == true else { return event }
            return self.handleKey(code: event.keyCode) ? nil : event
        }
        // A click that is neither on the list nor in the page ends it; a click in the page is the page's to report (it blurs or refocuses a field).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.isPresented else { return event }
            if event.window === self.panel { return event }
            if event.window === self.ownerWindow, let anchor = self.anchorView {
                let local = anchor.convert(event.locationInWindow, from: nil)
                if anchor.bounds.contains(local) { return event }
            }
            self.dismiss()
            return event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
