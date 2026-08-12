import XCTest

final class LayoutMetricsTests: XCTestCase {

    // MARK: Content card — refs/ARC_PANE_CHROME.md, "where is the consistent padding"

    func test_cardInset_isPositiveAndAppliedUniformly_notTheOldZeroLeadingSpecialCase() {
        XCTAssertGreaterThan(
            OrbitMetrics.cardInset, 0,
            "OrbitMetrics.cardInset must be positive — a zero inset is the exact 'card butts " +
            "straight against its surround' defect refs/ARC_PANE_CHROME.md's padding fix exists to close."
        )
        XCTAssertLessThan(
            OrbitMetrics.cardInset, OrbitMetrics.sidebarMinWidth / 4,
            "OrbitMetrics.cardInset (\(OrbitMetrics.cardInset)pt) reads as an implausibly large " +
            "margin relative to the sidebar's own minimum width — sanity bound, not a measured target."
        )
    }

    func test_cardCornerRadius_isPositiveAndModest() {
        XCTAssertGreaterThan(
            OrbitMetrics.cardCornerRadius, 0,
            "OrbitMetrics.cardCornerRadius must be positive — the content card is meant to read as a rounded surface."
        )
        XCTAssertLessThan(
            OrbitMetrics.cardCornerRadius, OrbitMetrics.sidebarTopRowHeight,
            "OrbitMetrics.cardCornerRadius (\(OrbitMetrics.cardCornerRadius)pt) reads as implausibly large next to the chrome row height (\(OrbitMetrics.sidebarTopRowHeight)pt) it sits beside."
        )
    }

    func test_cardShadowRadius_isZero() {
        XCTAssertEqual(
            OrbitMetrics.cardShadowRadius, 0,
            "refs/ARC_VISUAL_REFERENCE.md §4: 'a thin, subtle lighter border (~1px, low-opacity " +
            "white)... not a heavy drop shadow.' OrbitMetrics.cardShadowRadius must stay 0 — " +
            "any positive value reintroduces the 'black rectangle punched out of a bright " +
            "field' defect the doc calls out."
        )
    }

    // MARK: Sidebar density — R14/R15, refs/DEFECTS.md, "the sidebar's scale"

    func test_sidebarRowHeight_isPlausibleAgainstSidebarWidthAndStaysUnifiedAcrossChromeBands() {
        let ratio = OrbitMetrics.sidebarRowHeight / OrbitMetrics.sidebarDefaultWidth
        XCTAssertGreaterThan(ratio, 0.08, "sidebarRowHeight (\(OrbitMetrics.sidebarRowHeight)pt) reads as cramped relative to sidebarDefaultWidth (\(OrbitMetrics.sidebarDefaultWidth)pt) — refs/DEFECTS.md's retracted 26pt figure is the exact kind of too-tight regression this floor exists to catch.")
        XCTAssertLessThan(ratio, 0.22, "sidebarRowHeight (\(OrbitMetrics.sidebarRowHeight)pt) reads as oversized relative to sidebarDefaultWidth (\(OrbitMetrics.sidebarDefaultWidth)pt) — refs/DEFECTS.md R15's \"all of the icons and buttons are now way too big\" is the exact kind of regression this ceiling exists to catch.")

        XCTAssertEqual(
            OrbitMetrics.sidebarTopRowHeight, OrbitMetrics.sidebarRowHeight,
            "sidebarTopRowHeight must stay unified with sidebarRowHeight — see both constants' own comments for why this shared-pitch decision survives independently of the pitch's own value."
        )
        XCTAssertEqual(
            OrbitMetrics.sidebarBottomBarHeight, OrbitMetrics.sidebarRowHeight,
            "sidebarBottomBarHeight must stay unified with sidebarRowHeight — see both constants' own comments for why this shared-pitch decision survives independently of the pitch's own value."
        )
    }

    func test_faviconSize_fitsRowWithRealMarginAndIsPlausibleAgainstTheIconLadder() {
        XCTAssertLessThan(
            OrbitMetrics.faviconSize, OrbitMetrics.sidebarRowHeight * 0.75,
            "faviconSize (\(OrbitMetrics.faviconSize)pt) leaves too little vertical margin inside sidebarRowHeight (\(OrbitMetrics.sidebarRowHeight)pt) — reads as a favicon crammed edge-to-edge in its row."
        )
        XCTAssertGreaterThan(
            OrbitMetrics.faviconSize, OrbitMetrics.sidebarRowHeight * 0.25,
            "faviconSize (\(OrbitMetrics.faviconSize)pt) reads as lost inside sidebarRowHeight (\(OrbitMetrics.sidebarRowHeight)pt) — too small to read as a favicon at this row height."
        )
        XCTAssertGreaterThanOrEqual(OrbitMetrics.faviconSize, OrbitMetrics.iconFavicon, "faviconSize should sit at or above iconFavicon, the rung it's paired with — see both constants' own comments.")
        XCTAssertLessThan(OrbitMetrics.faviconSize, OrbitMetrics.iconMedium, "faviconSize must stay below iconMedium — it's the small-icon rung, not the bottom-bar/toolbar rung.")
    }

    func test_sidebarHorizontalPadding_isPositiveAndLeavesRoomAtTheNarrowestSidebarWidth() {
        XCTAssertGreaterThan(
            OrbitMetrics.sidebarHorizontalPadding, 0,
            "OrbitMetrics.sidebarHorizontalPadding must be positive — a zero inset is the exact " +
            "'row content touching the sidebar's edge' defect refs/DEFECTS.md R13 exists to close."
        )
        XCTAssertLessThan(
            OrbitMetrics.sidebarHorizontalPadding * 2, OrbitMetrics.sidebarMinWidth,
            "Leading + trailing padding (\(OrbitMetrics.sidebarHorizontalPadding * 2)pt) must leave " +
            "room for row content at sidebarMinWidth (\(OrbitMetrics.sidebarMinWidth)pt) — a padding " +
            "this large relative to the minimum sidebar width would squeeze every row's content to " +
            "nothing at the narrow end of the resize range."
        )
    }

    // MARK: Sidebar sizing — DesignTokens.swift comments

    func test_sidebarDefaultWidth_sitsWithinBoundsWithHeadroomBothWaysAndGrewFromThePreR15Value() {
        XCTAssertGreaterThan(
            OrbitMetrics.sidebarDefaultWidth, OrbitMetrics.sidebarMinWidth,
            "The default must not sit flush against the minimum — a user opening the app for the " +
            "first time should have room to shrink the sidebar before hitting the clamp, not just room to grow it."
        )
        XCTAssertLessThan(
            OrbitMetrics.sidebarDefaultWidth, OrbitMetrics.sidebarMaxWidth,
            "The default must not sit flush against the maximum — a user opening the app for the " +
            "first time should have room to grow the sidebar before hitting the clamp, not just room to shrink it."
        )
    }

    // MARK: Favorites/"Top Apps" grid

    func test_favoritesGrid_atMaximumFavoriteCount_neverDominatesSidebarHeight() {
        let metrics = FavoritesGridMetrics(availableWidth: FavoritesGridMetrics.fallbackAvailableWidth)
        let rows = (OrbitMetrics.favoritesMaximumCount + metrics.columnCount - 1) / metrics.columnCount
        let blockHeight = CGFloat(rows) * metrics.tileHeight
            + CGFloat(rows - 1) * OrbitMetrics.favoriteGridSpacing
            + 2 * OrbitMetrics.favoriteGridVerticalPadding

        let representativeSidebarHeight: CGFloat = 840
        XCTAssertLessThan(
            blockHeight, representativeSidebarHeight / 2,
            "refs/DEFECTS.md V2: at \(OrbitMetrics.favoritesMaximumCount) favourites " +
            "(\(rows) rows of \(metrics.columnCount)) the grid measures \(blockHeight)pt tall. Even at " +
            "Arc's 12-favourite maximum it must stay under half a typical sidebar's height, or it " +
            "reads as 'favourites eating the sidebar' — the complaint that prompted this invariant."
        )
    }

    // MARK: Favourites — ARC_INTERACTION.md §3, referenced from DesignTokens.swift

    func test_favoritesMaximumCount_isTwelve() {
        XCTAssertEqual(
            OrbitMetrics.favoritesMaximumCount, 12,
            "DesignTokens.swift: 'Arc caps Favorites at 12 (confirmed by two independent " +
            "sources, refs/ARC_INTERACTION.md §3). Beyond this the grid stops accepting " +
            "drops.' OrbitMetrics.favoritesMaximumCount must stay 12 — see also " +
            "StoreTests.test_favorites_capAtTwelve, which exercises this at the BrowserStore " +
            "level."
        )
    }
}
