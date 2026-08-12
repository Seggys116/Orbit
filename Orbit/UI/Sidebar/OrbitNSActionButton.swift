import AppKit
import SwiftUI

class OrbitActionButtonClickCatchingView: NSView, OrbitClickCatching {
    var action: (() -> Void)?

    var clickCountAction: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let clickCountAction {
            clickCountAction(event.clickCount)
        } else {
            action?()
        }
    }

    // Interactive controls must opt out: under .fullSizeContentView, a view over the titlebar band that answers true here has its mouseDown consumed by AppKit for a window drag before mouseDown(with:) is ever called.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // point arrives in the superview's coordinate space, not this view's own bounds.
    override func hitTest(_ point: NSPoint) -> NSView? {
        orbitContainsHitTestPoint(point) ? self : nil
    }
}

private struct OrbitNSActionButtonCatcher: NSViewRepresentable {
    var action: (() -> Void)?
    var clickCountAction: ((Int) -> Void)?

    func makeNSView(context: Context) -> OrbitActionButtonClickCatchingView {
        let view = OrbitActionButtonClickCatchingView()
        view.action = action
        view.clickCountAction = clickCountAction
        return view
    }

    func updateNSView(_ nsView: OrbitActionButtonClickCatchingView, context: Context) {
        nsView.action = action
        nsView.clickCountAction = clickCountAction
    }
}

struct OrbitNSActionButton<Label: View>: View {
    private var action: (() -> Void)?
    private var clickCountAction: ((Int) -> Void)?
    @ViewBuilder var label: () -> Label

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.clickCountAction = nil
        self.label = label
    }

    init(onClickCount: @escaping (Int) -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = nil
        self.clickCountAction = onClickCount
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
            OrbitNSActionButtonCatcher(action: action, clickCountAction: clickCountAction)
        }
        #else
        OrbitNSActionButtonCatcher(action: action, clickCountAction: clickCountAction)
        #endif
    }
}
