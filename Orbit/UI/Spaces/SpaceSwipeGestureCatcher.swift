import AppKit
import SwiftUI

struct SpaceSwipeGestureCatcher: NSViewRepresentable {
    var onBegin: () -> Void
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    // hitTest returns nil: a bare NSView otherwise swallows every
    // click/drag inside this frame regardless of the .scrollWheel monitor's
    // own scoping below.
    final class PassThroughHitTestView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window else { return event }
            guard event.hasPreciseScrollingDeltas else { return event }

            let locationInView = view.convert(event.locationInWindow, from: nil)
            let isInsideBounds = view.bounds.contains(locationInView)

            if event.phase != [] {
                switch event.phase {
                case .began:
                    isGestureActive = isInsideBounds
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
