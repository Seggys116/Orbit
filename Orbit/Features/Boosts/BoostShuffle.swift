import Foundation

public enum BoostShuffle {

    // MARK: - Entry points

    public static func shuffled<G: RandomNumberGenerator>(
        _ boost: Boost,
        fontCandidates: [String],
        using generator: inout G
    ) -> Boost {
        var result = boost
        let palette = randomPalette(using: &generator)
        result.backgroundColor = palette.background
        result.textColor = palette.text
        result.accentColor = palette.accent
        if let font = fontCandidates.randomElement(using: &generator) {
            result.fontFamily = font
        }
        return result
    }

    public static func shuffled(_ boost: Boost, fontCandidates: [String]) -> Boost {
        var generator = SystemRandomNumberGenerator()
        return shuffled(boost, fontCandidates: fontCandidates, using: &generator)
    }

    // MARK: - The palette

    public struct Palette: Equatable, Sendable {
        public var background: ThemeColor
        public var text: ThemeColor
        public var accent: ThemeColor
    }

    public static let minimumContrastRatio: Double = 3.0

    private static let accentHueOffsets: [Double] = [180, 120, -120, 30, -30]

    public static func randomPalette<G: RandomNumberGenerator>(using generator: inout G) -> Palette {
        let hue = Double.random(in: 0..<360, using: &generator)
        let isDarkCanvas = Bool.random(using: &generator)

        let backgroundSaturation = Double.random(in: 0.08...0.45, using: &generator)
        let backgroundLightness = isDarkCanvas
            ? Double.random(in: 0.06...0.20, using: &generator)
            : Double.random(in: 0.88...0.98, using: &generator)
        let background = hsl(hue, backgroundSaturation, backgroundLightness)

        let textHue = wrapHue(hue + Double.random(in: -20...20, using: &generator))
        let textSaturation = Double.random(in: 0.05...0.55, using: &generator)

        var text = background
        var lightness = isDarkCanvas
            ? Double.random(in: 0.80...0.96, using: &generator)
            : Double.random(in: 0.06...0.24, using: &generator)
        for _ in 0..<12 {
            text = hsl(textHue, textSaturation, lightness)
            if contrastRatio(background, text) >= minimumContrastRatio { break }
            lightness = isDarkCanvas ? min(1.0, lightness + 0.06) : max(0.0, lightness - 0.06)
        }

        let accentHue = wrapHue(hue + (accentHueOffsets.randomElement(using: &generator) ?? 180))
        let accent = hsl(
            accentHue,
            Double.random(in: 0.55...0.95, using: &generator),
            isDarkCanvas
                ? Double.random(in: 0.55...0.72, using: &generator)
                : Double.random(in: 0.34...0.52, using: &generator)
        )

        return Palette(background: background, text: text, accent: accent)
    }

    // MARK: - Colour maths

    // Not ThemeColor.luminance (perceived-brightness approximation); this is WCAG's gamma-corrected relative luminance.
    public static func relativeLuminance(_ color: ThemeColor) -> Double {
        func linear(_ channel: Double) -> Double {
            let c = max(0, min(1, channel))
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    public static func contrastRatio(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    public static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> ThemeColor {
        let h = wrapHue(hue) / 360.0
        let s = max(0, min(1, saturation))
        let l = max(0, min(1, lightness))

        guard s > 0 else { return ThemeColor(red: l, green: l, blue: l) }

        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q

        func component(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2.0 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }

        return ThemeColor(
            red: component(h + 1.0 / 3.0),
            green: component(h),
            blue: component(h - 1.0 / 3.0)
        )
    }

    private static func wrapHue(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}
