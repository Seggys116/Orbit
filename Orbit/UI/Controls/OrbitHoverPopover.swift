import AppKit
import SwiftUI

struct OrbitHoverPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var preferredEdge: NSRectEdge = .maxX
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, preferredEdge: preferredEdge)
    }

    func makeNSView(context: Context) -> OrbitHoverPopoverAnchorView {
        let anchor = OrbitHoverPopoverAnchorView()
        anchor.onWindowChange = { [weak coordinator = context.coordinator] anchor in
            coordinator?.anchorWindowDidChange(anchor)
        }
        return anchor
    }

    func updateNSView(_ nsView: OrbitHoverPopoverAnchorView, context: Context) {
        context.coordinator.preferredEdge = preferredEdge
        context.coordinator.update(
            isPresented: isPresented,
            anchor: nsView,
            content: OrbitHoverPopoverHostedContent(content: content(), environment: context.environment)
        )
    }

    static func dismantleNSView(_ nsView: OrbitHoverPopoverAnchorView, coordinator: Coordinator) {
        // anchor.window stays non-nil for at least one more run-loop turn after this returns.
        nsView.isDismantled = true
        nsView.onWindowChange = nil
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator {
        typealias HostedContent = OrbitHoverPopoverHostedContent<Content>

        private var isPresented: Binding<Bool>
        var preferredEdge: NSRectEdge

        private var popover: NSPopover?
        private var hostingController: NSHostingController<HostedContent>?
        private var escapeMonitor: Any?
        private var resignKeyObserver: NSObjectProtocol?
        private var outsideClickMonitor: Any?
        private var globalOutsideClickMonitor: Any?
        // The click-catching region a same-anchor re-click must be excluded from — the anchor overlays its real button exactly, since it is that button's own .background.
        private weak var currentAnchor: NSView?

        // Do not replace with a DispatchQueue.main.async retry: it can fire against
        // an already-dismantled anchor, or never fire if the anchor never gets a window.
        private var pendingContent: HostedContent?

        init(isPresented: Binding<Bool>, preferredEdge: NSRectEdge) {
            self.isPresented = isPresented
            self.preferredEdge = preferredEdge
        }

        func update(isPresented: Bool, anchor: NSView, content: HostedContent) {
            guard isPresented else {
                dismiss()
                return
            }
            if let hostingController {
                hostingController.rootView = content
            } else {
                present(from: anchor, content: content)
            }
        }

        func anchorWindowDidChange(_ anchor: OrbitHoverPopoverAnchorView) {
            guard anchor.window != nil else {
                if popover != nil { dismiss() }
                return
            }
            guard let content = pendingContent, popover == nil else { return }
            guard isPresented.wrappedValue else {
                pendingContent = nil
                return
            }
            present(from: anchor, content: content)
        }

        private func present(from anchor: NSView, content: HostedContent) {
            if let anchor = anchor as? OrbitHoverPopoverAnchorView, anchor.isDismantled {
                pendingContent = nil
                return
            }

            guard anchor.window != nil else {
                pendingContent = content
                return
            }
            pendingContent = nil

            let hostingController = NSHostingController(rootView: content)
            hostingController.sizingOptions = [.preferredContentSize]

            let popover = NSPopover()
            popover.contentViewController = hostingController
            popover.behavior = .applicationDefined // Default .transient eats the click that dismisses it.
            popover.animates = true

            // -[NSPopover showRelativeToRect:ofView:preferredEdge:] raises an uncatchable
            // NSInvalidArgumentException if the anchor has no window; window must be
            // checked last, right before show(), with nothing else evaluated after it.
            let positioningRect = anchor.bounds
            guard let window = anchor.window else {
                pendingContent = content
                return
            }

            self.hostingController = hostingController
            self.popover = popover
            self.currentAnchor = anchor

            popover.show(relativeTo: positioningRect, of: anchor, preferredEdge: preferredEdge)
            installDismissalMonitors(window: window)
        }

        func dismiss() {
            pendingContent = nil
            guard popover != nil else { return }
            popover?.close()
            popover = nil
            hostingController = nil
            currentAnchor = nil
            removeDismissalMonitors()
        }

        private func installDismissalMonitors(window: NSWindow) {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.popover != nil else { return event }
                guard event.keyCode == 53 else { return event } // kVK_Escape
                self.close()
                return nil
            }
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
            // Local, not .transient: the event is returned unmodified so it still reaches whatever
            // it hit; .transient's own monitor eats the click outright instead.
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.dismissIfOutside(event)
                return event
            }
            // Catches a click on the menu bar or another app, neither of which necessarily resigns this window's key status.
            globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }

        private func dismissIfOutside(_ event: NSEvent) {
            guard let popover, let popoverWindow = popover.contentViewController?.view.window else { return }
            guard event.window !== popoverWindow else { return }
            // A click back on the anchor itself (e.g. re-clicking the toolbar icon) is the
            // caller's own action to arbitrate, not a dismiss-and-reopen from here.
            if let currentAnchor, let anchorWindow = currentAnchor.window, anchorWindow === event.window {
                let locationInAnchor = currentAnchor.convert(event.locationInWindow, from: nil)
                if currentAnchor.bounds.contains(locationInAnchor) { return }
            }
            close()
        }

        private func removeDismissalMonitors() {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
            escapeMonitor = nil
            if let resignKeyObserver {
                NotificationCenter.default.removeObserver(resignKeyObserver)
            }
            resignKeyObserver = nil
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
            }
            outsideClickMonitor = nil
            if let globalOutsideClickMonitor {
                NSEvent.removeMonitor(globalOutsideClickMonitor)
            }
            globalOutsideClickMonitor = nil
        }

        private func close() {
            dismiss()
            isPresented.wrappedValue = false
        }

        deinit {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
            if let resignKeyObserver {
                NotificationCenter.default.removeObserver(resignKeyObserver)
            }
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
            }
            if let globalOutsideClickMonitor {
                NSEvent.removeMonitor(globalOutsideClickMonitor)
            }
        }
    }
}

// NSHostingController(rootView:) starts a detached SwiftUI tree with no inherited
// environment; without re-applying it here, an @Environment(AppEnvironment.self)
// read inside content traps.
struct OrbitHoverPopoverHostedContent<Content: View>: View {
    var content: Content
    var environment: EnvironmentValues

    var body: some View {
        content.environment(\.self, environment)
    }
}

final class OrbitHoverPopoverAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    var isDismantled = false

    var onWindowChange: ((OrbitHoverPopoverAnchorView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(self)
    }
}

extension View {
    // Gated on isPresented: an unconditional background(OrbitHoverPopover(...)) breaks
    // ImageRenderer-based render tests on unhovered rows.
    func orbitHoverPopover<Content: View>(
        isPresented: Binding<Bool>,
        preferredEdge: NSRectEdge = .maxX,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background {
            if isPresented.wrappedValue {
                OrbitHoverPopover(isPresented: isPresented, preferredEdge: preferredEdge, content: content)
            }
        }
    }
}
