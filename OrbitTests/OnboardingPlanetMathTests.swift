import SwiftUI
import XCTest

// GlyphPlanetMath.swift is compiled into the test bundle (see ORBIT_TESTS_REUSED_SOURCES).

final class OnboardingPlanetMathTests: XCTestCase {

    private func assertClose(_ a: PlanetColor, _ b: PlanetColor, accuracy: Double = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: accuracy, file: file, line: line)
    }


    func test_oklab_roundTripsThroughSRGB() {
        for hex: UInt32 in [0xB49CFF, 0xE7C48A, 0x7EE7FF, 0x2A1F4D, 0x808080, 0xFF0000, 0x00FF00] {
            let color = PlanetColor(hex: hex)
            assertClose(PlanetColor(oklab: color.oklab), color)
        }
    }

    func test_oklab_whiteAndBlackSitOnTheLightnessAxis() {
        let white = PlanetColor(red: 1, green: 1, blue: 1).oklab
        let black = PlanetColor(red: 0, green: 0, blue: 0).oklab

        XCTAssertEqual(white.x, 1, accuracy: 1e-3)
        XCTAssertEqual(white.y, 0, accuracy: 1e-3)
        XCTAssertEqual(white.z, 0, accuracy: 1e-3)
        XCTAssertEqual(black.x, 0, accuracy: 1e-9)
    }

    func test_hex_decodesChannels() {
        let color = PlanetColor(hex: 0xFF8000)
        XCTAssertEqual(color.red, 1, accuracy: 1e-12)
        XCTAssertEqual(color.green, 128.0 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(color.blue, 0, accuracy: 1e-12)
    }


    func test_hsb_roundTrips() {
        for (hue, saturation, brightness) in [(0.0, 0.5, 0.9), (0.33, 0.8, 0.4), (0.6, 0.2, 1.0), (0.92, 1.0, 0.7)] {
            let color = PlanetColor(hue: hue, saturation: saturation, brightness: brightness)
            let back = color.hsb
            XCTAssertEqual(back.hue, hue, accuracy: 1e-9)
            XCTAssertEqual(back.saturation, saturation, accuracy: 1e-9)
            XCTAssertEqual(back.brightness, brightness, accuracy: 1e-9)
        }
    }

    // MARK: - Tinting

    func test_tinted_keepsTheHueAndBuildsALightAndAShadowTone() {
        let source = PlanetColor(hue: 0.55, saturation: 0.7, brightness: 0.25)
        let palette = GlyphPlanetPalette.tinted(by: source)

        XCTAssertEqual(palette.lit.hsb.hue, 0.55, accuracy: 0.005)
        XCTAssertEqual(palette.night.hsb.hue, 0.55, accuracy: 0.005)
        XCTAssertGreaterThan(palette.lit.relativeLuminance, palette.night.relativeLuminance)
        XCTAssertEqual(palette.lit.hsb.brightness, 0.97, accuracy: 1e-9, "a dark Space theme still gives a vivid lit tone")
    }

    func test_tinted_neverGoesGrey() {
        let grey = GlyphPlanetPalette.tinted(by: PlanetColor(red: 0.2, green: 0.2, blue: 0.2))
        XCTAssertGreaterThanOrEqual(grey.lit.hsb.saturation, 0.45 - 1e-9)
    }

    func test_inkResolution_darkensBothTonesWithoutShiftingHue() {
        let palette = GlyphPlanetPalette.cyan
        let glow = palette.resolved(ink: false)
        let ink = palette.resolved(ink: true)

        XCTAssertLessThan(ink.lit.x, glow.lit.x)
        XCTAssertLessThan(ink.night.x, glow.night.x)
        XCTAssertEqual(ink.lit.y, glow.lit.y, accuracy: 1e-12)
        XCTAssertEqual(ink.lit.z, glow.lit.z, accuracy: 1e-12)
        XCTAssertEqual(ink.night.y, glow.night.y, accuracy: 1e-12)
    }

    func test_inkLitTone_isDarkEnoughToReadOnPaper() {
        // The site's cyan lit tone is pale; as ink on near-white paper it must have real contrast.
        let ink = GlyphPlanetPalette.cyan.resolved(ink: true).lit
        let rendered = PlanetColor(oklab: ink)
        let paper = PlanetColor(hex: 0xF7F7F8)
        let ratio = (paper.relativeLuminance + 0.05) / (rendered.relativeLuminance + 0.05)
        XCTAssertGreaterThan(ratio, 2.0)
    }


    private let a = GlyphPlanetParams(night: SIMD3(0.2, 0.01, -0.02), lit: SIMD3(0.8, 0.05, 0.1), tilt: -0.3, fill: 0, bands: 8)
    private let b = GlyphPlanetParams(night: SIMD3(0.4, -0.03, 0.04), lit: SIMD3(0.9, -0.05, 0.2), tilt: 0.5, fill: 1, bands: 12)

    func test_params_zeroIsTheIdentity() {
        XCTAssertEqual(a + .zero, a)
        XCTAssertEqual(a - .zero, a)
        XCTAssertEqual(GlyphPlanetParams.zero.magnitudeSquared, 0)
    }

    func test_params_scaleScalesEveryChannel() {
        var scaled = a
        scaled.scale(by: 2)

        XCTAssertEqual(scaled.night, a.night * 2)
        XCTAssertEqual(scaled.lit, a.lit * 2)
        XCTAssertEqual(scaled.tilt, a.tilt * 2)
        XCTAssertEqual(scaled.fill, a.fill * 2)
        XCTAssertEqual(scaled.bands, a.bands * 2)
        XCTAssertEqual(scaled.magnitudeSquared, a.magnitudeSquared * 4, accuracy: 1e-9)
    }

    func test_params_blendHitsBothEndsAndTheMidpoint() {
        XCTAssertEqual(a.blended(toward: b, amount: 0), a)
        let end = a.blended(toward: b, amount: 1)
        XCTAssertEqual(end.tilt, b.tilt, accuracy: 1e-12)
        XCTAssertEqual(end.fill, b.fill, accuracy: 1e-12)
        XCTAssertEqual(end.lit.x, b.lit.x, accuracy: 1e-12)

        let mid = a.blended(toward: b, amount: 0.5)
        XCTAssertEqual(mid.tilt, (a.tilt + b.tilt) / 2, accuracy: 1e-12)
        XCTAssertEqual(mid.bands, 10, accuracy: 1e-12)
        XCTAssertEqual(mid.night.y, (a.night.y + b.night.y) / 2, accuracy: 1e-12)
    }

    func test_params_additionAndSubtractionInvert() {
        let restored = (a - b) + b
        XCTAssertEqual(restored.tilt, a.tilt, accuracy: 1e-12)
        XCTAssertEqual(restored.night.x, a.night.x, accuracy: 1e-12)
        XCTAssertEqual(restored.lit.z, a.lit.z, accuracy: 1e-12)
    }
}
