import AppKit
import SwiftUI

// Empty sidebar chrome has no drag path of its own. The window sets
// isMovableByWindowBackground to false so a click on the page cannot move it, and the
// transparent full-size titlebar only drags a view that answers mouseDownCanMoveWindow.
// Sidebar controls answer false so a click in that band reaches the control, which also
// means those views never start a drag. This surface calls performDrag(with:) itself.

struct SidebarChromeDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarChromeDragView {
        SidebarChromeDragView()
    }

    func updateNSView(_ nsView: SidebarChromeDragView, context: Context) {}

    static func dismantleNSView(_ nsView: SidebarChromeDragView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

@MainActor
final class SidebarChromeDragView: NSView {
    private var monitor: Any?
    private var passingThrough = false
    private var isDraggingWindow = false

    override var mouseDownCanMoveWindow: Bool { false }

    // A titlebar drag starts even when the window is not yet key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if passingThrough { return nil }
        guard !isHidden, alphaValue > 0.01, let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.monitorMouseDown(event) ?? event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { removeMonitor() }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            forwardContextClick(event)
            return
        }
        // A control that lost the hit test to this background still has to run.
        // Empty chrome has nothing under it but the hosting view, which is not a control.
        if let control = controlUnderneath(event) {
            control.mouseDown(with: event)
            return
        }
        beginWindowDrag(with: event)
    }

    // This view is the hit target for empty chrome, so the sidebar's SwiftUI context
    // menu never sees the right-click unless it is handed back.
    override func rightMouseDown(with event: NSEvent) {
        forwardContextClick(event)
    }

    private func beginWindowDrag(with event: NSEvent) {
        guard !isDraggingWindow, let window else { return }
        if event.clickCount >= 2 {
            OrbitTitleBarDoubleClick.handle(on: window)
            return
        }
        isDraggingWindow = true
        defer { isDraggingWindow = false }
        window.performDrag(with: event)
    }

    // The list's empty viewport is not this view. The scroll view claims it, including
    // points below the last row, outside the content's own frame. Rows, buttons, and
    // text fields sit inside that frame (or are controls) and keep the click.
    private func monitorMouseDown(_ event: NSEvent) -> NSEvent? {
        guard !isDraggingWindow, let window, event.window === window else { return event }
        guard alphaValue > 0.01, !isHidden else { return event }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
        guard !event.modifierFlags.contains(.control) else { return event }
        guard isEmptyScrollViewport(event) else { return event }
        beginWindowDrag(with: event)
        return nil
    }

    private func isEmptyScrollViewport(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView else { return false }
        let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        guard let hit else { return false }
        return SidebarChromeDragView.isEmptyScrollViewport(hit, windowPoint: event.locationInWindow)
    }

    private func controlUnderneath(_ event: NSEvent) -> NSView? {
        guard let content = window?.contentView else { return nil }
        passingThrough = true
        defer { passingThrough = false }
        let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        guard let hit, hit !== self, !hit.isDescendant(of: self) else { return nil }
        if hit is NSControl || hit is NSTextView || hit is NSScroller || hit is OrbitClickCatching {
            return hit
        }
        return nil
    }

    private func forwardContextClick(_ event: NSEvent) {
        guard let content = window?.contentView else { return }
        // Stay transparent for the whole forward. SwiftUI hit-tests again inside
        // rightMouseDown, and clearing the flag first would hand the click back here.
        passingThrough = true
        defer { passingThrough = false }
        let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        guard let hit, hit !== self, !hit.isDescendant(of: self) else { return }
        hit.rightMouseDown(with: event)
    }

    static func isEmptyScrollViewport(_ hit: NSView, windowPoint: NSPoint) -> Bool {
        guard isInertScrollSurface(hit) else { return false }
        let root = enclosingScrollView(from: hit) ?? hit
        let groups = platformContentGroups(in: root)
        guard !groups.isEmpty else { return false }
        return groups.allSatisfy { group in
            !group.convert(group.bounds, to: nil).contains(windowPoint)
        }
    }

    private static func isInertScrollSurface(_ view: NSView) -> Bool {
        if view is NSScroller || view is NSControl || view is NSTextView || view is OrbitClickCatching {
            return false
        }
        let name = "\(type(of: view))"
        if name.hasPrefix("NSHostingView") || name == "_NSGraphicsView" { return false }
        return name.contains("Scroll")
            || name.contains("ClipView")
            || name.contains("PlatformGroup")
            || name.contains("PlatformContainer")
            || name.contains("DocumentView")
    }

    private static func enclosingScrollView(from view: NSView) -> NSView? {
        var node: NSView? = view
        while let current = node {
            let name = "\(type(of: current))"
            if current is NSScrollView || name.contains("ScrollView") { return current }
            node = current.superview
        }
        return nil
    }

    private static func platformContentGroups(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if "\(type(of: view))".contains("PlatformGroupContainer") {
                found.append(view)
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }
}
