import AppKit
import Foundation
import OSLog

@MainActor
@Observable
final class EaselCanvasModel {
    let easelID: UUID
    private let store: EaselStore

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "EaselCanvasModel")

    private(set) var items: [EaselItem]
    var title: String

    private(set) var isOrphanedFromStore: Bool

    var viewportOrigin: CGPoint {
        didSet {
            guard oldValue != viewportOrigin else { return }
            scheduleViewportPersist()
        }
    }
    var viewportZoom: Double {
        didSet {
            guard oldValue != viewportZoom else { return }
            scheduleViewportPersist()
        }
    }

    var selection: Set<UUID> = []
    var activeTool: EaselTool = .select

    var strokeColorIndex: Int = EaselPalette.loadPreferredIndex() {
        didSet { EaselPalette.savePreferredIndex(strokeColorIndex) }
    }

    var strokeColor: ThemeColor { EaselPalette.themeColor(at: strokeColorIndex) }

    private(set) var activeGuides: [EaselAlignmentGuide] = []

    var dragOriginFrame: [UUID: CGRect] = [:]

    private var undoStack: [[EaselItem]] = []
    private var redoStack: [[EaselItem]] = []
    private static let maxHistory = 60

    private var titleDebounceTask: Task<Void, Never>?
    private var viewportDebounceTask: Task<Void, Never>?
    private static let titlePersistDebounce: Duration = .milliseconds(400)
    private static let viewportPersistDebounce: Duration = .milliseconds(150)

    init(easelID: UUID, store: EaselStore) {
        self.easelID = easelID
        self.store = store
        let loaded = store.easel(easelID)
        let easel = loaded ?? Easel(id: easelID)
        self.items = easel.items
        self.title = easel.title
        self.viewportOrigin = easel.viewportOrigin
        self.viewportZoom = easel.viewportZoom
        self.isOrphanedFromStore = loaded == nil

        if loaded == nil {
            // A stale/corrupted easel id must fail loudly, not silently discard every edit.
            EaselCanvasModel.logger.fault(
                "EaselCanvasModel.init: \(easelID.uuidString, privacy: .public) is not present in EaselStore's index — presenting a blank scratch document. EaselStore exposes no public API to seed this id, so nothing drawn on this canvas will reach disk until something else adds this id to the index."
            )
        }
    }

    // MARK: - Mutation entry point

    private func mutate(pushingHistory: Bool = true, _ body: (inout [EaselItem]) -> Void) {
        let before = items
        body(&items)
        if pushingHistory, items != before {
            undoStack.append(before)
            if undoStack.count > EaselCanvasModel.maxHistory { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        // Synchronous, undebounced: a crash between a draw and its write must not lose the stroke.
        persist()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        selection.removeAll()
        persist()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        selection.removeAll()
        persist()
    }

    // MARK: - Items

    @discardableResult
    func addItem(_ content: EaselItem.Content, frame: CGRect) -> UUID {
        let topZ = (items.map(\.zIndex).max() ?? -1) + 1
        let item = EaselItem(frame: frame, content: content, zIndex: topZ)
        mutate { $0.append(item) }
        selection = [item.id]
        return item.id
    }

    static let defaultStrokeWidth: Double = 3

    static let minimumShapeDragSpan: CGFloat = 4

    static func shapeGeometry(
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: Double
    ) -> (frame: CGRect, unitStart: CGPoint, unitEnd: CGPoint)? {
        guard hypot(end.x - start.x, end.y - start.y) >= minimumShapeDragSpan else { return nil }

        let inset = CGFloat(lineWidth) / 2 + 1
        let box = CGRect(
            x: min(start.x, end.x) - inset,
            y: min(start.y, end.y) - inset,
            width: abs(end.x - start.x) + inset * 2,
            height: abs(end.y - start.y) + inset * 2
        )

        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: box.width > 0 ? (point.x - box.minX) / box.width : 0,
                y: box.height > 0 ? (point.y - box.minY) / box.height : 0
            )
        }

        return (box, unit(start), unit(end))
    }

    @discardableResult
    func addShape(
        kind: EaselItem.ShapeKind,
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: Double = EaselCanvasModel.defaultStrokeWidth
    ) -> UUID? {
        guard let geometry = EaselCanvasModel.shapeGeometry(from: start, to: end, lineWidth: lineWidth) else {
            return nil
        }
        return addItem(
            .shape(
                kind: kind,
                color: strokeColor,
                lineWidth: lineWidth,
                unitStart: geometry.unitStart,
                unitEnd: geometry.unitEnd
            ),
            frame: geometry.frame
        )
    }

    func updateItem(_ id: UUID, pushingHistory: Bool = true, _ transform: (inout EaselItem) -> Void) {
        mutate(pushingHistory: pushingHistory) { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            transform(&list[index])
        }
    }

    private var dragBaseline: [EaselItem]?

    func beginDrag() {
        dragBaseline = items
    }

    func updateDuringDrag(_ id: UUID, _ transform: (inout EaselItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        transform(&items[index])
    }

    func commitDrag() {
        activeGuides = []
        guard let baseline = dragBaseline, baseline != items else { dragBaseline = nil; return }
        undoStack.append(baseline)
        if undoStack.count > EaselCanvasModel.maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        dragBaseline = nil
        persist()
    }

    // MARK: - Alignment guides

    func snappedFrame(_ frame: CGRect, movingItemID: UUID, threshold: CGFloat) -> CGRect {
        var verticalCandidates: [CGFloat] = []
        var horizontalCandidates: [CGFloat] = []
        for other in items where other.id != movingItemID {
            verticalCandidates.append(contentsOf: [other.frame.minX, other.frame.midX, other.frame.maxX])
            horizontalCandidates.append(contentsOf: [other.frame.minY, other.frame.midY, other.frame.maxY])
        }

        var snapped = frame
        var guides: [EaselAlignmentGuide] = []

        if let hit = EaselCanvasModel.bestSnap(
            edges: [frame.minX, frame.midX, frame.maxX],
            candidates: verticalCandidates,
            threshold: threshold
        ) {
            snapped.origin.x += hit.delta
            guides.append(EaselAlignmentGuide(axis: .vertical, position: hit.line))
        }

        if let hit = EaselCanvasModel.bestSnap(
            edges: [frame.minY, frame.midY, frame.maxY],
            candidates: horizontalCandidates,
            threshold: threshold
        ) {
            snapped.origin.y += hit.delta
            guides.append(EaselAlignmentGuide(axis: .horizontal, position: hit.line))
        }

        activeGuides = guides
        return snapped
    }

    func clearGuides() {
        activeGuides = []
    }

    private static func bestSnap(
        edges: [CGFloat],
        candidates: [CGFloat],
        threshold: CGFloat
    ) -> (line: CGFloat, delta: CGFloat)? {
        var best: (line: CGFloat, delta: CGFloat)?
        for edge in edges {
            for candidate in candidates {
                let delta = candidate - edge
                guard abs(delta) <= threshold else { continue }
                if best == nil || abs(delta) < abs(best!.delta) {
                    best = (candidate, delta)
                }
            }
        }
        return best
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        mutate { $0.removeAll { selection.contains($0.id) } }
        selection.removeAll()
    }

    func bringToFront(_ id: UUID) {
        mutate { list in
            let topZ = (list.map(\.zIndex).max() ?? 0) + 1
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].zIndex = topZ
        }
    }

    func sendToBack(_ id: UUID) {
        mutate { list in
            let bottomZ = (list.map(\.zIndex).min() ?? 0) - 1
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].zIndex = bottomZ
        }
    }

    func setTitle(_ newTitle: String) {
        title = newTitle
        titleDebounceTask?.cancel()
        titleDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: EaselCanvasModel.titlePersistDebounce)
            guard !Task.isCancelled else { return }
            self?.commitTitle()
        }
    }

    private func commitTitle() {
        titleDebounceTask?.cancel()
        titleDebounceTask = nil
        store.renameEasel(easelID, to: title)
        reportIfWriteWasDropped(context: "commitTitle")
    }

    // Must be called before this model is discarded, or a title still inside the debounce window is dropped.
    func flushPendingTitleEdit() {
        guard titleDebounceTask != nil else { return }
        commitTitle()
    }

    // MARK: - Persistence

    private func persist() {
        store.updateEasel(easelID) { easel in
            easel.items = self.items
            easel.viewportOrigin = self.viewportOrigin
            easel.viewportZoom = self.viewportZoom
        }
        reportIfWriteWasDropped(context: "persist")
    }

    func persistViewport() {
        viewportDebounceTask?.cancel()
        viewportDebounceTask = nil
        store.updateEasel(easelID) { easel in
            easel.viewportOrigin = self.viewportOrigin
            easel.viewportZoom = self.viewportZoom
        }
        reportIfWriteWasDropped(context: "persistViewport")
    }

    private func scheduleViewportPersist() {
        viewportDebounceTask?.cancel()
        viewportDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: EaselCanvasModel.viewportPersistDebounce)
            guard !Task.isCancelled else { return }
            self?.persistViewport()
        }
    }

    private func reportIfWriteWasDropped(context: StaticString) {
        guard store.easel(easelID) == nil else { return }
        isOrphanedFromStore = true
        EaselCanvasModel.logger.fault(
            "\(context, privacy: .public): write to easel \(self.easelID.uuidString, privacy: .public) was silently dropped by EaselStore — this id is still not present in its index. Edits are being kept in memory only and will be lost when this model is discarded."
        )
    }

    // MARK: - Images

    func storeImageData(_ data: Data) -> String? {
        try? store.storeImage(data, forEasel: easelID)
    }

    func imageData(fileName: String) -> Data? {
        store.loadImageData(fileName: fileName, forEasel: easelID)
    }

    // MARK: - Live web-region capture cache

    func cacheWebRegionSnapshot(itemID: UUID, image: NSImage) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        _ = try? store.storeImage(png, forEasel: easelID, preferredFileName: webRegionCacheFileName(itemID))
    }

    func cachedWebRegionSnapshot(itemID: UUID) -> NSImage? {
        guard let data = store.loadImageData(fileName: webRegionCacheFileName(itemID), forEasel: easelID) else { return nil }
        return NSImage(data: data)
    }

    private func webRegionCacheFileName(_ itemID: UUID) -> String {
        EaselCanvasModel.webRegionCacheFileName(itemID)
    }

    // Name format must match EaselExporter's, which reads the same cached file.
    static func webRegionCacheFileName(_ itemID: UUID) -> String {
        "\(itemID.uuidString).livecapture.png"
    }
}

struct EaselAlignmentGuide: Equatable, Hashable {
    enum Axis: Hashable { case vertical, horizontal }
    var axis: Axis
    var position: CGFloat
}

enum EaselTool: String, CaseIterable {
    case select
    case image
    case text
    case ellipse
    case rectangle
    case arrow
    case draw
    case webCapture

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .image: return "photo"
        case .text: return "character"
        case .ellipse: return "circle"
        case .rectangle: return "square"
        case .arrow: return "arrow.up.right"
        case .draw: return "scribble"
        case .webCapture: return "camera.viewfinder"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select"
        case .image: return "Image"
        case .text: return "Text"
        case .ellipse: return "Circle"
        case .rectangle: return "Square"
        case .arrow: return "Arrow"
        case .draw: return "Draw"
        case .webCapture: return "Capture Page"
        }
    }

    var shapeKind: EaselItem.ShapeKind? {
        switch self {
        case .ellipse: return .ellipse
        case .rectangle: return .rectangle
        case .arrow: return .arrow
        case .select, .image, .text, .draw, .webCapture: return nil
        }
    }

    var usesStrokeColor: Bool {
        shapeKind != nil || self == .draw
    }
}

enum EaselPalette {
    static let colors: [ThemeColor] = [
        ThemeColor(red: 194 / 255, green: 161 / 255, blue: 42 / 255),
        ThemeColor(red: 207 / 255, green: 216 / 255, blue: 113 / 255),
        ThemeColor(red: 29 / 255, green: 89 / 255, blue: 20 / 255),
        ThemeColor(red: 49 / 255, green: 164 / 255, blue: 192 / 255),
        ThemeColor(red: 49 / 255, green: 57 / 255, blue: 251 / 255),
        ThemeColor(red: 166 / 255, green: 114 / 255, blue: 158 / 255),
        ThemeColor(red: 0, green: 0, blue: 0),
        ThemeColor(red: 187 / 255, green: 187 / 255, blue: 187 / 255),
        ThemeColor(red: 1, green: 1, blue: 1),
        ThemeColor(red: 242 / 255, green: 194 / 255, blue: 172 / 255),
        ThemeColor(red: 215 / 255, green: 72 / 255, blue: 5 / 255)
    ]

    static let defaultIndex = 10

    static let topRowCount = 6

    private static let preferenceKey = "easel.strokeColorIndex"

    static func themeColor(at index: Int) -> ThemeColor {
        colors.indices.contains(index) ? colors[index] : colors[defaultIndex]
    }

    static func loadPreferredIndex(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: preferenceKey) != nil else { return defaultIndex }
        let stored = defaults.integer(forKey: preferenceKey)
        return colors.indices.contains(stored) ? stored : defaultIndex
    }

    static func savePreferredIndex(_ index: Int, defaults: UserDefaults = .standard) {
        guard colors.indices.contains(index) else { return }
        defaults.set(index, forKey: preferenceKey)
    }
}
