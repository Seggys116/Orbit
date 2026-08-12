import SwiftUI

enum SettingsMetrics {
    // MARK: Rail

    static let railWidth: CGFloat = 190
    static let railRowHeight: CGFloat = 30
    static let railIconSize: CGFloat = 14
    static let railFontSize: CGFloat = 12.5
    static let railHorizontalPadding: CGFloat = 14
    static let railSectionSpacing: CGFloat = 2
    static let railTopPadding: CGFloat = 16
    static let railTitleBottomPadding: CGFloat = 12

    // MARK: Content column

    static let contentMaxWidth: CGFloat = 560
    static let contentHorizontalPadding: CGFloat = 24

    // MARK: Window geometry

    static let windowDefaultWidth: CGFloat = railWidth + 1 + contentMaxWidth + (contentHorizontalPadding * 2)
    static let windowDefaultHeight: CGFloat = 640

    static let contentMinWidth: CGFloat = 420
    static let windowMinWidth: CGFloat = railWidth + 1 + contentMinWidth
    static let windowMinHeight: CGFloat = 480

    // MARK: Row rhythm

    static let rowVerticalPadding: CGFloat = 4
    static let rowMinHeight: CGFloat = 30
    static let sectionRowSpacing: CGFloat = 3
    static let sectionStackSpacing: CGFloat = 16

    static let fieldColumnWidth: CGFloat = 260
}
