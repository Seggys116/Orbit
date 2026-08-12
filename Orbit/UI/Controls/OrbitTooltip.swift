import AppKit
import SwiftUI

final class OrbitTooltipBackingView: NSView, NSViewToolTipOwner {

    // addToolTip(_:owner:userData:), not the inherited toolTip property: when the
    // NSHostingView IS the contentView, AppKit's own auto-derived rect resolves empty.
    private(set) var tooltipText: String?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    func apply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tooltipText = trimmed.isEmpty ? nil : trimmed
        refreshTooltipRect()
    }

    override func layout() {
        super.layout()
        refreshTooltipRect()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTooltipRect()
    }

    private func refreshTooltipRect() {
        removeAllToolTips()
        guard tooltipText != nil, !bounds.isEmpty else { return }
        addToolTip(bounds, owner: self, userData: nil)
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        tooltipText ?? ""
    }
}

struct OrbitTooltipBacking: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> OrbitTooltipBackingView {
        let view = OrbitTooltipBackingView()
        view.apply(text)
        return view
    }

    func updateNSView(_ nsView: OrbitTooltipBackingView, context: Context) {
        nsView.apply(text)
    }
}

extension View {
    // help(...) alone shows nothing here; backs it with a real AppKit tooltip rect.
    func orbitTooltip(_ text: String) -> some View {
        modifier(OrbitTooltipModifier(text: text))
    }
}

// ImageRenderer cannot flatten OrbitTooltipBacking (an invisible NSViewRepresentable) and paints a
// visible placeholder in its place instead, so screenshot/render tests skip it via the same flag
// OrbitHoverHighlight already uses for OrbitHoverTracker.
private struct OrbitTooltipModifier: ViewModifier {
    var text: String

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        if screenshotModeRepresentableDisabled {
            content.modifier(SwiftUIHelpModifier(text: text))
        } else {
            content.background(OrbitTooltipBacking(text: text)).modifier(SwiftUIHelpModifier(text: text))
        }
        #else
        content.background(OrbitTooltipBacking(text: text)).modifier(SwiftUIHelpModifier(text: text))
        #endif
    }
}

// Kept as a modifier so a rename sweep across `help(` sites can't rewrite this into orbitTooltip(_:) and recurse.
private struct SwiftUIHelpModifier: ViewModifier {
    var text: String

    func body(content: Content) -> some View {
        content.help(text)
    }
}
