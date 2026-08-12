import AppKit
import SwiftUI

@MainActor
final class CaptureOverlayWindowController: NSWindowController {
    private let contents: any WebContents
    private let onFinish: () -> Void
    private var viewportCSSSize = CGSize(width: 1280, height: 800)

    init(contents: any WebContents, onFinish: @escaping () -> Void) {
        self.contents = contents
        self.onFinish = onFinish
        let frame = CaptureOverlayWindowController.screenFrame(for: contents.view)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        Task {
            if let raw = try? await contents.evaluateJavaScript("({w: window.innerWidth, h: window.innerHeight})"),
               let dict = raw as? [String: Any],
               let width = (dict["w"] as? NSNumber)?.doubleValue, let height = (dict["h"] as? NSNumber)?.doubleValue,
               width > 0, height > 0 {
                self.viewportCSSSize = CGSize(width: width, height: height)
            }
            let hosting = NSHostingView(rootView: RegionSelectionView(
                contents: self.contents,
                cssSize: self.viewportCSSSize,
                pixelSize: window.frame.size,
                onCancel: { [weak self] in self?.finish() },
                onCommit: { [weak self] image in
                    self?.finish()
                    if let image { CaptureController.finish(image: image, suggestedName: "Region Capture") }
                }
            ))
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func finish() {
        window?.orderOut(nil)
        onFinish()
    }

    private static func screenFrame(for view: NSView) -> NSRect {
        guard let window = view.window else { return NSRect(x: 0, y: 0, width: 800, height: 600) }
        let windowFrame = view.convert(view.bounds, to: nil)
        return window.convertToScreen(windowFrame)
    }
}

private struct RegionSelectionView: View {
    var contents: any WebContents
    var cssSize: CGSize
    var pixelSize: CGSize
    var onCancel: () -> Void
    var onCommit: (NSImage?) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var snappedRect: CGRect?
    @State private var isCapturing = false

    private var isDeveloperModeEnabled: Bool { DeveloperModeSettings.isEnabled }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)

                if let rect = selectionRect {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: rect.width, height: rect.height)
                        .background(
                            Color.white.opacity(0.001)
                        )
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .position(x: rect.midX, y: rect.midY)
                        .blendMode(.normal)
                }

                if isCapturing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        commit(containerSize: proxy.size)
                    }
            )
            .onExitCommand { onCancel() }
            .overlay(alignment: .topTrailing) {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .padding(16)
            }
            .overlay(alignment: .top) {
                Text(isDeveloperModeEnabled ? "Drag to select, or click an element to snap to it. Esc to cancel." : "Drag to select a region. Esc to cancel.")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 16)
            }
        }
    }

    private var selectionRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    private func commit(containerSize: CGSize) {
        guard var rect = selectionRect else { onCancel(); return }
        let isClick = rect.width < 4 && rect.height < 4

        isCapturing = true
        let scaleX = cssSize.width / max(containerSize.width, 1)
        let scaleY = cssSize.height / max(containerSize.height, 1)

        Task {
            if isClick, isDeveloperModeEnabled, let point = dragCurrent {
                let pageX = point.x * scaleX
                let pageY = point.y * scaleY
                if let snapped = await elementRect(atPageX: pageX, pageY: pageY) {
                    rect = CGRect(x: snapped.minX / scaleX, y: snapped.minY / scaleY, width: snapped.width / scaleX, height: snapped.height / scaleY)
                } else {
                    onCancel()
                    return
                }
            }
            guard rect.width > 2, rect.height > 2 else { onCancel(); return }
            let pageRect = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
            let image = await contents.capturePreview(rect: pageRect, size: CGSize(width: pageRect.width, height: pageRect.height))
            onCommit(image)
        }
    }

    private func elementRect(atPageX x: Double, pageY y: Double) async -> CGRect? {
        let script = "(function(){ var el = document.elementFromPoint(\(x), \(y)); if (!el) return null; var r = el.getBoundingClientRect(); return {x:r.left,y:r.top,w:r.width,h:r.height}; })();"
        guard let raw = try? await contents.evaluateJavaScript(script), let dict = raw as? [String: Any],
              let rx = (dict["x"] as? NSNumber)?.doubleValue, let ry = (dict["y"] as? NSNumber)?.doubleValue,
              let rw = (dict["w"] as? NSNumber)?.doubleValue, let rh = (dict["h"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: rx, y: ry, width: rw, height: rh)
    }
}
