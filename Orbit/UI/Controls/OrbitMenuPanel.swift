//  Borderless custom panel Orbit paints itself; it never uses NSMenu.popUp, runModal or a nested run loop, so tests can drive it.

import AppKit
import SwiftUI

/// Set when a menu dismisses, cleared next run-loop turn; a trigger button uses it to avoid reopening the menu.
enum OrbitMenuClickGuard {
    private static var dismissedToken: UInt64 = 0

    static func noteDismissed() {
        dismissedToken &+= 1
        let noted = dismissedToken
        DispatchQueue.main.async {
            if dismissedToken == noted { dismissedToken = 0 }
        }
    }

    static var wasDismissedThisTurn: Bool { dismissedToken != 0 }

    /// Clears the dismissal flag at once; tests use it so one test's dismissal cannot swallow the next test's click.
    static func _test_reset() {
        dismissedToken = 0
    }
}

final class OrbitMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OrbitMenuPanelController {

    private struct Level {
        let panel: OrbitMenuPanel
        let hosting: NSHostingView<OrbitMenuPanelContent>
        var entries: [OrbitContextMenuEntry]
        let selection: OrbitMenuSelectionModel
        let arrow: OrbitMenuArrow?
        let parentItemID: UUID?
    }

    private var levels: [Level] = []
    private weak var ownerWindow: NSWindow?
    weak var anchorView: NSView?
    /// Screen coordinates of the opening control; the panel's shadow covers it, so a second click misses the button.
    private var anchorScreenRect: CGRect = .zero
    private var sentinel: OrbitMenuAnchorSentinel?
    private var onDismiss: (() -> Void)?

    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isPresented: Bool { !levels.isEmpty }

    func present(
        entries: [OrbitContextMenuEntry],
        anchorRect: CGRect,
        anchorView: NSView?,
        ownerWindow: NSWindow,
        mode: OrbitMenuPlacementMode,
        preferredDirection: OrbitMenuDirection,
        showsArrow: Bool,
        onDismiss: (() -> Void)? = nil
    ) {
        dismiss()
        guard !entries.isEmpty else { return }

        self.ownerWindow = ownerWindow
        self.anchorScreenRect = anchorRect
        self.anchorView = anchorView
        self.onDismiss = onDismiss

        pushLevel(
            entries: entries,
            anchorRect: anchorRect,
            mode: mode,
            preferredDirection: preferredDirection,
            showsArrow: showsArrow,
            parentItemID: nil
        )
        guard let root = levels.first else { return }

        ownerWindow.addChildWindow(root.panel, ordered: .above)
        root.panel.makeKeyAndOrderFront(nil)

        if let anchorView {
            let sentinel = OrbitMenuAnchorSentinel(frame: .zero)
            sentinel.onWindowLost = { [weak self] in self?.dismiss() }
            anchorView.addSubview(sentinel)
            self.sentinel = sentinel
        }

        installMonitors(ownerWindow: ownerWindow, rootPanel: root.panel)
    }

    func dismiss() {
        removeMonitors()
        sentinel?.onWindowLost = nil
        sentinel?.removeFromSuperview()
        sentinel = nil
        let owner = ownerWindow
        let keyWasOurs = levels.contains { $0.panel === NSApp.keyWindow }
        for level in levels.reversed() {
            level.panel.parent?.removeChildWindow(level.panel)
            level.panel.orderOut(nil)
            level.panel.contentView = nil
            level.panel.close()
        }
        levels.removeAll()
        ownerWindow = nil
        // A .nonactivatingPanel child does not reliably hand key status back to its parent on close, and a menu action (e.g. "New Tab") would then run with no key window and lose its focus request; the closed panel can still read as key until the run loop turns.
        let key = NSApp.keyWindow
        let nothingElseIsKey = key == nil || keyWasOurs
        if nothingElseIsKey, let owner, owner.isVisible, owner.canBecomeKey {
            owner.makeKeyAndOrderFront(nil)
        }
        let callback = onDismiss
        onDismiss = nil
        OrbitMenuClickGuard.noteDismissed()
        callback?()
    }

    private func pushLevel(
        entries: [OrbitContextMenuEntry],
        anchorRect: CGRect,
        mode: OrbitMenuPlacementMode,
        preferredDirection: OrbitMenuDirection,
        showsArrow: Bool,
        parentItemID: UUID?
    ) {
        let selection = OrbitMenuSelectionModel(entries: entries)
        let depth = levels.count

        let panel = OrbitMenuPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Orbit menu")
        if let appearance = ownerWindow?.effectiveAppearance {
            panel.appearance = appearance
        }

        // Two passes: the beak's edge and offset are only known after the container is placed and clamped.
        let hosting = NSHostingView(
            rootView: makeContent(
                entries: entries,
                arrow: showsArrow ? OrbitMenuArrow(edge: .top, offset: 0) : nil,
                selection: selection,
                depth: depth
            )
        )
        let measured = hosting.fittingSize
        let containerSize = CGSize(
            width: OrbitMetrics.contextMenuWidth,
            height: max(0, measured.height - 2 * OrbitMetrics.contextMenuShadowPadding)
        )

        let screen = screenForAnchor(anchorRect)
        let geometry = OrbitMenuPlacement.geometry(
            contentSize: containerSize,
            anchor: anchorRect,
            mode: mode,
            preferredDirection: preferredDirection,
            showsArrow: showsArrow,
            visibleFrame: screen.visibleFrame
        )

        hosting.rootView = makeContent(entries: entries, arrow: geometry.arrow, selection: selection, depth: depth)

        let panelFrame = geometry.containerFrame.insetBy(
            dx: -OrbitMetrics.contextMenuShadowPadding, dy: -OrbitMetrics.contextMenuShadowPadding
        )
        panel.setFrame(panelFrame, display: false)
        hosting.frame = CGRect(origin: .zero, size: panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        levels.append(
            Level(
                panel: panel, hosting: hosting, entries: entries, selection: selection,
                arrow: geometry.arrow, parentItemID: parentItemID
            )
        )
    }

    /// Refreshes the open root menu in place; entry count and order are the caller's contract, so nothing is re-measured or re-placed.
    func updateRootEntries(_ entries: [OrbitContextMenuEntry]) {
        guard let root = levels.first, root.entries.count == entries.count else { return }
        levels[0].entries = entries
        root.selection.setEntries(entries)
        root.hosting.rootView = makeContent(
            entries: entries, arrow: root.arrow, selection: root.selection, depth: 0
        )
    }

    private func makeContent(
        entries: [OrbitContextMenuEntry], arrow: OrbitMenuArrow?, selection: OrbitMenuSelectionModel, depth: Int
    ) -> OrbitMenuPanelContent {
        OrbitMenuPanelContent(
            entries: entries,
            arrow: arrow,
            selection: selection,
            onSelect: { [weak self] in self?.dismiss() },
            onRowActivate: { [weak self] item, frame in
                self?.rowDidActivate(item, frameInMenu: frame, depth: depth)
            }
        )
    }

    private func screenForAnchor(_ anchor: CGRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
            ?? ownerWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // Hopped off the current turn because this fires inside a SwiftUI update, where opening or closing a window is re-entrant; the selection is re-checked on arrival.
    private func rowDidActivate(_ item: OrbitContextMenuItem, frameInMenu: CGRect, depth: Int) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, depth < self.levels.count else { return }
                guard self.levels[depth].selection.selectedItemID == item.id else { return }
                self.collapse(toDepth: depth + 1)
                guard item.hasSubmenu, let submenu = item.submenu else { return }
                self.openSubmenu(for: item, entries: submenu, frameInMenu: frameInMenu, depth: depth)
            }
        }
    }

    private func openSubmenu(
        for item: OrbitContextMenuItem, entries: [OrbitContextMenuEntry], frameInMenu: CGRect, depth: Int
    ) {
        guard depth < levels.count else { return }
        guard levels.last?.parentItemID != item.id else { return }
        let parent = levels[depth]
        let rowRect = screenRect(ofRowFrame: frameInMenu, in: parent)

        pushLevel(
            entries: entries,
            anchorRect: rowRect,
            mode: .submenu,
            preferredDirection: .down,
            showsArrow: false,
            parentItemID: item.id
        )
        guard let child = levels.last else { return }
        parent.panel.addChildWindow(child.panel, ordered: .above)
        child.panel.orderFront(nil)
    }

    /// `frameInMenu` is SwiftUI-space (origin top-left, y down) inside the hosted container, which is inset from the panel by the shadow padding.
    private func screenRect(ofRowFrame frameInMenu: CGRect, in level: Level) -> CGRect {
        let container = level.panel.frame.insetBy(
            dx: OrbitMetrics.contextMenuShadowPadding, dy: OrbitMetrics.contextMenuShadowPadding
        )
        return CGRect(
            x: container.minX + frameInMenu.minX,
            y: container.maxY - frameInMenu.maxY,
            width: frameInMenu.width,
            height: frameInMenu.height
        )
    }

    private func collapse(toDepth depth: Int) {
        while levels.count > depth, let level = levels.popLast() {
            level.panel.parent?.removeChildWindow(level.panel)
            level.panel.orderOut(nil)
            level.panel.contentView = nil
            level.panel.close()
        }
    }

    /// `true` when the menu consumed the key; it inspects one already-delivered event and never runs a nested event loop.
    @discardableResult
    func handleKey(code: UInt16) -> Bool {
        guard let action = OrbitMenuKeyAction.from(keyCode: code), let level = levels.last else { return false }
        switch action {
        case .moveDown:
            level.selection.move(by: 1)
        case .moveUp:
            level.selection.move(by: -1)
        case .moveToFirst:
            level.selection.selectedItemID = level.selection.navigableItems.first?.id
        case .moveToLast:
            level.selection.selectedItemID = level.selection.navigableItems.last?.id
        case .openSubmenu:
            // Selecting an item with a submenu already opened it via rowDidActivate, so this only moves focus into it.
            guard levels.count > 1, let deepest = levels.last else { return true }
            deepest.selection.selectedItemID = deepest.selection.navigableItems.first?.id
        case .closeSubmenu:
            guard levels.count > 1 else { return true }
            collapse(toDepth: levels.count - 1)
        case .activate:
            guard let item = level.selection.selectedItem, item.isEnabled, !item.hasSubmenu else { return true }
            item.action?()
            dismiss()
        case .dismiss:
            if levels.count > 1 {
                collapse(toDepth: levels.count - 1)
            } else {
                dismiss()
            }
        }
        return true
    }

    private func installMonitors(ownerWindow: NSWindow, rootPanel: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresented else { return event }
            return self.handleKey(code: event.keyCode) ? nil : event
        }
        // Local rather than a .transient popover monitor: the event is returned unmodified so the click still reaches its target.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.clickClosesAnchor(event) {
                self.dismiss()
                return nil
            }
            self.dismissIfOutside(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: rootPanel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfKeyWentElsewhere() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: ownerWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    private func dismissIfKeyWentElsewhere() {
        guard isPresented else { return }
        // A submenu panel of our own taking key is not "somewhere else".
        if let key = NSApp.keyWindow, levels.contains(where: { $0.panel === key }) { return }
        dismiss()
    }

    private func dismissIfOutside(_ event: NSEvent) {
        guard isPresented else { return }
        guard let window = event.window else {
            dismiss()
            return
        }
        guard !levels.contains(where: { $0.panel === window }) else { return }
        dismiss()
    }

    private func clickClosesAnchor(_ event: NSEvent) -> Bool {
        guard isPresented, anchorScreenRect.width > 1, anchorScreenRect.height > 1 else { return false }
        let screenPoint: NSPoint
        if let window = event.window {
            screenPoint = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        return anchorScreenRect.insetBy(dx: -4, dy: -4).contains(screenPoint)
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localMouseMonitor = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

struct OrbitMenuPanelContent: View {
    var entries: [OrbitContextMenuEntry]
    var arrow: OrbitMenuArrow?
    var selection: OrbitMenuSelectionModel
    var onSelect: () -> Void
    var onRowActivate: (OrbitContextMenuItem, CGRect) -> Void

    var body: some View {
        OrbitContextMenuView(
            entries: entries,
            onSelect: onSelect,
            arrow: arrow,
            selection: selection,
            onRowActivate: onRowActivate
        )
        .compositingGroup()
        .shadow(
            color: .black.opacity(OrbitMetrics.contextMenuShadowOpacity),
            radius: OrbitMetrics.contextMenuShadowRadius,
            y: OrbitMetrics.contextMenuShadowYOffset
        )
        .padding(OrbitMetrics.contextMenuShadowPadding)
    }
}

/// Zero-sized, non-hit-testable probe reporting when its host view leaves the window, since `NSView.window` isn't KVO-observable.
final class OrbitMenuAnchorSentinel: NSView {
    var onWindowLost: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, let onWindowLost else { return }
        self.onWindowLost = nil
        onWindowLost()
    }
}
