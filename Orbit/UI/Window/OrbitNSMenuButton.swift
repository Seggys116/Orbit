import AppKit
import SwiftUI

// SwiftUI Menu(.menuStyle(.borderlessButton)) is unreliable in this app's hosting
// configuration; this drives a real NSMenu off a real NSView.mouseDown(with:) instead.
class OrbitMenuButtonClickCatchingView: NSView, OrbitClickCatching {
    var menuProvider: (() -> NSMenu)?

    var presentMenu: (NSMenu, NSView) -> Void = { menu, view in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: view)
    }

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        presentMenu(menu, self)
    }

    // Without this, AppKit consumes the click one layer up as a window drag before
    // mouseDown(with:) above ever runs (the window's transparent titlebar band).
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        orbitContainsHitTestPoint(point) ? self : nil
    }
}

private struct OrbitNSMenuButtonCatcher: NSViewRepresentable {
    var menuProvider: () -> NSMenu

    func makeNSView(context: Context) -> OrbitMenuButtonClickCatchingView {
        let view = OrbitMenuButtonClickCatchingView()
        view.menuProvider = menuProvider
        return view
    }

    func updateNSView(_ nsView: OrbitMenuButtonClickCatchingView, context: Context) {
        nsView.menuProvider = menuProvider
    }
}

struct OrbitNSMenuButton<Label: View>: View {
    var menu: () -> NSMenu
    @ViewBuilder var label: () -> Label

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
            OrbitNSMenuButtonCatcher(menuProvider: menu)
        }
        #else
        OrbitNSMenuButtonCatcher(menuProvider: menu)
        #endif
    }
}
