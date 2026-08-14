import AppKit
import SwiftUI

struct SpaceSwipeGestureCatcher: NSViewRepresentable {
    var onBegin: () -> Void
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    // hitTest returns nil: a bare NSView otherwise swallows every
    // click/drag inside this frame regardless of the .scrollWheel monitor's
    // own scoping below.
    class PassThroughHitTestView: NSView {
        var windowDidChange: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?()
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughHitTestView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onBegin = onBegin
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegin: onBegin, onChange: onChange, onEnd: onEnd)
    }

    @MainActor
    final class Coordinator {
        var onBegin: () -> Void
        var onChange: (CGFloat) -> Void
        var onEnd: (CGFloat, CGFloat) -> Void

        private weak var view: NSView?
        private var monitor: Any?
        // -1 matches no window, so a catcher with no window rejects every event.
        private(set) var monitoredWindowNumber = -1

        var isMonitorInstalled: Bool { monitor != nil }

        private var isGestureActive = false
        private var isTrackingHorizontal = false
        private var accumulatedTranslation: CGFloat = 0
        private var undecidedDX: CGFloat = 0
        private var undecidedDY: CGFloat = 0
        private var lastSampleTime: TimeInterval = 0
        private var recentVelocity: CGFloat = 0

        init(onBegin: @escaping () -> Void, onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat, CGFloat) -> Void) {
            self.onBegin = onBegin
            self.onChange = onChange
            self.onEnd = onEnd
        }

        func attach(to view: PassThroughHitTestView) {
            self.view = view
            view.windowDidChange = { [weak self, weak view] in
                guard let self, let view else { return }
                syncMonitor(for: view)
            }
            syncMonitor(for: view)
        }

        func detach() {
            (view as? PassThroughHitTestView)?.windowDidChange = nil
            removeMonitor()
        }

        // Tied to window membership: a monitor that outlives its window still runs on every wheel tick everywhere.
        func syncMonitor(for view: NSView) {
            guard let window = view.window else {
                monitoredWindowNumber = -1
                isGestureActive = false
                isTrackingHorizontal = false
                removeMonitor()
                return
            }
            monitoredWindowNumber = window.windowNumber
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.windowNumber == monitoredWindowNumber else { return event }
            // Only .began reads geometry, so page scrolling walks no view hierarchy here.
            guard isGestureActive || event.phase == .began else { return event }
            guard event.hasPreciseScrollingDeltas else { return event }

            if event.phase != [] {
                switch event.phase {
                case .began:
                    isGestureActive = isInsideCatcher(event)
                    isTrackingHorizontal = false
                    accumulatedTranslation = 0
                    undecidedDX = 0
                    undecidedDY = 0
                    recentVelocity = 0
                    lastSampleTime = event.timestamp
                    if isGestureActive { onBegin() }
                    return isGestureActive ? nil : event

                case .changed:
                    guard isGestureActive else { return event }
                    return process(event)

                case .ended, .cancelled:
                    // isGestureActive drops unconditionally so later momentum
                    // events for this touch are ignored, not re-finalised.
                    guard isGestureActive else { return event }
                    let consumed = isTrackingHorizontal
                    isGestureActive = false
                    isTrackingHorizontal = false
                    if consumed { onEnd(accumulatedTranslation, recentVelocity) }
                    return consumed ? nil : event

                default:
                    return event
                }
            }

            // Momentum phases arrive with event.phase == [].
            switch event.momentumPhase {
            case .began, .changed, .ended, .cancelled:
                guard isGestureActive else { return event }
                let consumed = isTrackingHorizontal
                isGestureActive = false
                isTrackingHorizontal = false
                return consumed ? nil : event
            default:
                return event
            }
        }

        private func isInsideCatcher(_ event: NSEvent) -> Bool {
            guard let view, view.window != nil else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }

        private func process(_ event: NSEvent) -> NSEvent? {
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let now = event.timestamp
            let dt = max(now - lastSampleTime, 1.0 / 240.0)
            lastSampleTime = now

            if isTrackingHorizontal {
                accumulatedTranslation += dx
                recentVelocity = dx / CGFloat(dt)
                onChange(accumulatedTranslation)
                return nil
            }

            undecidedDX += dx
            undecidedDY += dy
            let magnitude = hypot(undecidedDX, undecidedDY)
            guard magnitude > 4 else {
                return event
            }

            if abs(undecidedDX) > abs(undecidedDY) * 1.15 {
                isTrackingHorizontal = true
                accumulatedTranslation = undecidedDX
                recentVelocity = dx / CGFloat(dt)
                onChange(accumulatedTranslation)
                return nil
            } else {
                isGestureActive = false
                return event
            }
        }
    }
}
