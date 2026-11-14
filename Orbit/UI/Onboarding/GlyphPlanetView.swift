import AppKit
import SwiftUI

/// A live dithered glyph planet (Shaders/GlyphPlanet.metal colorEffect, shipped as GlyphPlanet.metallib); Reduce Motion freezes spin and twinkle and snaps changes, and the timeline pauses while the window is occluded or minimised.
struct GlyphPlanetView: View {
    var palette: GlyphPlanetPalette
    var tiltDegrees: Double
    var bands: Double
    var fill: Double
    var spinRate: Double = 0.16

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWindowVisible = true

    var body: some View {
        // Light appearance is the site's "ink" mode: dark glyphs printed on paper.
        let ink = colorScheme == .light
        let colors = palette.resolved(ink: ink)
        let params = GlyphPlanetParams(
            night: colors.night,
            lit: colors.lit,
            tilt: tiltDegrees * .pi / 180,
            fill: min(max(fill, 0), 1),
            bands: bands
        )
        GlyphPlanetCanvas(
            params: params,
            ink: ink,
            spinRate: spinRate,
            isAnimating: isWindowVisible && !reduceMotion
        )
        .orbitAnimation(OrbitMotion.dramatic, value: params)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .accessibilityHidden(true)
    }
}

/// Accumulates time only while animation runs, so the planet resumes where it paused.
private final class ActiveClock {
    private var banked: TimeInterval = 0
    private var runStart: Date?

    func elapsed(at date: Date, running: Bool) -> TimeInterval {
        if running {
            let start = runStart ?? date
            runStart = start
            return banked + date.timeIntervalSince(start)
        }
        if let start = runStart {
            banked += date.timeIntervalSince(start)
            runStart = nil
        }
        return banked
    }
}

// Animatable so the spring interpolates `params` every frame and re-evaluates this body with the in-between values.
private struct GlyphPlanetCanvas: View, Animatable {
    var params: GlyphPlanetParams
    let ink: Bool
    let spinRate: Double
    let isAnimating: Bool

    // The pose Reduce Motion freezes on, and where the live clock starts so the first frame matches it.
    private static let restingTime = 40.0

    @State private var clock = ActiveClock()

    var animatableData: GlyphPlanetParams {
        get { params }
        set { params = newValue }
    }

    private static let shaderLibrary: ShaderLibrary? = {
        guard let url = Bundle.main.url(forResource: "GlyphPlanet", withExtension: "metallib") else { return nil }
        return ShaderLibrary(url: url)
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { context in
            let time = Self.restingTime + clock.elapsed(at: context.date, running: isAnimating)
            let values = params
            let inkFlag: Float = ink ? 1 : 0
            let spin = Float(spinRate)
            let backdrop = Rectangle().fill(OrbitNeutral.bg)
            if let library = Self.shaderLibrary {
                backdrop.visualEffect { content, proxy in
                    content.colorEffect(
                        library.glyphPlanet(
                            .float2(proxy.size),
                            .float(Float(time)),
                            .float(spin),
                            .float(Float(values.tilt)),
                            .float(Float(values.bands)),
                            .float(Float(values.fill)),
                            .float(1),
                            .float(inkFlag),
                            .float3(Float(values.night.x), Float(values.night.y), Float(values.night.z)),
                            .float3(Float(values.lit.x), Float(values.lit.y), Float(values.lit.z))
                        )
                    )
                }
            } else {
                backdrop
            }
        }
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> WindowVisibilityProbeView {
        let view = WindowVisibilityProbeView()
        view.onChange = { visible in
            Task { @MainActor in
                if isVisible != visible { isVisible = visible }
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityProbeView, context: Context) {}
}

private final class WindowVisibilityProbeView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            observers.append(token)
        }
        report()
    }

    private func report() {
        guard let window else { return }
        onChange(window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }

    private func removeObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }
}
