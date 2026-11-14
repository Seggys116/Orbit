import Foundation
import SwiftUI
import simd

// Pure colour and interpolation maths for GlyphPlanetView, free of views and AppKit so it can be unit tested on its own.

nonisolated struct PlanetColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6
        let fraction = h - Double(Int(h))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 1e-9 else { return (0, 0, maximum) }
        var hue: Double
        if maximum == red {
            hue = (green - blue) / delta
        } else if maximum == green {
            hue = 2 + (blue - red) / delta
        } else {
            hue = 4 + (red - green) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maximum, maximum)
    }


    private static func toLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func fromLinear(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    var oklab: SIMD3<Double> {
        let r = Self.toLinear(red)
        let g = Self.toLinear(green)
        let b = Self.toLinear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(
            0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        )
    }

    init(oklab lab: SIMD3<Double>) {
        var l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        var m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        var s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        l = l * l * l
        m = m * m * m
        s = s * s * s
        self.init(
            red: Self.fromLinear(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: Self.fromLinear(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: Self.fromLinear(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }

    var relativeLuminance: Double {
        0.2126 * Self.toLinear(red) + 0.7152 * Self.toLinear(green) + 0.0722 * Self.toLinear(blue)
    }
}

nonisolated struct GlyphPlanetPalette: Equatable, Sendable {
    var night: PlanetColor
    var lit: PlanetColor

    static let violet = GlyphPlanetPalette(night: PlanetColor(hex: 0x2A1F4D), lit: PlanetColor(hex: 0xB49CFF))
    static let amber = GlyphPlanetPalette(night: PlanetColor(hex: 0x3A2412), lit: PlanetColor(hex: 0xE7C48A))
    static let cyan = GlyphPlanetPalette(night: PlanetColor(hex: 0x12324A), lit: PlanetColor(hex: 0x7EE7FF))

    /// Space themes are deliberately dark, so the hue of `color` is kept and the brightness rebuilt: a vivid lit tone and a deep shadow tone.
    static func tinted(by color: PlanetColor) -> GlyphPlanetPalette {
        let source = color.hsb
        let saturation = min(max(source.saturation, 0.45), 0.85)
        return GlyphPlanetPalette(
            night: PlanetColor(hue: source.hue, saturation: min(saturation * 1.1, 0.95), brightness: 0.22),
            lit: PlanetColor(hue: source.hue, saturation: saturation, brightness: 0.97)
        )
    }

    /// Ink mode draws dark glyphs on light paper, so both tones drop in lightness; OKLab lightness scales without shifting hue.
    func resolved(ink: Bool) -> (night: SIMD3<Double>, lit: SIMD3<Double>) {
        var nightLab = night.oklab
        var litLab = lit.oklab
        if ink {
            nightLab.x *= 0.5
            litLab.x *= 0.62
        }
        return (nightLab, litLab)
    }
}

/// Everything the planet animates, as one vector so SwiftUI's spring (OrbitMotion.dramatic) interpolates it together; colours interpolate in OKLab.
nonisolated struct GlyphPlanetParams: VectorArithmetic, Equatable, Sendable {
    var night: SIMD3<Double>
    var lit: SIMD3<Double>
    var tilt: Double
    var fill: Double
    var bands: Double

    static var zero: GlyphPlanetParams {
        GlyphPlanetParams(night: .zero, lit: .zero, tilt: 0, fill: 0, bands: 0)
    }

    static func + (lhs: GlyphPlanetParams, rhs: GlyphPlanetParams) -> GlyphPlanetParams {
        GlyphPlanetParams(
            night: lhs.night + rhs.night,
            lit: lhs.lit + rhs.lit,
            tilt: lhs.tilt + rhs.tilt,
            fill: lhs.fill + rhs.fill,
            bands: lhs.bands + rhs.bands
        )
    }

    static func - (lhs: GlyphPlanetParams, rhs: GlyphPlanetParams) -> GlyphPlanetParams {
        GlyphPlanetParams(
            night: lhs.night - rhs.night,
            lit: lhs.lit - rhs.lit,
            tilt: lhs.tilt - rhs.tilt,
            fill: lhs.fill - rhs.fill,
            bands: lhs.bands - rhs.bands
        )
    }

    mutating func scale(by rhs: Double) {
        night *= rhs
        lit *= rhs
        tilt *= rhs
        fill *= rhs
        bands *= rhs
    }

    var magnitudeSquared: Double {
        simd_length_squared(night) + simd_length_squared(lit) + tilt * tilt + fill * fill + bands * bands
    }

    /// Straight-line blend, the same operation SwiftUI performs frame by frame.
    func blended(toward other: GlyphPlanetParams, amount: Double) -> GlyphPlanetParams {
        var delta = other - self
        delta.scale(by: amount)
        return self + delta
    }
}
