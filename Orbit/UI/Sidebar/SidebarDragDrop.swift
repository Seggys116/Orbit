//  Do not replace sidebarDragSource's plain SwiftUI .onDrag with a hand-rolled AppKit drag source: it broke both clicking and dragging sidebar rows entirely when tried (OrbitAppTests/SidebarRowRealTreeDragEvidenceTests.swift guards the regression).

import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension UTType {
    static let orbitSidebarNode = UTType(exportedAs: "com.orbit.browser.sidebarNode")
}

struct SidebarDragPayload: Codable, Transferable, Equatable {
    enum Kind: String, Codable {
        case pinnedNode
        case todayTab
        case favorite
    }

    var nodeID: UUID
    var kind: Kind
    var spaceID: SpaceID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .orbitSidebarNode)
    }
}

@MainActor
enum SidebarDragSession {
    private static var record: (payload: SidebarDragPayload, changeCount: Int?)?
    private static var generation: UInt64 = 0

    static func begin(_ payload: SidebarDragPayload) {
        generation &+= 1
        let thisGeneration = generation
        // changeCount must not be captured synchronously: AppKit's dragging session (which bumps it) doesn't start until this .onDrag closure returns, so an inline read would always be stale. Captured one main-async hop later instead.
        record = (payload, nil)
        DispatchQueue.main.async {
            guard generation == thisGeneration, record != nil else { return }
            record?.changeCount = NSPasteboard(name: .drag).changeCount
        }
        SidebarTearOffDetector.begin(payload)
    }

    /// True from `begin` until the drag is consumed or discarded; `current` is nil on the first turn.
    static var hasInFlightDrag: Bool { record != nil }

    static var current: SidebarDragPayload? {
        guard let record, let changeCount = record.changeCount else { return nil }
        guard changeCount == NSPasteboard(name: .drag).changeCount else { return nil }
        return record.payload
    }

    static func end() {
        record = nil
        SidebarTearOffDetector.markConsumed()
    }

    static func discardStaleRecord() {
        record = nil
    }

    // .all visibility, deliberately: every drop zone gates on hasItemsConforming(to: [.orbitSidebarNode]), and narrowing this risks the type not being advertised on the pasteboard at all, silently disabling drops rather than merely slowing them.
    static func itemProvider(for payload: SidebarDragPayload) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        provider.registerDataRepresentation(
            for: .orbitSidebarNode,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

extension View {
    func sidebarDragSource(_ payload: SidebarDragPayload) -> some View {
        onDrag {
            SidebarDragSession.begin(payload)
            return SidebarDragSession.itemProvider(for: payload)
        }
    }

    func sidebarDragSource<Preview: View>(
        _ payload: SidebarDragPayload,
        @ViewBuilder preview: @escaping () -> Preview
    ) -> some View {
        onDrag {
            SidebarDragSession.begin(payload)
            return SidebarDragSession.itemProvider(for: payload)
        } preview: {
            preview()
        }
    }
}

struct SidebarDragLabel: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: 180)
    }
}

private struct SidebarRowDragSource: ViewModifier {
    var payload: SidebarDragPayload
    var label: String?
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if let label {
            content.sidebarDragSource(payload) { SidebarDragLabel(title: label) }
        } else {
            content.sidebarDragSource(payload)
        }
    }
}

private struct SplitSideHint: View {
    var edge: SplitEdge
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let horizontal = edge == .left || edge == .right
            let width = horizontal ? proxy.size.width * 0.5 : proxy.size.width
            let height = horizontal ? proxy.size.height : proxy.size.height * 0.5
            let x: CGFloat = edge == .right ? proxy.size.width - width / 2 : (horizontal ? width / 2 : proxy.size.width / 2)
            let y: CGFloat = edge == .bottom ? proxy.size.height - height / 2 : (horizontal ? proxy.size.height / 2 : height / 2)
            ZStack {
                Rectangle().fill(color.opacity(0.2))
                VStack(spacing: 2) {
                    Image(systemName: edge.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(edge.label)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(color)
            }
            .frame(width: width, height: height)
            .position(x: x, y: y)
        }
        .frame(height: OrbitMetrics.sidebarRowHeight)
        .allowsHitTesting(false)
    }
}

enum DropInsertion: Equatable {
    case before(UUID)
    case after(UUID)
    case insideFolder(FolderID)
    case groupingWithSibling(UUID, SplitEdge?)
}

enum PinnedTreeLocation {
    static func locate(_ id: UUID, in nodes: [SidebarNode], parent: FolderID? = nil) -> (parent: FolderID?, index: Int)? {
        for (index, node) in nodes.enumerated() {
            if node.id == id { return (parent, index) }
            if case .folder(let folder) = node, let found = locate(id, in: folder.children, parent: folder.id) {
                return found
            }
        }
        return nil
    }
}

// Every reorder here removes the dragged node before inserting at a target index; computing that index from the anchor's pre-removal position overshoots by one on downward drags whenever the dragged node's own index sits before the anchor's.
enum SidebarReorderMath {
    static func insertionIndex(before anchorIndex: Int, draggedIndex: Int?) -> Int {
        guard let draggedIndex, draggedIndex < anchorIndex else { return anchorIndex }
        return anchorIndex - 1
    }

    static func insertionIndex(after anchorIndex: Int, draggedIndex: Int?) -> Int {
        insertionIndex(before: anchorIndex, draggedIndex: draggedIndex) + 1
    }
}

let sidebarDragActivityDecayNanoseconds: UInt64 = 300_000_000

// One sleeping task per row for the whole of a drag, not one created and cancelled per drop update. dropUpdated fires on every pointer move, so the per-event version allocated and tore down a Task for every row the pointer touched, dozens of times a second, for a deadline that only ever moves forward.
@MainActor
final class SidebarDragActivityDecay {
    private var deadline = ContinuousClock.now
    private var task: Task<Void, Never>?

    /// Pushes the deadline out. `onExpire` runs once, after the deadline has passed without another ping.
    func ping(decayNanoseconds: UInt64 = sidebarDragActivityDecayNanoseconds, onExpire: @escaping @MainActor () -> Void) {
        deadline = ContinuousClock.now + .nanoseconds(Int64(decayNanoseconds))
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while let self {
                let remaining = self.deadline - ContinuousClock.now
                guard remaining > .zero else { break }
                try? await Task.sleep(for: remaining)
                if Task.isCancelled { return }
            }
            self?.task = nil
            onExpire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

struct InsertionIndicatorLine: View {
    var color: Color

    static var height: CGFloat { OrbitMetrics.sidebarInsertionIndicatorKnobDiameter }

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(color, lineWidth: OrbitMetrics.sidebarInsertionIndicatorThickness)
                .frame(
                    width: OrbitMetrics.sidebarInsertionIndicatorKnobDiameter,
                    height: OrbitMetrics.sidebarInsertionIndicatorKnobDiameter
                )
            Rectangle()
                .fill(color)
                .frame(height: OrbitMetrics.sidebarInsertionIndicatorThickness)
        }
        .frame(height: Self.height)
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
        .transition(.opacity)
    }
}

// MARK: - Drop destinations that propose `.move`, not `.copy`

// sidebarPayloadDropDestination / SidebarPayloadDropDelegate propose .move via DropDelegate.dropUpdated(info:) — .dropDestination(for:action:isTargeted:) hard-codes .copy, which is what makes AppKit draw the green + badge on the drag image.
struct SidebarPayloadDropDelegate: DropDelegate {
    var onDrop: ([SidebarDragPayload], CGPoint) -> Bool
    var onTargeted: (Bool) -> Void
    var onUpdate: (CGPoint) -> Void = { _ in }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.orbitSidebarNode])
    }

    func dropEntered(info: DropInfo) { onTargeted(true) }

    func dropExited(info: DropInfo) { onTargeted(false) }

    static let proposedOperation: DropOperation = .move

    // dropUpdated fires continuously while a drag hovers a live zone, unlike dropEntered/dropExited which fire once per visit; onUpdate rides that same cadence so SidebarDropTarget.noteDragActivity() never lets a caret go stale mid-hover.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        onUpdate(info.location)
        return DropProposal(operation: Self.proposedOperation)
    }

    func performDrop(info: DropInfo) -> Bool {
        // dropExited is not guaranteed after a successful drop, so the targeted flag is cleared here too.
        onTargeted(false)
        let providers = info.itemProviders(for: [.orbitSidebarNode])
        guard !providers.isEmpty else { return false }
        let location = info.location

        // Rung 1: the drag Orbit itself started, read straight out of memory.
        if providers.count == 1, let inFlight = SidebarDragSession.current {
            SidebarDragSession.end()
            _ = onDrop([inFlight], location)
            return true
        }

        // Rung 2: real bytes on the drag pasteboard.
        let syncPayloads = SidebarDragPayload.decodeSynchronously()
        if !syncPayloads.isEmpty, syncPayloads.count == providers.count {
            SidebarDragSession.end()
            _ = onDrop(syncPayloads, location)
            return true
        }

        // Rung 3: the original asynchronous decode.
        SidebarDragPayload.decode(from: providers) { payloads in
            SidebarDragSession.end()
            guard !payloads.isEmpty else { return }
            _ = onDrop(payloads, location)
        }
        return true
    }
}

extension SidebarDragPayload {
    static func decode(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor ([SidebarDragPayload]) -> Void
    ) {
        Task { @MainActor in
            var payloads: [SidebarDragPayload] = []
            for provider in providers {
                if let payload = await decode(from: provider) { payloads.append(payload) }
            }
            completion(payloads)
        }
    }

    private static func decode(from provider: NSItemProvider) async -> SidebarDragPayload? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: SidebarDragPayload.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    static func decodeSynchronously() -> [SidebarDragPayload] {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier)
        let items = pasteboard.pasteboardItems ?? []
        return items.compactMap { item in
            guard let data = item.data(forType: type) else { return nil }
            return try? JSONDecoder().decode(SidebarDragPayload.self, from: data)
        }
    }
}

extension View {
    func sidebarPayloadDropDestination(
        action: @escaping ([SidebarDragPayload], CGPoint) -> Bool,
        isTargeted: @escaping (Bool) -> Void = { _ in },
        onUpdate: @escaping (CGPoint) -> Void = { _ in }
    ) -> some View {
        onDrop(
            of: [.orbitSidebarNode],
            delegate: SidebarPayloadDropDelegate(onDrop: action, onTargeted: isTargeted, onUpdate: onUpdate)
        )
    }
}

enum SidebarRowBodyDropIntent: Equatable {
    case groupIntoFolder
    case createSplit(SplitGroup.Axis)
    case reorderOnly
}

struct SidebarDropTarget<Content: View>: View {
    var payload: SidebarDragPayload
    var rowID: UUID
    var isFolder: Bool
    // theme.readableForeground, not Color(theme.primary.nsColor): primary is the sidebar's own background gradient stop, so the latter draws this invisibly against it.
    var accentColor: Color
    var bodyDropIntent: SidebarRowBodyDropIntent = .groupIntoFolder
    var rejectDropIDs: Set<UUID> = []
    var ownsDragSource: Bool = true
    var dragLabel: String? = nil
    var onDrop: (SidebarDragPayload, DropInsertion) -> Void
    @ViewBuilder var content: () -> Content

    @State private var topTargeted = false
    @State private var bottomTargeted = false
    @State private var insideTargeted = false
    @State private var proposedEdge: SplitEdge?
    @State private var rowSize: CGSize = .zero

    // The two strips default to .allowsHitTesting(false): SwiftUI hit-tests a ZStack front-to-back, so an unconditionally hit-testable strip would swallow every ordinary click/drag-start in its band before content() ever sees it.
    @State private var isDragActivityNearby = false
    @State private var dragActivityDecay = SidebarDragActivityDecay()

    // Debounced "a drag is near this row" flag, driven by every zone's dropEntered/dropUpdated ping; without the decay's force-clear, a dwelling drag or an Esc-cancelled one (no dropExited) leaves a stuck caret/highlight.
    // Only writes state that actually changed: dropUpdated lands here on every pointer move, and an unchanged assignment still invalidates the row.
    private func noteDragActivity() {
        if !isDragActivityNearby { isDragActivityNearby = true }
        dragActivityDecay.ping {
            isDragActivityNearby = false
            topTargeted = false
            bottomTargeted = false
            insideTargeted = false
        }
    }

    // Ensures exactly one of the three targeted flags is ever true at once — without it, the abutting top/bottom/body zones were observed oscillating against each other roughly every 300ms.
    private func clearOtherZones(keeping zone: DropZone) {
        if zone != .top { topTargeted = false }
        if zone != .bottom { bottomTargeted = false }
        if zone != .inside { insideTargeted = false }
    }

    private enum DropZone: Equatable { case top, bottom, inside }

    #if DEBUG
    // Bypasses this view's entire drag/drop apparatus, not just .draggable: ImageRenderer also renders a .dropDestination-decorated view as blank, and this view stacks three of them around one drag source.
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    var body: some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            content()
        } else {
            realBody
        }
        #else
        realBody
        #endif
    }

    private var showsBodyHighlight: Bool {
        isFolder || bodyDropIntent != .reorderOnly
    }

    private var bodyAffordanceGlyph: String? {
        if isFolder { return "folder" }
        switch bodyDropIntent {
        case .groupIntoFolder: return "folder.badge.plus"
        // SplitGroup.Axis.horizontal means panes side by side, so its glyph is the one split by a vertical rule: 2x1.
        case .createSplit(.horizontal): return "rectangle.split.2x1"
        case .createSplit(.vertical): return "rectangle.split.1x2"
        case .reorderOnly: return nil
        }
    }

    private func draggedPayload() -> SidebarDragPayload? {
        SidebarDragSession.current ?? SidebarDragPayload.decodeSynchronously().first
    }

    private func rejects(_ payload: SidebarDragPayload?) -> Bool {
        guard let payload else { return false }
        if payload.nodeID == rowID { return true }
        return rejectDropIDs.contains(payload.nodeID)
    }

    private var realBody: some View {
        ZStack(alignment: .top) {
            content()
                .modifier(SidebarRowDragSource(payload: payload, label: dragLabel, enabled: ownsDragSource))
                .sidebarPayloadDropDestination { items, _ in
                    guard let item = items.first, !rejects(item) else { return false }
                    if isFolder {
                        onDrop(item, .insideFolder(rowID))
                    } else {
                        onDrop(item, .groupingWithSibling(rowID, proposedEdge))
                    }
                    return true
                } isTargeted: { targeted in
                    let show = targeted && !rejects(draggedPayload())
                    insideTargeted = show
                    if !show { proposedEdge = nil }
                    if show {
                        clearOtherZones(keeping: .inside)
                        noteDragActivity()
                    }
                } onUpdate: { location in
                    noteDragActivity()
                    guard !rejects(draggedPayload()) else {
                        proposedEdge = nil
                        return
                    }
                    guard case .createSplit(let axis) = bodyDropIntent, rowSize.width > 0, rowSize.height > 0 else {
                        proposedEdge = nil
                        return
                    }
                    proposedEdge = SplitDropZoneGeometry.edge(
                        at: location,
                        in: rowSize,
                        allowedOrientation: axis
                    )
                }

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: OrbitMetrics.sidebarRowHeight * OrbitMetrics.sidebarRowEdgeDropZoneFraction)
                    .contentShape(Rectangle())
                    .sidebarPayloadDropDestination { items, _ in
                        guard let item = items.first, item.nodeID != rowID else { return false }
                        onDrop(item, .before(rowID))
                        return true
                    } isTargeted: { targeted in
                        topTargeted = targeted
                        if targeted {
                            clearOtherZones(keeping: .top)
                            noteDragActivity()
                        }
                    } onUpdate: { _ in
                        noteDragActivity()
                    }
                Spacer(minLength: 0)
                Color.clear
                    .frame(height: OrbitMetrics.sidebarRowHeight * OrbitMetrics.sidebarRowEdgeDropZoneFraction)
                    .contentShape(Rectangle())
                    .sidebarPayloadDropDestination { items, _ in
                        guard let item = items.first, item.nodeID != rowID else { return false }
                        onDrop(item, .after(rowID))
                        return true
                    } isTargeted: { targeted in
                        bottomTargeted = targeted
                        if targeted {
                            clearOtherZones(keeping: .bottom)
                            noteDragActivity()
                        }
                    } onUpdate: { _ in
                        noteDragActivity()
                    }
            }
            .allowsHitTesting(isDragActivityNearby)

            if topTargeted {
                InsertionIndicatorLine(color: accentColor)
                    .offset(y: -InsertionIndicatorLine.height / 2)
                    .allowsHitTesting(false)
            }
            if bottomTargeted || (insideTargeted && !showsBodyHighlight) {
                InsertionIndicatorLine(color: accentColor)
                    .offset(y: OrbitMetrics.sidebarRowHeight - InsertionIndicatorLine.height / 2)
                    .allowsHitTesting(false)
            }

            if insideTargeted, showsBodyHighlight, let edge = proposedEdge {
                SplitSideHint(edge: edge, color: accentColor)
                    .allowsHitTesting(false)
            } else if insideTargeted, showsBodyHighlight, let glyph = bodyAffordanceGlyph {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Image(systemName: glyph)
                        .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                        .foregroundStyle(accentColor)
                }
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
                .frame(height: OrbitMetrics.sidebarRowHeight)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { rowSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in rowSize = size }
            }
        }
        // Elevated only while showing an indicator: .offset does not affect layout, so the bottom caret's offset puts roughly half its height into the next row's band, which would otherwise paint over it.
        .zIndex(dropIndicatorState == .none ? 0 : 1)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                .fill(insideTargeted && showsBodyHighlight ? accentColor.opacity(0.18) : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                        .strokeBorder(accentColor.opacity(insideTargeted && showsBodyHighlight ? 0.9 : 0), lineWidth: 1.5)
                )
        )
        .animation(OrbitMotion.quick, value: dropIndicatorState)
    }

    // One animation keyed on the single indicator that can be showing, instead of three modifiers each re-evaluated on every flag change. clearOtherZones keeps at most one of the three true, so this loses no transition.
    private enum DropIndicatorState: Equatable { case none, top, bottom, inside }

    private var dropIndicatorState: DropIndicatorState {
        if insideTargeted { return .inside }
        if topTargeted { return .top }
        if bottomTargeted { return .bottom }
        return .none
    }
}
