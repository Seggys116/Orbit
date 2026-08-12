import AppKit
import SwiftUI

// MARK: - The AppKit hover surface

final class OrbitHoverTrackingNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    private(set) var isHovering = false

    private var localMonitor: Any?
    private var globalMonitor: Any?

    // Must return nil: this view sits over a real control and must never swallow its click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detachMonitors()
        guard let window else { return }
        // Off by default on a fresh NSWindow; without it, .mouseMoved never fires for this window.
        window.acceptsMouseMovedEvents = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleLocal(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.setHovering(false)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            detachMonitors()
            setHovering(false)
        }
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    private func detachMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handleLocal(_ event: NSEvent) {
        guard let window, event.window === window else {
            setHovering(false)
            return
        }
        updateHover(atLocationInView: convert(event.locationInWindow, from: nil))
    }

    func updateHover(atLocationInView point: NSPoint) {
        setHovering(bounds.contains(point))
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHoverChanged?(hovering)
    }
}

private struct OrbitHoverTracker: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> OrbitHoverTrackingNSView {
        let view = OrbitHoverTrackingNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: OrbitHoverTrackingNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

// MARK: - Forced hover (DEBUG only)

#if DEBUG
private struct OrbitForcedHoverHighlightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var orbitForcedHoverHighlight: Bool {
        get { self[OrbitForcedHoverHighlightKey.self] }
        set { self[OrbitForcedHoverHighlightKey.self] = newValue }
    }
}
#endif

// MARK: - The modifier

struct OrbitHoverHighlight: ViewModifier {
    var fill: Color
    var cornerRadius: CGFloat
    var isActive: Bool

    @State private var isHovering = false

    #if DEBUG
    @Environment(\.orbitForcedHoverHighlight) private var forcedHover
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    private var isHighlighted: Bool {
        guard isActive else { return false }
        #if DEBUG
        if forcedHover { return true }
        #endif
        return isHovering
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHighlighted ? fill : Color.clear)
                    .allowsHitTesting(false)
            }
            .background(tracker)
            .animation(OrbitMotion.quick, value: isHighlighted)
    }

    @ViewBuilder
    private var tracker: some View {
        #if DEBUG
        if !screenshotModeRepresentableDisabled {
            OrbitHoverTracker(onHoverChanged: { isHovering = $0 })
        }
        #else
        OrbitHoverTracker(onHoverChanged: { isHovering = $0 })
        #endif
    }
}

extension View {
    func orbitHoverHighlight(fill: Color, cornerRadius: CGFloat, isActive: Bool = true) -> some View {
        modifier(OrbitHoverHighlight(fill: fill, cornerRadius: cornerRadius, isActive: isActive))
    }
}
