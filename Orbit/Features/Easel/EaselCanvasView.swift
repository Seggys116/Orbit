import SwiftUI
import UniformTypeIdentifiers

struct EaselCanvasView: View {
    @Environment(AppEnvironment.self) private var env
    let easelID: UUID

    @State private var model: EaselCanvasModel?
    @State private var currentStrokePoints: [CGPoint] = []
    @State private var isDrawing = false
    @State private var showWebCaptureSheet = false
    @State private var newTextEditingID: UUID?
    @State private var lastDragTranslation: CGSize = .zero
    @State private var showColorPalette = false
    @State private var shapeDragStart: CGPoint?
    @State private var shapeDragCurrent: CGPoint?
    @State private var flushToken = UUID()

    var body: some View {
        Group {
            if let model {
                canvas(model)
            } else {
                ProgressView().onAppear { rebuildModelIfNeeded() }
            }
        }
        .onChange(of: easelID) { _, _ in rebuildModelIfNeeded() }
        .onAppear { registerFlush() }
        .onDisappear { DocumentEditorFlushRegistry.shared.deregister(flushToken) }
        .orbitDocumentAppearance()
    }

    // Two different easels routed through the same tree position can be mistaken by SwiftUI
    // for the same view being updated; this rebuilds model whenever easelID disagrees with it.
    private func rebuildModelIfNeeded() {
        guard model?.easelID != easelID else { return }
        if let outgoingModel = model {
            tearDown(outgoingModel)
        }
        model = EaselCanvasModel(easelID: easelID, store: env.easelStore)
    }

    private func registerFlush() {
        DocumentEditorFlushRegistry.shared.register(flushToken) {
            guard let model else { return }
            tearDown(model)
        }
    }

    @ViewBuilder
    private func canvas(_ model: EaselCanvasModel) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(nsColor: OrbitInternalPageChrome.surfaceNSColor)
                    .overlay(EaselGridBackground(zoom: model.viewportZoom, origin: model.viewportOrigin))

                ZStack(alignment: .topLeading) {
                    ForEach(model.items.sorted(by: { $0.zIndex < $1.zIndex })) { item in
                        EaselItemContainerView(
                            model: model,
                            item: item,
                            env: env,
                            isSelected: model.selection.contains(item.id)
                        )
                    }

                    if isDrawing, currentStrokePoints.count > 1 {
                        Path { path in
                            path.addLines(currentStrokePoints)
                        }
                        .stroke(
                            Color(model.strokeColor.nsColor),
                            style: StrokeStyle(
                                lineWidth: CGFloat(EaselCanvasModel.defaultStrokeWidth),
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                    }

                    if let kind = model.activeTool.shapeKind,
                       let start = shapeDragStart, let current = shapeDragCurrent {
                        shapePreview(kind: kind, from: start, to: current, model: model)
                    }

                    alignmentGuideOverlay(model)
                }
                .frame(width: 4000, height: 4000, alignment: .topLeading)
                .scaleEffect(model.viewportZoom, anchor: .topLeading)
                .offset(x: model.viewportOrigin.x, y: model.viewportOrigin.y)
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "easelCanvasSpace")
            .gesture(backgroundDragGesture(model))
            .gesture(MagnificationGesture()
                .onChanged { value in
                    model.viewportZoom = min(3.0, max(0.15, model.viewportZoom * value))
                }
                .onEnded { _ in
                    model.persistViewport()
                }
            )
            .onTapGesture { model.selection.removeAll() }
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers, location in
                guard let provider = providers.first else { return false }
                let canvasPoint = toCanvasPoint(location, model: model)
                handleImageDrop(provider: provider, at: canvasPoint, model: model)
                return true
            }
        }
        .overlay(alignment: .top) { titleBar(model) }
        .overlay(alignment: .bottomLeading) { toolPalette(model) }
        .overlay(alignment: .bottom) { statusBar(model) }
        .overlay(alignment: .bottomTrailing) { exportButton(model) }
        .sheet(isPresented: $showWebCaptureSheet) {
            EaselWebCaptureSheet(model: model) { showWebCaptureSheet = false }
        }
        .onDisappear { tearDown(model) }
        .background(KeyCaptureView { event in handleKey(event, model: model) })
    }

    // MARK: - Title bar

    private func titleBar(_ model: EaselCanvasModel) -> some View {
        HStack(spacing: 4) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).disabled(!model.canUndo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain).disabled(!model.canRedo)

            Divider().frame(height: 16)

            TextField("Untitled Easel", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 160)

            if model.isOrphanedFromStore {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .orbitTooltip("This easel could not be found in storage. Nothing drawn here will be saved.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.top, 10)
    }

    // MARK: - Tool palette

    private func toolPalette(_ model: EaselCanvasModel) -> some View {
        HStack(spacing: 4) {
            ForEach(EaselTool.allCases, id: \.self) { tool in
                Button {
                    select(tool: tool, model: model)
                } label: {
                    Image(systemName: tool.symbolName)
                        .frame(width: 26, height: 22)
                        .background(
                            model.activeTool == tool ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .orbitTooltip(tool.label)
            }

            Divider().frame(height: 16)

            Button { showColorPalette.toggle() } label: {
                Circle()
                    .fill(Color(model.strokeColor.nsColor))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .orbitTooltip("Colour")
            .popover(isPresented: $showColorPalette, arrowEdge: .top) {
                colorPalette(model)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.leading, 12)
        .padding(.bottom, 12)
    }

    private func select(tool: EaselTool, model: EaselCanvasModel) {
        switch tool {
        case .webCapture:
            showWebCaptureSheet = true
        case .image:
            presentImagePicker(model)
        default:
            model.activeTool = tool
        }
    }

    private func colorPalette(_ model: EaselCanvasModel) -> some View {
        let rows: [[Int]] = [
            Array(0..<EaselPalette.topRowCount),
            Array(EaselPalette.topRowCount..<EaselPalette.colors.count)
        ]
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 8) {
                    ForEach(rows[rowIndex], id: \.self) { index in
                        Button {
                            model.strokeColorIndex = index
                            showColorPalette = false
                        } label: {
                            Circle()
                                .fill(Color(EaselPalette.themeColor(at: index).nsColor))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
                                .overlay {
                                    if model.strokeColorIndex == index {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(
                                                EaselPalette.themeColor(at: index).luminance > 0.6 ? Color.black : Color.white
                                            )
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Export

    private func exportButton(_ model: EaselCanvasModel) -> some View {
        Button {
            EaselExporter.presentExportPanel(for: model.easelID, store: env.easelStore)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .orbitTooltip("Export Easel as Image")
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
    }

    private func statusBar(_ model: EaselCanvasModel) -> some View {
        HStack(spacing: 8) {
            Button { zoom(model, by: 1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain)
            Text("\(Int(model.viewportZoom * 100))%").font(.system(size: 10.5)).foregroundStyle(.secondary)
            Button { zoom(model, by: 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain)
            Button("Reset View") {
                withAnimation(OrbitMotion.standard) { model.viewportOrigin = .zero; model.viewportZoom = 1.0 }
                model.persistViewport()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Button("Delete") { model.deleteSelected() }.buttonStyle(.plain).font(.system(size: 10.5))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }

    private func zoom(_ model: EaselCanvasModel, by factor: Double) {
        withAnimation(OrbitMotion.standard) {
            model.viewportZoom = min(3.0, max(0.15, model.viewportZoom * factor))
        }
        model.persistViewport()
    }

    // MARK: - Alignment guides

    @ViewBuilder
    private func alignmentGuideOverlay(_ model: EaselCanvasModel) -> some View {
        if !model.activeGuides.isEmpty {
            Canvas { context, size in
                for guide in model.activeGuides {
                    var path = Path()
                    switch guide.axis {
                    case .vertical:
                        path.move(to: CGPoint(x: guide.position, y: 0))
                        path.addLine(to: CGPoint(x: guide.position, y: size.height))
                    case .horizontal:
                        path.move(to: CGPoint(x: 0, y: guide.position))
                        path.addLine(to: CGPoint(x: size.width, y: guide.position))
                    }
                    context.stroke(
                        path,
                        with: .color(.accentColor.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 1 / max(model.viewportZoom, 0.15), dash: [4, 3])
                    )
                }
            }
            .frame(width: 4000, height: 4000)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func shapePreview(kind: EaselItem.ShapeKind, from start: CGPoint, to end: CGPoint, model: EaselCanvasModel) -> some View {
        let width = EaselCanvasModel.defaultStrokeWidth
        if let geometry = EaselCanvasModel.shapeGeometry(from: start, to: end, lineWidth: width) {
            EaselShapeGeometry.path(
                kind: kind,
                lineWidth: CGFloat(width),
                unitStart: geometry.unitStart,
                unitEnd: geometry.unitEnd,
                in: geometry.frame
            )
            .stroke(
                Color(model.strokeColor.nsColor),
                style: StrokeStyle(lineWidth: CGFloat(width), lineCap: .round, lineJoin: .round)
            )
        }
    }

    // MARK: - Image picker

    private func presentImagePicker(_ model: EaselCanvasModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add to Easel"
        guard panel.runModal() == .OK else { return }

        var offset: CGFloat = 0
        let centre = CGPoint(
            x: (240 - model.viewportOrigin.x) / model.viewportZoom,
            y: (200 - model.viewportOrigin.y) / model.viewportZoom
        )
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            insertImage(data, at: CGPoint(x: centre.x + offset, y: centre.y + offset), model: model)
            offset += 24
        }
    }

    // MARK: - Teardown

    // Commits any half-finished stroke/shape and flushes debounced writes so nothing in progress is lost.
    private func tearDown(_ model: EaselCanvasModel) {
        if isDrawing, currentStrokePoints.count > 1 {
            finishStroke(model)
        } else {
            isDrawing = false
            currentStrokePoints = []
        }
        if model.activeTool.shapeKind != nil, shapeDragStart != nil, let current = shapeDragCurrent {
            finishShape(model, endingAt: current)
        } else {
            shapeDragStart = nil
            shapeDragCurrent = nil
        }
        model.flushPendingTitleEdit()
        model.persistViewport()
    }

    // MARK: - Gestures

    private func backgroundDragGesture(_ model: EaselCanvasModel) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                switch model.activeTool {
                case .select:
                    let delta = CGSize(width: value.translation.width - lastDragTranslation.width, height: value.translation.height - lastDragTranslation.height)
                    model.viewportOrigin.x += delta.width
                    model.viewportOrigin.y += delta.height
                    lastDragTranslation = value.translation
                case .draw:
                    isDrawing = true
                    let point = toCanvasPoint(value.location, model: model)
                    currentStrokePoints.append(point)
                case .ellipse, .rectangle, .arrow:
                    let point = toCanvasPoint(value.location, model: model)
                    if shapeDragStart == nil {
                        shapeDragStart = toCanvasPoint(value.startLocation, model: model)
                    }
                    shapeDragCurrent = point
                case .text, .image, .webCapture:
                    break
                }
            }
            .onEnded { value in
                switch model.activeTool {
                case .select:
                    lastDragTranslation = .zero
                    model.persistViewport()
                case .draw:
                    finishStroke(model)
                case .ellipse, .rectangle, .arrow:
                    finishShape(model, endingAt: toCanvasPoint(value.location, model: model))
                case .text:
                    let point = toCanvasPoint(value.location, model: model)
                    let id = model.addItem(.text(""), frame: CGRect(x: point.x - 80, y: point.y - 16, width: 160, height: 32))
                    newTextEditingID = id
                    model.activeTool = .select
                case .image, .webCapture:
                    break
                }
            }
    }

    private func finishShape(_ model: EaselCanvasModel, endingAt end: CGPoint) {
        defer { shapeDragStart = nil; shapeDragCurrent = nil }
        guard let kind = model.activeTool.shapeKind, let start = shapeDragStart else { return }
        if model.addShape(kind: kind, from: start, to: end) != nil {
            model.activeTool = .select
        }
    }

    private func finishStroke(_ model: EaselCanvasModel) {
        defer { isDrawing = false; currentStrokePoints = [] }
        guard currentStrokePoints.count > 1 else { return }
        let smoothed = EaselCanvasView.smooth(currentStrokePoints)
        let minX = smoothed.map(\.x).min() ?? 0
        let minY = smoothed.map(\.y).min() ?? 0
        let maxX = smoothed.map(\.x).max() ?? 0
        let maxY = smoothed.map(\.y).max() ?? 0
        let frame = CGRect(x: minX - 6, y: minY - 6, width: (maxX - minX) + 12, height: (maxY - minY) + 12)
        let relativePoints = smoothed.map { CGPoint(x: $0.x - frame.origin.x, y: $0.y - frame.origin.y) }
        _ = model.addItem(
            .drawing(points: relativePoints, color: model.strokeColor, width: EaselCanvasModel.defaultStrokeWidth),
            frame: frame
        )
    }

    private static func smooth(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        func pass(_ input: [CGPoint]) -> [CGPoint] {
            var output: [CGPoint] = [input[0]]
            for index in 1..<(input.count - 1) {
                let previous = input[index - 1]
                let current = input[index]
                let next = input[index + 1]
                output.append(CGPoint(x: (previous.x + current.x + next.x) / 3, y: (previous.y + current.y + next.y) / 3))
            }
            output.append(input[input.count - 1])
            return output
        }
        return pass(pass(points))
    }

    // MARK: - Image drag-and-drop

    private func handleImageDrop(provider: NSItemProvider, at point: CGPoint, model: EaselCanvasModel) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                }
                guard let url = resolvedURL, let imageData = try? Data(contentsOf: url) else { return }
                Task { @MainActor in insertImage(imageData, at: point, model: model) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in insertImage(data, at: point, model: model) }
            }
        }
    }

    private func insertImage(_ data: Data, at point: CGPoint, model: EaselCanvasModel) {
        guard let fileName = model.storeImageData(data) else { return }
        let size = NSImage(data: data)?.size ?? CGSize(width: 220, height: 145)
        let aspect = size.width > 0 ? size.height / size.width : 0.66
        let width: CGFloat = 220
        let height = width * aspect
        let frame = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        _ = model.addItem(.image(fileName: fileName), frame: frame)
    }

    private func toCanvasPoint(_ location: CGPoint, model: EaselCanvasModel) -> CGPoint {
        CGPoint(
            x: (location.x - model.viewportOrigin.x) / model.viewportZoom,
            y: (location.y - model.viewportOrigin.y) / model.viewportZoom
        )
    }

    private func handleKey(_ event: NSEvent, model: EaselCanvasModel) -> Bool {
        if event.keyCode == 51 || event.keyCode == 117 { // delete / forward-delete
            guard !model.selection.isEmpty else { return false }
            model.deleteSelected()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }
            return true
        }
        return false
    }
}

private struct EaselGridBackground: View {
    var zoom: Double
    var origin: CGPoint

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 32 * zoom
            guard spacing > 4 else { return }
            let offsetX = origin.x.truncatingRemainder(dividingBy: spacing)
            let offsetY = origin.y.truncatingRemainder(dividingBy: spacing)
            var x = offsetX
            while x < size.width {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.secondary.opacity(0.08)), lineWidth: 1)
                x += spacing
            }
            var y = offsetY
            while y < size.height {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.secondary.opacity(0.08)), lineWidth: 1)
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

struct KeyCaptureView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }

    final class KeyCaptureNSView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            if onKeyDown?(event) != true {
                super.keyDown(with: event)
            }
        }
    }
}
