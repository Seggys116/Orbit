import SwiftUI

enum OrbitWindowCoordinateSpace {
    static let name = "orbit.window"
}

// Falls back to its own bounds when the window coordinate space can't be resolved.
struct WindowSlicedThemeBackground: View {
    var theme: SpaceTheme
    var blur: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.bounds(of: .named(OrbitWindowCoordinateSpace.name))

            ThemeBackgroundView(theme: theme, blur: blur)
                .frame(
                    width: window?.width ?? proxy.size.width,
                    height: window?.height ?? proxy.size.height
                )
                .offset(x: window?.minX ?? 0, y: window?.minY ?? 0)
        }
        .clipped() // the painted gradient is deliberately larger than this view
        .allowsHitTesting(false)
    }
}

struct ThemeBackgroundView: View {
    var theme: SpaceTheme
    var blur: Double = 0 // 0...1 gradient softness, from the theme editor's blur slider

    @Environment(\.colorScheme) private var colorScheme
    @State private var displayedTheme: SpaceTheme
    @State private var previousTheme: SpaceTheme?
    @State private var crossfadeProgress: Double = 1

    init(theme: SpaceTheme, blur: Double = 0) {
        self.theme = theme
        self.blur = blur
        _displayedTheme = State(initialValue: theme)
    }

    var body: some View {
        ZStack {
            if let previousTheme, crossfadeProgress < 0.999 {
                layer(for: previousTheme).opacity(1 - crossfadeProgress)
            }
            layer(for: displayedTheme).opacity(crossfadeProgress)
        }
        .ignoresSafeArea()
        .onChange(of: theme) { oldValue, newValue in
            previousTheme = oldValue
            displayedTheme = newValue
            crossfadeProgress = 0
            withAnimation(OrbitMotion.dramatic) { crossfadeProgress = 1 }
        }
        #if DEBUG
        .onAppear { ThemeSelfCheck.runOnce() }
        #endif
    }

    @ViewBuilder
    private func layer(for theme: SpaceTheme) -> some View {
        ZStack {
            ThemePaintView(theme: theme, colorScheme: colorScheme)
                .blur(radius: CGFloat(blur * 46))
            GrainOverlay(opacity: theme.grain, isDarkSurface: theme.isDarkSurface(for: colorScheme))
        }
    }
}

struct ThemePaintView: View {
    var theme: SpaceTheme
    var colorScheme: ColorScheme

    private var colors: [Color] {
        let adapted = theme.adaptedColors(for: colorScheme)
        return adapted.isEmpty ? [Color.gray] : adapted
    }

    var body: some View {
        switch theme.style {
        case .solid:
            colors[0]
        case .linear:
            LinearGradient(
                colors: colors.count > 1 ? colors : [colors[0], colors[0].opacity(0.7)],
                startPoint: rotatedStart(angle: theme.angle),
                endPoint: rotatedEnd(angle: theme.angle)
            )
        case .mesh:
            if colors.count >= 2 {
                MeshGradient(width: 3, height: 3, points: meshPoints(seed: theme.meshSeed), colors: meshColors(colors))
            } else {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private func rotatedStart(angle: Double) -> UnitPoint {
        let radians = (angle - 90) * .pi / 180
        return UnitPoint(x: 0.5 - cos(radians) * 0.6, y: 0.5 - sin(radians) * 0.6)
    }

    private func rotatedEnd(angle: Double) -> UnitPoint {
        let radians = (angle - 90) * .pi / 180
        return UnitPoint(x: 0.5 + cos(radians) * 0.6, y: 0.5 + sin(radians) * 0.6)
    }

    // Corners never jitter and edges only jitter tangentially, so the mesh always fully covers the view with no seam.
    private func meshPoints(seed: UInt64) -> [SIMD2<Float>] {
        var generator = SeededGenerator(seed: seed)
        func tangentJitter() -> Float { Float.random(in: -0.14...0.14, using: &generator) }
        func centerJitter() -> Float { Float.random(in: -0.12...0.12, using: &generator) }

        // Row-major, 3 columns x 3 rows: index = row * 3 + col.
        return [
            SIMD2(0, 0), SIMD2(0.5 + tangentJitter(), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + tangentJitter()), SIMD2(0.5 + centerJitter(), 0.5 + centerJitter()), SIMD2(1, 0.5 + tangentJitter()),
            SIMD2(0, 1), SIMD2(0.5 + tangentJitter(), 1), SIMD2(1, 1),
        ]
    }

    // Falls back to plain cycling when stopPositions isn't set for colors.
    func meshColors(_ colors: [Color]) -> [Color] {
        guard
            let positions = theme.stopPositions,
            positions.count == colors.count,
            colors.count >= 2
        else {
            return (0..<9).map { colors[$0 % colors.count] }
        }

        // Avoids divide-by-zero when a grid point lands exactly on a stop.
        let softening = 0.02

        let components = colors.map(\.srgbComponents)

        return (0..<9).map { index in
            let point = (x: Double(index % 3) / 2, y: Double(index / 3) / 2)

            let weights = positions.map { stop -> Double in
                let dx = point.x - stop.x
                let dy = point.y - stop.y
                let distanceSquared = dx * dx + dy * dy
                return 1 / (distanceSquared + softening)
            }
            let totalWeight = weights.reduce(0, +)

            var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
            for (component, weight) in zip(components, weights) {
                let normalized = weight / totalWeight
                red += component.red * normalized
                green += component.green * normalized
                blue += component.blue * normalized
                alpha += component.alpha * normalized
            }

            return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
        }
    }
}

extension SpaceTheme {
    private static let legacyDefaultPalette: [ThemeColor] = [
        ThemeColor(red: 0.36, green: 0.42, blue: 0.95),
        ThemeColor(red: 0.62, green: 0.38, blue: 0.92),
        ThemeColor(red: 0.94, green: 0.47, blue: 0.66),
    ]

    // Migrates the old vivid default to the new dark one at display time, rather than rewriting state.json.
    var resolvedPalette: [ThemeColor] {
        colors == SpaceTheme.legacyDefaultPalette ? SpaceTheme.defaultPalette : colors
    }

    var meshSeed: UInt64 {
        var hasher = Hasher()
        hasher.combine(resolvedPalette)
        hasher.combine(angle)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    func adaptedColors(for scheme: ColorScheme) -> [Color] {
        let base = resolvedPalette.map { Color($0.nsColor) }
        guard followsSystemAppearance else { return base }
        switch scheme {
        case .dark:
            return base.map { $0.blended(with: .black, fraction: 0.04) }
        default:
            return base.map { $0.blended(with: .white, fraction: 0.06) }
        }
    }

    var isDarkSurface: Bool {
        (resolvedPalette.first ?? SpaceTheme.defaultPalette[0]).luminance <= 0.55
    }

    // As isDarkSurface, but against the painted (appearance-adapted) surface.
    func isDarkSurface(for scheme: ColorScheme) -> Bool {
        guard let first = adaptedColors(for: scheme).first else { return isDarkSurface }
        return first.approximateLuminance <= 0.55
    }

    var readableForeground: Color {
        isDarkSurface ? Color.white.opacity(0.90) : Color.black.opacity(0.82)
    }

    var readableSecondaryForeground: Color {
        isDarkSurface ? Color.white.opacity(0.55) : Color.black.opacity(0.50)
    }
}

extension Color {
    func blended(with other: Color, fraction: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = CGFloat(fraction)
        return Color(
            red: Double(a.redComponent * (1 - t) + b.redComponent * t),
            green: Double(a.greenComponent * (1 - t) + b.greenComponent * t),
            blue: Double(a.blueComponent * (1 - t) + b.blueComponent * t),
            opacity: Double(a.alphaComponent)
        )
    }

    var approximateLuminance: Double {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return 0.2126 * Double(rgb.redComponent) + 0.7152 * Double(rgb.greenComponent) + 0.0722 * Double(rgb.blueComponent)
    }

    var srgbComponents: (red: Double, green: Double, blue: Double, alpha: Double) {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return (
            Double(rgb.redComponent),
            Double(rgb.greenComponent),
            Double(rgb.blueComponent),
            Double(rgb.alphaComponent)
        )
    }
}

// Tiny deterministic RNG so mesh jitter is stable per-theme.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
