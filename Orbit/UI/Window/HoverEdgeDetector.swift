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

struct HoverEdgeDetector: NSViewRepresentable {
    var hotZoneWidth: CGFloat
    var onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onHoverChanged = onHoverChanged
        view.hotZoneWidth = hotZoneWidth
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.hotZoneWidth = hotZoneWidth
    }
}

@MainActor
final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    var hotZoneWidth: CGFloat = 0 {
        didSet {
            guard hotZoneWidth != oldValue, let lastKnownLocationInView else { return }
            updateHover(atLocationInView: lastKnownLocationInView)
        }
    }

    private(set) var isInsideHotZone = false

    private var lastKnownLocationInView: NSPoint?
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
        updateHover(atLocationInView: convert(event.locationInWindow, from: nil))
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
