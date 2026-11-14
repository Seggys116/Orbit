// With the device toolbar on, the page is laid out at the device's CSS size and scaled to fit or to a fixed zoom.

import AppKit
import SwiftUI

struct OrbitDeviceViewport<Page: View>: View {
    var model: OrbitInspectDeviceModel
    @ViewBuilder var page: () -> Page

    var body: some View {
        if model.isActive {
            OrbitDeviceStage(model: model, page: page)
        } else {
            page()
        }
    }
}

private struct OrbitDeviceStage<Page: View>: View {
    var model: OrbitInspectDeviceModel
    var page: () -> Page

    var body: some View {
        GeometryReader { geo in
            let layout = model.layout(in: geo.size)
            ScrollView([.horizontal, .vertical]) {
                framed(layout)
                    .padding(.top, OrbitDeviceLayout.inset + OrbitDeviceLayout.readoutHeight)
                    .padding([.horizontal, .bottom], OrbitDeviceLayout.inset)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            // Only a zoom above fit can outgrow the stage, and only then should a drag pan it.
            .scrollDisabled(!layout.overflows(stage: geo.size))
            .background(InspectChrome.surface)
            .overlay(alignment: .top) { readout(layout) }
            .onAppear { model.reportScale(layout.scale) }
            .onChange(of: layout.scale) { _, scale in model.reportScale(scale) }
        }
        .background(InspectChrome.background)
    }

    private func framed(_ layout: OrbitDeviceLayout) -> some View {
        let frame = layout.frame
        let grip = OrbitDeviceLayout.gripSpace
        return ZStack(alignment: .topLeading) {
            page()
                .frame(width: layout.content.width, height: layout.content.height)
                .scaleEffect(layout.scale, anchor: .topLeading)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipped()
                .background(
                    // The shadow sits on a plain backing, not on the page, so it never rasterises the web view.
                    Rectangle()
                        .fill(InspectChrome.panel)
                        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 3)
                )
                .overlay(Rectangle().strokeBorder(InspectChrome.hairline, lineWidth: 1).allowsHitTesting(false))

            handle(.right)
                .frame(width: grip, height: frame.height)
                .offset(x: frame.width)
            handle(.bottom)
                .frame(width: frame.width, height: grip)
                .offset(y: frame.height)
            handle(.corner)
                .frame(width: grip, height: grip)
                .offset(x: frame.width, y: frame.height)
        }
        .frame(width: frame.width + grip, height: frame.height + grip, alignment: .topLeading)
    }

    private func handle(_ handle: OrbitDeviceResizeHandle) -> some View {
        OrbitDeviceGripHandle(handle: handle)
            .overlay(
                OrbitDeviceGrip(
                    handle: handle,
                    onBegan: { model.beginResize() },
                    onDrag: { model.dragResize(translation: $0, handle: handle) },
                    onEnd: { model.endResize() }
                )
            )
            .orbitTooltip(Self.tooltip(for: handle))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(for: handle))
            .accessibilityHint("Drag to resize, or edit the size in the device toolbar")
    }

    private static func label(for handle: OrbitDeviceResizeHandle) -> String {
        switch handle {
        case .right: "Resize viewport width"
        case .bottom: "Resize viewport height"
        case .corner: "Resize viewport width and height"
        }
    }

    private static func tooltip(for handle: OrbitDeviceResizeHandle) -> String {
        switch handle {
        case .right: "Drag to change the width"
        case .bottom: "Drag to change the height"
        case .corner: "Drag to change the width and height"
        }
    }

    /// "402 x 874   67%   DPR 3, touch, emulated (JS)". Drops the trailing parts before it would clip.
    private func readout(_ layout: OrbitDeviceLayout) -> some View {
        let settings = model.settings
        let size = OrbitDeviceFormat.sizeText(width: settings.width, height: settings.height)
        let percent = OrbitDeviceFormat.percentText(layout.scale)
        let emulation = OrbitDeviceFormat.emulationSummary(for: settings)
        let full = emulation.isEmpty ? "\(size)   \(percent)" : "\(size)   \(percent)   \(emulation)"
        return ViewThatFits(in: .horizontal) {
            readoutText(full)
            readoutText("\(size)   \(percent)")
            readoutText(size)
        }
        .frame(height: OrbitDeviceLayout.readoutHeight)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Viewport \(full)")
    }

    private func readoutText(_ text: String) -> some View {
        Text(text)
            .font(InspectChrome.monoSmall)
            .foregroundStyle(InspectChrome.muted)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// What a handle looks like. The grip view above it takes the clicks.
private struct OrbitDeviceGripHandle: View {
    var handle: OrbitDeviceResizeHandle

    @State private var hovering = false

    var body: some View {
        ZStack {
            switch handle {
            case .right: Capsule().frame(width: 4, height: 36)
            case .bottom: Capsule().frame(width: 36, height: 4)
            case .corner: RoundedRectangle(cornerRadius: 2, style: .continuous).frame(width: 8, height: 8)
            }
        }
        .foregroundStyle(hovering ? InspectChrome.accent : InspectChrome.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: hovering)
    }
}

/// AppKit like the inspector's other resize handles, so the first click drags instead of focusing the window.
private struct OrbitDeviceGrip: NSViewRepresentable {
    var handle: OrbitDeviceResizeHandle
    var onBegan: () -> Void
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> OrbitDeviceGripView {
        let view = OrbitDeviceGripView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: OrbitDeviceGripView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: OrbitDeviceGripView) {
        if view.handle != handle {
            view.handle = handle
            view.window?.invalidateCursorRects(for: view)
        }
        view.onBegan = onBegan
        view.onDrag = onDrag
        view.onEnd = onEnd
    }
}

final class OrbitDeviceGripView: NSView {
    var handle: OrbitDeviceResizeHandle = .corner
    var onBegan: () -> Void = {}
    /// Screen points moved since the press, positive right and down.
    var onDrag: (CGSize) -> Void = { _ in }
    var onEnd: () -> Void = {}

    private var startPoint: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        onBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        report(event)
    }

    override func mouseUp(with event: NSEvent) {
        report(event)
        startPoint = nil
        onEnd()
    }

    private func report(_ event: NSEvent) {
        guard let startPoint else { return }
        let point = event.locationInWindow
        // Window coordinates grow upward; the viewport grows downward.
        onDrag(CGSize(width: point.x - startPoint.x, height: startPoint.y - point.y))
    }

    private var cursor: NSCursor {
        switch handle {
        case .right: return .resizeLeftRight
        case .bottom: return .resizeUpDown
        case .corner:
            if #available(macOS 15, *) {
                return NSCursor.frameResize(position: .bottomRight, directions: .all)
            }
            return .crosshair
        }
    }
}
