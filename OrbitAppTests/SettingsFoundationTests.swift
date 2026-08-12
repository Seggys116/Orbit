import SwiftUI
import XCTest
@testable import Orbit

// MARK: - 1. SettingsPalette / SettingsMetrics — pure logic, no rendering

final class SettingsPaletteAndMetricsTests: XCTestCase {

    // MARK: SettingsPalette aliases LibraryPalette

    func test_settingsPalette_everyMember_aliasesLibraryPaletteExactly() {
        XCTAssertEqual(SettingsPalette.sidebarBackground, LibraryPalette.sidebarBackground)
        XCTAssertEqual(SettingsPalette.contentBackground, LibraryPalette.contentBackground)
        XCTAssertEqual(SettingsPalette.divider, LibraryPalette.divider)
        XCTAssertEqual(SettingsPalette.textPrimary, LibraryPalette.textPrimary)
        XCTAssertEqual(SettingsPalette.textSecondary, LibraryPalette.textSecondary)
        XCTAssertEqual(SettingsPalette.textTertiary, LibraryPalette.textTertiary)
        XCTAssertEqual(SettingsPalette.selectedFill, LibraryPalette.selectedFill)
        XCTAssertEqual(SettingsPalette.hoverFill, LibraryPalette.hoverFill)
        XCTAssertEqual(SettingsPalette.accent, LibraryPalette.accent)
    }

    // MARK: SettingsMetrics — rail figures deliberately shared with Library's

    func test_railWidth_deliberatelyMatchesLibraryNavWidth() {
        XCTAssertEqual(SettingsMetrics.railWidth, LibraryMetrics.navWidth)
    }

    func test_railRowHeight_deliberatelyMatchesLibraryNavRowHeight() {
        XCTAssertEqual(SettingsMetrics.railRowHeight, LibraryMetrics.navRowHeight)
    }

    func test_windowDefaultWidth_isDerivedFromRailAndContentColumn() {
        let expected = SettingsMetrics.railWidth + 1 + SettingsMetrics.contentMaxWidth + (SettingsMetrics.contentHorizontalPadding * 2)
        XCTAssertEqual(SettingsMetrics.windowDefaultWidth, expected)
    }

    func test_windowMinWidth_isDerivedFromRailAndContentMinWidth() {
        let expected = SettingsMetrics.railWidth + 1 + SettingsMetrics.contentMinWidth
        XCTAssertEqual(SettingsMetrics.windowMinWidth, expected)
    }

    func test_windowDefaultSize_isAtLeastTheWindowMinimumSize() {
        XCTAssertGreaterThanOrEqual(SettingsMetrics.windowDefaultWidth, SettingsMetrics.windowMinWidth)
        XCTAssertGreaterThanOrEqual(SettingsMetrics.windowDefaultHeight, SettingsMetrics.windowMinHeight)
    }

    func test_contentMinWidth_isLessThanContentMaxWidth() {
        XCTAssertLessThan(SettingsMetrics.contentMinWidth, SettingsMetrics.contentMaxWidth)
    }

    func test_windowDefaultHeight_isTallerThanThePreviousDefault() {
        let previousDefaultHeight: CGFloat = 480
        XCTAssertGreaterThan(SettingsMetrics.windowDefaultHeight, previousDefaultHeight)
    }
}

// MARK: - 2. SettingsPane.shortcuts's "Keybinds" title divergence

final class SettingsPaneKeybindsRenameTests: XCTestCase {

    func test_shortcutsPane_title_isKeybinds() {
        XCTAssertEqual(SettingsPane.shortcuts.title, "Keybinds")
    }

    func test_shortcutsPane_rawValue_isUnchanged() {
        XCTAssertEqual(SettingsPane.shortcuts.rawValue, "shortcuts")
    }

    func test_everyOtherPaneTitle_isUnchangedByTheKeybindsRename() {
        XCTAssertEqual(SettingsPane.general.title, "General")
        XCTAssertEqual(SettingsPane.profiles.title, "Profiles")
        XCTAssertEqual(SettingsPane.assist.title, "Assist")
        XCTAssertEqual(SettingsPane.links.title, "Links")
        XCTAssertEqual(SettingsPane.extensions.title, "Extensions")
        XCTAssertEqual(SettingsPane.icloud.title, "iCloud")
    }
}

// MARK: - 3. SettingsSidebarView — real rendering

@MainActor
final class SettingsSidebarRenderTests: XCTestCase {

    private static let size = CGSize(width: SettingsMetrics.railWidth, height: 400)

    func test_background_paintsSettingsPaletteSidebarBackground() {
        let rendered = render(SettingsSidebarView(selection: .constant(.general)), size: Self.size)
        let sampled = rendered.color(atX: 4, y: Int(Self.size.height) - 4)

        let referenceSwatch = render(SettingsPalette.sidebarBackground, size: Self.size)
        let expected = referenceSwatch.color(atX: 4, y: Int(Self.size.height) - 4)

        if !sampled.isApproximately(expected, tolerance: 0.03) {
            rendered.writeDiagnosticPNG(named: "SettingsSidebarRenderTests_background-FAILED")
        }
        XCTAssertTrue(
            sampled.isApproximately(expected, tolerance: 0.03),
            "Expected the rail's background to equal SettingsPalette.sidebarBackground (rendered reference: \(expected)), found \(sampled)."
        )
    }

    func test_background_paintsSettingsPaletteSidebarBackground_atTheVeryTopOfTheFrame() {
        let rendered = render(SettingsSidebarView(selection: .constant(.general)), size: Self.size)
        let sampled = rendered.color(atX: 4, y: 2)

        let referenceSwatch = render(SettingsPalette.sidebarBackground, size: Self.size)
        let expected = referenceSwatch.color(atX: 4, y: 2)

        if !sampled.isApproximately(expected, tolerance: 0.03) {
            rendered.writeDiagnosticPNG(named: "SettingsSidebarRenderTests_backgroundTop-FAILED")
        }
        XCTAssertTrue(
            sampled.isApproximately(expected, tolerance: 0.03),
            "Expected the rail's background to reach the very top of its own frame (rendered reference: \(expected)), found \(sampled)."
        )
    }

    func test_selectedRow_fillVisiblyDiffersFromTheSameRowWhenUnselected() {
        let firstRowBand = CGRect(x: 0, y: 34, width: SettingsMetrics.railWidth, height: SettingsMetrics.railRowHeight + 12)

        let selected = render(SettingsSidebarView(selection: .constant(.general)), size: Self.size)
        let unselected = render(SettingsSidebarView(selection: .constant(.icloud)), size: Self.size)

        let selectedAverage = selected.averageColor(in: firstRowBand)
        let unselectedAverage = unselected.averageColor(in: firstRowBand)

        if selectedAverage.isApproximately(unselectedAverage, tolerance: 0.02) {
            selected.writeDiagnosticPNG(named: "SettingsSidebarRenderTests_selected-FAILED")
            unselected.writeDiagnosticPNG(named: "SettingsSidebarRenderTests_unselected-FAILED")
        }
        XCTAssertFalse(
            selectedAverage.isApproximately(unselectedAverage, tolerance: 0.02),
            "Expected General's row to look visibly different selected (\(selectedAverage)) vs unselected (\(unselectedAverage))."
        )
    }

    func test_everyRowRenders_someNonBackgroundContent() {
        let rendered = render(SettingsSidebarView(selection: .constant(.general)), size: Self.size)
        let background = RGBA(r: 0.1647, g: 0.1451, b: 0.1961, a: 1)
        let railBand = CGRect(x: 0, y: 34, width: SettingsMetrics.railWidth, height: 34 + (SettingsMetrics.railRowHeight * 7))
        XCTAssertTrue(
            rendered.containsNonBackgroundPixels(in: railBand, background: background, tolerance: 0.05),
            "Expected the rail's row list to paint real foreground content (icons/labels) over its background."
        )
    }
}

// MARK: - 4. SettingsRootView — the real rail-height regression

@MainActor
final class SettingsRootViewLayoutTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    func test_railFillsFullHeight_evenBesideGeneralPanesTallerContent() {
        SettingsRouter.shared.selectedPane = .general
        let size = CGSize(width: SettingsMetrics.windowDefaultWidth, height: SettingsMetrics.windowDefaultHeight)
        let rendered = render(SettingsRootView().environment(env), size: size)
        let sampled = rendered.color(atX: 4, y: 2)

        let referenceSwatch = render(SettingsPalette.sidebarBackground, size: size)
        let expected = referenceSwatch.color(atX: 4, y: 2)

        if !sampled.isApproximately(expected, tolerance: 0.03) {
            rendered.writeDiagnosticPNG(named: "SettingsRootViewLayoutTests_railTop-FAILED")
        }
        XCTAssertTrue(
            sampled.isApproximately(expected, tolerance: 0.03),
            "Expected SettingsRootView's rail to reach the very top of the window, flush against SettingsPalette.sidebarBackground (rendered reference: \(expected)), found \(sampled) — a mismatch here means the HStack's children are no longer the same height (see this test's own header)."
        )
    }
}

// MARK: - 5. OrbitSettingsRow — truncation regression (2026-08-06 design cleanup pass)

@MainActor
final class OrbitSettingsRowTruncationTests: XCTestCase {

    private static let oneLineDescription = "Short."

    private static let longDescription =
        "Stored in your login Keychain, never in Orbit's preferences or its saved state. Not needed for a local server."

    func test_longDescription_wrapsToMultipleLines_ratherThanTruncatingToOne() {
        let width: CGFloat = 260

        let oneLine = render(
            OrbitSettingsRow(title: "API key", description: Self.oneLineDescription) {
                OrbitToggle(accessibilityLabel: "test control", isOn: .constant(true))
            },
            size: CGSize(width: width, height: 200)
        )
        let long = render(
            OrbitSettingsRow(title: "API key", description: Self.longDescription) {
                OrbitToggle(accessibilityLabel: "test control", isOn: .constant(true))
            },
            size: CGSize(width: width, height: 200)
        )

        guard let oneLineBox = oneLine.boundingBoxOfContent(), let longBox = long.boundingBoxOfContent() else {
            oneLine.writeDiagnosticPNG(named: "OrbitSettingsRowTruncationTests_oneLine_empty")
            long.writeDiagnosticPNG(named: "OrbitSettingsRowTruncationTests_long_empty")
            XCTFail("OrbitSettingsRow drew nothing at width \(width)pt.")
            return
        }

        if longBox.height <= oneLineBox.height + 10 {
            long.writeDiagnosticPNG(named: "OrbitSettingsRowTruncationTests_long-FAILED")
        }
        XCTAssertGreaterThan(
            longBox.height, oneLineBox.height + 10,
            "A \(Self.longDescription.count)-character description rendered at \(width)pt must wrap to more than one line — got a row height of \(longBox.height)pt, barely more than the \(oneLineBox.height)pt a single short line costs. This is the exact truncation defect defect 1 of the 2026-08-06 design cleanup pass fixed: OrbitSettingsRow's description Text had no .fixedSize(horizontal: false, vertical: true), so it silently clipped to one ellipsized line instead of wrapping."
        )
    }

    func test_orbitSettingsValueRow_longDescription_wrapsToMultipleLines() {
        let width: CGFloat = 260

        let oneLine = render(
            OrbitSettingsValueRow(title: "Status", description: Self.oneLineDescription) {
                Text("Never").foregroundStyle(.secondary)
            },
            size: CGSize(width: width, height: 200)
        )
        let long = render(
            OrbitSettingsValueRow(title: "Status", description: Self.longDescription) {
                Text("Never").foregroundStyle(.secondary)
            },
            size: CGSize(width: width, height: 200)
        )

        guard let oneLineBox = oneLine.boundingBoxOfContent(), let longBox = long.boundingBoxOfContent() else {
            oneLine.writeDiagnosticPNG(named: "OrbitSettingsValueRowTruncationTests_oneLine_empty")
            long.writeDiagnosticPNG(named: "OrbitSettingsValueRowTruncationTests_long_empty")
            XCTFail("OrbitSettingsValueRow drew nothing at width \(width)pt.")
            return
        }

        if longBox.height <= oneLineBox.height + 10 {
            long.writeDiagnosticPNG(named: "OrbitSettingsValueRowTruncationTests_long-FAILED")
        }
        XCTAssertGreaterThan(
            longBox.height, oneLineBox.height + 10,
            "OrbitSettingsValueRow must wrap a long description across multiple lines, exactly like OrbitSettingsRow — got \(longBox.height)pt vs. a one-line baseline of \(oneLineBox.height)pt."
        )
    }
}
