//  Deliberately not NSTrackingArea-based: hotZoneWidth changes re-test the last known
//  pointer location immediately, so hover detection can't fall out of step mid-animation.

import AppKit
import SwiftUI

enum SidebarHoverPhase: Equatable {
    case hidden
    case peeking
    case revealed
    case hiding

    var isPanelPresented: Bool { self != .hidden }

    func hoverChanged(_ hovering: Bool) -> SidebarHoverPhase {
        if hovering {
            return self == .hidden ? .peeking : .revealed
        } else {
            return self == .hidden ? .hidden : .hiding
        }
    }

    func revealAnimationCompleted() -> SidebarHoverPhase {
        self == .peeking ? .revealed : self
    }

    func hideDelayElapsed() -> SidebarHoverPhase {
        self == .hiding ? .hidden : self
    }
}

/// Whether a pointer outside the sidebar is clearly not coming back to it: far away, or leaving quickly.
enum SidebarDismissIntent {

    struct Sample: Equatable {
        var x: CGFloat
        var time: TimeInterval
    }

    static let farDistance: CGFloat = 240
    static let fastAwaySpeed: CGFloat = 1100
    static let minimumAwayDistance: CGFloat = 20
    static let minimumSampleInterval: TimeInterval = 0.002
    static let maximumSampleInterval: TimeInterval = 0.12

    static func shouldDismiss(previous: Sample?, current: Sample, hotZoneWidth: CGFloat) -> Bool {
        let beyondEdge = current.x - hotZoneWidth
        guard beyondEdge > 0 else { return false }
        if beyondEdge >= farDistance { return true }
        guard beyondEdge >= minimumAwayDistance, let previous else { return false }
        let elapsed = current.time - previous.time
        guard elapsed >= minimumSampleInterval, elapsed <= maximumSampleInterval else { return false }
        let speedAway = (current.x - previous.x) / CGFloat(elapsed)
        return speedAway >= fastAwaySpeed
    }
}

struct HoverEdgeDetector: NSViewRepresentable {
    var hotZoneWidth: CGFloat
    var onHoverChanged: (Bool) -> Void
    var onDismissIntent: () -> Void = {}

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onHoverChanged = onHoverChanged
        view.onDismissIntent = onDismissIntent
        view.hotZoneWidth = hotZoneWidth
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onDismissIntent = onDismissIntent
        nsView.hotZoneWidth = hotZoneWidth
    }
}

@MainActor
final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onDismissIntent: (() -> Void)?

    var hotZoneWidth: CGFloat = 0 {
        didSet {
            guard hotZoneWidth != oldValue, let lastKnownLocationInView else { return }
            updateHover(atLocationInView: lastKnownLocationInView)
        }
    }

    private(set) var isInsideHotZone = false

    private var lastKnownLocationInView: NSPoint?
    private var previousSample: SidebarDismissIntent.Sample?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            detachMonitor()
            return
        }
        window.acceptsMouseMovedEvents = true
        attachMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { detachMonitor() }
    }

    private func attachMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func detachMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateHover(atLocationInView: point)
        let sample = SidebarDismissIntent.Sample(x: point.x, time: event.timestamp)
        defer { previousSample = sample }
        guard !isInsideHotZone else { return }
        if SidebarDismissIntent.shouldDismiss(previous: previousSample, current: sample, hotZoneWidth: hotZoneWidth) {
            onDismissIntent?()
        }
    }

    func updateHover(atLocationInView point: NSPoint) {
        lastKnownLocationInView = point
        let hotZone = CGRect(x: 0, y: 0, width: hotZoneWidth, height: bounds.height)
        let inside = hotZone.contains(point)
        guard inside != isInsideHotZone else { return }
        isInsideHotZone = inside
        onHoverChanged?(inside)
    }

    // Must return nil: once grown to cover the revealed overlay's footprint, this
    // view physically overlaps every real control the overlay draws.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
