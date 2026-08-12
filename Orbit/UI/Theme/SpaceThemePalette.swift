//  Stops are blended in CIE L*a*b*, not HSB; chroma is capped per hue to
//  whatever sRGB can actually render at that lightness.

import Foundation

public enum SpaceThemePalette {

    static let presetCount = 10

    private static let primaryStopLightness = 23.0
    private static let secondaryStopLightness = 26.0
    private static let secondaryStopHueDriftDegrees = 6.0
    private static let chromaRequest = 150.0

    static let excludedHueLowDegrees = 30.0
    static let excludedHueHighDegrees = 120.0

    static let renderedExcludedHueLowDegrees = 15.0
    static let renderedExcludedHueHighDegrees = 105.0

    private static let constrainedHueArcLowDegrees = 140.0
    private static let constrainedHueArcHighDegrees = 270.0
    private static let constrainedHueCount = 3
    private static let abundantHueArcLowDegrees = 270.0
    private static let abundantHueArcHighDegrees = 390.0
    private static let abundantHueCount = 6

    private static let curatedHueDegrees: [Double] = {
        var hues: [Double] = []
        let constrainedStep = (constrainedHueArcHighDegrees - constrainedHueArcLowDegrees) / Double(constrainedHueCount)
        for index in 0..<constrainedHueCount {
            hues.append(constrainedHueArcLowDegrees + Double(index) * constrainedStep)
        }
        let abundantStep = (abundantHueArcHighDegrees - abundantHueArcLowDegrees) / Double(abundantHueCount)
        for index in 0..<abundantHueCount {
            let hue = abundantHueArcLowDegrees + Double(index) * abundantStep
            hues.append(hue.truncatingRemainder(dividingBy: 360))
        }
        return hues
    }()

    public static let presets: [SpaceTheme] = {
        var result: [SpaceTheme] = [
            SpaceTheme(style: .mesh, colors: SpaceTheme.defaultPalette, angle: 18, grain: 0.35),
        ]
        for (index, hueDegrees) in curatedHueDegrees.enumerated() {
            result.append(generatedTheme(hueDegrees: hueDegrees, angleSeed: index + 1))
        }
        return result
    }()

    private static func generatedTheme(hueDegrees: Double, angleSeed: Int) -> SpaceTheme {
        let stopOne = generatedColor(lightness: primaryStopLightness, chroma: chromaRequest, hueDegrees: hueDegrees)
        let stopTwo = generatedColor(
            lightness: secondaryStopLightness,
            chroma: chromaRequest,
            hueDegrees: hueDegrees + secondaryStopHueDriftDegrees
        )
        let angle = Double((angleSeed * 37) % 360)
        return SpaceTheme(style: .mesh, colors: [stopOne, stopTwo], angle: angle, grain: 0.4)
    }

    private static let maximumGeneratedLuminance = 0.40

    private static func generatedColor(lightness: Double, chroma: Double, hueDegrees: Double) -> ThemeColor {
        var candidateLightness = lightness
        var candidate = gamutMappedLabColor(lightness: candidateLightness, chroma: chroma, hueDegrees: hueDegrees)
        var iterations = 0
        while candidate.luminance > maximumGeneratedLuminance, iterations < 24 {
            candidateLightness *= 0.92
            candidate = gamutMappedLabColor(lightness: candidateLightness, chroma: chroma, hueDegrees: hueDegrees)
            iterations += 1
        }
        return candidate
    }

    private static func gamutMappedLabColor(lightness: Double, chroma: Double, hueDegrees: Double) -> ThemeColor {
        func candidate(_ chroma: Double) -> ThemeColor {
            let hueRadians = hueDegrees * .pi / 180
            return ThemeColor(lab: (lightness: lightness, a: chroma * cos(hueRadians), b: chroma * sin(hueRadians)))
        }
        let atRequestedChroma = candidate(chroma)
        guard !atRequestedChroma.isWithinSRGBGamut else { return atRequestedChroma }

        var passing = 0.0
        var failing = chroma
        for _ in 0..<40 {
            let midpoint = (passing + failing) / 2
            if candidate(midpoint).isWithinSRGBGamut {
                passing = midpoint
            } else {
                failing = midpoint
            }
        }
        return candidate(passing).clampedToUnitRange
    }

    // MARK: - Assignment

    public static func nextDefaultTheme(avoiding usedThemes: [SpaceTheme]) -> SpaceTheme {
        let used = Set(usedThemes.map(\.colors))
        if let unused = presets.first(where: { !used.contains($0.colors) }) {
            return unused
        }
        return proceduralTheme(avoiding: used, extensionIndex: usedThemes.count - presets.count)
    }

    public static func defaultThemes(count: Int, avoiding usedThemes: [SpaceTheme] = []) -> [SpaceTheme] {
        guard count > 0 else { return [] }
        var accumulated = usedThemes
        var result: [SpaceTheme] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let next = nextDefaultTheme(avoiding: accumulated)
            result.append(next)
            accumulated.append(next)
        }
        return result
    }

    private static let maximumProceduralAttempts = 40
    private static let proceduralHueArcDegrees = 360.0 - (excludedHueHighDegrees - excludedHueLowDegrees)
    private static let goldenAngleFraction = 0.6180339887498949

    private static func proceduralTheme(avoiding used: Set<[ThemeColor]>, extensionIndex: Int) -> SpaceTheme {
        for attempt in 0..<maximumProceduralAttempts {
            let step = extensionIndex + attempt
            let fraction = (Double(step + 1) * goldenAngleFraction).truncatingRemainder(dividingBy: 1.0)
            let hueDegrees = excludedHueHighDegrees + fraction * proceduralHueArcDegrees
            let theme = generatedTheme(hueDegrees: hueDegrees, angleSeed: presets.count + step)
            if !used.contains(theme.colors) { return theme }
        }
        return presets[extensionIndex % presets.count]
    }
}

extension ThemeColor {
    private static let d65WhiteX = 0.95047
    private static let d65WhiteY = 1.0
    private static let d65WhiteZ = 1.08883
    private static let labDelta = 6.0 / 29.0

    private static func srgbToLinear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ component: Double) -> Double {
        component <= 0.0031308 ? component * 12.92 : 1.055 * pow(component, 1 / 2.4) - 0.055
    }

    private static func labForwardTransfer(_ t: Double) -> Double {
        t > labDelta * labDelta * labDelta ? cbrt(t) : t / (3 * labDelta * labDelta) + 4.0 / 29.0
    }

    private static func labInverseTransfer(_ t: Double) -> Double {
        t > labDelta ? t * t * t : 3 * labDelta * labDelta * (t - 4.0 / 29.0)
    }

    public var labComponents: (lightness: Double, a: Double, b: Double) {
        let r = Self.srgbToLinear(red)
        let g = Self.srgbToLinear(green)
        let b = Self.srgbToLinear(blue)

        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b

        let fx = Self.labForwardTransfer(x / Self.d65WhiteX)
        let fy = Self.labForwardTransfer(y / Self.d65WhiteY)
        let fz = Self.labForwardTransfer(z / Self.d65WhiteZ)

        return (lightness: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    public init(lab: (lightness: Double, a: Double, b: Double)) {
        let fy = (lab.lightness + 16) / 116
        let fx = fy + lab.a / 500
        let fz = fy - lab.b / 200

        let x = Self.d65WhiteX * Self.labInverseTransfer(fx)
        let y = Self.d65WhiteY * Self.labInverseTransfer(fy)
        let z = Self.d65WhiteZ * Self.labInverseTransfer(fz)

        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z

        self.init(red: Self.linearToSRGB(r), green: Self.linearToSRGB(g), blue: Self.linearToSRGB(b), alpha: 1)
    }

    var isWithinSRGBGamut: Bool {
        let tolerance = 1e-6
        return (-tolerance...(1 + tolerance)).contains(red)
            && (-tolerance...(1 + tolerance)).contains(green)
            && (-tolerance...(1 + tolerance)).contains(blue)
    }

    var clampedToUnitRange: ThemeColor {
        ThemeColor(red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1), alpha: alpha)
    }

    public func deltaE76(to other: ThemeColor) -> Double {
        let a = labComponents
        let b = other.labComponents
        let dl = a.lightness - b.lightness
        let da = a.a - b.a
        let db = a.b - b.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
