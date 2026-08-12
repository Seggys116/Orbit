import SwiftUI
import AppKit

struct EaselWebCaptureSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: EaselCanvasModel
    var onDone: () -> Void

    @State private var selectedTabID: TabID?
    @State private var previewImage: NSImage?
    @State private var viewportCSSSize: CGSize = CGSize(width: 1280, height: 800)
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var isCapturing = false

    private var openTabs: [(TabID, Tab)] {
        env.webContents.keys.compactMap { id in env.tab(id).map { (id, $0) } }
            .sorted { $0.1.lastAccessedAt > $1.1.lastAccessedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Capture from Page").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { onDone() }
            }
            .padding(14)
            Divider()

            HStack(spacing: 0) {
                List(openTabs, id: \.0, selection: $selectedTabID) { id, tab in
                    HStack {
                        FaviconView(url: tab.faviconURL, host: tab.url.host() ?? "")
                            .frame(width: 14, height: 14)
                        Text(tab.displayTitle).font(.system(size: 12)).lineLimit(1)
                    }
                    .tag(id)
                }
                .frame(width: 220)
                .onChange(of: selectedTabID) { _, newValue in
                    guard let newValue else { return }
                    Task { await loadPreview(for: newValue) }
                }

                Divider()

                captureArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 480)
        .onAppear { selectedTabID = env.activeTabID ?? openTabs.first?.0 }
    }

    @ViewBuilder
    private var captureArea: some View {
        if let previewImage {
            GeometryReader { proxy in
                let displaySize = fittedSize(image: previewImage, in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.05)
                    Image(nsImage: previewImage)
                        .resizable()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                    if let rect = selectionRect(displaySize: displaySize, containerSize: proxy.size) {
                        Rectangle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(Rectangle().fill(Color.accentColor.opacity(0.15)))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .local)
                        .onChanged { value in
                            if dragStart == nil { dragStart = value.startLocation }
                            dragCurrent = value.location
                        }
                        .onEnded { _ in }
                )
                .overlay(alignment: .bottom) {
                    HStack {
                        Text(dragStart == nil ? "Drag to select a region" : "Release, then Capture")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Capture") { commitCapture(displaySize: displaySize, containerSize: proxy.size) }
                            .buttonStyle(.borderedProminent)
                            .disabled(dragStart == nil || dragCurrent == nil || isCapturing)
                    }
                    .padding(10)
                }
            }
            .padding(12)
        } else {
            VStack {
                ProgressView()
                Text("Loading preview…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fittedSize(image: NSImage, in container: CGSize) -> CGSize {
        let availableHeight = container.height - 40
        let scale = min(container.width / image.size.width, availableHeight / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func selectionRect(displaySize: CGSize, containerSize: CGSize) -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    private func loadPreview(for tabID: TabID) async {
        previewImage = nil
        dragStart = nil
        dragCurrent = nil
        guard let contents = env.webContents[tabID] else { return }
        if let sizeResult = try? await contents.evaluateJavaScript("({w: window.innerWidth, h: window.innerHeight})"),
           let dict = sizeResult as? [String: Any],
           let width = (dict["w"] as? NSNumber)?.doubleValue, let height = (dict["h"] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            viewportCSSSize = CGSize(width: width, height: height)
        }
        let targetSize = CGSize(width: 900, height: 900 * viewportCSSSize.height / viewportCSSSize.width)
        previewImage = await contents.capturePreview(rect: nil, size: targetSize)
    }

    private func commitCapture(displaySize: CGSize, containerSize: CGSize) {
        guard let tabID = selectedTabID, let contents = env.webContents[tabID],
              let tab = env.tab(tabID), let rect = selectionRect(displaySize: displaySize, containerSize: containerSize) else { return }
        isCapturing = true

        let imageOriginX = (containerSize.width - displaySize.width) / 2
        let imageOriginY = (containerSize.height - displaySize.height) / 2 - 20
        let localRect = CGRect(x: rect.minX - imageOriginX, y: rect.minY - imageOriginY, width: rect.width, height: rect.height)
            .intersection(CGRect(origin: .zero, size: displaySize))
        guard localRect.width > 4, localRect.height > 4 else { isCapturing = false; return }

        let scaleX = viewportCSSSize.width / displaySize.width
        let scaleY = viewportCSSSize.height / displaySize.height
        let pageCropRect = CGRect(
            x: localRect.minX * scaleX, y: localRect.minY * scaleY,
            width: localRect.width * scaleX, height: localRect.height * scaleY
        )

        let aspect = pageCropRect.height / max(pageCropRect.width, 1)
        let canvasWidth: CGFloat = 320
        let canvasCenter = CGPoint(
            x: (-model.viewportOrigin.x + 240) / model.viewportZoom,
            y: (-model.viewportOrigin.y + 200) / model.viewportZoom
        )
        let frame = CGRect(x: canvasCenter.x, y: canvasCenter.y, width: canvasWidth, height: canvasWidth * aspect)

        let sourceURL = contents.navigationState.url ?? tab.url
        let itemID = model.addItem(.liveWebRegion(url: sourceURL, selector: nil, cropRect: pageCropRect), frame: frame)

        Task {
            if let cropped = await contents.capturePreview(rect: pageCropRect, size: CGSize(width: canvasWidth, height: canvasWidth * aspect)) {
                model.cacheWebRegionSnapshot(itemID: itemID, image: cropped)
            }
            await MainActor.run { isCapturing = false; onDone() }
        }
    }
}
