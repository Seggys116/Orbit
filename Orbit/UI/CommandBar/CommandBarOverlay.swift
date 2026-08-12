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
    var onScrimTap: () -> Void = {}
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let region = resolvedRegion(in: proxy.size)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onScrimTap)
                    .ignoresSafeArea()

                dim(over: region)

                content(CommandBarPlacement.width(forAvailableWidth: region.width))
                    .position(x: region.midX, y: region.midY)
            }
        }
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

struct CommandBarOverlay: View {
    @Environment(AppEnvironment.self) private var env

    var anchors: [CommandBarAnchorID: CGRect] = [:]

    var body: some View {
        CommandBarOverlayLayout(
            targetRect: CommandBarPlacement.targetRect(
                mode: env.commandBarMode,
                activeTabID: env.activeTabID,
                anchors: anchors
            ),
            onScrimTap: { env.dismissCommandBar() }
        ) { width in
            CommandBarView(width: width, seededFrom: env)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.13)))
        .zIndex(10)
    }
}
