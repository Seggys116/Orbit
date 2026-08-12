import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SpaceThemePaletteTests: XCTestCase {

    // MARK: - Determinism and the shipped default

    func test_nextDefaultTheme_withNothingInUse_isExactlyTheShippedDefault() {
        let theme = SpaceThemePalette.nextDefaultTheme(avoiding: [])
        XCTAssertEqual(theme.colors, SpaceTheme.defaultPalette)
    }

    func test_nextDefaultTheme_isPure_sameInputAlwaysProducesTheSameOutput() {
        let usedThemes = [SpaceTheme(colors: SpaceTheme.defaultPalette)]
        let first = SpaceThemePalette.nextDefaultTheme(avoiding: usedThemes)
        let second = SpaceThemePalette.nextDefaultTheme(avoiding: usedThemes)
        XCTAssertEqual(first, second)
    }

    // MARK: - Distinctness while the curated set has room

    func test_creatingSpacesOneAtATime_neverRepeatsAGradientWhileCuratedPresetsRemain() {
        var used: [SpaceTheme] = []
        var seenColorSets: Set<[ThemeColor]> = []
        for _ in 0..<SpaceThemePalette.presets.count {
            let next = SpaceThemePalette.nextDefaultTheme(avoiding: used)
            XCTAssertFalse(
                seenColorSets.contains(next.colors),
                "A Space created while curated presets remain must never repeat a gradient already in use."
            )
            seenColorSets.insert(next.colors)
            used.append(next)
        }
        XCTAssertEqual(seenColorSets.count, SpaceThemePalette.presets.count)
    }

    // MARK: - The batch entry point onboarding needs

    func test_defaultThemes_returnsCountDistinctThemes() {
        let themes = SpaceThemePalette.defaultThemes(count: 6)
        XCTAssertEqual(themes.count, 6)
        XCTAssertEqual(Set(themes.map(\.colors)).count, 6, "All six pre-defined onboarding Spaces must get visibly different gradients.")
        XCTAssertEqual(themes.first?.colors, SpaceTheme.defaultPalette, "The first of a pre-defined batch keeps the shipped default look, same as a lone Space would.")
    }

    func test_defaultThemes_matchesCallingNextDefaultThemeInALoopByHand() {
        let batch = SpaceThemePalette.defaultThemes(count: 5)

        var handRolled: [SpaceTheme] = []
        for _ in 0..<5 {
            handRolled.append(SpaceThemePalette.nextDefaultTheme(avoiding: handRolled))
        }

        XCTAssertEqual(batch, handRolled)
    }

    func test_defaultThemes_respectsThemesAlreadyInUseBeforeTheBatch() {
        let existing = [SpaceThemePalette.nextDefaultTheme(avoiding: [])]
        let batch = SpaceThemePalette.defaultThemes(count: 4, avoiding: existing)

        XCTAssertFalse(batch.contains { $0.colors == existing[0].colors })
        XCTAssertEqual(Set(batch.map(\.colors)).count, batch.count)
    }

    func test_defaultThemes_zeroOrNegativeCountReturnsEmpty() {
        XCTAssertEqual(SpaceThemePalette.defaultThemes(count: 0), [])
        XCTAssertEqual(SpaceThemePalette.defaultThemes(count: -3), [])
    }

    // MARK: - Matching on the gradient, not the whole theme

    func test_avoiding_matchesOnColorsEvenWhenOtherThemeFieldsDiffer() {
        let sameColorsDifferentGrain = SpaceTheme(
            style: .linear,
            colors: SpaceTheme.defaultPalette,
            angle: 200,
            grain: 0.9
        )
        let next = SpaceThemePalette.nextDefaultTheme(avoiding: [sameColorsDifferentGrain])
        XCTAssertNotEqual(next.colors, SpaceTheme.defaultPalette, "A theme with the shipped default's exact colours -- however its other fields differ -- must count as that gradient already being in use.")
    }

    // MARK: - Exhaustion: degrading sensibly, not repeating immediately

    func test_onceCuratedPresetsAreExhausted_theNextAssignmentIsStillNew() {
        let allPresetsInUse = SpaceThemePalette.presets
        let eleventh = SpaceThemePalette.nextDefaultTheme(avoiding: allPresetsInUse)

        XCTAssertFalse(
            allPresetsInUse.contains { $0.colors == eleventh.colors },
            "The eleventh Space must not clone any of the first ten's gradients."
        )
        XCTAssertLessThan(eleventh.primary.luminance, 0.55, "A procedurally extended theme must still read as a dark surface, same as every curated preset.")
    }

    func test_pastExhaustion_aWholeFurtherBatchStaysMutuallyDistinct() {
        let batch = SpaceThemePalette.defaultThemes(count: SpaceThemePalette.presets.count + 15)

        XCTAssertEqual(batch.count, SpaceThemePalette.presets.count + 15)
        XCTAssertEqual(
            Set(batch.map(\.colors)).count, batch.count,
            "Twenty-five Spaces created in one pass -- fifteen past the curated set of ten -- must all still read as distinct gradients."
        )
    }

    func test_anEnormousBatch_stillReturnsExactlyCountThemesWithoutCrashing() {
        let enormous = SpaceThemePalette.defaultThemes(count: 500)
        XCTAssertEqual(enormous.count, 500)
        XCTAssertLessThanOrEqual(Set(enormous.map(\.colors)).count, 500)
        XCTAssertGreaterThan(Set(enormous.map(\.colors)).count, SpaceThemePalette.presets.count)
    }

    // MARK: - Legibility: every preset, both appearances

    func test_everyPreset_isADarkSurface() {
        for (index, preset) in SpaceThemePalette.presets.enumerated() {
            XCTAssertTrue(
                preset.isDarkSurface,
                "presets[\(index)] (colors \(preset.colors)) must read as a dark surface -- readableForeground picks a fixed near-white for exactly that assumption."
            )
        }
    }

    func test_everyPreset_readableForegroundTiersClearWCAGContrastFloors() {
        for (index, preset) in SpaceThemePalette.presets.enumerated() {
            let fg = ThemeColor(NSColor(preset.readableForeground))
            let fgSecondary = ThemeColor(NSColor(preset.readableSecondaryForeground))

            for scheme: ColorScheme in [.dark, .light] {
                for stop in preset.adaptedColors(for: scheme) {
                    let background = ThemeColor(NSColor(stop))
                    let primaryContrast = fg.composited(over: background).contrastRatio(against: background)
                    let secondaryContrast = fgSecondary.composited(over: background).contrastRatio(against: background)

                    XCTAssertGreaterThanOrEqual(
                        primaryContrast, PaneHeaderColorResolver.foregroundContrastTarget,
                        "presets[\(index)] primary foreground only reached \(primaryContrast):1 in \(scheme), below the \(PaneHeaderColorResolver.foregroundContrastTarget):1 floor."
                    )
                    XCTAssertGreaterThanOrEqual(
                        secondaryContrast, PaneHeaderColorResolver.dimmedForegroundContrastTarget,
                        "presets[\(index)] secondary foreground only reached \(secondaryContrast):1 in \(scheme), below the \(PaneHeaderColorResolver.dimmedForegroundContrastTarget):1 floor."
                    )
                }
            }
        }
    }

    func test_proceduralExtension_readableForegroundTiersClearWCAGContrastFloorsToo() {
        let extended = SpaceThemePalette.defaultThemes(count: SpaceThemePalette.presets.count + 10)
            .suffix(10)

        for theme in extended {
            XCTAssertTrue(theme.isDarkSurface)
            let fg = ThemeColor(NSColor(theme.readableForeground))
            for scheme: ColorScheme in [.dark, .light] {
                for stop in theme.adaptedColors(for: scheme) {
                    let background = ThemeColor(NSColor(stop))
                    let contrast = fg.composited(over: background).contrastRatio(against: background)
                    XCTAssertGreaterThanOrEqual(
                        contrast, PaneHeaderColorResolver.foregroundContrastTarget,
                        "A procedurally generated theme (colors \(theme.colors)) only reached \(contrast):1 in \(scheme)."
                    )
                }
            }
        }
    }

    func test_everyPreset_hasAtLeastOneColorStop() {
        for preset in SpaceThemePalette.presets {
            XCTAssertFalse(preset.colors.isEmpty)
        }
    }

    func test_everyPreset_primaryColorIsItsOwnFirstStopNotTheFallback() {
        for preset in SpaceThemePalette.presets {
            XCTAssertEqual(preset.primary, preset.colors.first)
        }
    }

    // MARK: - Measurable distinctness (CIE76 ΔE)

    private static let minimumPrimaryDeltaE = 10.0

    private static let minimumSecondaryDeltaE = 6.0

    func test_everyPairOfPresets_primaryStopsAreMeasurablyDistinct() {
        let presets = SpaceThemePalette.presets
        var worst = Double.greatestFiniteMagnitude
        var worstPair = (0, 0)
        for i in 0..<presets.count {
            for j in (i + 1)..<presets.count {
                let d = presets[i].primary.deltaE76(to: presets[j].primary)
                if d < worst { worst = d; worstPair = (i, j) }
                XCTAssertGreaterThanOrEqual(
                    d, Self.minimumPrimaryDeltaE,
                    "presets[\(i)] and presets[\(j)] only measured ΔE \(d) apart on their primary stop -- below the \(Self.minimumPrimaryDeltaE) 'perceptible at a glance' floor a user could tell them apart by."
                )
            }
        }
        print("SpaceThemePaletteTests: worst-case primary-stop ΔE = \(worst) between presets[\(worstPair.0)] and presets[\(worstPair.1)].")
    }

    func test_everyPairOfPresets_secondaryStopsAreMeasurablyDistinct() {
        let presets = SpaceThemePalette.presets
        for i in 0..<presets.count {
            for j in (i + 1)..<presets.count {
                guard let a = presets[i].colors.last, let b = presets[j].colors.last else {
                    XCTFail("presets[\(i)]/presets[\(j)] unexpectedly has no colour stops.")
                    continue
                }
                let d = a.deltaE76(to: b)
                XCTAssertGreaterThanOrEqual(
                    d, Self.minimumSecondaryDeltaE,
                    "presets[\(i)] and presets[\(j)] only measured ΔE \(d) apart on their secondary stop -- below the \(Self.minimumSecondaryDeltaE) floor."
                )
            }
        }
    }

    private static let minimumGeneratedChroma = 16.0

    func test_everyGeneratedPreset_hasMeaningfulPerceptualChroma() {
        for (index, preset) in SpaceThemePalette.presets.enumerated() where index != 0 {
            for stop in preset.colors {
                let lab = stop.labComponents
                let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
                XCTAssertGreaterThanOrEqual(
                    chroma, Self.minimumGeneratedChroma,
                    "presets[\(index)]'s stop \(stop) only reached chroma \(chroma) -- a muted neutral, not a colour with real presence."
                )
            }
        }
    }

    func test_noGeneratedPreset_hasAnInputHueInsideTheExcludedLabHueArc() {
        let excludedArc = SpaceThemePalette.excludedHueLowDegrees...SpaceThemePalette.excludedHueHighDegrees
        for (index, preset) in SpaceThemePalette.presets.enumerated() where index != 0 {
            let lab = preset.primary.labComponents
            var hueDegrees = atan2(lab.b, lab.a) * 180 / .pi
            if hueDegrees < 0 { hueDegrees += 360 }
            XCTAssertFalse(
                excludedArc.contains(hueDegrees),
                "presets[\(index)]'s primary stop's Lab-hue input sits at \(hueDegrees) degrees, inside \(excludedArc)."
            )
        }
    }

    func test_noPreset_rendersInsideTheMuddyPerceivedHueArc() {
        let excludedArc = SpaceThemePalette.renderedExcludedHueLowDegrees...SpaceThemePalette.renderedExcludedHueHighDegrees
        for (index, preset) in SpaceThemePalette.presets.enumerated() {
            for (stopIndex, stop) in preset.colors.enumerated() {
                let hueDegrees = stop.hsb.hue * 360
                XCTAssertFalse(
                    excludedArc.contains(hueDegrees),
                    "presets[\(index)]'s stop \(stopIndex) (\(stop)) renders at perceived hue \(hueDegrees) degrees, inside the \(excludedArc)-degree arc that reads as brown/olive/khaki -- regardless of what Lab-hue input produced it."
                )
            }
        }
    }

    // MARK: - Visual verification

    private static var screenshotOutputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrbitAppTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("refs/screenshots", isDirectory: true)
    }

    func test_spaceThemePalettePresetsPreviewGrid_dark() async {
        await renderAndSavePaletteGrid(name: "space-theme-palette-presets", appearance: .darkAqua)
    }

    func test_spaceThemePalettePresetsPreviewGrid_light() async {
        await renderAndSavePaletteGrid(name: "space-theme-palette-presets-light", appearance: .aqua)
    }

    private func renderAndSavePaletteGrid(name: String, appearance: NSAppearance.Name) async {
        let view = SpaceThemePalettePreviewGrid(themes: SpaceThemePalette.presets)
        let size = SpaceThemePalettePreviewGrid.size(forCount: SpaceThemePalette.presets.count)
        let rendered = await renderForScreenshot(view, size: size, appearance: appearance)
        let destination = Self.screenshotOutputDirectory.appendingPathComponent("\(name).png")
        let wrote = rendered.writePNG(to: destination)
        XCTAssertTrue(wrote, "Expected to write \(name).png to \(destination.path).")
        print("SpaceThemePaletteTests: wrote \(name).png (\(Int(size.width))x\(Int(size.height))pt @2x) to \(destination.path)")
    }
}

// MARK: - Screenshot-only preview grid

private struct SpaceThemePalettePreviewGrid: View {
    var themes: [SpaceTheme]

    private static let columns = 2
    private static let swatchSize = CGSize(width: 320, height: 190)
    private static let spacing: CGFloat = 16

    static func size(forCount count: Int) -> CGSize {
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        return CGSize(
            width: CGFloat(columns) * swatchSize.width + CGFloat(columns - 1) * spacing + spacing * 2,
            height: CGFloat(rows) * swatchSize.height + CGFloat(max(rows - 1, 0)) * spacing + spacing * 2
        )
    }

    var body: some View {
        let rows = Array(stride(from: 0, to: themes.count, by: Self.columns))
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(rows, id: \.self) { rowStart in
                HStack(spacing: Self.spacing) {
                    ForEach(rowStart..<min(rowStart + Self.columns, themes.count), id: \.self) { index in
                        swatch(index: index, theme: themes[index])
                    }
                }
            }
        }
        .padding(Self.spacing)
        .background(Color.black)
    }

    private func swatch(index: Int, theme: SpaceTheme) -> some View {
        ZStack {
            ThemeBackgroundView(theme: theme)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Circle()
                        .fill(theme.readableForeground)
                        .frame(width: 10, height: 10)
                    Text("Preset \(index) -- Space")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.readableForeground)
                    Spacer()
                }
                Text(hexSummary(theme))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.readableSecondaryForeground)
                Spacer()
                Text("Aa Bb Cc")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.readableForeground)
                Text("Sidebar text at readableSecondaryForeground")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.readableSecondaryForeground)
            }
            .padding(14)
        }
        .frame(width: Self.swatchSize.width, height: Self.swatchSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    }

    private func hexSummary(_ theme: SpaceTheme) -> String {
        theme.colors.map { color -> String in
            let r = Int((color.red * 255).rounded())
            let g = Int((color.green * 255).rounded())
            let b = Int((color.blue * 255).rounded())
            return String(format: "#%02X%02X%02X", r, g, b)
        }.joined(separator: " -> ")
    }
}
