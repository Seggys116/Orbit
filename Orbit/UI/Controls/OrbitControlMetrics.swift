import SwiftUI

enum OrbitControlMetrics {

    // MARK: OrbitToggle

    static let toggleWidth: CGFloat = 34
    static let toggleHeight: CGFloat = 20
    static let toggleCompactWidth: CGFloat = 28
    static let toggleCompactHeight: CGFloat = 16
    static let toggleKnobPadding: CGFloat = 2
    static let toggleKnobShadowOpacity: Double = 0.28
    static let toggleTrackOffOpacityDark: Double = 0.18
    static let toggleTrackOffOpacityLight: Double = 0.12
    static let toggleTrackOnOpacity: Double = 0.92

    // MARK: OrbitSegmentedControl

    static let segmentedHeight: CGFloat = 26
    static let segmentedCornerRadius: CGFloat = 7
    static let segmentedInset: CGFloat = 2
    static let segmentedFontSize: CGFloat = 11.5
    static let segmentedHorizontalPadding: CGFloat = 10

    // MARK: OrbitPopupButton

    static let popupHeight: CGFloat = 26
    static let popupCornerRadius: CGFloat = 7
    static let popupHorizontalPadding: CGFloat = 10
    static let popupChevronSize: CGFloat = 9
    static let popupFontSize: CGFloat = 12
    static let popupRowFontSize: CGFloat = 12.5

    // MARK: OrbitTextField

    static let textFieldHeight: CGFloat = 28
    static let textFieldCornerRadius: CGFloat = 7
    static let textFieldHorizontalPadding: CGFloat = 10
    static let textFieldFontSize: CGFloat = 12.5
    static let textFieldFocusRingWidth: CGFloat = 2
    static let textFieldIconSize: CGFloat = 12

    // MARK: OrbitButton

    static let buttonHeight: CGFloat = 28
    static let buttonCompactHeight: CGFloat = 22
    static let buttonCornerRadius: CGFloat = 7
    static let buttonHorizontalPadding: CGFloat = 14
    static let buttonCompactHorizontalPadding: CGFloat = 8
    static let buttonFontSize: CGFloat = 12.5
    static let buttonIconSpacing: CGFloat = 6
    static let buttonDisabledOpacity: Double = 0.4
    static let buttonPressedOpacityDelta: Double = 0.08

    // MARK: OrbitSlider

    static let sliderTrackHeight: CGFloat = 4
    static let sliderKnobDiameter: CGFloat = 14
    static let sliderFocusRingWidth: CGFloat = 2

    // MARK: OrbitSettingsRow

    static let settingsRowMinHeight: CGFloat = 34
    static let settingsRowLabelSpacing: CGFloat = 2
    static let settingsRowContentSpacing: CGFloat = 16
    static let settingsRowTitleFontSize: CGFloat = 12.5
    static let settingsRowDescriptionFontSize: CGFloat = 11
    static let settingsRowVerticalPadding: CGFloat = 7

    // MARK: OrbitSectionHeader / OrbitSettingsSection

    static let sectionHeaderFontSize: CGFloat = 11
    static let sectionHeaderSpacing: CGFloat = 8
    static let sectionCornerRadius: CGFloat = 10
    static let sectionPadding: CGFloat = 14
    static let sectionRowSpacing: CGFloat = 4
    static let sectionStackSpacing: CGFloat = 22

    // MARK: Extension action badge

    static let extensionBadgeHeight: CGFloat = 13
    static let extensionBadgeFontSize: CGFloat = 9
    static let extensionBadgeHorizontalPadding: CGFloat = 3.5
    static let extensionBadgeMinimumWidth: CGFloat = 13
    static let extensionBadgeCornerRadius: CGFloat = 6.5
    // Chrome truncates the badge at roughly four glyphs; anything longer is
    // clipped by the icon slot rather than pushing the grid out of alignment.
    static let extensionBadgeMaximumCharacters = 4

    // MARK: Shared fills — appearance-aware, not system-material-based

    static let controlFillOpacityDark: Double = 0.08
    static let controlFillOpacityLight: Double = 0.045
    static let controlBorderOpacityDark: Double = 0.14
    static let controlBorderOpacityLight: Double = 0.10
    static let controlHoverFillOpacityDark: Double = 0.13
    static let controlHoverFillOpacityLight: Double = 0.08
}

enum OrbitControlColor {
    static func fill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(OrbitControlMetrics.controlFillOpacityDark)
            : Color.black.opacity(OrbitControlMetrics.controlFillOpacityLight)
    }

    static func hoverFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(OrbitControlMetrics.controlHoverFillOpacityDark)
            : Color.black.opacity(OrbitControlMetrics.controlHoverFillOpacityLight)
    }

    static func border(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(OrbitControlMetrics.controlBorderOpacityDark)
            : Color.black.opacity(OrbitControlMetrics.controlBorderOpacityLight)
    }

    static func primaryForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
    }

    static func secondaryForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5)
    }

    // extensions::ExtensionAction has no default badge colour (SkColor value-initializes
    // transparent); these are Orbit's fallback so a text-only badge stays legible.
    static func extensionBadgeFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.90, green: 0.29, blue: 0.24) : Color(red: 0.83, green: 0.19, blue: 0.15)
    }

    static let extensionBadgeText = Color.white
}

extension Color {
    /// One badge colour exactly as chrome.action.setBadgeBackgroundColor /
    /// setBadgeTextColor supplied it, in sRGB -- the same space SkColor's
    /// 8-bit components are already in.
    init(_ actionColor: ExtensionActionColor) {
        self.init(
            .sRGB,
            red: Double(actionColor.red) / 255,
            green: Double(actionColor.green) / 255,
            blue: Double(actionColor.blue) / 255,
            opacity: Double(actionColor.alpha) / 255
        )
    }
}
