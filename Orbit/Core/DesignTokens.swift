import AppKit
import Observation
import SwiftUI

enum OrbitMetrics {
    static let iconFavicon: CGFloat = 15
    static let iconChrome: CGFloat = 17
    static let iconMedium: CGFloat = 20
    static let iconLarge: CGFloat = 24

    static let sidebarFolderToggleSize: CGFloat = iconFavicon

    // Apple Color Emoji draw near edge-to-edge, unlike SF Symbols, so they need a smaller fraction.
    static let spaceIconEmojiScaleFraction: CGFloat = 0.58
    static let spaceIconSymbolScaleFraction: CGFloat = 0.78

    static let sidebarDefaultWidth: CGFloat = 240
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 560
    // Hit column: anything wider is empty padding that steals clicks from the tab edge.
    static let sidebarResizeHandleWidth: CGFloat = 4
    static let sidebarHoverEdgeWidth: CGFloat = 8
    static let sidebarAutoHideDelay: Double = 0.45

    static let sidebarRowHeight: CGFloat = 36
    // Must stay 0 — sidebarRowHeight is already the full row pitch.
    static let sidebarRowSpacing: CGFloat = 0
    static let sidebarRowPillVerticalInset: CGFloat = 3
    static let sidebarRowCornerRadius: CGFloat = 10
    static let sidebarRowLoadingBarHeight: CGFloat = 2

    static let sidebarInsertionIndicatorThickness: CGFloat = 2
    static let sidebarInsertionIndicatorKnobDiameter: CGFloat = 8

    static let sidebarRowEdgeDropZoneFraction: CGFloat = 0.28

    static let sidebarHorizontalPadding: CGFloat = 10
    static let sidebarRowContentInset: CGFloat = 5
    static let sidebarSectionSpacing: CGFloat = 10
    static let sidebarInterSectionGap: CGFloat = 8

    static let sidebarTopRowHeight: CGFloat = 36
    static let sidebarTopRowIconSize: CGFloat = iconChrome

    static let sidebarSpaceNameRowHeight: CGFloat = 36
    static let sidebarSpaceNameFontSize: CGFloat = 14
    static let sidebarSpaceNameOpacity: Double = 0.5
    static let sidebarSpaceIconSize: CGFloat = iconChrome

    static let sidebarRowFontSize: CGFloat = 13
    static let sidebarRowLabelOpacityInactive: Double = 0.82
    static let sidebarRowLabelOpacityActive: Double = 1.0
    static let sidebarActiveRowOpacity: Double = 0.10
    static let sidebarHoverRowOpacity: Double = 0.06

    static let sidebarSplitGroupContainerOpacity: Double = 0.04
    static let sidebarSplitGroupPaneOpacity: Double = sidebarHoverRowOpacity
    static let sidebarSplitGroupPaneHoverOpacity: Double = (sidebarSplitGroupPaneOpacity + sidebarActiveRowOpacity) / 2
    static let sidebarSplitGroupInnerInset: CGFloat = 3
    static let sidebarSplitGroupPaneCornerRadius: CGFloat = sidebarRowCornerRadius - sidebarSplitGroupInnerInset
    static let sidebarRowContentSpacing: CGFloat = 10
    static let sidebarSplitGroupContentSpacing: CGFloat = sidebarRowContentSpacing / 2
    static let sidebarPinnedSlashSpacing: CGFloat = sidebarRowContentSpacing / 3
    static let sidebarIndentPerDepth: CGFloat = faviconSize
    static let sidebarFaviconCornerRadius: CGFloat = 6
    static let sidebarCloseButtonSize: CGFloat = 20
    static let sidebarUtilityGlyphSize: CGFloat = 12

    static let sidebarDividerOpacity: Double = 0.12

    static let todayDividerRowHeight: CGFloat = sidebarCloseButtonSize

    static let sidebarNewTabRowOpacity: Double = 0.45

    static let faviconSize: CGFloat = 16
    static let spaceBadgeSize: CGFloat = 40

    static let favoriteTileMinWidth: CGFloat = 52
    static let favoriteTileHeight: CGFloat = 52
    static let favoriteIconGlyphSize: CGFloat = 24
    static let favoriteTileCornerRadius: CGFloat = 14
    static let favoriteGridSpacing: CGFloat = 8
    static let favoriteGridVerticalPadding: CGFloat = 10

    static let favoritesMaximumCount = 12

    static let sidebarBottomBarHeight: CGFloat = 36
    static let sidebarBottomBarIconSize: CGFloat = 24
    static let sidebarBottomBarSpacing: CGFloat = 12
    static let sidebarBottomBarHorizontalPadding: CGFloat = sidebarHorizontalPadding

    static let liveCalendarRowInnerSpacing: CGFloat = 6
    static let liveCalendarJoinButtonHorizontalPadding: CGFloat = 9
    static let liveCalendarJoinButtonVerticalPadding: CGFloat = 4
    static let liveCalendarCardHorizontalPadding: CGFloat = 10
    static let liveCalendarCardVerticalPadding: CGFloat = 7

    static let miniPlayerCornerRadius: CGFloat = 12

    static let miniPlayerHorizontalInset: CGFloat = sidebarBottomBarHorizontalPadding

    static let miniPlayerContentPadding: CGFloat = sidebarHorizontalPadding / 2

    static let miniPlayerRowSpacing: CGFloat = sidebarInterSectionGap

    static let miniPlayerControlGlyphSize: CGFloat = iconFavicon

    static let miniPlayerControlSize: CGFloat = sidebarBottomBarIconSize

    static let miniPlayerSurfaceOpacity: Double = 0.16

    // The tile each Space icon sits in; measured against Arc, whose tile is ~33pt with the glyph at ~45% of it.
    static let spacePagerDotSize: CGFloat = 28
    static let spacePagerDotSpacing: CGFloat = 2
    static let spacePagerContainerPadding: CGFloat = 2
    static let spacePagerInactiveOpacity: Double = 0.72
    static let spacePagerIconInactiveOpacity: Double = 0.5
    static let spacePagerIconInactiveSaturation: Double = 0.1
    static let spacePagerTileCornerRadius: CGFloat = 8
    static let spacePagerEmojiScaleFraction: CGFloat = 0.52
    static let spacePagerSymbolScaleFraction: CGFloat = 0.5
    static let spacePagerDotScaleFraction: CGFloat = 0.3

    static let spacePagerMinimumSizeScale: CGFloat = 0.6

    static let trafficLightDiameter: CGFloat = 12
    static let trafficLightSpacing: CGFloat = 8
    // Must equal sidebarHorizontalPadding: aligns with the real, AppKit-hosted traffic lights.
    static let trafficLightLeadingInset: CGFloat = sidebarHorizontalPadding

    static let trafficLightTopInset: CGFloat = (sidebarTopRowHeight - trafficLightDiameter) / 2

    static let cardCornerRadius: CGFloat = 10

    static let cardInset: CGFloat = 9

    // Docked leading padding: the resize handle occupies the rest of cardInset, so the page stays one inset from the sidebar.
    static let contentCardLeadingSeam: CGFloat = cardInset - sidebarResizeHandleWidth

    static let cardBorderWidth: CGFloat = 1
    static let cardBorderOpacity: Double = 0.10
    static let cardShadowRadius: CGFloat = 0
    static let cardShadowOpacity: Double = 0
    static let cardShadowYOffset: CGFloat = 0

    static let commandBarWidth: CGFloat = 620
    static let commandBarMaxHeight: CGFloat = 460
    static let commandBarCornerRadius: CGFloat = 12
    static let commandBarTopOffset: CGFloat = 96
    static let commandBarInputFontSize: CGFloat = 17
    static let commandBarRowHeight: CGFloat = 44

    static let commandBarSeparatorOpacity: Double = cardBorderOpacity
    static let commandBarSeparatorHeight: CGFloat = 1
    static let commandBarSeparatorInset: CGFloat = 16

    static let splitDividerThickness: CGFloat = 6
    static let splitMinimumFraction: Double = 0.15

    static let popoverCornerRadius: CGFloat = 14
    static let tabPreviewWidth: CGFloat = 280
    static let tabPreviewHeight: CGFloat = 180

    static let folderPreviewWidth: CGFloat = tabPreviewWidth
    static let folderPreviewVisibleRows: CGFloat = 8
    static let folderPreviewMaxHeight: CGFloat = commandBarRowHeight * folderPreviewVisibleRows

    static let folderPreviewHoverDelay: Double = 0.45

    static let alertAccessoryFieldWidth: CGFloat = 260
    static let alertAccessoryFieldHeight: CGFloat = 22

    static let siteControlActionButtonHeight: CGFloat = 32
    static let siteControlActionButtonGap: CGFloat = 8
    static let siteControlActionButtonCornerRadius: CGFloat = 5
    static let siteControlRowHorizontalMargin: CGFloat = 9
    static let siteControlRowBadgeDiameter: CGFloat = 32
    static let siteControlRowBadgeGlyphSize: CGFloat = 13
    static let siteControlRowPitch: CGFloat = 43
    static let siteControlRowBadgeToTextGap: CGFloat = 9
    static let siteControlRowTitleFontSize: CGFloat = 13.5
    static let siteControlRowValueFontSize: CGFloat = 11.5
    static let siteControlFooterPillHeight: CGFloat = 32
    static let siteControlFooterPillHorizontalPadding: CGFloat = 11
    static let siteControlFooterGlyphSize: CGFloat = 14
    static let siteControlFooterLabelFontSize: CGFloat = 14
    static let siteControlFooterGlyphToTextGap: CGFloat = 9

    static let extensionInstallSheetWidth: CGFloat = 420
    static let extensionInstallSheetPadding: CGFloat = 20
    static let extensionInstallStackSpacing: CGFloat = 14
    static let extensionInstallHeaderSpacing: CGFloat = 12
    static let extensionInstallIconSize: CGFloat = 36
    static let extensionInstallIconGlyphSize: CGFloat = 20
    static let extensionInstallTitleFontSize: CGFloat = 15
    static let extensionInstallDetailFontSize: CGFloat = 11.5
    static let extensionInstallCaptionFontSize: CGFloat = 11
    static let extensionInstallFailureGlyphSize: CGFloat = 15

    static let extensionInstallProgressBarHeight: CGFloat = 4
    static let extensionInstallProgressBarWidth: CGFloat =
        extensionInstallSheetWidth - (extensionInstallSheetPadding * 2)
        - extensionInstallIconSize - extensionInstallHeaderSpacing
    // Stages that cannot report a fraction paint the full span dimmed, not a partial bar.
    static let extensionInstallProgressIndeterminateOpacity: Double = 0.45
    static let extensionInstallProgressTrackOpacityDark: Double = 0.16
    static let extensionInstallProgressTrackOpacityLight: Double = 0.12
    // Held across stage changes so the window does not resize under the pointer.
    static let extensionInstallProgressMinimumBodyHeight: CGFloat = 52

    static let contextMenuWidth: CGFloat = 250
    // Deliberately not popoverCornerRadius: the menu is its own Orbit-drawn surface with a wider radius.
    static let contextMenuCornerRadius: CGFloat = 18
    static let contextMenuRowHeight: CGFloat = 32
    // Close to a pill against a 32pt row, so a selected row never reads as a squared-off system bar.
    static let contextMenuRowCornerRadius: CGFloat = 11
    static let contextMenuRowHorizontalPadding: CGFloat = 8
    static let contextMenuRowHorizontalInset: CGFloat = 6
    static let contextMenuVerticalPadding: CGFloat = contextMenuRowHorizontalInset
    static let contextMenuIconSize: CGFloat = 13
    static let contextMenuIconToTitleGap: CGFloat = 8
    static let contextMenuFontSize: CGFloat = 13
    static let contextMenuShortcutFontSize: CGFloat = 11.5
    static let contextMenuSectionHeaderFontSize: CGFloat = 11
    static let contextMenuDividerVerticalPadding: CGFloat = 5
    static let contextMenuSubmenuChevronSize: CGFloat = 10
    static let contextMenuHoverOpacityLight: Double = 0.30
    static let contextMenuHoverOpacityDark: Double = 0.26
    static let contextMenuDisabledOpacity: Double = 0.38
    static let contextMenuDividerThickness: CGFloat = 1

    static let contextMenuShadowRadius: CGFloat = 22
    static let contextMenuShadowOpacity: Double = 0.34
    static let contextMenuShadowYOffset: CGFloat = 8
    // Must stay >= contextMenuShadowRadius + contextMenuShadowYOffset, or the panel clips its own shadow.
    static let contextMenuShadowPadding: CGFloat = 34
    static let contextMenuArrowWidth: CGFloat = 24
    static let contextMenuArrowHeight: CGFloat = 10
    // Without the fillet the beak meets the edge at a corner and reads as a stuck-on triangle.
    static let contextMenuArrowFillet: CGFloat = 4
    static let contextMenuArrowTipRadius: CGFloat = 2.4
    static let contextMenuAnchorGap: CGFloat = 5
    static let contextMenuScreenEdgeInset: CGFloat = 8
    static let contextMenuSubmenuOverlap: CGFloat = 4
}

@MainActor
@Observable
final class BorderlessSettings {

    #if DEBUG
    static var shared = BorderlessSettings()
    #else
    static let shared = BorderlessSettings()
    #endif

    static let defaultsKey = "OrbitBorderlessWindow"

    @ObservationIgnored private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.defaultsKey)
        }
    }

    init(defaults: UserDefaults = OrbitDefaults.standard) {
        self.defaults = defaults
        self.isEnabled = (defaults.object(forKey: Self.defaultsKey) as? Bool) ?? false
    }

    var cardInset: CGFloat { isEnabled ? 0 : OrbitMetrics.cardInset }

    var cardCornerRadius: CGFloat { OrbitMetrics.cardCornerRadius }

    // Card edges that run flush against the window edge; the window's own mask rounds those corners.
    func flushEdges(isSidebarVisible: Bool) -> Edge.Set {
        guard isEnabled else { return [] }
        return isSidebarVisible ? [.top, .bottom, .trailing] : .all
    }

    static func cardCornerRadii(flushEdges: Edge.Set) -> RectangleCornerRadii {
        let radius = OrbitMetrics.cardCornerRadius
        func corner(_ a: Edge.Set, _ b: Edge.Set) -> CGFloat {
            flushEdges.contains(a) && flushEdges.contains(b) ? 0 : radius
        }
        return RectangleCornerRadii(
            topLeading: corner(.top, .leading),
            bottomLeading: corner(.bottom, .leading),
            bottomTrailing: corner(.bottom, .trailing),
            topTrailing: corner(.top, .trailing)
        )
    }

    func contentCardLeadingInset(isSidebarVisible: Bool) -> CGFloat {
        if isEnabled { return isSidebarVisible ? -OrbitMetrics.sidebarResizeHandleWidth : 0 }
        return isSidebarVisible ? OrbitMetrics.contentCardLeadingSeam : OrbitMetrics.cardInset
    }
}

private struct PaneCardFlushEdgesKey: EnvironmentKey {
    static let defaultValue: Edge.Set = []
}

extension EnvironmentValues {
    var paneCardFlushEdges: Edge.Set {
        get { self[PaneCardFlushEdgesKey.self] }
        set { self[PaneCardFlushEdgesKey.self] = newValue }
    }
}

enum OrbitMotion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let quick = Animation.spring(response: 0.22, dampingFraction: 0.86)
    static let dramatic = Animation.spring(response: 0.48, dampingFraction: 0.78)
    static let interactive = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.8)

    static let fade = Animation.easeOut(duration: 0.16)

    @MainActor static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Nil under Reduce Motion so the change snaps; fades survive because they carry no movement.
    static func resolved(_ token: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion && token != fade ? nil : token
    }
}

/// For use outside a view, where `accessibilityReduceMotion` is not available from the environment.
@MainActor
@discardableResult
func withOrbitAnimation<Result>(_ token: Animation = OrbitMotion.standard, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(OrbitMotion.resolved(token, reduceMotion: OrbitMotion.prefersReducedMotion), body)
}

private struct OrbitAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let token: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(OrbitMotion.resolved(token, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func orbitAnimation<Value: Equatable>(_ token: Animation = OrbitMotion.standard, value: Value) -> some View {
        modifier(OrbitAnimationModifier(token: token, value: value))
    }
}

/// Shared corner-radius scale. Nested shapes are concentric: inner = outer - inset, via `concentric`.
enum OrbitRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let row: CGFloat = OrbitMetrics.sidebarRowCornerRadius
    static let lg: CGFloat = 12
    static let panel: CGFloat = OrbitMetrics.popoverCornerRadius
    static let window: CGFloat = 16

    static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outer - inset)
    }
}

enum OrbitSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

/// Neutral palette shared with the Orbit website; every text colour passes WCAG AA on `bg`, `bg2` and `card`.
enum OrbitNeutral {
    static let bg = adaptive(light: 0xF7F7F8, dark: 0x06060C)
    static let bg2 = adaptive(light: 0xEFEFF2, dark: 0x0B0B14)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x101019)
    static let raised = adaptive(light: 0xFFFFFF, dark: 0x16161F)
    static let ink = adaptive(light: 0x0B0B12, dark: 0xF4F4F8)
    static let ink2 = adaptive(light: 0x2A2A36, dark: 0xD6D6E0)
    static let muted = adaptive(light: 0x5B5B6B, dark: 0xA3A3B5)
    static let muted2 = adaptive(light: 0x6E6E7E, dark: 0x8D8DA0)
    static let line = adaptive(light: 0x0B0B12, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let hairline = adaptive(light: 0x0B0B12, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let chip = adaptive(light: 0x0B0B12, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.07)
    static let chipStrong = adaptive(light: 0x0B0B12, lightAlpha: 0.10, dark: 0xFFFFFF, darkAlpha: 0.12)
    static let sunk = adaptive(light: 0x0B0B12, lightAlpha: 0.035, dark: 0x000000, darkAlpha: 0.30)
    static let accent = adaptive(light: 0x6D3FE0, dark: 0xB49CFF)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x0B0B12)
    static let good = adaptive(light: 0x15703B, dark: 0x4CC38A)
    static let warn = adaptive(light: 0x9A5500, dark: 0xF0A443)
    static let bad = adaptive(light: 0xC4302B, dark: 0xFF7A70)

    static func adaptive(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum OrbitFont {
    static let sidebarRow = Font.system(size: OrbitMetrics.sidebarRowFontSize, weight: .regular)
    static let sidebarRowActive = Font.system(size: OrbitMetrics.sidebarRowFontSize, weight: .medium)
    static let sidebarSectionHeader = Font.system(size: 11, weight: .semibold)
    static let sidebarSpaceName = Font.system(size: OrbitMetrics.sidebarSpaceNameFontSize, weight: .regular)
    static let sidebarNewTabRow = Font.system(size: OrbitMetrics.sidebarRowFontSize, weight: .regular)
    static let spaceTitle = Font.system(size: 13, weight: .semibold)
    static let commandBarInput = Font.system(size: OrbitMetrics.commandBarInputFontSize, weight: .regular)
    static let commandBarRowTitle = Font.system(size: 13.5, weight: .medium)
    static let commandBarRowSubtitle = Font.system(size: 11.5, weight: .regular)
    static let addressIndicator = Font.system(size: 12, weight: .medium)
}

enum OrbitAcrylic {
    static let windowTintOpacity: Double = 0.60

    static let panelTintOpacity: Double = 0.55

    static let panelEdgeHighlight = Color.white.opacity(0.10)
    static let panelEdgeHighlightWidth: CGFloat = 1
}

enum OrbitColor {
    static let sidebarDividerLight = Color.black.opacity(0.08)
    static let sidebarDividerDark = Color.white.opacity(0.09)
    static let hoverFillLight = Color.black.opacity(0.055)
    static let hoverFillDark = Color.white.opacity(0.08)
    static let selectionFillLight = Color.black.opacity(0.09)
    static let selectionFillDark = Color.white.opacity(0.13)

    // The panel is borderless and transparent, so this must be a real opaque colour.
    static let menuSurfaceDark = Color(.sRGB, red: 0.129, green: 0.129, blue: 0.141, opacity: 1)
    static let menuSurfaceLight = Color(.sRGB, red: 0.973, green: 0.973, blue: 0.980, opacity: 1)

    static func menuSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? menuSurfaceDark : menuSurfaceLight
    }

    static func menuDivider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? sidebarDividerDark : sidebarDividerLight
    }

    // A selected row must whisper, not read as the system's saturated accent bar.
    static let menuHighlightWarmHue: Double = 0.94
    static let menuHighlightWarmth: Double = 0.78
    static let menuHighlightSaturationScaleDark: Double = 0.40
    static let menuHighlightSaturationScaleLight: Double = 0.95
    static let menuHighlightBrightnessDark: Double = 0.88
    static let menuHighlightBrightnessLight: Double = 0.62

    static func menuHighlight(for scheme: ColorScheme) -> Color {
        let accent = NSColor(Color.accentColor).usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let scale = scheme == .dark ? menuHighlightSaturationScaleDark : menuHighlightSaturationScaleLight
        return Color(
            hue: warmedHue(from: Double(hue)),
            saturation: min(Double(saturation), 1) * scale,
            brightness: scheme == .dark ? menuHighlightBrightnessDark : menuHighlightBrightnessLight
        )
    }

    /// Travels the shorter way round the hue wheel toward the rose anchor.
    private static func warmedHue(from hue: Double) -> Double {
        var delta = menuHighlightWarmHue - hue
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        let warmed = hue + delta * menuHighlightWarmth
        return warmed - warmed.rounded(.down)
    }
}
