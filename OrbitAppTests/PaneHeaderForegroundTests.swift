//  Regression guard: a two-mode luminance threshold put #ff6600 on the wrong side.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class PaneHeaderForegroundTests: XCTestCase {

    private func hex(_ value: String) -> ThemeColor {
        var raw = value
        if raw.hasPrefix("#") { raw.removeFirst() }
        let packed = UInt32(raw, radix: 16) ?? 0
        return ThemeColor(
            red: Double((packed >> 16) & 0xff) / 255,
            green: Double((packed >> 8) & 0xff) / 255,
            blue: Double(packed & 0xff) / 255
        )
    }

    private func describe(_ color: ThemeColor) -> String {
        String(
            format: "#%02x%02x%02x",
            Int((color.red * 255).rounded()),
            Int((color.green * 255).rounded()),
            Int((color.blue * 255).rounded())
        )
    }

    // MARK: - The defect

    func test_saturatedOrange_getsDarkGlyphs_whichTheOldThresholdGotBackwards() {
        let orange = hex("#ff6600")
        let white = ThemeColor(red: 1, green: 1, blue: 1)

        XCTAssertEqual(
            PaneHeaderColorResolver.foreground(for: orange), .light,
            "Precondition: the old luminance threshold really does call #ff6600 'needs light glyphs'. If this ever changes, the case below stops being the regression it was written for."
        )

        let derived = PaneHeaderColorResolver.foregroundColor(for: orange)
        XCTAssertLessThan(
            derived.relativeLuminance, orange.relativeLuminance,
            "The derived glyph colour is lighter than the orange bar it sits on — the direction the old threshold got wrong. Got \(describe(derived))."
        )
        XCTAssertGreaterThan(
            derived.contrastRatio(against: orange), white.contrastRatio(against: orange),
            "The derived colour must contrast better on #ff6600 than the white the old rule painted (2.9:1)."
        )
        XCTAssertGreaterThanOrEqual(
            derived.contrastRatio(against: orange),
            PaneHeaderColorResolver.foregroundContrastTarget,
            "Primary glyphs on #ff6600 should clear AAA; got \(derived.contrastRatio(against: orange))."
        )
    }

    // MARK: - The guarantee, across the range

    func test_primaryGlyphsClearTheContrastFloorOnEveryColourAPageCanProduce() {
        let backgrounds = [
            "#ffffff", "#000000", "#161617", "#ff6600", "#0d1117", "#1e2327",
            "#f8f9fa", "#353535", "#2a2632", "#00ff00", "#0000ff", "#ffff00",
        ]
        for value in backgrounds {
            let background = hex(value)
            let derived = PaneHeaderColorResolver.foregroundColor(for: background)
            let contrast = derived.contrastRatio(against: background)
            let black = ThemeColor(red: 0, green: 0, blue: 0).contrastRatio(against: background)
            let white = ThemeColor(red: 1, green: 1, blue: 1).contrastRatio(against: background)
            let bestPossible = max(black, white)

            if bestPossible >= PaneHeaderColorResolver.foregroundContrastTarget {
                XCTAssertGreaterThanOrEqual(
                    contrast, PaneHeaderColorResolver.foregroundContrastTarget,
                    "\(value) admits \(bestPossible):1 but the derived glyph \(describe(derived)) only reached \(contrast):1."
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    contrast, bestPossible * 0.9,
                    "\(value) cannot reach the target in any direction (best \(bestPossible):1), so the derivation must return close to that best rather than something dimmer. Got \(contrast):1."
                )
            }
        }
    }

    func test_primaryGlyphsTakeTheMostContrastingEnd_notMerelyTheFloor() {
        let darkBar = hex("#161617")
        let derived = PaneHeaderColorResolver.foregroundColor(for: darkBar)
        XCTAssertGreaterThan(
            derived.contrastRatio(against: darkBar), 15,
            "On a near-black bar the glyphs should be near-white (about 18:1), not a grey that merely clears 7:1. Got \(describe(derived)) at \(derived.contrastRatio(against: darkBar)):1."
        )
    }

    func test_glyphsAreMonochrome_carryingNoneOfTheBarsHue() {
        for value in ["#ff6600", "#0000ff", "#00ff00", "#2a2632", "#f8f9fa"] {
            let background = hex(value)
            let primary = PaneHeaderColorResolver.foregroundColor(for: background)
            let dimmed = PaneHeaderColorResolver.dimmedForegroundColor(for: background)

            XCTAssertEqual(
                primary.hsb.saturation, 0, accuracy: 0.0001,
                "Primary glyphs on \(value) picked up the bar's hue: \(describe(primary))."
            )
            XCTAssertEqual(
                dimmed.hsb.saturation, 0, accuracy: 0.0001,
                "Dimmed glyphs on \(value) picked up the bar's hue: \(describe(dimmed)) — the tint the primary tier dropped, arriving through the back door."
            )
        }
    }

    func test_primaryGlyphsAreTheFullyInvertedEnd_notAPerChannelInversion() {
        for value in ["#ffffff", "#000000", "#161617", "#ff6600", "#0000ff", "#808080"] {
            let background = hex(value)
            let derived = PaneHeaderColorResolver.foregroundColor(for: background)
            let isExtreme = derived == PaneHeaderColorResolver.invertedDark
                || derived == PaneHeaderColorResolver.invertedLight
            XCTAssertTrue(
                isExtreme,
                "Primary glyphs on \(value) landed on \(describe(derived)), which is neither end of the scale."
            )
        }

        let orange = hex("#ff6600")
        let perChannel = ThemeColor(red: 1 - orange.red, green: 1 - orange.green, blue: 1 - orange.blue)
        XCTAssertEqual(
            perChannel.contrastRatio(against: orange), 1.02, accuracy: 0.05,
            "The per-channel inversion of #ff6600 is #0099ff, which is invisible on it. This is why 'inverted' means the luminance extreme."
        )
        XCTAssertGreaterThan(
            PaneHeaderColorResolver.foregroundColor(for: orange).contrastRatio(against: orange),
            perChannel.contrastRatio(against: orange),
            "Whatever the rule becomes, it must beat the naive inversion it was distinguished from."
        )
    }

    // MARK: - The dimmed tier

    func test_dimmedGlyphsAreSubordinateToPrimaryButStillClearTheirOwnFloor() {
        for value in ["#ffffff", "#161617", "#ff6600", "#0d1117"] {
            let background = hex(value)
            let primary = PaneHeaderColorResolver.foregroundColor(for: background)
            let dimmed = PaneHeaderColorResolver.dimmedForegroundColor(for: background)

            XCTAssertGreaterThanOrEqual(
                dimmed.contrastRatio(against: background),
                PaneHeaderColorResolver.dimmedForegroundContrastTarget * 0.99,
                "Dimmed glyphs on \(value) fell below their 3:1 floor at \(describe(dimmed))."
            )
            XCTAssertLessThan(
                dimmed.contrastRatio(against: background),
                primary.contrastRatio(against: background),
                "Dimmed glyphs on \(value) contrast as hard as the primary ones, so nothing reads as secondary."
            )
        }
    }

    func test_bothTiersAgreeOnDirection() {
        for value in ["#ffffff", "#000000", "#ff6600", "#808080", "#161617"] {
            let background = hex(value)
            let primary = PaneHeaderColorResolver.foregroundColor(for: background)
            let dimmed = PaneHeaderColorResolver.dimmedForegroundColor(for: background)
            let primaryIsDarker = primary.relativeLuminance < background.relativeLuminance
            let dimmedIsDarker = dimmed.relativeLuminance < background.relativeLuminance
            XCTAssertEqual(
                primaryIsDarker, dimmedIsDarker,
                "On \(value) the two tiers went opposite ways: primary \(describe(primary)), dimmed \(describe(dimmed))."
            )
        }
    }

    // MARK: - The contrast arithmetic itself

    func test_theTwoLuminancesAreDifferentOnPurpose() {
        let orange = hex("#ff6600")
        XCTAssertEqual(orange.luminance, 0.4987, accuracy: 0.001,
                       "The perceived-luminance helper is what the 0.5/0.55/0.6 thresholds elsewhere are calibrated against.")
        XCTAssertEqual(orange.relativeLuminance, 0.3077, accuracy: 0.001,
                       "WCAG relative luminance linearises the components first; this is the one contrast may be computed from.")
    }

    func test_contrastRatioMatchesTheWCAGDefinition() {
        let black = ThemeColor(red: 0, green: 0, blue: 0)
        let white = ThemeColor(red: 1, green: 1, blue: 1)
        XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.001)
        XCTAssertEqual(
            black.contrastRatio(against: hex("#ff6600")), 7.15, accuracy: 0.05,
            "The number the whole change turns on: black on #ff6600."
        )
        XCTAssertEqual(
            white.contrastRatio(against: hex("#ff6600")), 2.94, accuracy: 0.05,
            "And what the old rule painted there instead."
        )
    }

    // MARK: - The neutral fallback

    // Regression guard: the untinted bar briefly resolved SpaceTheme.adaptedColors' last stop.
    // Asserted at the source since the alternative is reaching into a SwiftUI private property.
    func test_theUntintedBarNeverComesFromTheSpaceTheme() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Orbit/UI/Toolbar/ToolbarView.swift"),
            encoding: .utf8
        )
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for banned in ["adaptedColors", "paneSpaceTheme", "readableForeground"] {
            XCTAssertFalse(
                code.contains(banned),
                "ToolbarView reaches for `\(banned)`, which is a Space-theme colour route into the pane header. The header's background comes from the page or from the appearance neutral — never from the Space."
            )
        }
    }

    func test_theAppearanceNeutralsAreDistinctAndBothUsableAsABar() {
        let dark = ThemeColor(red: 0.16, green: 0.155, blue: 0.18)
        let light = ThemeColor(red: 0.945, green: 0.945, blue: 0.955)

        XCTAssertEqual(PaneHeaderColorResolver.foregroundColor(for: dark), .init(red: 1, green: 1, blue: 1),
                       "The dark neutral must take white glyphs.")
        XCTAssertEqual(PaneHeaderColorResolver.foregroundColor(for: light), .init(red: 0, green: 0, blue: 0),
                       "The light neutral must take black glyphs.")
        XCTAssertGreaterThanOrEqual(
            PaneHeaderColorResolver.foregroundColor(for: dark).contrastRatio(against: dark),
            PaneHeaderColorResolver.foregroundContrastTarget
        )
        XCTAssertGreaterThanOrEqual(
            PaneHeaderColorResolver.foregroundColor(for: light).contrastRatio(against: light),
            PaneHeaderColorResolver.foregroundContrastTarget
        )
    }
}
