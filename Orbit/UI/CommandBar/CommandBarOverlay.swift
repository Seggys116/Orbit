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

                dim(over: region)

                content(CommandBarPlacement.width(forAvailableWidth: region.width))
                    .fixedSize()
                    .position(x: region.midX, y: region.midY)
            }
        }
        .contentShape(CommandBarScrimShape(leadingInset: passthroughLeadingWidth))
    }

    private func dim(over region: CGRect) -> some View {
        RoundedRectangle(cornerRadius: targetRect == nil ? 0 : OrbitMetrics.cardCornerRadius, style: .continuous)
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
    var onTap: () -> Void

    func makeNSView(context: Context) -> CommandBarScrimClickView {
        let view = CommandBarScrimClickView()
        view.leadingInset = leadingInset
        view.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: CommandBarScrimClickView, context: Context) {
        nsView.leadingInset = leadingInset
        nsView.onTap = onTap
    }
}

final class CommandBarScrimClickView: NSView {
    var leadingInset: CGFloat = 0
    var onTap: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x >= leadingInset else { return nil }
        return self
    }

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
            passthroughLeadingWidth: passthroughLeadingWidth
        ) { width in
            CommandBarView(width: width, seededFrom: env)
        }
        // ImageRenderer fills an NSViewRepresentable with an opaque placeholder the size of
        // the overlay. The live window still needs the catcher; a flattened render must not include it.
        .background {
            if showsScrimClickCatcher {
                CommandBarScrimClickCatcher(leadingInset: passthroughLeadingWidth, onTap: { env.dismissCommandBar() })
            }
        }
        .transition(.opacity.animation(.easeOut(duration: 0.13)))
        .zIndex(10)
    }
}
