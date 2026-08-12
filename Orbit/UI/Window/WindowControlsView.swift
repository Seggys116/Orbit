import AppKit
import SwiftUI

// MARK: - Metrics

enum OrbitWindowControlMetrics {
    static let diameter: CGFloat = OrbitMetrics.trafficLightDiameter
    static let spacing: CGFloat = OrbitMetrics.trafficLightSpacing
    static let leadingInset: CGFloat = OrbitMetrics.trafficLightLeadingInset
    static let clusterWidth: CGFloat = diameter * 3 + spacing * 2
    static let topInset: CGFloat = OrbitMetrics.trafficLightTopInset
}

// MARK: - Actions

struct WindowControlActions {
    var windowProvider: () -> NSWindow?

    static let noop = WindowControlActions(windowProvider: { nil })

    func close() { windowProvider()?.performClose(nil) }
    func miniaturize() { windowProvider()?.performMiniaturize(nil) }
    func zoom() { windowProvider()?.performZoom(nil) }
}

// MARK: - Cluster (pure, testable rendering)

struct WindowControlsCluster: View {
    var isKey: Bool
    var isHovering: Bool
    var actions: WindowControlActions = .noop

    static let closeColor = Color(red: 1.0, green: 0.373, blue: 0.341)      // #FF5F57
    static let minimizeColor = Color(red: 0.996, green: 0.737, blue: 0.180) // #FEBC2E
    static let zoomColor = Color(red: 0.157, green: 0.784, blue: 0.251)     // #28C840
    static let inactiveColor = Color(red: 0.55, green: 0.55, blue: 0.53)

    var body: some View {
        HStack(spacing: OrbitWindowControlMetrics.spacing) {
            dot(color: WindowControlsCluster.closeColor, glyph: "xmark", help: "Close", action: actions.close)
            dot(color: WindowControlsCluster.minimizeColor, glyph: "minus", help: "Minimize", action: actions.miniaturize)
            dot(color: WindowControlsCluster.zoomColor, glyph: "plus", help: "Zoom", action: actions.zoom)
        }
        .frame(width: OrbitWindowControlMetrics.clusterWidth, height: OrbitWindowControlMetrics.diameter, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func dot(color: Color, glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isKey ? color : WindowControlsCluster.inactiveColor)
                if isHovering {
                    Image(systemName: glyph)
                        .font(.system(size: OrbitWindowControlMetrics.diameter * 0.6, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: OrbitWindowControlMetrics.diameter, height: OrbitWindowControlMetrics.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .orbitTooltip(help)
    }
}

// MARK: - Live view (wires the cluster to the real hosting window)

struct WindowControlsView: View {
    var windowProvider: () -> NSWindow? = { NSApp.keyWindow }

    @State private var hostedWindow: NSWindow?
    @State private var isKey = true
    @State private var isHovering = false

    var body: some View {
        WindowControlsCluster(
            isKey: isKey,
            isHovering: isHovering,
            actions: WindowControlActions(windowProvider: { hostedWindow ?? windowProvider() })
        )
        .onHover { hovering in isHovering = hovering }
        .background(
            // Must stay 0x0: without it, an off-screen ImageRenderer paints this representable as a solid band across the cluster's full bounds, merging the dots into one pill.
            WindowKeyStateReader(window: $hostedWindow, isKey: $isKey)
                .frame(width: 0, height: 0)
        )
    }
}

private struct WindowKeyStateReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    @Binding var isKey: Bool

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onWindowChange = { newWindow in
            window = newWindow
            isKey = newWindow?.isKeyWindow ?? true
        }
        view.onKeyChange = { key in isKey = key }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {}

    final class ObservingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        var onKeyChange: ((Bool) -> Void)?
        private var becomeKeyObserver: NSObjectProtocol?
        private var resignKeyObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            onWindowChange?(window)
            guard let window else { return }
            becomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onKeyChange?(true) }
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onKeyChange?(false) }
        }

        private func removeObservers() {
            if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
            becomeKeyObserver = nil
            resignKeyObserver = nil
        }

        deinit {
            if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        }
    }
}
