import AppKit
import SwiftUI

enum OrbitSplitPaneMetrics {
    static let interPaneGap: CGFloat = OrbitMetrics.cardInset

    // Split in half across the two facing edges: paneGap * 2 + splitDividerThickness == interPaneGap. A flat per-edge number instead would double the visible seam width.
    static let paneGap: CGFloat = max(0, (interPaneGap - OrbitMetrics.splitDividerThickness) / 2)
}

struct SplitViewContainer: View {
    @Environment(AppEnvironment.self) private var env
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
        if let group = env.splitGroup(for: rootTabID) {
            let orientation = group.axis
            GeometryReader { proxy in
                let total = orientation == .horizontal ? proxy.size.width : proxy.size.height
                Group {
                    if orientation == .horizontal {
                        HStack(spacing: 0) { paneItems(group: group, total: total, orientation: orientation) }
                    } else {
                        VStack(spacing: 0) { paneItems(group: group, total: total, orientation: orientation) }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func paneItems(group: SplitGroup, total: CGFloat, orientation: SplitOrientation) -> some View {
        let dividerCount = max(0, group.tabIDs.count - 1)
        let available = max(0, total - CGFloat(dividerCount) * OrbitMetrics.splitDividerThickness)
        let lastIndex = group.tabIDs.count - 1
        ForEach(Array(group.tabIDs.enumerated()), id: \.element) { index, tabID in
            if let tab = env.tab(tabID) {
                let length = available * CGFloat(group.fractions.indices.contains(index) ? group.fractions[index] : 1.0 / Double(group.tabIDs.count))
                // Padding applied before .frame(width:), not after: SwiftUI's .padding() adds to a view's ideal size, so padding an already-fixed view would overflow the total width instead of shrinking the inner content.
                SingleTabContentView(tab: tab, isFocusedPane: env.focusedSplitPaneIndex == index)
                    .padding(.leading, (orientation == .horizontal && index > 0) ? OrbitSplitPaneMetrics.paneGap : 0)
                    .padding(.trailing, (orientation == .horizontal && index < lastIndex) ? OrbitSplitPaneMetrics.paneGap : 0)
                    .padding(.top, (orientation == .vertical && index > 0) ? OrbitSplitPaneMetrics.paneGap : 0)
                    .padding(.bottom, (orientation == .vertical && index < lastIndex) ? OrbitSplitPaneMetrics.paneGap : 0)
                    .frame(
                        width: orientation == .horizontal ? length : nil,
                        height: orientation == .vertical ? length : nil
                    )
                    // A plain .onTapGesture here would win the mouse-down/up pair before AppKit routes it to the embedded engine view, swallowing the first click on any page control. SplitPaneFocusObserver observes instead of claiming the click.
                    .background {
                        if mountsFocusObserver {
                            SplitPaneFocusObserver(onClick: { env.focusSplitPane(index: index) })
                        }
                    }
            }
            if index < lastIndex {
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
