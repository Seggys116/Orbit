import SwiftUI
import XCTest

@testable import Orbit

@MainActor
// Excluded renders below: a MeshGradient theme render stalls past five minutes on a hosted runner.
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class ThemeEditorRedesignTests: XCTestCase {

    // MARK: - Fixtures

    private static var sampleTheme: SpaceTheme {
        SpaceTheme(
            style: .mesh,
            colors: [
                ThemeColor(red: 0.157, green: 0.192, blue: 0.290),
                ThemeColor(red: 0.322, green: 0.239, blue: 0.376),
                ThemeColor(red: 0.180, green: 0.318, blue: 0.325),
            ],
            angle: 42,
            grain: 0.45
        )
    }

    // MARK: - Back-compatibility: a pre-redesign document must still decode

    // Asserts against a hand-written JSON literal rather than a round-trip
    // of the current type, which would encode the new field and prove nothing.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_themeWithoutStopPositions_stillDecodes
    func test_themeWithoutStopPositions_stillDecodes() throws {
        let legacyJSON = """
        {
            "style": "mesh",
            "colors": [
                { "red": 0.1725, "green": 0.1569, "blue": 0.2039, "alpha": 1 },
                { "red": 0.2078, "green": 0.1804, "blue": 0.2353, "alpha": 1 }
            ],
            "angle": 18,
            "grain": 0.5,
            "followsSystemAppearance": true,
            "prefersDarkContent": false
        }
        """
        let decoded = try JSONDecoder().decode(SpaceTheme.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(
            decoded.stopPositions,
            "A document written before per-stop positions existed must decode with stopPositions nil, not fail and not fabricate an array."
        )
        XCTAssertEqual(decoded.colors.count, 2)
        XCTAssertEqual(decoded.style, .mesh)
        XCTAssertEqual(decoded.angle, 18, accuracy: 0.0001)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_unpositionedTheme_doesNotEncodeStopPositions

    func test_unpositionedTheme_doesNotEncodeStopPositions() throws {
        let encoded = try JSONEncoder().encode(SpaceTheme())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNil(
            object["stopPositions"],
            "SpaceTheme() has never been hand-positioned, so it must not write a stopPositions key at all."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_stopPositions_roundTripThroughCodable

    func test_stopPositions_roundTripThroughCodable() throws {
        var theme = Self.sampleTheme
        theme.stopPositions = [
            ThemeStopPosition(x: 0.1, y: 0.2),
            ThemeStopPosition(x: 0.5, y: 0.5),
            ThemeStopPosition(x: 0.9, y: 0.8),
        ]

        let decoded = try JSONDecoder().decode(SpaceTheme.self, from: JSONEncoder().encode(theme))

        XCTAssertEqual(decoded.stopPositions, theme.stopPositions)
        XCTAssertEqual(decoded, theme)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_stopPosition_clampsOutOfRangeInput

    func test_stopPosition_clampsOutOfRangeInput() {
        let low = ThemeStopPosition(x: -3, y: -0.5)
        let high = ThemeStopPosition(x: 4, y: 1.9)

        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.y, 0)
        XCTAssertEqual(high.x, 1)
        XCTAssertEqual(high.y, 1)
    }

    // MARK: - Default layout

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_defaultStopPositions_areDeterministicAndInBounds

    func test_defaultStopPositions_areDeterministicAndInBounds() {
        for count in 0...6 {
            let first = SpaceTheme.defaultStopPositions(count: count)
            let second = SpaceTheme.defaultStopPositions(count: count)

            XCTAssertEqual(first, second, "defaultStopPositions(count: \(count)) must be pure -- the same count always yields the same layout.")
            XCTAssertEqual(first.count, count)
            for position in first {
                XCTAssertTrue((0.12...0.88).contains(position.x), "x \(position.x) escaped the inset the layout promises.")
                XCTAssertTrue((0.12...0.88).contains(position.y), "y \(position.y) escaped the inset the layout promises.")
            }
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_defaultStopPositions_areDistinct

    func test_defaultStopPositions_areDistinct() {
        let positions = SpaceTheme.defaultStopPositions(count: 4)
        for (i, a) in positions.enumerated() {
            for (j, b) in positions.enumerated() where j > i {
                let distance = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
                XCTAssertGreaterThan(distance, 0.1, "Default stops \(i) and \(j) overlap at distance \(distance).")
            }
        }
    }

    // MARK: - Resolution when the stop count changes

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolvedStopPositions_keepsHandSetPrefixWhenAStopIsAdded

    func test_resolvedStopPositions_keepsHandSetPrefixWhenAStopIsAdded() {
        var theme = Self.sampleTheme
        let handSet = [
            ThemeStopPosition(x: 0.15, y: 0.15),
            ThemeStopPosition(x: 0.85, y: 0.20),
            ThemeStopPosition(x: 0.50, y: 0.80),
        ]
        theme.stopPositions = handSet
        theme.colors.append(ThemeColor(red: 0.4, green: 0.3, blue: 0.5))

        let resolved = theme.resolvedStopPositions

        XCTAssertEqual(resolved.count, 4)
        XCTAssertEqual(Array(resolved.prefix(3)), handSet, "The three stops the user positioned must stay exactly where they were put.")
        XCTAssertEqual(
            resolved[3],
            SpaceTheme.defaultStopPositions(count: 4)[3],
            "Only the genuinely-unpositioned new stop falls back, and it takes the default for the new count."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolvedStopPositions_truncatesWhenAStopIsRemoved

    func test_resolvedStopPositions_truncatesWhenAStopIsRemoved() {
        var theme = Self.sampleTheme
        let handSet = [
            ThemeStopPosition(x: 0.15, y: 0.15),
            ThemeStopPosition(x: 0.85, y: 0.20),
            ThemeStopPosition(x: 0.50, y: 0.80),
        ]
        theme.stopPositions = handSet
        theme.colors.removeLast()

        XCTAssertEqual(theme.resolvedStopPositions, Array(handSet.prefix(2)))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_normalizeStopPositions_leavesAnUnpositionedThemeNil

    func test_normalizeStopPositions_leavesAnUnpositionedThemeNil() {
        var theme = Self.sampleTheme
        XCTAssertNil(theme.stopPositions)

        theme.colors.append(ThemeColor(red: 0.4, green: 0.3, blue: 0.5))
        theme.normalizeStopPositions()

        XCTAssertNil(
            theme.stopPositions,
            "A theme nobody has hand-positioned must keep deriving its layout fresh, not be silently upgraded to a frozen array."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_normalizeStopPositions_reconcilesAPositionedTheme

    func test_normalizeStopPositions_reconcilesAPositionedTheme() {
        var theme = Self.sampleTheme
        theme.stopPositions = [
            ThemeStopPosition(x: 0.15, y: 0.15),
            ThemeStopPosition(x: 0.85, y: 0.20),
            ThemeStopPosition(x: 0.50, y: 0.80),
        ]
        theme.colors.append(ThemeColor(red: 0.4, green: 0.3, blue: 0.5))
        theme.normalizeStopPositions()

        XCTAssertEqual(theme.stopPositions?.count, 4)
        XCTAssertEqual(theme.stopPositions, theme.resolvedStopPositions)
    }

    // MARK: - The renderer's fallback is genuinely unchanged

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_meshColours_forAnUnpositionedTheme_areTheOriginalCycledPalette

    func test_meshColours_forAnUnpositionedTheme_areTheOriginalCycledPalette() {
        let theme = Self.sampleTheme
        XCTAssertNil(theme.stopPositions)

        let adapted = theme.adaptedColors(for: .dark)
        let painted = ThemePaintView(theme: theme, colorScheme: .dark).meshColors(adapted)

        XCTAssertEqual(painted.count, 9)
        for index in 0..<9 {
            assertSameColor(
                painted[index],
                adapted[index % adapted.count],
                "Grid point \(index) must still take the plain cycled palette entry when no positions are set."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_meshColours_withMismatchedPositionCount_fallBackToCycling

    func test_meshColours_withMismatchedPositionCount_fallBackToCycling() {
        var theme = Self.sampleTheme
        theme.stopPositions = [ThemeStopPosition(x: 0.1, y: 0.1)]

        let adapted = theme.adaptedColors(for: .dark)
        let painted = ThemePaintView(theme: theme, colorScheme: .dark).meshColors(adapted)

        for index in 0..<9 {
            assertSameColor(painted[index], adapted[index % adapted.count])
        }
    }

    // MARK: - Positions actually move colour

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_meshColours_pullTowardAStopPinnedToACorner

    func test_meshColours_pullTowardAStopPinnedToACorner() {
        var theme = Self.sampleTheme
        theme.stopPositions = [
            ThemeStopPosition(x: 0.0, y: 0.0),
            ThemeStopPosition(x: 1.0, y: 1.0),
            ThemeStopPosition(x: 0.95, y: 0.95),
        ]

        let adapted = theme.adaptedColors(for: .dark)
        let painted = ThemePaintView(theme: theme, colorScheme: .dark).meshColors(adapted)

        let topLeft = painted[0].srgbComponents
        let toStopZero = distance(topLeft, adapted[0].srgbComponents)
        let toStopOne = distance(topLeft, adapted[1].srgbComponents)

        XCTAssertLessThan(
            toStopZero,
            toStopOne,
            "The top-left grid point must read closer to the stop pinned on top of it than to the ones pinned diagonally opposite."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_meshColours_changeWhenAStopMoves

    func test_meshColours_changeWhenAStopMoves() {
        var theme = Self.sampleTheme
        theme.stopPositions = [
            ThemeStopPosition(x: 0.1, y: 0.1),
            ThemeStopPosition(x: 0.9, y: 0.5),
            ThemeStopPosition(x: 0.5, y: 0.9),
        ]
        let adapted = theme.adaptedColors(for: .dark)
        let before = ThemePaintView(theme: theme, colorScheme: .dark).meshColors(adapted)

        theme.stopPositions?[0] = ThemeStopPosition(x: 0.9, y: 0.9)
        let after = ThemePaintView(theme: theme, colorScheme: .dark).meshColors(adapted)

        let moved = zip(before, after).contains { distance($0.srgbComponents, $1.srgbComponents) > 0.001 }
        XCTAssertTrue(moved, "Dragging a stop across the surface must repaint the mesh.")
    }

    // MARK: - Style selection actually paints something different (Defect 3)

    // Regression cover: .mesh used to fall back to a plain LinearGradient below three stops, so "Linear" and "Mesh" looked identical at the common two-stop case.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_themeStyles_paintVisiblyDifferentBitmapsAtTwoStops
    func test_themeStyles_paintVisiblyDifferentBitmapsAtTwoStops() {
        let baseTheme = SpaceTheme(
            style: .solid,
            colors: [
                ThemeColor(red: 0.157, green: 0.192, blue: 0.290),
                ThemeColor(red: 0.836, green: 0.427, blue: 0.447),
            ],
            angle: 18,
            grain: 0
        )
        XCTAssertEqual(baseTheme.colors.count, 2, "This regression only reproduces at the specific stop count the defect report called out.")
        XCTAssertNil(baseTheme.stopPositions, "Unpositioned is the common case this bug actually shipped in -- meshColors(_:) must reach its fallback-cycling path here, not the hand-positioned one already covered above.")

        let size = CGSize(width: 240, height: 240)

        func rendered(_ style: SpaceTheme.Style) -> RenderedImage {
            var theme = baseTheme
            theme.style = style
            return render(ThemePaintView(theme: theme, colorScheme: .dark), size: size, appearance: .darkAqua)
        }

        let solid = rendered(.solid)
        let linear = rendered(.linear)
        let mesh = rendered(.mesh)

        var samplePoints: [(x: Int, y: Int)] = []
        for row in 1..<6 {
            for col in 1..<6 {
                samplePoints.append((x: col * Int(size.width) / 6, y: row * Int(size.height) / 6))
            }
        }

        func meanSampledDistance(_ lhs: RenderedImage, _ rhs: RenderedImage) -> Double {
            let total = samplePoints.reduce(0.0) { partial, point in
                let a = lhs.color(atX: point.x, y: point.y)
                let b = rhs.color(atX: point.x, y: point.y)
                return partial + distance(
                    (red: a.r, green: a.g, blue: a.b, alpha: a.a),
                    (red: b.r, green: b.g, blue: b.b, alpha: b.a)
                )
            }
            return total / Double(samplePoints.count)
        }

        let solidVsLinear = meanSampledDistance(solid, linear)
        let linearVsMesh = meanSampledDistance(linear, mesh)
        let solidVsMesh = meanSampledDistance(solid, mesh)

        XCTAssertGreaterThan(
            solidVsLinear, 0.08,
            "A flat fill and a two-stop gradient sweep must read as visibly different across the sampled grid."
        )
        XCTAssertGreaterThan(
            linearVsMesh, 0.05,
            "This is the exact regression under test: with the pre-fix >= 3 stop guard, .mesh painted the same near-vertical gradient .linear does at two stops, and this distance would be near zero."
        )
        XCTAssertGreaterThan(
            solidVsMesh, 0.08,
            "Mesh at two stops must also read as visibly different from a flat solid fill."
        )
    }

    // MARK: - Stop-count clamping and selection validity (correctness pass)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clampedStopIndex_staysInBoundsAtEveryEdge

    func test_clampedStopIndex_staysInBoundsAtEveryEdge() {
        XCTAssertEqual(SpaceTheme.clampedStopIndex(0, count: 4), 0)
        XCTAssertEqual(SpaceTheme.clampedStopIndex(3, count: 4), 3)
        XCTAssertEqual(SpaceTheme.clampedStopIndex(2, count: 4), 2, "An index already inside the current bounds must pass through unchanged.")
        XCTAssertEqual(SpaceTheme.clampedStopIndex(4, count: 4), 3, "An index one past the last stop (the shape left behind by a remove) must clamp to the new last index.")
        XCTAssertEqual(SpaceTheme.clampedStopIndex(99, count: 4), 3)
        XCTAssertEqual(SpaceTheme.clampedStopIndex(-1, count: 4), 0, "A negative index must never be handed back to a caller that will subscript colors with it.")
        XCTAssertEqual(SpaceTheme.clampedStopIndex(0, count: 1), 0, "The minimum stop count (1) must still resolve to a valid, subscriptable index.")
        XCTAssertEqual(SpaceTheme.clampedStopIndex(5, count: 0), 0, "count == 0 has no valid index at all; this must not go negative or crash a caller that then subscripts colors[0].")
    }

    // MARK: - Palette apply resets positions (correctness pass)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_applyPalette_replacesColorsAndResetsStopPositions

    func test_applyPalette_replacesColorsAndResetsStopPositions() {
        var theme = Self.sampleTheme
        theme.stopPositions = [
            ThemeStopPosition(x: 0.1, y: 0.1),
            ThemeStopPosition(x: 0.5, y: 0.5),
            ThemeStopPosition(x: 0.9, y: 0.9),
        ]
        let newPalette = [ThemeColor(red: 0.9, green: 0.2, blue: 0.1), ThemeColor(red: 0.1, green: 0.4, blue: 0.9)]

        theme.applyPalette(newPalette)

        XCTAssertEqual(theme.colors, newPalette, "Applying a palette must replace colors wholesale, not merge or append.")
        XCTAssertNil(
            theme.stopPositions,
            "A freshly picked whole palette must go back to the default diagonal layout, not keep a hand-dragged arrangement authored for a different set of colours."
        )
    }

    // MARK: - Single-stop colour assignment touches only the selected index (correctness pass)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_setColor_touchesOnlyTheSelectedStop

    func test_setColor_touchesOnlyTheSelectedStop() {
        var theme = Self.sampleTheme
        XCTAssertEqual(theme.colors.count, 3)
        let originalFirst = theme.colors[0]
        let originalThird = theme.colors[2]
        let picked = ThemeColor(red: 0.05, green: 0.85, blue: 0.4)

        theme.setColor(picked, atStop: 1)

        XCTAssertEqual(theme.colors[0], originalFirst, "Stop 0 must be untouched by a pick scoped to stop 1.")
        XCTAssertEqual(theme.colors[1], picked, "Stop 1 must take the picked colour.")
        XCTAssertEqual(theme.colors[2], originalThird, "Stop 2 must be untouched by a pick scoped to stop 1.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_setColor_outOfBoundsIndexIsANoOp

    func test_setColor_outOfBoundsIndexIsANoOp() {
        var theme = Self.sampleTheme
        let original = theme.colors

        theme.setColor(ThemeColor(red: 1, green: 1, blue: 1), atStop: 99)
        theme.setColor(ThemeColor(red: 0, green: 0, blue: 0), atStop: -1)

        XCTAssertEqual(theme.colors, original, "A stop index that does not exist (e.g. transiently out of sync with selectedStopIndex around a stop-count change) must leave colors untouched rather than trap.")
    }

    // MARK: - Swatch strip page cycling wraparound (correctness pass)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_wrappedPageIndex_wrapsForwardPastTheLastPage

    func test_wrappedPageIndex_wrapsForwardPastTheLastPage() {
        XCTAssertEqual(ThemeSwatchStripView.wrappedPageIndex(0, by: 1, count: 3), 1)
        XCTAssertEqual(ThemeSwatchStripView.wrappedPageIndex(1, by: 1, count: 3), 2)
        XCTAssertEqual(ThemeSwatchStripView.wrappedPageIndex(2, by: 1, count: 3), 0, "Chevron-right from the last page must wrap to the first.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_wrappedPageIndex_wrapsBackwardPastTheFirstPage

    func test_wrappedPageIndex_wrapsBackwardPastTheFirstPage() {
        XCTAssertEqual(ThemeSwatchStripView.wrappedPageIndex(0, by: -1, count: 3), 2, "Chevron-left from the first page must wrap to the last.")
        XCTAssertEqual(ThemeSwatchStripView.wrappedPageIndex(2, by: -1, count: 3), 1)
        XCTAssertEqual(ThemeSwatchStripView.wrappedPageIndex(1, by: -1, count: 3), 0)
    }

    // MARK: - Rotary dial value<->angle conversion (correctness pass)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rotationDial_valueFromRawDegrees_isIdentityAcrossItsFullRange

    func test_rotationDial_valueFromRawDegrees_isIdentityAcrossItsFullRange() {
        for degrees in stride(from: 0.0, through: 360.0, by: 30.0) {
            let value = ThemeRotaryDial<EmptyView>.value(fromRawDegrees: degrees, range: 0...360, angleRange: 0...360)
            XCTAssertEqual(value, degrees, accuracy: 0.0001, "The rotation dial's range and angleRange are identical, so this conversion must be the identity function.")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_rotationDial_angleDegrees_isInverseOfValueFromRawDegrees

    func test_rotationDial_angleDegrees_isInverseOfValueFromRawDegrees() {
        for value in stride(from: 0.0, through: 350.0, by: 45.0) {
            let angle = ThemeRotaryDial<EmptyView>.angleDegrees(forValue: value, range: 0...360, angleRange: 0...360)
            let roundTripped = ThemeRotaryDial<EmptyView>.value(fromRawDegrees: angle, range: 0...360, angleRange: 0...360)
            XCTAssertEqual(roundTripped, value, accuracy: 0.0001, "Drawing at angleDegrees(value) and then committing that same raw angle back must reproduce the original value.")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_softnessDial_valueFromRawDegrees_mapsTheSweepAndClampsTheDeadZone

    func test_softnessDial_valueFromRawDegrees_mapsTheSweepAndClampsTheDeadZone() {
        let range = 0.0...1.0
        let angleRange = -135.0...135.0

        // atan2 reports 0..<360 clockwise from 12 o'clock, so -135 degrees is
        // raw 225 and +135 degrees is raw 135.
        XCTAssertEqual(ThemeRotaryDial<EmptyView>.value(fromRawDegrees: 225, range: range, angleRange: angleRange), 0, accuracy: 0.0001, "Raw 225 degrees is angleRange's own lower bound (-135); it must map to range.lowerBound.")
        XCTAssertEqual(ThemeRotaryDial<EmptyView>.value(fromRawDegrees: 135, range: range, angleRange: angleRange), 1, accuracy: 0.0001, "Raw 135 degrees is angleRange's own upper bound; it must map to range.upperBound.")
        XCTAssertEqual(ThemeRotaryDial<EmptyView>.value(fromRawDegrees: 0, range: range, angleRange: angleRange), 0.5, accuracy: 0.0001, "Raw 0 degrees (12 o'clock) sits exactly at the sweep's own midpoint.")

        let atDeadZoneCenter = ThemeRotaryDial<EmptyView>.value(fromRawDegrees: 180, range: range, angleRange: angleRange)
        XCTAssertEqual(atDeadZoneCenter, 1, accuracy: 0.0001, "Raw 180 lands on the boundary this implementation resolves toward angleRange's upper bound (135), i.e. range.upperBound (1).")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_softnessDial_valueFromRawDegrees_deadZoneNeighboursSnapToOppositeEnds

    func test_softnessDial_valueFromRawDegrees_deadZoneNeighboursSnapToOppositeEnds() {
        let range = 0.0...1.0
        let angleRange = -135.0...135.0

        XCTAssertEqual(
            ThemeRotaryDial<EmptyView>.value(fromRawDegrees: 179, range: range, angleRange: angleRange), 1, accuracy: 0.0001,
            "Just past the sweep's upper raw edge (135) but still short of the unwrap threshold must clamp to the upper end."
        )
        XCTAssertEqual(
            ThemeRotaryDial<EmptyView>.value(fromRawDegrees: 181, range: range, angleRange: angleRange), 0, accuracy: 0.0001,
            "Just past the unwrap threshold (>180) renormalizes toward the lower end and clamps there instead."
        )
    }

    // MARK: - Wave slider grain clamp and nudge (correctness pass)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_waveSlider_clampedValue_staysInsideZeroToOne

    func test_waveSlider_clampedValue_staysInsideZeroToOne() {
        XCTAssertEqual(ThemeWaveSlider.clampedValue(-0.4), 0)
        XCTAssertEqual(ThemeWaveSlider.clampedValue(1.7), 1)
        XCTAssertEqual(ThemeWaveSlider.clampedValue(0.35), 0.35, accuracy: 0.0001)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_waveSlider_nudgedValue_movesByTheDocumentedStepAndClamps

    func test_waveSlider_nudgedValue_movesByTheDocumentedStepAndClamps() {
        XCTAssertEqual(ThemeWaveSlider.nudgedValue(0.5, direction: 1), 0.55, accuracy: 0.0001, "Grain nudges by 0.05 per arrow-key press/VoiceOver increment.")
        XCTAssertEqual(ThemeWaveSlider.nudgedValue(0.5, direction: -1), 0.45, accuracy: 0.0001)
        XCTAssertEqual(ThemeWaveSlider.nudgedValue(0.98, direction: 1), 1, "Nudging past the top must clamp, not overshoot.")
        XCTAssertEqual(ThemeWaveSlider.nudgedValue(0.02, direction: -1), 0, "Nudging past the bottom must clamp, not go negative.")
    }

    // MARK: - Visual verification

    private static var screenshotOutputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrbitAppTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("refs/screenshots", isDirectory: true)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_themeEditorPanel_dark

    func test_themeEditorPanel_dark() async {
        await renderAndSavePanel(name: "space-theme-picker", appearance: .darkAqua)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_themeEditorPanel_light

    func test_themeEditorPanel_light() async {
        await renderAndSavePanel(name: "space-theme-picker-light", appearance: .aqua)
    }

    private func renderAndSavePanel(name: String, appearance: NSAppearance.Name) async {
        var theme = Self.sampleTheme
        theme.stopPositions = SpaceTheme.defaultStopPositions(count: theme.colors.count)

        let isDark = appearance == .darkAqua || appearance == .vibrantDark
        // Stands in for the popover chrome renderForScreenshot provides no background for; controls here rely on it for their low-opacity fills to read correctly.
        let popoverChrome = isDark
            ? Color(.sRGB, red: 0.129, green: 0.129, blue: 0.141, opacity: 1)
            : Color(.sRGB, red: 0.957, green: 0.957, blue: 0.965, opacity: 1)

        let view = ThemeEditorView(theme: .constant(theme), onDone: {})
            .background(popoverChrome)
        let rendered = await renderForScreenshot(view, size: CGSize(width: 380, height: 568), appearance: appearance)
        let destination = Self.screenshotOutputDirectory.appendingPathComponent("\(name).png")

        XCTAssertTrue(rendered.writePNG(to: destination), "Expected to write \(name).png to \(destination.path).")
        print("ThemeEditorRedesignTests: wrote \(name).png to \(destination.path)")
    }

    // MARK: - Helpers

    private func distance(
        _ a: (red: Double, green: Double, blue: Double, alpha: Double),
        _ b: (red: Double, green: Double, blue: Double, alpha: Double)
    ) -> Double {
        let dr = a.red - b.red
        let dg = a.green - b.green
        let db = a.blue - b.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private func assertSameColor(_ lhs: Color, _ rhs: Color, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(distance(lhs.srgbComponents, rhs.srgbComponents), 0.0001, message, file: file, line: line)
    }
}
