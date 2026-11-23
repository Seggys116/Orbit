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

    /// Which slot of the layout each page sits in. A page keeps its slot, and so its host, when panes arrive before it or leave ahead of it.
    @State private var slots = SplitPaneSlots()

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
            // Hold Command and drag a pane to move it beside another. Absent in screenshot mode with the other AppKit observers.
            .background {
                if mountsFocusObserver, let group, group.tabIDs.count > 1 {
                    PaneRearrangeObserver(
                        frames: Self.paneFrames(group: group, size: proxy.size),
                        axis: orientation,
                        onTarget: { target, edge in
                            guard let target, let edge else { env.activeSplitDropZone = nil; return }
                            env.activeSplitDropZone = SplitDropZone(edge: edge, targetTabID: group.tabIDs[target])
                        },
                        onDrop: { source, target, edge in
                            env.activeSplitDropZone = nil
                            withAnimation(layoutAnimation) {
                                env.rearrangePane(group.tabIDs[source], onto: group.tabIDs[target], edge: edge)
                            }
                        },
                        onEnd: { env.activeSplitDropZone = nil }
                    )
                }
            }
        }
        // Only a pane arriving animates, and by sliding in. Resizing a live page every frame makes WebKit lay it out every frame and SwiftUI re-allocate the pane's surfaces, which dropped frames.
        .animation(layoutAnimation, value: tabIDs.count)
    }

    /// The sidebar slid over the page is not part of the page: a press on a row in it must not pick the pane beneath. Picking it moves focus into the page, which sends the sidebar away before the row's click finishes, so the tab the person chose is never selected.
    static func floatingSidebarCovers(x: CGFloat, windowWidth: CGFloat, sidebarWidth: CGFloat, isRevealed: Bool) -> Bool {
        guard isRevealed else { return false }
        return x <= OrbitHoverPanelMetrics.edgeInset + OrbitHoverPanelMetrics.overlayWidth(forSidebarWidth: sidebarWidth, availableWidth: windowWidth)
    }

    /// Each pane's rectangle in the container, top-left origin: the same arithmetic the layout below uses.
    static func paneFrames(group: SplitGroup, size: CGSize) -> [CGRect] {
        let horizontal = group.axis == .horizontal
        let total = horizontal ? size.width : size.height
        let count = group.tabIDs.count
        let available = max(0, total - CGFloat(max(0, count - 1)) * OrbitMetrics.splitDividerThickness)
        var frames: [CGRect] = []
        var cursor: CGFloat = 0
        for index in 0..<count {
            let fraction = group.fractions.indices.contains(index) ? group.fractions[index] : 1.0 / Double(count)
            let length = available * CGFloat(fraction)
            frames.append(horizontal
                ? CGRect(x: cursor, y: 0, width: length, height: size.height)
                : CGRect(x: 0, y: cursor, width: size.width, height: length))
            cursor += length + OrbitMetrics.splitDividerThickness
        }
        return frames
    }

    private var layoutAnimation: Animation {
        reduceMotion ? OrbitMotion.fade : OrbitMotion.standard
    }

    /// What a pane is doing while a pane arrives in the split. The layout is already final. Every pane is drawn where it was and eases to where it lands: the panes squeeze toward their new places, and the arriving pane fades up in the room they make, so a drop on the left, on the top, or between two panes of a split all read as the page being pushed aside from the side it was dropped on. What is drawn wider than its place overflows it instead of moving its neighbours. One leaving is simply gone, since its space is taken by the neighbour at once and a fade there would play over the page that replaced it.
    struct PaneMotion: Equatable {
        /// Where the pane is drawn, from its place, along the split's axis.
        var shift: CGFloat = 0
        var opacity: Double = 1
        /// How much longer than its place the pane is drawn, along the split's axis.
        var extraLength: CGFloat = 0
        var isMoving: Bool { shift != 0 || extraLength != 0 }
    }

    /// A page is laid out again for every frame it is resized, and with several in motion that costs more than a frame, so only a pane that is the one other page in the layout is squeezed (its length eased); with more, the panes keep their length and are slid aside, which only moves what is drawn.
    static let squeezedPaneLimit = 2

    /// `lengths` are the panes' lengths along the axis now, `divider` the thickness between them. Before the arrival the other panes shared the same span evenly.
    static func paneMotion(
        motion: SplitMotion?, index: Int, tabIDs: [TabID], lengths: [CGFloat], divider: CGFloat, reduceMotion: Bool
    ) -> PaneMotion {
        guard let motion, let arrivingIndex = tabIDs.firstIndex(of: motion.arrivingTabID), tabIDs.count > 1,
              lengths.count == tabIDs.count, lengths.indices.contains(index) else { return PaneMotion() }
        let remaining = max(0, min(1, 1 - motion.progress))
        if index == arrivingIndex { return PaneMotion(opacity: Double(min(1, motion.progress * 1.6))) }
        guard !reduceMotion else { return PaneMotion() }

        let before = tabIDs.count - 1
        let span = lengths.reduce(0, +) + CGFloat(tabIDs.count - 1) * divider
        let oldLength = max(0, (span - CGFloat(before - 1) * divider) / CGFloat(before))
        let oldIndex = index < arrivingIndex ? index : index - 1
        let oldStart = CGFloat(oldIndex) * (oldLength + divider)
        let newStart = lengths[..<index].reduce(0) { $0 + $1 + divider }
        let squeezes = tabIDs.count <= squeezedPaneLimit
        return PaneMotion(shift: (oldStart - newStart) * remaining, extraLength: squeezes ? (oldLength - lengths[index]) * remaining : 0)
    }

    @ViewBuilder
    private func paneItems(group: SplitGroup?, tabIDs: [TabID], total: CGFloat, orientation: SplitOrientation) -> some View {
        let dividerCount = max(0, tabIDs.count - 1)
        let available = max(0, total - CGFloat(dividerCount) * OrbitMetrics.splitDividerThickness)
        let lastIndex = tabIDs.count - 1
        let lengths = tabIDs.indices.map { i -> CGFloat in
            available * CGFloat(group.map { $0.fractions.indices.contains(i) ? $0.fractions[i] : 1.0 / Double(tabIDs.count) } ?? 1.0)
        }
        let keys = slots.keys(for: tabIDs)
        let entries = tabIDs.enumerated().map { PaneEntry(index: $0.offset, tabID: $0.element, key: keys[$0.offset]) }
        ForEach(entries, id: \.key) { entry in
            let index = entry.index
            let tabID = entry.tabID
            if let tab = env.tab(tabID) {
                let fraction = group.map { $0.fractions.indices.contains(index) ? $0.fractions[index] : 1.0 / Double(tabIDs.count) } ?? 1.0
                let length = available * CGFloat(fraction)
                let motion = Self.paneMotion(motion: env.splitMotion, index: index, tabIDs: tabIDs, lengths: lengths, divider: OrbitMetrics.splitDividerThickness, reduceMotion: reduceMotion)
                // Padding applied before .frame(width:), not after: SwiftUI's .padding() adds to a view's ideal size, so padding an already-fixed view would overflow the total width instead of shrinking the inner content.
                let leadingGap = (orientation == .horizontal && index > 0) ? OrbitSplitPaneMetrics.paneGap : 0
                let trailingGap = (orientation == .horizontal && index < lastIndex) ? OrbitSplitPaneMetrics.paneGap : 0
                let topGap = (orientation == .vertical && index > 0) ? OrbitSplitPaneMetrics.paneGap : 0
                let bottomGap = (orientation == .vertical && index < lastIndex) ? OrbitSplitPaneMetrics.paneGap : 0
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
                    // The page is given its own length plus the motion's extra, and the place it takes in the row stays `length` below: what overflows the place is drawn over the neighbour.
                    .frame(
                        width: orientation == .horizontal ? max(0, length - leadingGap - trailingGap + motion.extraLength) : nil,
                        height: orientation == .vertical ? max(0, length - topGap - bottomGap + motion.extraLength) : nil,
                        alignment: orientation == .horizontal ? .leading : .top
                    )
                    .padding(.leading, leadingGap)
                    .padding(.trailing, trailingGap)
                    .padding(.top, topGap)
                    .padding(.bottom, bottomGap)
                    .frame(
                        width: orientation == .horizontal ? length : nil,
                        height: orientation == .vertical ? length : nil,
                        alignment: orientation == .horizontal ? .leading : .top
                    )
                    // The page already there takes its new size in one step; what moves is the arrival's motion, below, which only transforms what is drawn.
                    .animation(nil, value: tabIDs.count)
                    .offset(x: orientation == .horizontal ? motion.shift : 0, y: orientation == .vertical ? motion.shift : 0)
                    .opacity(motion.opacity)
                    // A plain .onTapGesture here would win the mouse-down/up pair before AppKit routes it to the embedded engine view, swallowing the first click on any page control. SplitPaneFocusObserver observes instead of claiming the click.
                    .background {
                        if mountsFocusObserver, group != nil {
                            SplitPaneFocusObserver(
                                onClick: { env.focusSplitPane(index: index) },
                                ignores: { point, windowWidth in
                                    Self.floatingSidebarCovers(
                                        x: point.x, windowWidth: windowWidth,
                                        sidebarWidth: env.effectiveSidebarWidth, isRevealed: env.isSidebarHoverRevealed
                                    )
                                }
                            )
                        }
                    }
                    .transition(.identity)
            }
            if index < lastIndex, let group {
                SplitDividerView(group: group, dividerIndex: index, orientation: orientation, totalLength: available)
            }
        }
    }
}

/// A pane of the layout: where it sits now, which page, and the slot that page holds.
private struct PaneEntry {
    var index: Int
    var tabID: TabID
    var key: Int
}

/// Remembers which slot of the layout each page occupies, so a page keeps its host (and is not re-embedded) when panes arrive in front of it, between it and another, or leave ahead of it. Panes were keyed by position, which moved every later page into a different host and showed it blank until WebKit painted it again.
///
/// A page that was in the layout keeps its slot. A page that takes the place of one that left (a lone pane showing another tab) takes that slot, so switching tabs still swaps the page inside the same host. Any other page gets a new slot.
final class SplitPaneSlots {
    private var slots: [(key: Int, tab: TabID)] = []
    private var nextKey = 0

    func keys(for tabIDs: [TabID]) -> [Int] {
        let previous = slots
        var vacated = previous.filter { !tabIDs.contains($0.tab) }.map(\.key)
        var assigned: [(key: Int, tab: TabID)] = []
        for tab in tabIDs {
            if let kept = previous.first(where: { $0.tab == tab }) {
                assigned.append(kept)
            } else if !vacated.isEmpty {
                assigned.append((vacated.removeFirst(), tab))
            } else {
                assigned.append((nextKey, tab))
                nextKey += 1
            }
        }
        slots = assigned
        return assigned.map(\.key)
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
    /// A press at this point (window coordinates, with the window's width) that something drawn over the page has taken.
    var ignores: (CGPoint, CGFloat) -> Bool = { _, _ in false }

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClick = onClick
        view.ignores = ignores
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onClick = onClick
        nsView.ignores = ignores
        #if DEBUG
        nsView.isArmed = !screenshotModeRepresentableDisabled
        #endif
    }

    final class ObserverView: NSView {
        var onClick: (() -> Void)?
        var ignores: ((CGPoint, CGFloat) -> Bool)?
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
                if self.ignores?(event.locationInWindow, window.frame.width) == true { return event }
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


/// Command-drag on a pane of a split moves it. A Command press that never moves is an ordinary click and goes to the page unchanged.
private struct PaneRearrangeObserver: NSViewRepresentable {
    var frames: [CGRect]
    var axis: SplitOrientation
    /// The pane under the pointer (never the dragged one) and the side of it the drop would land on.
    var onTarget: (_ target: Int?, _ edge: SplitEdge?) -> Void
    var onDrop: (_ source: Int, _ target: Int, _ edge: SplitEdge) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.frames = frames
        view.axis = axis
        view.onTarget = onTarget
        view.onDrop = onDrop
        view.onEnd = onEnd
    }

    final class ObserverView: NSView {
        var frames: [CGRect] = []
        var axis: SplitOrientation = .horizontal
        var onTarget: ((Int?, SplitEdge?) -> Void)?
        var onDrop: ((Int, Int, SplitEdge) -> Void)?
        var onEnd: (() -> Void)?

        /// How far the pointer must move after a Command press before it is a drag and not a click.
        static let dragSlop: CGFloat = 5

        private enum Phase {
            case idle
            case pressed(source: Int, down: NSEvent)
            case dragging(source: Int, target: Int?, edge: SplitEdge?)
        }

        private var phase = Phase.idle
        private var monitor: Any?
        private var replaying = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { cancel(); removeMonitor() }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The pointer in the container's own top-left coordinates.
        private func local(_ event: NSEvent) -> CGPoint {
            let point = convert(event.locationInWindow, from: nil)
            return CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard !replaying, let window, event.window === window else { return event }
            switch event.type {
            case .leftMouseDown:
                guard event.modifierFlags.contains(.command), frames.count > 1 else { return event }
                let point = local(event)
                guard bounds.contains(convert(event.locationInWindow, from: nil)),
                      let source = frames.firstIndex(where: { $0.contains(point) }) else { return event }
                phase = .pressed(source: source, down: event)
                return nil
            case .leftMouseDragged:
                switch phase {
                case .idle:
                    return event
                case .pressed(let source, let down):
                    let moved = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
                    guard moved >= Self.dragSlop else { return nil }
                    NSCursor.closedHand.push()
                    phase = .dragging(source: source, target: nil, edge: nil)
                    update(event, source: source)
                    return nil
                case .dragging(let source, _, _):
                    update(event, source: source)
                    return nil
                }
            case .leftMouseUp:
                switch phase {
                case .idle:
                    return event
                case .pressed(_, let down):
                    // Never moved: the page gets the click it would have had, press first.
                    phase = .idle
                    replaying = true
                    NSApp.sendEvent(down)
                    replaying = false
                    return event
                case .dragging(let source, let target, let edge):
                    phase = .idle
                    NSCursor.pop()
                    if let target, let edge { onDrop?(source, target, edge) } else { onEnd?() }
                    return nil
                }
            case .keyDown:
                guard event.keyCode == 53 else { return event }
                switch phase {
                case .dragging:
                    cancel()
                    return nil
                default:
                    return event
                }
            default:
                return event
            }
        }

        private func update(_ event: NSEvent, source: Int) {
            let point = local(event)
            var target: Int?
            var edge: SplitEdge?
            if let index = frames.firstIndex(where: { $0.contains(point) }), index != source {
                let frame = frames[index]
                target = index
                edge = SplitDropZoneGeometry.edge(
                    at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                    in: frame.size,
                    allowedOrientation: axis
                )
            }
            phase = .dragging(source: source, target: target, edge: edge)
            onTarget?(target, edge)
        }

        private func cancel() {
            if case .dragging = phase { NSCursor.pop() }
            phase = .idle
            onEnd?()
        }
    }
}
