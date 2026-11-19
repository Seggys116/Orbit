import AppKit
import SwiftUI

enum OrbitSplitPaneMetrics {
    static let interPaneGap: CGFloat = OrbitMetrics.cardInset

    // Split in half across the two facing edges: paneGap * 2 + splitDividerThickness == interPaneGap. A flat per-edge number instead would double the visible seam width.
    static let paneGap: CGFloat = max(0, (interPaneGap - OrbitMetrics.splitDividerThickness) / 2)
}

/// Lays out every tab on screen, a lone page being a layout of one pane. Entering or leaving a split therefore
/// adds or removes a pane beside the page already there, instead of replacing the view the page lives in: the
/// page's host is never rebuilt, so nothing re-embeds, nothing shows a frozen frame, and the change animates.
///
/// Panes are keyed by position, not by tab. A pane that shows another page swaps it inside the same host, which is
/// how a recently used page comes back without being re-embedded.
struct SplitViewContainer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var rootTabID: TabID

    #if DEBUG
    // ImageRenderer cannot flatten a representable and paints a corruption artifact instead; the artifact would land precisely in the seam a render test measures, so the view must be absent from the render entirely, not merely disarmed.
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    private var mountsFocusObserver: Bool {
        #if DEBUG
        !screenshotModeRepresentableDisabled
        #else
        true
        #endif
    }

    var body: some View {
        let group = env.splitGroup(for: rootTabID)
        let tabIDs = group?.tabIDs ?? [rootTabID]
        let orientation = group?.axis ?? .horizontal
        GeometryReader { proxy in
            let total = orientation == .horizontal ? proxy.size.width : proxy.size.height
            Group {
                if orientation == .horizontal {
                    HStack(spacing: 0) { paneItems(group: group, tabIDs: tabIDs, total: total, orientation: orientation) }
                } else {
                    VStack(spacing: 0) { paneItems(group: group, tabIDs: tabIDs, total: total, orientation: orientation) }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Only a pane arriving animates, and by sliding in. Resizing a live page every frame makes WebKit lay it out every frame and SwiftUI re-allocate the pane's surfaces, which dropped frames.
        .animation(layoutAnimation, value: tabIDs.count)
    }

    private var layoutAnimation: Animation {
        reduceMotion ? OrbitMotion.fade : OrbitMotion.standard
    }

    /// A pane arriving slides in from its own edge. One leaving is simply gone, since its space is taken by the neighbour at once and a fade there would play over the page that replaced it.
    private func paneTransition(index: Int, orientation: SplitOrientation) -> AnyTransition {
        if reduceMotion { return .asymmetric(insertion: .opacity, removal: .identity) }
        let edge: Edge = orientation == .horizontal ? (index == 0 ? .leading : .trailing) : (index == 0 ? .top : .bottom)
        return .asymmetric(insertion: .move(edge: edge).combined(with: .opacity), removal: .identity)
    }

    @ViewBuilder
    private func paneItems(group: SplitGroup?, tabIDs: [TabID], total: CGFloat, orientation: SplitOrientation) -> some View {
        let dividerCount = max(0, tabIDs.count - 1)
        let available = max(0, total - CGFloat(dividerCount) * OrbitMetrics.splitDividerThickness)
        let lastIndex = tabIDs.count - 1
        ForEach(Array(tabIDs.enumerated()), id: \.offset) { index, tabID in
            if let tab = env.tab(tabID) {
                let fraction = group.map { $0.fractions.indices.contains(index) ? $0.fractions[index] : 1.0 / Double(tabIDs.count) } ?? 1.0
                let length = available * CGFloat(fraction)
                // Padding applied before .frame(width:), not after: SwiftUI's .padding() adds to a view's ideal size, so padding an already-fixed view would overflow the total width instead of shrinking the inner content.
                SingleTabContentView(tab: tab, isFocusedPane: group == nil || env.focusedSplitPaneIndex == index)
                    .transformEnvironment(\.paneCardFlushEdges) { edges in
                        let innerLeading = orientation == .horizontal && index > 0
                        let innerTrailing = orientation == .horizontal && index < lastIndex
                        let innerTop = orientation == .vertical && index > 0
                        let innerBottom = orientation == .vertical && index < lastIndex
                        if innerLeading { edges.remove(.leading) }
                        if innerTrailing { edges.remove(.trailing) }
                        if innerTop { edges.remove(.top) }
                        if innerBottom { edges.remove(.bottom) }
                    }
                    .padding(.leading, (orientation == .horizontal && index > 0) ? OrbitSplitPaneMetrics.paneGap : 0)
                    .padding(.trailing, (orientation == .horizontal && index < lastIndex) ? OrbitSplitPaneMetrics.paneGap : 0)
                    .padding(.top, (orientation == .vertical && index > 0) ? OrbitSplitPaneMetrics.paneGap : 0)
                    .padding(.bottom, (orientation == .vertical && index < lastIndex) ? OrbitSplitPaneMetrics.paneGap : 0)
                    .frame(
                        width: orientation == .horizontal ? length : nil,
                        height: orientation == .vertical ? length : nil
                    )
                    // The page already there takes its new size in one step. Only the arriving pane's transition animates.
                    .animation(nil, value: tabIDs.count)
                    // A plain .onTapGesture here would win the mouse-down/up pair before AppKit routes it to the embedded engine view, swallowing the first click on any page control. SplitPaneFocusObserver observes instead of claiming the click.
                    .background {
                        if mountsFocusObserver, group != nil {
                            SplitPaneFocusObserver(onClick: { env.focusSplitPane(index: index) })
                        }
                    }
                    .transition(paneTransition(index: index, orientation: orientation))
            }
            if index < lastIndex, let group {
                SplitDividerView(group: group, dividerIndex: index, orientation: orientation, totalLength: available)
            }
        }
    }
}

struct SplitDividerView: View {
    @Environment(AppEnvironment.self) private var env
    var group: SplitGroup
    var dividerIndex: Int
    var orientation: SplitOrientation
    var totalLength: CGFloat

    @State private var startFractions: [Double]?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.white.opacity(0.16) : Color.clear)
            .frame(
                width: orientation == .horizontal ? OrbitMetrics.splitDividerThickness : nil,
                height: orientation == .vertical ? OrbitMetrics.splitDividerThickness : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    (orientation == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if startFractions == nil { startFractions = group.fractions }
                        guard let startFractions, totalLength > 0 else { return }
                        let delta = orientation == .horizontal ? value.translation.width : value.translation.height
                        let deltaFraction = Double(delta / totalLength)
                        var fractions = startFractions
                        guard fractions.indices.contains(dividerIndex + 1) else { return }
                        fractions[dividerIndex] += deltaFraction
                        fractions[dividerIndex + 1] -= deltaFraction
                        env.resizeSplit(group.id, fractions: fractions)
                    }
                    .onEnded { _ in startFractions = nil }
            )
    }
}

private struct SplitPaneFocusObserver: NSViewRepresentable {
    var onClick: () -> Void

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onClick = onClick
        #if DEBUG
        nsView.isArmed = !screenshotModeRepresentableDisabled
        #endif
    }

    final class ObserverView: NSView {
        var onClick: (() -> Void)?
        #if DEBUG
        var isArmed = true
        #endif
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return event }
                #if DEBUG
                guard self.isArmed else { return event }
                #endif
                guard let window = self.window, event.window === window else { return event }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(locationInView) {
                    self.onClick?()
                }
                // Never consumed: returns the same event so AppKit's normal dispatch continues as if this monitor were not installed.
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeMonitor() }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
