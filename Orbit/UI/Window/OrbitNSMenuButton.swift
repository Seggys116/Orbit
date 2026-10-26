import AppKit
import SwiftUI

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

protocol OrbitHandlesRightClick: NSView {}

@MainActor
final class OrbitEntryMenuButtonView: NSView, OrbitClickCatching {
    var entriesProvider: (() -> [OrbitContextMenuEntry])?
    var preferredDirection: OrbitMenuDirection = .down
    var presentEntries: (([OrbitContextMenuEntry], NSView) -> Void)?

    private let controller = OrbitMenuPanelController()

    override func mouseDown(with event: NSEvent) {
        if OrbitMenuClickGuard.wasDismissedThisTurn { return }
        guard let entries = entriesProvider?(), !entries.isEmpty else { return }
        if let presentEntries {
            presentEntries(entries, self)
            return
        }
        guard let window else { return }
        controller.present(
            entries: entries,
            anchorRect: window.convertToScreen(convert(bounds, to: nil)),
            anchorView: self,
            ownerWindow: window,
            mode: .anchored,
            preferredDirection: preferredDirection,
            showsArrow: true
        )
    }

    // Otherwise the transparent titlebar band turns the click into a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        orbitContainsHitTestPoint(point) ? self : nil
    }
}

private struct OrbitEntryMenuButtonCatcher: NSViewRepresentable {
    var entries: () -> [OrbitContextMenuEntry]
    var preferredDirection: OrbitMenuDirection

    func makeNSView(context: Context) -> OrbitEntryMenuButtonView {
        let view = OrbitEntryMenuButtonView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: OrbitEntryMenuButtonView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: OrbitEntryMenuButtonView) {
        view.entriesProvider = entries
        view.preferredDirection = preferredDirection
    }
}

struct OrbitMenuButton<Label: View>: View {
    var entries: () -> [OrbitContextMenuEntry]
    var preferredDirection: OrbitMenuDirection = .down
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
            OrbitEntryMenuButtonCatcher(entries: entries, preferredDirection: preferredDirection)
        }
        #else
        OrbitEntryMenuButtonCatcher(entries: entries, preferredDirection: preferredDirection)
        #endif
    }
}

/// One shared monitor serves all anchors: the smallest under the pointer wins; a backdrop anchor only when alone.
@MainActor
final class OrbitRightClickAnchorView: NSView {
    var entriesProvider: ((CGPoint) -> [OrbitContextMenuEntry])?
    var isBackdrop = false

    private static let anchors = NSHashTable<OrbitRightClickAnchorView>.weakObjects()
    private static var monitor: Any?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            Self.anchors.remove(self)
            return
        }
        Self.anchors.add(self)
        Self.installMonitorIfNeeded()
    }

    private static func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            handle(event) ? nil : event
        }
    }

    static func isMenuTrigger(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard isMenuTrigger(event), let window = event.window else { return false }
        let target = menuTarget(at: event.locationInWindow, in: window)
        guard let target, let entries = target.entriesProvider?(target.convert(event.locationInWindow, from: nil)), !entries.isEmpty else {
            return false
        }
        OrbitContextMenuPresenter.shared.present(
            entries: entries,
            anchorView: target,
            at: target.convert(event.locationInWindow, from: nil)
        )
        return true
    }

    static func menuTarget(at locationInWindow: NSPoint, in window: NSWindow) -> OrbitRightClickAnchorView? {
        guard !isClaimedByView(at: locationInWindow, in: window) else { return nil }
        return anchors.allObjects
            .filter { $0.window === window && $0.entriesProvider != nil && $0.contains(locationInWindow) }
            .min { $0.takesPriority(over: $1) }
    }

    private static func isClaimedByView(at locationInWindow: NSPoint, in window: NSWindow) -> Bool {
        var node = window.contentView?.superview?.hitTest(locationInWindow)
        while let current = node {
            if current is OrbitHandlesRightClick || current is NSText || current is NSTextField { return true }
            node = current.superview
        }
        return false
    }

    // Bounds first, then visibleRect: visibleRect alone let a favourite tile claim the row above it.
    func contains(_ locationInWindow: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor else { return false }
        let point = convert(locationInWindow, from: nil)
        return bounds.contains(point) && visibleRect.intersection(bounds).contains(point)
    }

    private func takesPriority(over other: OrbitRightClickAnchorView) -> Bool {
        if isBackdrop != other.isBackdrop { return !isBackdrop }
        return bounds.width * bounds.height < other.bounds.width * other.bounds.height
    }
}

private struct OrbitRightClickAnchor: NSViewRepresentable {
    var entries: (CGPoint) -> [OrbitContextMenuEntry]
    var isBackdrop: Bool

    func makeNSView(context: Context) -> OrbitRightClickAnchorView {
        let view = OrbitRightClickAnchorView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: OrbitRightClickAnchorView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: OrbitRightClickAnchorView) {
        view.entriesProvider = entries
        view.isBackdrop = isBackdrop
    }
}

// ImageRenderer paints an NSViewRepresentable as a visible placeholder, so render tests skip it via the shared flag.
private struct OrbitRightClickMenuModifier: ViewModifier {
    var entries: (CGPoint) -> [OrbitContextMenuEntry]
    var isBackdrop: Bool

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        if screenshotModeRepresentableDisabled {
            content
        } else {
            content.background(OrbitRightClickAnchor(entries: entries, isBackdrop: isBackdrop))
        }
        #else
        content.background(OrbitRightClickAnchor(entries: entries, isBackdrop: isBackdrop))
        #endif
    }
}

extension View {
    func orbitRightClickMenu(_ entries: @escaping (CGPoint) -> [OrbitContextMenuEntry]) -> some View {
        modifier(OrbitRightClickMenuModifier(entries: entries, isBackdrop: false))
    }

    func orbitRightClickMenu(_ entries: @escaping () -> [OrbitContextMenuEntry]) -> some View {
        orbitRightClickMenu { _ in entries() }
    }

    func orbitRightClickBackdropMenu(_ entries: @escaping () -> [OrbitContextMenuEntry]) -> some View {
        modifier(OrbitRightClickMenuModifier(entries: { _ in entries() }, isBackdrop: true))
    }
}
