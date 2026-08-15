import SwiftUI

enum LibraryPalette {
    static let sidebarBackground = Color(red: 0.1647, green: 0.1451, blue: 0.1961)
    static let contentBackground = Color(red: 0.2000, green: 0.1725, blue: 0.2275)
    static let cardFill = Color.white.opacity(0.045)
    static let cardFillHover = Color.white.opacity(0.075)
    static let cardBorder = Color.white.opacity(0.07)

    static let divider = Color.white.opacity(0.09)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.36)

    static let selectedFill = Color.white.opacity(0.11)
    static let hoverFill = Color.white.opacity(0.06)

    static let accent = Color(red: 0.62, green: 0.55, blue: 0.95)
    static let destructive = Color(red: 0.92, green: 0.45, blue: 0.45)

    static let progressTrack = Color.white.opacity(0.12)

    static let previewBackground = Color(red: 0.1725, green: 0.1490, blue: 0.1961)
}

enum LibraryMetrics {
    static let navWidth: CGFloat = 190
    static let navRowHeight: CGFloat = 30
    static let navIconSize: CGFloat = 14
    static let navFontSize: CGFloat = 12.5
    static let navHorizontalPadding: CGFloat = 14
    static let navSectionSpacing: CGFloat = 2

    static let contentHorizontalPadding: CGFloat = 22
    static let contentTopPadding: CGFloat = 16

    static let searchFieldHeight: CGFloat = 28
    static let searchFieldCornerRadius: CGFloat = 8
    static let searchFieldMaxWidth: CGFloat = 220

    static let rowCornerRadius: CGFloat = 9
    static let rowVerticalPadding: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 10
    static let rowSpacing: CGFloat = 4
    static let rowIconSize: CGFloat = 30

    static let dateGroupSpacing: CGFloat = 18
    static let dateHeaderFontSize: CGFloat = 11.5

    static let actionButtonSize: CGFloat = 22

    // MARK: Wide-row columns (used once the list has the full window to itself, i.e. no preview selection)

    static let rowMetaColumnWidth: CGFloat = 160
    static let rowSecondaryColumnWidth: CGFloat = 120
    static let rowDateColumnWidth: CGFloat = 76

    // MARK: Three-column layout (rail + list + preview)

    static let listColumnWidth: CGFloat = 346
    static let previewMinWidth: CGFloat = 440

    static let previewLeadingCornerRadius: CGFloat = 12
    static let previewContentPadding: CGFloat = 24
    static let previewArtworkMaxSize: CGFloat = 220
    static let previewArtworkCornerRadius: CGFloat = 10
    static let previewCaptureSize = CGSize(width: 1280, height: 800)

    static let windowDefaultWidth: CGFloat = navWidth + 1 + listColumnWidth + 720
    static let windowDefaultHeight: CGFloat = 720
    static let windowMinWidth: CGFloat = navWidth + 1 + listColumnWidth + previewMinWidth
    static let windowMinHeight: CGFloat = 480
}
