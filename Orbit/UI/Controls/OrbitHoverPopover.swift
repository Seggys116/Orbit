import AppKit
import SwiftUI

struct OrbitHoverPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var preferredEdge: NSRectEdge = .maxX
    /// A popover the user can move into and click inside (a folder's list of tabs). The pointer leaving the anchor then no longer closes it by itself: the popover closes once the pointer has been outside the anchor, the popover and the strip between them for `OrbitHoverPopoverPointerZone.grace`.
    var keepsOpenWhilePointerInside: Bool = false
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(isPresented: $isPresented, preferredEdge: preferredEdge)
        coordinator.keepsOpenWhilePointerInside = keepsOpenWhilePointerInside
        return coordinator
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
        context.coordinator.keepsOpenWhilePointerInside = keepsOpenWhilePointerInside
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
        var keepsOpenWhilePointerInside = false

        private var pointerTimer: Timer?
        private var pointerLastInside = Date()
        private var appResignObserver: NSObjectProtocol?
        /// Replaced in tests: the real pointer is not scriptable.
        var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
        var primaryButtonIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

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

            let hostingController = SizingHostingController(rootView: content)
            // preferredContentSize only. minSize would floor the popover above a small page,
            // and the safe area would inset that page a second time — the popover's border
            // and arrow already sit outside the content rect.
            hostingController.sizingOptions = [.preferredContentSize]
            hostingController.safeAreaRegions = []

            let popover = NSPopover()
            popover.contentViewController = hostingController
            // NSPopover reads preferredContentSize when it is shown and does not follow
            // later changes. An extension popup is born at 25×25 and grows once the page
            // reports; without this the bubble stays the loading size and clips the page.
            hostingController.onPreferredSizeChange = { [weak popover] preferred in
                guard let popover, popover.isShown else { return }
                guard let next = OrbitHoverPopoverContentSize.next(current: popover.contentSize, preferred: preferred) else { return }
                popover.contentSize = next
            }
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
            startPointerTracking()
        }

        func dismiss() {
            pendingContent = nil
            stopPointerTracking()
            guard let popover else { return }
            // An animating close outlives this object and releases the popover again from the animation.
            popover.animates = false
            popover.close()
            self.popover = nil
            hostingController = nil
            currentAnchor = nil
            removeDismissalMonitors()
        }

        // MARK: Pointer tracking (keepsOpenWhilePointerInside)

        private func startPointerTracking() {
            stopPointerTracking()
            guard keepsOpenWhilePointerInside else { return }
            pointerLastInside = Date()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluatePointer(now: Date()) }
            }
            // .common, not the default mode: the timer must keep running while the user scrolls the popover's list.
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }

        private func stopPointerTracking() {
            pointerTimer?.invalidate()
            pointerTimer = nil
        }

        /// One sample of the pointer. Internal so a test can drive it with a scripted pointer and clock.
        func evaluatePointer(now: Date) {
            guard let popover, let anchor = currentAnchor,
                  let anchorWindow = anchor.window,
                  let popoverWindow = popover.contentViewController?.view.window
            else { return }
            let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if hasOpenMenuPanel(in: popoverWindow) || primaryButtonIsDown() || OrbitHoverPopoverPointerZone.contains(pointerLocation(), anchor: anchorRect, popover: popoverWindow.frame) {
                pointerLastInside = now
                return
            }
            if OrbitHoverPopoverPointerZone.hasLapsed(lastInside: pointerLastInside, now: now) {
                close()
            }
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
                MainActor.assumeIsolated { self?.closeUnlessThePopoverTookFocus() }
            }
            // The whole app going to the background closes it too, including when the popover's own window was the key one (which the observer above no longer treats as "focus left").
            appResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
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
            if let eventWindow = event.window, Self.isMenuPanel(eventWindow, descendantOf: popoverWindow) { return }
            // A click back on the anchor itself (e.g. re-clicking the toolbar icon) is the
            // caller's own action to arbitrate, not a dismiss-and-reopen from here.
            if let currentAnchor, let anchorWindow = currentAnchor.window, anchorWindow === event.window {
                let locationInAnchor = currentAnchor.convert(event.locationInWindow, from: nil)
                if currentAnchor.bounds.contains(locationInAnchor) { return }
            }
            close()
        }

        // The popover's own window becoming key is what happens when the user clicks into it (a text field in an extension popup, a row in a folder preview). That resigns the anchor's window, and treating it as "focus left" closed the popover on the very mouse-down that was meant for it.
        // Looked at one turn later, because AppKit has not finished moving key status when didResignKey is posted.
        private func closeUnlessThePopoverTookFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover != nil else { return }
                let popoverWindow = self.popover?.contentViewController?.view.window
                if let popoverWindow, self.hasOpenMenuPanel(in: popoverWindow) { return }
                if OrbitHoverPopoverPointerZone.holdsFocus(popoverWindowIsKey: popoverWindow?.isKeyWindow ?? false) { return }
                self.close()
            }
        }

        private func hasOpenMenuPanel(in popoverWindow: NSWindow) -> Bool {
            popoverWindow.childWindows?.contains { $0 is OrbitMenuPanel } ?? false
        }

        private static func isMenuPanel(_ window: NSWindow, descendantOf popoverWindow: NSWindow) -> Bool {
            guard window is OrbitMenuPanel else { return false }
            var ancestor = window.parent
            while let current = ancestor {
                if current === popoverWindow { return true }
                ancestor = current.parent
            }
            return false
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
            if let appResignObserver {
                NotificationCenter.default.removeObserver(appResignObserver)
            }
            appResignObserver = nil
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
            if let appResignObserver {
                NotificationCenter.default.removeObserver(appResignObserver)
            }
            pointerTimer?.invalidate()
        }
    }
}

/// Where the pointer may rest without closing a popover that keeps itself open, in screen coordinates.
enum OrbitHoverPopoverPointerZone {
    /// Long enough to cross the gap and to forgive a pointer clipping a corner on the way; short enough that moving off feels like leaving.
    static let grace: TimeInterval = 0.25

    /// The anchor, the popover, and the strip between them across the anchor's own height. The strip is what lets the pointer cross a popover's arrow without passing through either rectangle.
    static func contains(_ point: NSPoint, anchor: NSRect, popover: NSRect) -> Bool {
        if anchor.contains(point) || popover.contains(point) { return true }
        let minX = min(anchor.minX, popover.minX)
        let maxX = max(anchor.maxX, popover.maxX)
        let corridor = NSRect(x: minX, y: anchor.minY, width: maxX - minX, height: anchor.height)
        return corridor.contains(point)
    }

    static func hasLapsed(lastInside: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastInside) > grace
    }

    static func holdsFocus(popoverWindowIsKey: Bool) -> Bool { popoverWindowIsKey }
}

enum OrbitHoverPopoverContentSize {
    /// `nil` when `preferred` is not a real size yet, or already applied.
    static func next(current: NSSize, preferred: NSSize) -> NSSize? {
        guard preferred.width > 1, preferred.height > 1 else { return nil }
        let next = NSSize(width: ceil(preferred.width), height: ceil(preferred.height))
        if abs(current.width - next.width) <= 0.5, abs(current.height - next.height) <= 0.5 { return nil }
        return next
    }
}

private final class SizingHostingController<Content: View>: NSHostingController<Content> {
    var onPreferredSizeChange: ((NSSize) -> Void)?

    // An explicit deinit keeps the Release SIL optimiser off the synthesised destructor.
    deinit {}

    override func viewDidLayout() {
        super.viewDidLayout()
        // preferredContentSize tracks the bounds the popover already has. fittingSize
        // is the SwiftUI frame, which follows the document both when it grows and when it shrinks.
        let fitted = view.fittingSize
        guard fitted.width > 1, fitted.height > 1 else { return }
        onPreferredSizeChange?(fitted)
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
        keepsOpenWhilePointerInside: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background {
            if isPresented.wrappedValue {
                OrbitHoverPopover(
                    isPresented: isPresented,
                    preferredEdge: preferredEdge,
                    keepsOpenWhilePointerInside: keepsOpenWhilePointerInside,
                    content: content
                )
            }
        }
    }
}
