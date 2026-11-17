import AppKit
import SwiftUI

class OrbitActionButtonClickCatchingView: NSView, OrbitClickCatching {
    var action: (() -> Void)?

    var clickCountAction: ((Int) -> Void)?

    // Nil claims this view's bounds. A custom region is how a content-sized catcher can answer for a larger drawn pill; click recovery calls hitTest directly, so the region may extend past the view's frame.
    var hitContains: ((CGRect, CGPoint) -> Bool)?

    // A control that can also start a drag (a sidebar row) fires when the button is released, not when it goes down: firing on press switched to the tab the moment a drag began, so the page being dragged became the page under it and could not be dropped beside another.
    var firesOnRelease = false

    // How far (points) the pointer may move between press and release and still count as a click; a drag that AppKit has taken over never delivers the release at all.
    static let clickSlop: CGFloat = 4

    private var pressOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if firesOnRelease {
            pressOrigin = event.locationInWindow
            return
        }
        fire(clickCount: event.clickCount)
    }

    override func mouseUp(with event: NSEvent) {
        guard firesOnRelease, let origin = pressOrigin else {
            super.mouseUp(with: event)
            return
        }
        pressOrigin = nil
        let moved = hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y)
        guard moved <= Self.clickSlop else { return }
        fire(clickCount: event.clickCount)
    }

    private func fire(clickCount: Int) {
        if let clickCountAction {
            clickCountAction(clickCount)
        } else {
            action?()
        }
    }

    // Interactive controls must opt out: under .fullSizeContentView, a view over the titlebar band that answers true here has its mouseDown consumed by AppKit for a window drag before mouseDown(with:) is ever called.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // point arrives in the superview's coordinate space, not this view's own bounds.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitContains else { return orbitContainsHitTestPoint(point) ? self : nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return hitContains(bounds, local) ? self : nil
    }
}

private struct OrbitNSActionButtonCatcher: NSViewRepresentable {
    var action: (() -> Void)?
    var clickCountAction: ((Int) -> Void)?
    var hitContains: ((CGRect, CGPoint) -> Bool)?
    var firesOnRelease = false

    func makeNSView(context: Context) -> OrbitActionButtonClickCatchingView {
        let view = OrbitActionButtonClickCatchingView()
        view.action = action
        view.clickCountAction = clickCountAction
        view.hitContains = hitContains
        view.firesOnRelease = firesOnRelease
        return view
    }

    func updateNSView(_ nsView: OrbitActionButtonClickCatchingView, context: Context) {
        nsView.action = action
        nsView.clickCountAction = clickCountAction
        nsView.hitContains = hitContains
        nsView.firesOnRelease = firesOnRelease
    }
}

struct OrbitNSActionButton<Label: View>: View {
    private var action: (() -> Void)?
    private var clickCountAction: ((Int) -> Void)?
    private var hitContains: ((CGRect, CGPoint) -> Bool)?
    private var firesOnRelease = false
    @ViewBuilder var label: () -> Label

    init(
        action: @escaping () -> Void,
        hitContains: ((CGRect, CGPoint) -> Bool)? = nil,
        firesOnRelease: Bool = false,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.action = action
        self.clickCountAction = nil
        self.hitContains = hitContains
        self.firesOnRelease = firesOnRelease
        self.label = label
    }

    init(onClickCount: @escaping (Int) -> Void, firesOnRelease: Bool = false, @ViewBuilder label: @escaping () -> Label) {
        self.action = nil
        self.clickCountAction = onClickCount
        self.hitContains = nil
        self.firesOnRelease = firesOnRelease
        self.label = label
    }

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    var body: some View {
        label()
            .overlay(clickCatcher)
    }

    @ViewBuilder
    private var clickCatcher: some View {
        #if DEBUG
        if !screenshotModeRepresentableDisabled {
            OrbitNSActionButtonCatcher(action: action, clickCountAction: clickCountAction, hitContains: hitContains, firesOnRelease: firesOnRelease)
        }
        #else
        OrbitNSActionButtonCatcher(action: action, clickCountAction: clickCountAction, hitContains: hitContains, firesOnRelease: firesOnRelease)
        #endif
    }
}
