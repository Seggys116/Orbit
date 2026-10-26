import AppKit
import SwiftUI

enum CommandBarAnchorID: Hashable, Sendable {
    case contentRegion
    case pane(TabID)
}

struct CommandBarAnchorsKey: PreferenceKey {
    static let defaultValue: [CommandBarAnchorID: CGRect] = [:]

    static func reduce(value: inout [CommandBarAnchorID: CGRect], nextValue: () -> [CommandBarAnchorID: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// The Command Bar panel's own frame, in CommandBarOverlayLayout.coordinateSpaceName. The scrim's AppKit click catcher needs it to stay out of the panel's way: a catcher that claimed the whole overlay would dismiss the bar on every click inside it.
struct CommandBarPanelFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

extension View {
    func commandBarAnchor(_ id: CommandBarAnchorID) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CommandBarAnchorsKey.self,
                    value: [id: proxy.frame(in: .named(OrbitWindowCoordinateSpace.name))]
                )
            }
            .allowsHitTesting(false)
        )
    }
}

enum CommandBarPlacement {
    static let widthFraction: CGFloat = 0.67
    static let minimumWidth: CGFloat = 320

    static func width(forAvailableWidth availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return OrbitMetrics.commandBarWidth }
        let floored = max(availableWidth * widthFraction, min(minimumWidth, availableWidth))
        return min(floored, OrbitMetrics.commandBarWidth)
    }

    static func targetRect(
        mode: CommandBarMode,
        activeTabID: TabID?,
        anchors: [CommandBarAnchorID: CGRect]
    ) -> CGRect? {
        if let target = mode.targetTabID, let pane = usable(anchors[.pane(target)]) {
            return pane
        }
        if case .editURL = mode, let activeTabID, let pane = usable(anchors[.pane(activeTabID)]) {
            return pane
        }
        return usable(anchors[.contentRegion])
    }

    // .zero is a real value a mounted-but-not-yet-laid-out view publishes; it must not be treated as usable.
    private static func usable(_ rect: CGRect?) -> CGRect? {
        guard let rect,
              rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width > 0, rect.height > 0
        else { return nil }
        return rect
    }
}

struct CommandBarOverlayLayout<Content: View>: View {
    static var coordinateSpaceName: String { "OrbitCommandBarOverlay" }

    var targetRect: CGRect?
    var scrimOpacity: Double = 0.18
    /// Leading width that stays clickable. The sidebar lives there; a scrim
    /// across it turned a tab click into "dismiss the new-tab bar" and left
    /// the blank page on screen.
    var passthroughLeadingWidth: CGFloat = 0
    /// SwiftUI-only tap; the main window uses CommandBarScrimClickCatcher instead.
    var onScrimTap: (() -> Void)?
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let region = resolvedRegion(in: proxy.size)
            ZStack {
                if let onScrimTap {
                    Color.clear
                        .contentShape(CommandBarScrimShape(leadingInset: passthroughLeadingWidth))
                        .onTapGesture(perform: onScrimTap)
                }

                dim(over: region, in: proxy.size)

                content(CommandBarPlacement.width(forAvailableWidth: region.width))
                    .fixedSize()
                    .background(
                        GeometryReader { panel in
                            Color.clear.preference(
                                key: CommandBarPanelFrameKey.self,
                                value: panel.frame(in: .named(Self.coordinateSpaceName))
                            )
                        }
                        .allowsHitTesting(false)
                    )
                    .position(x: region.midX, y: region.midY)
            }
            .coordinateSpace(.named(Self.coordinateSpaceName))
        }
        .contentShape(CommandBarScrimShape(leadingInset: passthroughLeadingWidth))
    }

    private func dimFlushEdges(for region: CGRect, in containerSize: CGSize) -> Edge.Set {
        guard targetRect != nil else { return .all }
        guard BorderlessSettings.shared.isEnabled else { return [] }
        var edges: Edge.Set = []
        if region.minX <= 0.5 { edges.insert(.leading) }
        if region.minY <= 0.5 { edges.insert(.top) }
        if region.maxX >= containerSize.width - 0.5 { edges.insert(.trailing) }
        if region.maxY >= containerSize.height - 0.5 { edges.insert(.bottom) }
        return edges
    }

    private func dim(over region: CGRect, in containerSize: CGSize) -> some View {
        UnevenRoundedRectangle(
            cornerRadii: BorderlessSettings.cardCornerRadii(flushEdges: dimFlushEdges(for: region, in: containerSize)),
            style: .continuous
        )
            .fill(Color.black.opacity(scrimOpacity))
            .frame(width: region.width, height: region.height)
            .position(x: region.midX, y: region.midY)
            .allowsHitTesting(false)
    }

    private func resolvedRegion(in containerSize: CGSize) -> CGRect {
        guard let targetRect, targetRect.width > 0, targetRect.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        return targetRect
    }
}

/// Clicks on the page dismiss the bar. Clicks on the sidebar fall through
/// to the tab rows, which both select the tab and take the bar down.
struct CommandBarScrimClickCatcher: NSViewRepresentable {
    var leadingInset: CGFloat
    /// The panel's frame in this view's own top-left-origin space. Nil until the panel has laid out; the catcher claims nothing until then.
    var excludedRect: CGRect?
    var onTap: () -> Void

    func makeNSView(context: Context) -> CommandBarScrimClickView {
        let view = CommandBarScrimClickView()
        view.leadingInset = leadingInset
        view.excludedRect = excludedRect
        view.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: CommandBarScrimClickView, context: Context) {
        nsView.leadingInset = leadingInset
        nsView.excludedRect = excludedRect
        nsView.onTap = onTap
    }
}

// OrbitClickCatching, so OrbitWindowContentView's click recovery can find it: over the page, NSHostingView.hitTest resolves to the hosting view itself rather than to an NSView representable beneath the SwiftUI overlay, and recovery is the only path that then reaches this view.
// Flipped so its bounds share SwiftUI's top-left origin with excludedRect.
final class CommandBarScrimClickView: NSView, OrbitClickCatching {
    var leadingInset: CGFloat = 0
    var excludedRect: CGRect?
    var onTap: () -> Void = {}

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard Self.claims(local, in: bounds, leadingInset: leadingInset, excluding: excludedRect) else { return nil }
        return self
    }

    static func claims(_ point: CGPoint, in bounds: CGRect, leadingInset: CGFloat, excluding panel: CGRect?) -> Bool {
        guard bounds.contains(point), point.x >= leadingInset else { return false }
        // No panel frame yet means the layout has not run; claiming everything then would swallow clicks meant for the bar.
        guard let panel, !panel.isNull, !panel.isEmpty else { return false }
        return !panel.contains(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onTap()
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// The scrim covers the page and leaves the sidebar strip alone.
struct CommandBarScrimShape: Shape {
    var leadingInset: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset = min(max(leadingInset, 0), rect.width)
        return Path(CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset, height: rect.height))
    }
}

struct CommandBarOverlay: View {
    @Environment(AppEnvironment.self) private var env

    @State private var panelFrame: CGRect?

    var anchors: [CommandBarAnchorID: CGRect] = [:]
    var passthroughLeadingWidth: CGFloat = 0

    #if DEBUG
    // ImageRenderer paints an NSViewRepresentable as an opaque block over the whole overlay.
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    private var showsScrimClickCatcher: Bool {
        #if DEBUG
        !screenshotModeRepresentableDisabled
        #else
        true
        #endif
    }

    var body: some View {
        CommandBarOverlayLayout(
            targetRect: CommandBarPlacement.targetRect(
                mode: env.commandBarMode,
                activeTabID: env.activeTabID,
                anchors: anchors
            ),
            passthroughLeadingWidth: passthroughLeadingWidth,
            // Both paths dismiss, because AppKit resolves a click over the page two different ways. When the walk lands on the hosting view itself (the normal case, SwiftUI having claimed the dimmed region) only this tap sees the click; the AppKit catcher below is for the walks that resolve to it directly. dismissCommandBar() is idempotent, so a click that somehow reached both is harmless.
            onScrimTap: { env.dismissCommandBar() }
        ) { width in
            CommandBarView(width: width, seededFrom: env)
        }
        .onPreferenceChange(CommandBarPanelFrameKey.self) { frame in
            panelFrame = frame.isNull ? nil : frame
        }
        // ImageRenderer fills an NSViewRepresentable with an opaque placeholder the size of
        // the overlay. The live window still needs the catcher; a flattened render must not include it.
        .background {
            if showsScrimClickCatcher {
                CommandBarScrimClickCatcher(leadingInset: passthroughLeadingWidth, excludedRect: panelFrame, onTap: { env.dismissCommandBar() })
            }
        }
        .transition(.opacity.animation(.easeOut(duration: 0.13)))
        .zIndex(10)
    }
}
