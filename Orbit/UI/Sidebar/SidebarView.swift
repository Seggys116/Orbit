import SwiftUI
#if DEBUG
import OSLog
#endif

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env

    // Docked, the window already paints one continuous gradient behind everything, so this must not paint a second one (visible seam); hover-revealed, it floats above web content and must.
    var paintsOwnBackground: Bool = false

    var backgroundOpacity: Double = 1

    var space: Space?

    @State private var isHovered = false

    var body: some View {
        Group {
            if let space = space ?? env.activeSpace {
                content(for: space)
            } else {
                Color.clear
            }
        }
        #if DEBUG
        .onAppear { SidebarView.logMetricsSelfCheckOnce() }
        #endif
    }

    private func content(for space: Space) -> some View {
        standardContent(for: space)
    }

    private func standardContent(for space: Space) -> some View {
        // A subview is omitted from this VStack entirely, not rendered at zero height, whenever it should contribute no space: spacing: is charged between every adjacent subview pair regardless of how small any one of them reports its own height.
        let hasPinnedNodes = !env.pinnedNodes(in: space.id).isEmpty
        let showPinnedSection = hasPinnedNodes && !space.isPinnedSectionCollapsed
        let showsLiveFolderAlone = !showPinnedSection
            && !space.isPinnedSectionCollapsed
            && GitHubLiveFolderVisibility.shouldRender(config: space.githubLiveFolder, store: .shared)

        return VStack(alignment: .leading, spacing: 0) {
            SidebarTopRow(theme: space.theme)

            if !env.isTornOffWindow(for: space) {
                SpaceTitleRow(space: space)
            }

            if env.isTornOffWindow(for: space) {
                TornOffWindowBar(theme: space.theme)
            }

            FavoritesGridView(spaceID: space.id, theme: space.theme)

            LiveCalendarJoinRow(spaceID: space.id, theme: space.theme)

            ScrollView {
                VStack(alignment: .leading, spacing: OrbitMetrics.sidebarSectionSpacing) {
                    if showPinnedSection {
                        PinnedSectionView(spaceID: space.id, theme: space.theme)
                    } else if showsLiveFolderAlone {
                        GitHubLiveFolderRowView(spaceID: space.id, theme: space.theme)
                    }

                    TodayDividerRow(spaceID: space.id, theme: space.theme, revealsBroom: isHovered)
                        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
                        .overlay(alignment: .top) {
                            if !hasPinnedNodes {
                                PinnedSectionEmptyDropZone(spaceID: space.id, theme: space.theme)
                                    .offset(y: -OrbitMetrics.sidebarRowHeight)
                            } else if !showPinnedSection {
                                PinnedSectionCollapsedDropZone(spaceID: space.id, theme: space.theme)
                                    .offset(y: -OrbitMetrics.sidebarRowHeight)
                            }
                        }

                    TodaySectionView(spaceID: space.id, theme: space.theme)
                }
                .padding(.top, OrbitMetrics.sidebarSectionSpacing)
                .padding(.bottom, OrbitMetrics.sidebarSectionSpacing)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            SidebarMiniPlayerTray(theme: space.theme)

            TidyDownloadCardView(theme: space.theme)

            SidebarBottomBar(theme: space.theme)
                .padding(.bottom, OrbitMetrics.sidebarInterSectionGap)
        }
        .background {
            if paintsOwnBackground {
                WindowSlicedThemeBackground(theme: space.theme, blur: SpaceVisualPrefsStore.shared.blur(for: space.id))
                    .opacity(backgroundOpacity)
            }
        }
        .gitHubLiveFolderToast(for: space, theme: space.theme, presenter: .shared)
        .persistenceFailureToast(theme: space.theme)
        .onHover { isHovered = $0 }
    }

    // MARK: - Self-check (no Screen Recording permission in this environment)

    #if DEBUG
    private static let selfCheckLogger = Logger(subsystem: "com.orbit.browser", category: "SidebarMetricsSelfCheck")
    private static var hasLoggedMetrics = false

    // Checks invariants only, via logger.fault, never assert(): design values are tuned by eye, and an assert() built on one would trap a DEBUG launch every time the sidebar is retuned to the size the user actually asked for.
    private static func logMetricsSelfCheckOnce() {
        guard !hasLoggedMetrics else { return }
        hasLoggedMetrics = true
        selfCheckLogger.info("""
        sidebarRowHeight=\(OrbitMetrics.sidebarRowHeight, privacy: .public) \
        sidebarRowSpacing=\(OrbitMetrics.sidebarRowSpacing, privacy: .public) \
        faviconSize=\(OrbitMetrics.faviconSize, privacy: .public) \
        sidebarRowFontSize=\(OrbitMetrics.sidebarRowFontSize, privacy: .public) \
        sidebarHorizontalPadding=\(OrbitMetrics.sidebarHorizontalPadding, privacy: .public) \
        favoriteTileHeight=\(OrbitMetrics.favoriteTileHeight, privacy: .public) \
        favoriteIconGlyphSize=\(OrbitMetrics.favoriteIconGlyphSize, privacy: .public) \
        sidebarSpaceNameOpacity=\(OrbitMetrics.sidebarSpaceNameOpacity, privacy: .public)
        """)
        if OrbitMetrics.sidebarRowSpacing != 0 {
            selfCheckLogger.fault("sidebarRowSpacing must stay 0: sidebarRowHeight is the FULL row pitch, so any positive spacing double-counts the gap between rows. Got \(OrbitMetrics.sidebarRowSpacing, privacy: .public).")
        }
        if OrbitMetrics.sidebarRowPillVerticalInset * 2 >= OrbitMetrics.sidebarRowHeight {
            selfCheckLogger.fault("sidebarRowPillVerticalInset (\(OrbitMetrics.sidebarRowPillVerticalInset, privacy: .public)pt) applied to both the top and bottom of a row must leave positive pill height inside sidebarRowHeight (\(OrbitMetrics.sidebarRowHeight, privacy: .public)pt).")
        }
        if OrbitMetrics.faviconSize >= OrbitMetrics.sidebarRowHeight {
            selfCheckLogger.fault("A row's favicon (\(OrbitMetrics.faviconSize, privacy: .public)pt) must fit inside the row (\(OrbitMetrics.sidebarRowHeight, privacy: .public)pt).")
        }
        if OrbitMetrics.sidebarRowFontSize >= OrbitMetrics.sidebarRowHeight {
            selfCheckLogger.fault("A row's label (\(OrbitMetrics.sidebarRowFontSize, privacy: .public)pt) must fit inside the row (\(OrbitMetrics.sidebarRowHeight, privacy: .public)pt).")
        }
        if OrbitMetrics.sidebarHorizontalPadding * 2 >= OrbitMetrics.sidebarMinWidth {
            selfCheckLogger.fault("Leading + trailing padding (\(OrbitMetrics.sidebarHorizontalPadding, privacy: .public)pt each) must leave room for content at the narrowest permitted sidebar width (\(OrbitMetrics.sidebarMinWidth, privacy: .public)pt).")
        }
    }
    #endif
}
