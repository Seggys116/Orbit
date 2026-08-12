import AppKit
import SwiftUI

enum OrbitMetrics {
    // MARK: Icon scale

    static let iconFavicon: CGFloat = 15
    static let iconChrome: CGFloat = 17
    static let iconMedium: CGFloat = 20
    static let iconLarge: CGFloat = 24

    static let sidebarFolderToggleSize: CGFloat = iconFavicon

    static let spaceIconEmojiScaleFraction: CGFloat = 0.8

    // MARK: Sidebar

    static let sidebarDefaultWidth: CGFloat = 240
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 560
    static let sidebarResizeHandleWidth: CGFloat = 8
    static let sidebarHoverEdgeWidth: CGFloat = 8
    static let sidebarAutoHideDelay: Double = 0.45

    static let sidebarRowHeight: CGFloat = 36
    // Must stay 0 — sidebarRowHeight is already the full row pitch.
    static let sidebarRowSpacing: CGFloat = 0
    static let sidebarRowPillVerticalInset: CGFloat = 3
    static let sidebarRowCornerRadius: CGFloat = 10
    static let sidebarRowLoadingBarHeight: CGFloat = 2

    // MARK: Drag insertion indicator

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

    // MARK: Split-group row (`Orbit/UI/Sidebar/SplitGroupRowView.swift`)

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

    // MARK: Favorites/"Top Apps" tiles

    static let favoriteTileMinWidth: CGFloat = 52
    static let favoriteTileHeight: CGFloat = 52
    static let favoriteIconGlyphSize: CGFloat = 24
    static let favoriteTileCornerRadius: CGFloat = 14
    static let favoriteGridSpacing: CGFloat = 8
    static let favoriteGridVerticalPadding: CGFloat = 10

    static let favoritesMaximumCount = 12

    // MARK: Sidebar bottom bar

    static let sidebarBottomBarHeight: CGFloat = 36
    static let sidebarBottomBarIconSize: CGFloat = 24
    static let sidebarBottomBarSpacing: CGFloat = 12
    static let sidebarBottomBarHorizontalPadding: CGFloat = sidebarHorizontalPadding

    // MARK: Live Calendar row (LiveCalendarRowView)

    static let liveCalendarRowInnerSpacing: CGFloat = 6
    static let liveCalendarJoinButtonHorizontalPadding: CGFloat = 9
    static let liveCalendarJoinButtonVerticalPadding: CGFloat = 4
    static let liveCalendarCardHorizontalPadding: CGFloat = 10
    static let liveCalendarCardVerticalPadding: CGFloat = 7

    // MARK: Now-playing card (SidebarMiniPlayerView)

    static let miniPlayerCornerRadius: CGFloat = 12

    static let miniPlayerHorizontalInset: CGFloat = sidebarBottomBarHorizontalPadding

    static let miniPlayerContentPadding: CGFloat = sidebarHorizontalPadding / 2

    static let miniPlayerRowSpacing: CGFloat = sidebarInterSectionGap

    static let miniPlayerControlGlyphSize: CGFloat = iconFavicon

    static let miniPlayerControlSize: CGFloat = sidebarBottomBarIconSize

    static let miniPlayerSurfaceOpacity: Double = 0.16

    // MARK: Space pager (SpaceSwitcherPagerView)

    static let spacePagerDotSize: CGFloat = sidebarBottomBarIconSize
    static let spacePagerDotSpacing: CGFloat = 10
    static let spacePagerContainerPadding: CGFloat = 4
    static let spacePagerActiveOpacity: Double = 1
    static let spacePagerInactiveOpacity: Double = 0.55

    static let spacePagerMinimumSizeScale: CGFloat = 0.6

    // MARK: Traffic lights

    static let trafficLightDiameter: CGFloat = 12
    static let trafficLightSpacing: CGFloat = 8
    // Must equal sidebarHorizontalPadding: aligns with the real, AppKit-hosted traffic lights.
    static let trafficLightLeadingInset: CGFloat = sidebarHorizontalPadding

    static let trafficLightTopInset: CGFloat = (sidebarTopRowHeight - trafficLightDiameter) / 2

    // MARK: Content card

    static let cardCornerRadius: CGFloat = 10

    static let cardInset: CGFloat = 9

    static let cardBorderWidth: CGFloat = 1
    static let cardBorderOpacity: Double = 0.10
    static let cardShadowRadius: CGFloat = 0
    static let cardShadowOpacity: Double = 0
    static let cardShadowYOffset: CGFloat = 0

    // MARK: Command Bar

    static let commandBarWidth: CGFloat = 620
    static let commandBarMaxHeight: CGFloat = 460
    static let commandBarCornerRadius: CGFloat = 12
    static let commandBarTopOffset: CGFloat = 96
    static let commandBarInputFontSize: CGFloat = 17
    static let commandBarRowHeight: CGFloat = 44

    static let commandBarSeparatorOpacity: Double = cardBorderOpacity
    static let commandBarSeparatorHeight: CGFloat = 1
    static let commandBarSeparatorInset: CGFloat = 16

    // MARK: Split view

    static let splitDividerThickness: CGFloat = 6
    static let splitMinimumFraction: Double = 0.15

    // MARK: Popovers

    static let popoverCornerRadius: CGFloat = 14
    static let tabPreviewWidth: CGFloat = 280
    static let tabPreviewHeight: CGFloat = 180

    // MARK: Folder hover preview

    static let folderPreviewWidth: CGFloat = tabPreviewWidth
    static let folderPreviewVisibleRows: CGFloat = 8
    static let folderPreviewMaxHeight: CGFloat = commandBarRowHeight * folderPreviewVisibleRows

    static let folderPreviewHoverDelay: Double = 0.45

    // MARK: Modal accessory fields

    static let alertAccessoryFieldWidth: CGFloat = 260
    static let alertAccessoryFieldHeight: CGFloat = 22

    // MARK: Site Control Center (SiteControlPopoverView)

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

    // MARK: Extension install flow (ExtensionConsentSheetView is this flow's
    // reference dialog — every other visual state shares its scale).

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

    // The progress states are presented in the consent dialog's own sheet, at
    // its width and padding, so the bar spans the same text column the consent
    // dialog's description occupies rather than a width of its own.
    static let extensionInstallProgressBarHeight: CGFloat = 4
    static let extensionInstallProgressBarWidth: CGFloat =
        extensionInstallSheetWidth - (extensionInstallSheetPadding * 2)
        - extensionInstallIconSize - extensionInstallHeaderSpacing
    // A stage that genuinely cannot report a fraction (verifying, installing)
    // paints the full span dimmed rather than a partial bar: a bar stopped at
    // some fraction of the way across claims a position nothing measured.
    static let extensionInstallProgressIndeterminateOpacity: Double = 0.45
    static let extensionInstallProgressTrackOpacityDark: Double = 0.16
    static let extensionInstallProgressTrackOpacityLight: Double = 0.12
    // The sheet has to hold its height across a stage change, or the window
    // resizes under the pointer every time the installer moves on.
    static let extensionInstallProgressMinimumBodyHeight: CGFloat = 52

    // MARK: Context menu (OrbitContextMenuView) -- the custom, non-NSMenu
    // menu used for the web content right-click menu and other Orbit
    // surfaces that opt into it.

    static let contextMenuWidth: CGFloat = 250
    // Deliberately not popoverCornerRadius: the menu panel reads as its own
    // Orbit-drawn surface and carries a wider radius than a system popover.
    static let contextMenuCornerRadius: CGFloat = 18
    static let contextMenuRowHeight: CGFloat = 32
    // Close to a pill against a 32pt row -- a selected row must never read as
    // a squared-off system selection bar.
    static let contextMenuRowCornerRadius: CGFloat = 11
    static let contextMenuRowHorizontalPadding: CGFloat = 12
    // The visible gutter between the highlight and the container edge.
    static let contextMenuRowHorizontalInset: CGFloat = 8
    static let contextMenuVerticalPadding: CGFloat = 7
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

    // MARK: Floating menu panel (OrbitMenuPanel) — Orbit draws all of this
    // itself; the panel is borderless and fully transparent.

    static let contextMenuShadowRadius: CGFloat = 22
    static let contextMenuShadowOpacity: Double = 0.34
    static let contextMenuShadowYOffset: CGFloat = 8
    // Must stay >= contextMenuShadowRadius + contextMenuShadowYOffset, or the
    // panel clips its own shadow.
    static let contextMenuShadowPadding: CGFloat = 34
    static let contextMenuArrowWidth: CGFloat = 24
    static let contextMenuArrowHeight: CGFloat = 10
    // The concave fillet that carries the container's straight edge into the
    // beak's flank, and how blunt the tip is. Without the fillet the beak meets
    // the edge at a corner and reads as a triangle stuck onto the container.
    static let contextMenuArrowFillet: CGFloat = 4
    static let contextMenuArrowTipRadius: CGFloat = 2.4
    static let contextMenuAnchorGap: CGFloat = 5
    static let contextMenuScreenEdgeInset: CGFloat = 8
    static let contextMenuSubmenuOverlap: CGFloat = 4
}

enum OrbitMotion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let quick = Animation.spring(response: 0.22, dampingFraction: 0.86)
    static let dramatic = Animation.spring(response: 0.48, dampingFraction: 0.78)
    static let interactive = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.8)
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

    // The floating menu panel is borderless and transparent, so this is the
    // only thing behind a menu row — it has to be a real, opaque colour, not a
    // translucent tint layered over some other Orbit surface.
    static let menuSurfaceDark = Color(.sRGB, red: 0.129, green: 0.129, blue: 0.141, opacity: 1)
    static let menuSurfaceLight = Color(.sRGB, red: 0.973, green: 0.973, blue: 0.980, opacity: 1)

    static func menuSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? menuSurfaceDark : menuSurfaceLight
    }

    static func menuDivider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? sidebarDividerDark : sidebarDividerLight
    }

    // A selected row must whisper, not read as the system's saturated accent bar; these constants
    // pull the hue toward a warm rose and strip most of the saturation.
    static let menuHighlightWarmHue: Double = 0.94
    static let menuHighlightWarmth: Double = 0.78
    // Light needs far more of the tint's own saturation than dark: it is laid
    // over a near-white surface at low alpha, which washes hue out almost
    // completely. Dark sits over near-black, where a little goes a long way.
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

    /// Travels the shorter way round the wheel, so an accent already past the
    /// rose anchor is pulled back to it rather than dragged the long way.
    private static func warmedHue(from hue: Double) -> Double {
        var delta = menuHighlightWarmHue - hue
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        let warmed = hue + delta * menuHighlightWarmth
        return warmed - warmed.rounded(.down)
    }
}
