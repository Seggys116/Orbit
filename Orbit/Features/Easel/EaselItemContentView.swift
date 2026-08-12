import SwiftUI
import AppKit

struct EaselItemContentView: View {
    @Bindable var model: EaselCanvasModel
    var item: EaselItem
    var env: AppEnvironment
    @Binding var isEditingText: Bool
    @Binding var textDraft: String

    var body: some View {
        switch item.content {
        case .text(let text):
            textView(text)
        case .drawing(let points, let color, let width):
            drawingView(points: points, color: color, width: width)
        case .image(let fileName):
            imageView(fileName: fileName)
        case .liveWebRegion(let url, let selector, let cropRect):
            LiveWebRegionView(model: model, item: item, env: env, url: url, selector: selector, cropRect: cropRect)
        case .link(let url, let title):
            linkView(url: url, title: title)
        case .shape(let kind, let color, let lineWidth, let unitStart, let unitEnd):
            shapeView(kind: kind, color: color, lineWidth: lineWidth, unitStart: unitStart, unitEnd: unitEnd)
        }
    }

    // MARK: - Shapes

    private func shapeView(
        kind: EaselItem.ShapeKind,
        color: ThemeColor,
        lineWidth: Double,
        unitStart: CGPoint,
        unitEnd: CGPoint
    ) -> some View {
        Canvas { context, size in
            let path = EaselShapeGeometry.path(
                kind: kind,
                lineWidth: CGFloat(lineWidth),
                unitStart: unitStart,
                unitEnd: unitEnd,
                in: CGRect(origin: .zero, size: size)
            )
            context.stroke(
                path,
                with: .color(Color(color.nsColor)),
                style: StrokeStyle(lineWidth: CGFloat(lineWidth), lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: max(item.frame.width, 1), height: max(item.frame.height, 1))
    }

    // MARK: - Text

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        if isEditingText {
            VStack(spacing: 4) {
                TextEditor(text: $textDraft)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                Button("Done") { commitText() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.4)))
            .onAppear { textDraft = text }
        } else {
            Text(text.isEmpty ? "Double-click to edit" : text)
                .font(.system(size: 14))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.18)))
                .onTapGesture(count: 2) {
                    textDraft = text
                    isEditingText = true
                }
        }
    }

    private func commitText() {
        model.updateItem(item.id) { current in
            current.content = .text(textDraft)
        }
        isEditingText = false
    }

    // MARK: - Drawing

    private func drawingView(points: [CGPoint], color: ThemeColor, width: Double) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(Color(color.nsColor), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        .frame(width: item.frame.width, height: item.frame.height)
    }

    // MARK: - Image

    private func imageView(fileName: String) -> some View {
        Group {
            if let data = model.imageData(fileName: fileName), let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Link

    private func linkView(url: URL, title: String) -> some View {
        Button {
            openSourceURL(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "link")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? (url.host() ?? url.absoluteString) : title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(url.absoluteString).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
    }

    private func openSourceURL(_ url: URL) {
        guard let spaceID = env.activeSpace?.id else { return }
        env.openTab(url: url, in: spaceID)
    }
}

private struct LiveWebRegionView: View {
    @Bindable var model: EaselCanvasModel
    var item: EaselItem
    var env: AppEnvironment
    var url: URL
    var selector: String?
    var cropRect: CGRect

    @State private var image: NSImage?

    var body: some View {
        Button {
            guard let spaceID = env.activeSpace?.id else { return }
            env.openTab(url: url, in: spaceID)
        } label: {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    ProgressView().controlSize(.small)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(url.host() ?? url.absoluteString)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .task(id: url) { await refresh() }
    }

    private func refresh() async {
        if let cached = model.cachedWebRegionSnapshot(itemID: item.id) {
            image = cached
        }
        guard let liveContents = env.webContents.values.first(where: { $0.navigationState.url?.host() == url.host() && $0.navigationState.url?.path == url.path }) else {
            return
        }
        if let captured = await liveContents.capturePreview(rect: cropRect, size: CGSize(width: max(item.frame.width, 60), height: max(item.frame.height, 40))) {
            image = captured
            model.cacheWebRegionSnapshot(itemID: item.id, image: captured)
        }
    }
}
