//  A sibling of ToolbarView.addressField, not nested inside it: addressField's own click catcher overlays its entire label frame, so a smaller click target nested inside it would never receive its own click.

import AppKit
import SwiftUI

// MARK: - Pure glyph-state resolution

enum ToolbarAddressCopyGlyph: Equatable {
    case resting(symbol: String, isWarning: Bool)
    case none
    case hoverCopy
    case copied

    static func current(security: SecurityLevel, isHovering: Bool, isCopied: Bool) -> ToolbarAddressCopyGlyph {
        if isCopied { return .copied }
        if isHovering { return .hoverCopy }
        if let symbol = ToolbarSecurityGlyph.symbol(for: security) {
            return .resting(symbol: symbol, isWarning: ToolbarSecurityGlyph.isWarning(security))
        }
        return .none
    }
}

// MARK: - AppKit click + hover surface

final class ToolbarAddressCopyClickCatchingNSView: NSView, OrbitClickCatching {
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private(set) var isHovering = false
    private var monitor: Any?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // point arrives in the superview's coordinate space, not this view's own bounds.
    override func hitTest(_ point: NSPoint) -> NSView? {
        orbitContainsHitTestPoint(point) ? self : nil
    }

    // Under .fullSizeContentView, a view over the titlebar band that answers true here has its mouseDown consumed by AppKit for a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detachMonitor()
        guard let window else { return }
        // acceptsMouseMovedEvents is off by default on a fresh NSWindow; without it AppKit never generates .mouseMoved events at all.
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { detachMonitor() }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
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
        let inside = bounds.contains(point)
        guard inside != isHovering else { return }
        isHovering = inside
        onHoverChanged?(inside)
    }
}

private struct ToolbarAddressCopyClickCatcher: NSViewRepresentable {
    var onClick: () -> Void
    var onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ToolbarAddressCopyClickCatchingNSView {
        let view = ToolbarAddressCopyClickCatchingNSView()
        view.onClick = onClick
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: ToolbarAddressCopyClickCatchingNSView, context: Context) {
        nsView.onClick = onClick
        nsView.onHoverChanged = onHoverChanged
    }
}

// MARK: - The SwiftUI control

struct ToolbarAddressCopyControl: View {
    var security: SecurityLevel
    var url: URL
    var foreground: Color
    var pasteboard: NSPasteboard = .general

    @State private var isHovering = false
    @State private var isCopied = false
    @State private var copyGeneration = 0

    private var glyph: ToolbarAddressCopyGlyph {
        .current(security: security, isHovering: isHovering, isCopied: isCopied)
    }

    // Deliberately not glyph != .none: glyph folds in isHovering, which the click catcher reports, and the catcher's own size is what this predicate decides — reading glyph here would size the catcher from the catcher.
    private var drawsGlyph: Bool {
        ToolbarSecurityGlyph.symbol(for: security) != nil
    }

    var body: some View {
        glyphView
            .frame(
                width: drawsGlyph ? OrbitToolbarMetrics.addressCopyPillSize : nil,
                height: drawsGlyph ? OrbitToolbarMetrics.addressCopyPillSize : nil
            )
            .contentShape(Rectangle())
            .overlay(
                ToolbarAddressCopyClickCatcher(
                    onClick: handleClick,
                    onHoverChanged: { isHovering = $0 }
                )
            )
            .animation(OrbitMotion.quick, value: glyph)
            .task(id: copyGeneration) {
                guard copyGeneration > 0 else { return }
                try? await Task.sleep(for: .seconds(OrbitToolbarMetrics.addressCopyCheckmarkLingerDuration))
                guard !Task.isCancelled else { return }
                isCopied = false
            }
            .orbitTooltip(helpText)
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .resting(let symbol, let isWarning):
            Image(systemName: symbol)
                .font(.system(size: OrbitToolbarMetrics.securityGlyphSize))
                .foregroundStyle(isWarning ? ToolbarSecurityGlyph.warningColor(for: security) : foreground.opacity(0.6))
        case .none:
            EmptyView()
        case .hoverCopy:
            Image(systemName: "doc.on.doc")
                .font(.system(size: OrbitToolbarMetrics.securityGlyphSize))
                .foregroundStyle(foreground.opacity(0.85))
        case .copied:
            Image(systemName: "checkmark")
                .font(.system(size: OrbitToolbarMetrics.securityGlyphSize, weight: .semibold))
                .foregroundStyle(foreground.opacity(0.85))
        }
    }

    private var helpText: String {
        switch glyph {
        case .copied: "Copied"
        default: "Copy URL"
        }
    }

    // No focusPaneIfNeeded() here: this reads url, this pane's own parameter, not env state keyed by activeTabID, so there is nothing that could act on the wrong split pane.
    private func handleClick() {
        // Must match ToolbarContextMenuAction.copyURL's raw url.absoluteString, not Cmd-Shift-C's tracker-stripped copy, so hover-click and right-click never put different strings on the pasteboard for the same page.
        ToolbarContextMenuAction.copyURL(url, to: pasteboard)
        isCopied = true
        copyGeneration += 1
    }
}
