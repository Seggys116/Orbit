import AppKit
import SwiftUI

struct SidebarResizeHandle: View {
    @Environment(AppEnvironment.self) private var env

    static func resizedWidth(startWidth: CGFloat, translationX: CGFloat) -> CGFloat {
        SidebarResizeHandleNSView.clampedWidth(
            start: startWidth,
            deltaX: translationX,
            minWidth: OrbitMetrics.sidebarMinWidth,
            maxWidth: OrbitMetrics.sidebarMaxWidth
        )
    }

    var body: some View {
        SidebarResizeHandleRepresentable(
            minWidth: OrbitMetrics.sidebarMinWidth,
            maxWidth: OrbitMetrics.sidebarMaxWidth,
            defaultWidth: OrbitMetrics.sidebarDefaultWidth,
            currentWidth: { env.sidebarWidth },
            onWidthChange: { env.sidebarWidth = $0 }
        )
        .frame(width: OrbitMetrics.sidebarResizeHandleWidth)
    }
}

private struct SidebarResizeHandleRepresentable: NSViewRepresentable {
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var defaultWidth: CGFloat
    var currentWidth: () -> CGFloat
    var onWidthChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarResizeHandleNSView {
        let view = SidebarResizeHandleNSView()
        applyState(to: view)
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleNSView, context: Context) {
        applyState(to: nsView)
    }

    private func applyState(to view: SidebarResizeHandleNSView) {
        view.minWidth = minWidth
        view.maxWidth = maxWidth
        view.defaultWidth = defaultWidth
        view.currentWidth = currentWidth
        view.onWidthChange = onWidthChange
    }
}

@MainActor
final class SidebarResizeHandleNSView: NSView, OrbitClickCatching {
    var minWidth: CGFloat = OrbitMetrics.sidebarMinWidth
    var maxWidth: CGFloat = OrbitMetrics.sidebarMaxWidth
    var currentWidth: () -> CGFloat = { OrbitMetrics.sidebarDefaultWidth }
    var defaultWidth: CGFloat = OrbitMetrics.sidebarDefaultWidth
    var onWidthChange: (CGFloat) -> Void = { _ in }

    private(set) var dragStartWidth: CGFloat?
    private var dragStartLocationInWindow: NSPoint?

    private(set) var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var isDragging = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    // MARK: - Pure clamp math

    static func clampedWidth(start: CGFloat, deltaX: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let proposed = start + deltaX
        return min(max(proposed, minWidth), maxWidth)
    }

    // MARK: - Hit testing

    // point arrives in the superview's coordinate space, not this view's own bounds.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return orbitContainsHitTestPoint(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    // Under .fullSizeContentView, a view over the titlebar band that answers true here has its mouseDown consumed by AppKit for a window drag; this handle runs to the window's y=0 top edge, inside that band.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    // MARK: - Hover tracking (visual highlight only -- the cursor rect above
    // is what AppKit itself uses to swap the cursor, independent of this)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    // MARK: - Drag tracking -- the actual resize mechanism

    // AppKit delivers a double-click as two full mouseDown/mouseUp pairs; clickCount >= 2 resets and leaves dragStartWidth nil so the trailing mouseUp's applyDrag guard skips and doesn't overwrite the reset.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            dragStartWidth = nil
            dragStartLocationInWindow = nil
            isDragging = false
            onWidthChange(SidebarResizeHandleNSView.clampedWidth(
                start: defaultWidth,
                deltaX: 0,
                minWidth: minWidth,
                maxWidth: maxWidth
            ))
            return
        }
        dragStartWidth = currentWidth()
        dragStartLocationInWindow = event.locationInWindow
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        applyDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        applyDrag(event)
        dragStartWidth = nil
        dragStartLocationInWindow = nil
        isDragging = false
    }

    private func applyDrag(_ event: NSEvent) {
        guard let dragStartWidth, let dragStartLocationInWindow else { return }
        let deltaX = event.locationInWindow.x - dragStartLocationInWindow.x
        let clamped = SidebarResizeHandleNSView.clampedWidth(
            start: dragStartWidth,
            deltaX: deltaX,
            minWidth: minWidth,
            maxWidth: maxWidth
        )
        onWidthChange(clamped)
    }

    // MARK: - Visual: a white grabber pill while hovering or dragging

    static let grabberWidth: CGFloat = 4

    static let grabberVerticalInset: CGFloat = 10

    override func draw(_ dirtyRect: NSRect) {
        guard isHovering || isDragging else { return }
        let width = SidebarResizeHandleNSView.grabberWidth
        let inset = SidebarResizeHandleNSView.grabberVerticalInset
        let height = bounds.height - inset * 2
        guard height > width else { return }
        let rect = NSRect(x: ((bounds.width - width) / 2).rounded(), y: inset, width: width, height: height)
        NSColor.white.withAlphaComponent(isDragging ? 0.9 : 0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override var isOpaque: Bool { false }
}
