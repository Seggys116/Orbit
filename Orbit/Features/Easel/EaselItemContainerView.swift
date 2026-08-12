import SwiftUI

struct EaselItemContainerView: View {
    @Bindable var model: EaselCanvasModel
    var item: EaselItem
    var env: AppEnvironment
    var isSelected: Bool

    @State private var isEditingText = false
    @State private var textDraft: String = ""

    var body: some View {
        EaselItemContentView(model: model, item: item, env: env, isEditingText: $isEditingText, textDraft: $textDraft)
            .frame(width: max(item.frame.width, 1), height: max(item.frame.height, 1))
            .rotationEffect(.degrees(item.rotation))
            .position(x: item.frame.midX, y: item.frame.midY)
            .overlay {
                if isSelected {
                    selectionChrome
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if model.activeTool == .select {
                    model.selection = [item.id]
                }
            }
            .gesture(moveGesture)
            .contextMenu {
                Button("Bring to Front") { model.bringToFront(item.id) }
                Button("Send to Back") { model.sendToBack(item.id) }
                Divider()
                Button("Delete", role: .destructive) {
                    model.selection = [item.id]
                    model.deleteSelected()
                }
            }
            // Without this, an item's move gesture wins the hit test and swallows drawing-tool drags over it.
            .allowsHitTesting(model.activeTool == .select)
            .onDisappear { commitPendingTextEditIfNeeded() }
    }

    private func commitPendingTextEditIfNeeded() {
        guard isEditingText else { return }
        guard model.items.contains(where: { $0.id == item.id }) else {
            isEditingText = false
            return
        }
        model.updateItem(item.id) { current in
            guard case .text = current.content else { return }
            current.content = .text(textDraft)
        }
        isEditingText = false
    }

    private var selectionChrome: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: item.frame.width, height: item.frame.height)
                .position(x: item.frame.width / 2, y: item.frame.height / 2)
                .rotationEffect(.degrees(item.rotation))

            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                resizeHandleView(handle)
            }

            rotateHandleView
        }
        .position(x: item.frame.midX, y: item.frame.midY)
    }

    // MARK: - Move

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("easelCanvasSpace"))
            .onChanged { value in
                guard model.activeTool == .select, isSelected else { return }
                if model.dragOriginFrame[item.id] == nil {
                    model.beginDrag()
                    model.dragOriginFrame[item.id] = item.frame
                }
                guard let origin = model.dragOriginFrame[item.id] else { return }
                let delta = CGSize(width: value.translation.width / model.viewportZoom, height: value.translation.height / model.viewportZoom)
                let proposed = CGRect(
                    origin: CGPoint(x: origin.origin.x + delta.width, y: origin.origin.y + delta.height),
                    size: origin.size
                )
                let snapped = model.snappedFrame(
                    proposed,
                    movingItemID: item.id,
                    threshold: EaselItemContainerView.snapTolerance / model.viewportZoom
                )
                model.updateDuringDrag(item.id) { $0.frame = snapped }
            }
            .onEnded { _ in
                model.dragOriginFrame.removeValue(forKey: item.id)
                model.commitDrag()
            }
    }

    static let snapTolerance: CGFloat = 6 // screen points

    // MARK: - Resize

    private enum ResizeHandle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var alignment: UnitPoint {
            switch self {
            case .topLeft: return .topLeading
            case .topRight: return .topTrailing
            case .bottomLeft: return .bottomLeading
            case .bottomRight: return .bottomTrailing
            }
        }
    }

    private func resizeHandleView(_ handle: ResizeHandle) -> some View {
        let point = anchorPoint(for: handle.alignment)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: 9, height: 9)
            .position(point)
            .gesture(resizeGesture(handle))
    }

    private func anchorPoint(for alignment: UnitPoint) -> CGPoint {
        CGPoint(x: item.frame.width * alignment.x, y: item.frame.height * alignment.y)
    }

    private func resizeGesture(_ handle: ResizeHandle) -> some Gesture {
        DragGesture(coordinateSpace: .named("easelCanvasSpace"))
            .onChanged { value in
                if model.dragOriginFrame[item.id] == nil {
                    model.beginDrag()
                    model.dragOriginFrame[item.id] = item.frame
                }
                guard let origin = model.dragOriginFrame[item.id] else { return }
                let dx = value.translation.width / model.viewportZoom
                let dy = value.translation.height / model.viewportZoom
                var frame = origin
                switch handle {
                case .topLeft:
                    frame.origin.x += dx; frame.origin.y += dy
                    frame.size.width -= dx; frame.size.height -= dy
                case .topRight:
                    frame.origin.y += dy
                    frame.size.width += dx; frame.size.height -= dy
                case .bottomLeft:
                    frame.origin.x += dx
                    frame.size.width -= dx; frame.size.height += dy
                case .bottomRight:
                    frame.size.width += dx; frame.size.height += dy
                }
                frame.size.width = max(24, frame.size.width)
                frame.size.height = max(24, frame.size.height)
                model.updateDuringDrag(item.id) { $0.frame = frame }
            }
            .onEnded { _ in
                model.dragOriginFrame.removeValue(forKey: item.id)
                model.commitDrag()
            }
    }

    // MARK: - Rotate

    private var rotateHandleView: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .position(x: item.frame.width / 2, y: -20)
            .gesture(rotateGesture)
    }

    private var rotateGesture: some Gesture {
        DragGesture(coordinateSpace: .named("easelCanvasSpace"))
            .onChanged { value in
                // Must call beginDrag() like the other gestures, or the rotation is never persisted.
                if model.dragOriginFrame[item.id] == nil {
                    model.beginDrag()
                    model.dragOriginFrame[item.id] = item.frame
                }
                let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
                let vector = CGPoint(x: value.location.x - center.x * model.viewportZoom - model.viewportOrigin.x,
                                      y: value.location.y - center.y * model.viewportZoom - model.viewportOrigin.y)
                let angle = atan2(vector.y, vector.x) * 180 / .pi + 90
                model.updateDuringDrag(item.id) { $0.rotation = angle }
            }
            .onEnded { _ in
                model.dragOriginFrame.removeValue(forKey: item.id)
                model.commitDrag()
            }
    }
}
