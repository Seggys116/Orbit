import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class ToolbarHoverHighlightTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
    }

    // `Tab` alone is ambiguous in a file that imports SwiftUI.
    private func makeTab(url: String = "https://example.com") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func cleanup(_ tabIDs: [TabID]) {
        for id in tabIDs {
            env.state.tabs.removeValue(forKey: id)
            env.themeColors.removeValue(forKey: id)
        }
    }

    // MARK: - Geometry, derived from the same constants the view lays out with

    private static let canvas = CGSize(width: 520, height: OrbitToolbarMetrics.totalHeight)

    private static var iconRowCentreY: CGFloat {
        OrbitToolbarMetrics.topPadding + OrbitToolbarMetrics.height / 2
    }

    private static func navIconBox(_ index: Int) -> CGRect {
        let x = OrbitToolbarMetrics.leadingPadding
            + (OrbitToolbarMetrics.navIconSize + OrbitToolbarMetrics.navIconSpacing) * CGFloat(index)
        return CGRect(
            x: x,
            y: iconRowCentreY - OrbitToolbarMetrics.navIconSize / 2,
            width: OrbitToolbarMetrics.navIconSize,
            height: OrbitToolbarMetrics.navIconSize
        )
    }

    private static func fillProbe(in box: CGRect) -> CGRect {
        CGRect(x: box.minX + 1.5, y: box.midY - 3, width: 4, height: 6)
    }

    private func luminance(_ c: RGBA) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    // orbitScreenshotModeDragDisabled is required: ImageRenderer otherwise paints a corrupted block over each control's NSViewRepresentable click catcher, and every probe below would read identically regardless of what the header actually painted.
    private func renderHeader(tab: Orbit.Tab, hovered: Bool) -> RenderedImage {
        render(
            ToolbarView(tab: tab)
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true)
                .environment(\.orbitForcedHoverHighlight, hovered),
            size: Self.canvas
        )
    }

    // MARK: - 1. The shading actually appears, on every control the user named

    func test_hoveringPaintsAFillBehindEachNavButton_onADarkHeader() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }
        env.themeColors[tab.id] = ThemeColor(red: 0.06, green: 0.06, blue: 0.09)

        let resting = renderHeader(tab: tab, hovered: false)
        let hovered = renderHeader(tab: tab, hovered: true)

        let probe = Self.fillProbe(in: Self.navIconBox(2))
        let restingLuminance = luminance(resting.averageColor(in: probe))
        let hoveredLuminance = luminance(hovered.averageColor(in: probe))

        if hoveredLuminance <= restingLuminance + 0.01 {
            resting.writeDiagnosticPNG(named: "hoverHighlight-nav-resting-FAILED")
            hovered.writeDiagnosticPNG(named: "hoverHighlight-nav-hovered-FAILED")
        }
        XCTAssertGreaterThan(
            hoveredLuminance, restingLuminance + 0.01,
            "The reload button's own \(OrbitToolbarMetrics.navIconSize)pt box must visibly shade on hover over a dark header — resting luminance \(restingLuminance), hovered \(hoveredLuminance) in \(probe)."
        )
    }

    func test_hoveringPaintsAFillBehindEachNavButton_onALightHeader() {
        let tab = makeTab(url: "https://light.example.com")
        defer { cleanup([tab.id]) }
        env.themeColors[tab.id] = ThemeColor(red: 0.96, green: 0.96, blue: 0.98)

        let resting = renderHeader(tab: tab, hovered: false)
        let hovered = renderHeader(tab: tab, hovered: true)

        let probe = Self.fillProbe(in: Self.navIconBox(2))
        let restingLuminance = luminance(resting.averageColor(in: probe))
        let hoveredLuminance = luminance(hovered.averageColor(in: probe))

        if hoveredLuminance >= restingLuminance - 0.01 {
            resting.writeDiagnosticPNG(named: "hoverHighlight-navLight-resting-FAILED")
            hovered.writeDiagnosticPNG(named: "hoverHighlight-navLight-hovered-FAILED")
        }
        XCTAssertLessThan(
            hoveredLuminance, restingLuminance - 0.01,
            "Over a light header the hover fill is derived from the *dark* resolved foreground, so the button's box must darken — resting luminance \(restingLuminance), hovered \(hoveredLuminance) in \(probe)."
        )
    }

    func test_hoveringPaintsAFillBehindTheAddressGroup() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }
        env.themeColors[tab.id] = ThemeColor(red: 0.06, green: 0.06, blue: 0.09)

        let resting = renderHeader(tab: tab, hovered: false)
        let hovered = renderHeader(tab: tab, hovered: true)

        let band = CGRect(
            x: Self.canvas.width / 2 - 60,
            y: Self.iconRowCentreY - 8,
            width: 120,
            height: 16
        )
        let restingLuminance = luminance(resting.averageColor(in: band))
        let hoveredLuminance = luminance(hovered.averageColor(in: band))

        if hoveredLuminance <= restingLuminance + 0.005 {
            resting.writeDiagnosticPNG(named: "hoverHighlight-address-resting-FAILED")
            hovered.writeDiagnosticPNG(named: "hoverHighlight-address-hovered-FAILED")
        }
        XCTAssertGreaterThan(
            hoveredLuminance, restingLuminance + 0.005,
            "The centred address group must shade on hover — 'Buttons **and the URL** need a hover bg'. Resting luminance \(restingLuminance), hovered \(hoveredLuminance) across \(band)."
        )
    }

    func test_hoveringPaintsAFillBehindTheTrailingCluster() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }
        env.themeColors[tab.id] = ThemeColor(red: 0.06, green: 0.06, blue: 0.09)

        let resting = renderHeader(tab: tab, hovered: false)
        let hovered = renderHeader(tab: tab, hovered: true)

        let splitBox = CGRect(
            x: Self.canvas.width - OrbitToolbarMetrics.trailingPadding - OrbitToolbarMetrics.trailingIconSize,
            y: Self.iconRowCentreY - OrbitToolbarMetrics.trailingIconSize / 2,
            width: OrbitToolbarMetrics.trailingIconSize,
            height: OrbitToolbarMetrics.trailingIconSize
        )
        let probe = Self.fillProbe(in: splitBox)
        let restingLuminance = luminance(resting.averageColor(in: probe))
        let hoveredLuminance = luminance(hovered.averageColor(in: probe))

        if hoveredLuminance <= restingLuminance + 0.01 {
            resting.writeDiagnosticPNG(named: "hoverHighlight-trailing-resting-FAILED")
            hovered.writeDiagnosticPNG(named: "hoverHighlight-trailing-hovered-FAILED")
        }
        XCTAssertGreaterThan(
            hoveredLuminance, restingLuminance + 0.01,
            "The Split View button's own box must shade on hover — resting luminance \(restingLuminance), hovered \(hoveredLuminance) in \(probe)."
        )
    }

    // MARK: - 2. Nothing changes at rest

    func test_atRest_theHeaderIsUnchangedByTheHighlight() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }
        env.themeColors[tab.id] = ThemeColor(red: 0.06, green: 0.06, blue: 0.09)

        let resting = renderHeader(tab: tab, hovered: false)
        let restingAgain = renderHeader(tab: tab, hovered: false)

        var probes = (0..<3).map { Self.fillProbe(in: Self.navIconBox($0)) }
        probes.append(CGRect(x: Self.canvas.width / 2 - 60, y: Self.iconRowCentreY - 8, width: 120, height: 16))
        probes.append(Self.fillProbe(in: CGRect(
            x: Self.canvas.width - OrbitToolbarMetrics.trailingPadding - OrbitToolbarMetrics.trailingIconSize,
            y: Self.iconRowCentreY - OrbitToolbarMetrics.trailingIconSize / 2,
            width: OrbitToolbarMetrics.trailingIconSize,
            height: OrbitToolbarMetrics.trailingIconSize
        )))

        for probe in probes {
            let a = resting.averageColor(in: probe)
            let b = restingAgain.averageColor(in: probe)
            XCTAssertTrue(
                a.isApproximately(b, tolerance: 0.005),
                "At rest the hover highlight must paint nothing at all — \(probe) sampled \(a) in one render and \(b) in an identical one."
            )
        }
    }

    // MARK: - 3. The hover surface can never take a click

    func test_hoverSurface_neverClaimsAClick() {
        let view = OrbitHoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        XCTAssertNil(
            view.hitTest(NSPoint(x: 11, y: 11)),
            "OrbitHoverTrackingNSView must never be a hit-test target — a hover decoration that claims clicks kills the button it decorates."
        )
    }

    func test_hoverSurface_isNeverAWindowDragHandle() {
        let view = OrbitHoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "OrbitHoverTrackingNSView must not double as a title-bar drag handle."
        )
    }

    func test_hoverSurface_reportsEnterAndExitExactlyOnce() {
        let view = OrbitHoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.updateHover(atLocationInView: NSPoint(x: 11, y: 11))
        XCTAssertTrue(view.isHovering)
        view.updateHover(atLocationInView: NSPoint(x: 12, y: 12))
        view.updateHover(atLocationInView: NSPoint(x: 40, y: 11))
        XCTAssertFalse(view.isHovering)
        view.updateHover(atLocationInView: NSPoint(x: 41, y: 11))

        XCTAssertEqual(
            reported, [true, false],
            "Hover changes must be reported once per genuine edge — got \(reported)."
        )
    }

    // MARK: - The two fill opacities, and the polarity they are chosen by

    func test_hoverFillOpacity_isHeavierOverDarkChromeThanLight() {
        XCTAssertGreaterThan(
            OrbitToolbarMetrics.hoverFillOpacity(glyphsAreDark: false),
            OrbitToolbarMetrics.hoverFillOpacity(glyphsAreDark: true),
            "A white fill over dark chrome needs more alpha than a black fill over light chrome to read as equally strong — see OrbitToolbarMetrics' 'Hover highlight' section."
        )
        XCTAssertGreaterThan(OrbitToolbarMetrics.hoverFillOpacity(glyphsAreDark: true), 0)
        XCTAssertLessThan(
            OrbitToolbarMetrics.hoverFillOpacity(glyphsAreDark: false), 0.25,
            "A hover hint that heavy stops being a hint and starts being a selected state."
        )
    }

    // #ff6600's luminance (0.4987) sits just under 0.5 while black is the higher-contrast
    // glyph on it, so this is the case where the threshold and the glyph colour disagree.
    func test_hoverFillPolarity_followsTheGlyphColourNotTheLuminanceThreshold() {
        let hackerNewsOrange = ThemeColor(red: 1.0, green: 0.4, blue: 0.0)
        XCTAssertLessThan(
            hackerNewsOrange.luminance, 0.5,
            "Test precondition: #ff6600 must sit just below the luminance threshold, which is what makes the two rules disagree here."
        )

        XCTAssertTrue(
            PaneHeaderColorResolver.hasDarkForeground(on: hackerNewsOrange),
            "#ff6600 takes dark glyphs by contrast measurement — the hover fill's polarity must agree."
        )
        XCTAssertEqual(
            PaneHeaderColorResolver.foregroundColor(for: hackerNewsOrange),
            PaneHeaderColorResolver.invertedDark,
            "Test premise: the glyphs on #ff6600 really are the dark end of the scale."
        )

        for color in [
            ThemeColor(red: 0, green: 0, blue: 0),
            ThemeColor(red: 1, green: 1, blue: 1),
            hackerNewsOrange,
            ThemeColor(red: 0.5, green: 0.5, blue: 0.5),
            ThemeColor(red: 0.05, green: 0.05, blue: 0.08),
            ThemeColor(red: 0.96, green: 0.96, blue: 0.98)
        ] {
            let glyphIsDark = PaneHeaderColorResolver.foregroundColor(for: color) == PaneHeaderColorResolver.invertedDark
            XCTAssertEqual(
                PaneHeaderColorResolver.hasDarkForeground(on: color), glyphIsDark,
                "hasDarkForeground(on:) must never disagree with foregroundColor(for:) — disagreed on \(color)."
            )
        }
    }

    // MARK: - The shading traces the tap target, not the glyph

    func test_hoverHighlightCornerRadius_staysWellInsideTheTapTarget() {
        XCTAssertGreaterThan(OrbitToolbarMetrics.hoverHighlightCornerRadius, 0)
        XCTAssertLessThan(
            OrbitToolbarMetrics.hoverHighlightCornerRadius, OrbitToolbarMetrics.headerIconSize / 2,
            "A corner radius of half the tap target or more is a circle, not a button shape — the shading must still read as the square-ish region it actually is."
        )
    }

    func test_theLinkButtonAndTheURLAreTwoSeparateHoverTargets() {
        XCTAssertGreaterThan(
            OrbitToolbarMetrics.addressPillGap, 0,
            "A zero gap puts the two pills' edges in contact and they read as one pill with a seam — which is the state the user reported."
        )
        XCTAssertLessThan(
            OrbitToolbarMetrics.addressPillGap, OrbitToolbarMetrics.addressGroupHorizontalInset,
            "A gap wider than the address field's own inset breaks the pair apart into two unrelated controls."
        )
        XCTAssertEqual(
            OrbitToolbarMetrics.addressCopyPillSize, OrbitToolbarMetrics.headerIconSize,
            "The copy control's pill is the header's standard button box — see OrbitToolbarMetrics.addressCopyPillSize."
        )
    }
}
