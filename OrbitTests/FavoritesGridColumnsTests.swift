// Drives production FavoritesGridMetrics at real widths rather than rendering the view:
// its .draggable-decorated tiles fail to snapshot through ImageRenderer at all.

import XCTest
import SwiftUI

final class FavoritesGridColumnsTests: XCTestCase {

    private var contentWidths: [CGFloat] {
        stride(
            from: OrbitMetrics.sidebarMinWidth,
            through: OrbitMetrics.sidebarMaxWidth,
            by: 1
        ).map { $0 - 2 * (OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset) }
    }

    // MARK: "Stretch to fill the space available"

    func test_tilesAndGutters_exactlyConsumeTheAvailableWidth_atEverySidebarWidth() {
        for width in contentWidths {
            let metrics = FavoritesGridMetrics(availableWidth: width)
            let consumed = CGFloat(metrics.columnCount) * metrics.tileWidth
                + CGFloat(metrics.columnCount - 1) * OrbitMetrics.favoriteGridSpacing
            XCTAssertEqual(
                consumed, width, accuracy: 0.01,
                "At \(width)pt of content width the grid lays out \(metrics.columnCount) tiles of " +
                "\(metrics.tileWidth)pt, consuming \(consumed)pt. Tiles must fill the row exactly — " +
                "any shortfall is the dead trailing space the redesign brief calls out with " +
                "'they should stretch to fill the space available'."
            )
        }
    }

    // MARK: "No fixed count per column if possible"

    func test_columnCount_variesWithSidebarWidth() {
        let counts = Set(contentWidths.map { FavoritesGridMetrics(availableWidth: $0).columnCount })

        XCTAssertGreaterThan(
            counts.count, 1,
            "The 2026-08-06 brief: 'No fixed count per column if possible.' Across the sidebar's " +
            "full resize range (\(OrbitMetrics.sidebarMinWidth)–\(OrbitMetrics.sidebarMaxWidth)pt) " +
            "the grid produced only \(counts) column(s) — i.e. the count is still effectively fixed."
        )
    }

    func test_columnCount_neverDecreasesAsTheSidebarWidens() {
        var previous = 0
        for width in contentWidths {
            let count = FavoritesGridMetrics(availableWidth: width).columnCount
            XCTAssertGreaterThanOrEqual(
                count, previous,
                "Column count dropped from \(previous) to \(count) as the content width reached " +
                "\(width)pt. A wider sidebar must never fit fewer tiles per row."
            )
            previous = count
        }
    }

    func test_everyTile_isAtLeastTheMinimumWidth() {
        for width in contentWidths {
            let metrics = FavoritesGridMetrics(availableWidth: width)
            XCTAssertGreaterThanOrEqual(
                metrics.tileWidth, OrbitMetrics.favoriteTileMinWidth - 0.01,
                "At \(width)pt of content width the grid resolved \(metrics.columnCount) columns of " +
                "\(metrics.tileWidth)pt, below the \(OrbitMetrics.favoriteTileMinWidth)pt minimum that " +
                "count was derived from."
            )
        }
    }

    // MARK: "Gradually become squares"

    func test_tile_isNeverTallerThanItIsWide() {
        for width in contentWidths {
            let metrics = FavoritesGridMetrics(availableWidth: width)
            XCTAssertLessThanOrEqual(
                metrics.tileHeight, metrics.tileWidth + 0.01,
                "At \(width)pt of content width the tile is \(metrics.tileWidth)x\(metrics.tileHeight)pt " +
                "— taller than it is wide. 'Gradually become squares' means approaching a square from " +
                "the landscape side, never past it."
            )
        }
    }

    func test_someSidebarWidth_producesAnEssentiallySquareTile() {
        let closest = contentWidths
            .map { FavoritesGridMetrics(availableWidth: $0) }
            .map { $0.tileWidth - $0.tileHeight }
            .min() ?? .infinity

        XCTAssertLessThanOrEqual(
            closest, 1,
            "Across the sidebar's full resize range the tile never got closer than \(closest)pt to " +
            "square. favoriteTileMinWidth (\(OrbitMetrics.favoriteTileMinWidth)) must stay at or below " +
            "favoriteTileHeight (\(OrbitMetrics.favoriteTileHeight)) for the densest packing at some " +
            "width to actually land on a square."
        )
    }

    // MARK: "Icons are same size no matter what"

    func test_faviconGlyph_staysWithinNativeFaviconResolution() {
        let devicePixelsAt2x = OrbitMetrics.favoriteIconGlyphSize * 2
        XCTAssertLessThanOrEqual(
            devicePixelsAt2x, 64,
            "The 2026-08-06 brief: the tile's icon 'should be the size of favicons' because drawing it " +
            "larger 'puts quality issues in place'. favoriteIconGlyphSize " +
            "(\(OrbitMetrics.favoriteIconGlyphSize)pt) renders at \(devicePixelsAt2x)px on a 2x display, " +
            "past the 64px most sites ship — i.e. upsampled and soft."
        )
        XCTAssertGreaterThanOrEqual(
            OrbitMetrics.favoriteIconGlyphSize, OrbitMetrics.faviconSize,
            "A tile is a larger, more deliberate target than a sidebar row, so its favicon should not " +
            "be drawn smaller than a row's own (\(OrbitMetrics.faviconSize)pt)."
        )
    }

    func test_tile_hasRoomForTheFixedGlyphAndTheCountdownPill_atEverySidebarWidth() {
        let countdownPillHeight: CGFloat = 16
        let stackSpacing: CGFloat = 2

        for width in contentWidths {
            let metrics = FavoritesGridMetrics(availableWidth: width)
            XCTAssertGreaterThanOrEqual(
                metrics.tileHeight,
                OrbitMetrics.favoriteIconGlyphSize + stackSpacing + countdownPillHeight,
                "At \(width)pt of content width the tile is only \(metrics.tileHeight)pt tall — not " +
                "enough for a \(OrbitMetrics.favoriteIconGlyphSize)pt favicon stacked above the Live " +
                "Calendar countdown pill. Because the glyph is a fixed size, shrinking the tile is " +
                "what eats this budget; the pill would overhang the tile's edge."
            )
        }
    }

    // MARK: Grid wiring

    func test_columns_matchTheResolvedCountAndShareTheSpacingToken() {
        for width in contentWidths {
            let metrics = FavoritesGridMetrics(availableWidth: width)
            XCTAssertEqual(
                metrics.columns.count, metrics.columnCount,
                "The LazyVGrid's column array (\(metrics.columns.count)) must match the resolved " +
                "column count (\(metrics.columnCount)) at \(width)pt."
            )
            for item in metrics.columns {
                XCTAssertEqual(
                    item.spacing, OrbitMetrics.favoriteGridSpacing,
                    "Every column's spacing must trace to OrbitMetrics.favoriteGridSpacing, matching " +
                    "the LazyVGrid's own row spacing, not an independent literal."
                )
            }
        }
    }

    func test_zeroWidth_fallsBackToTheDefaultSidebarsContentWidth() {
        let unmeasured = FavoritesGridMetrics(availableWidth: 0)
        let defaultWidth = FavoritesGridMetrics(
            availableWidth: FavoritesGridMetrics.fallbackAvailableWidth
        )

        XCTAssertEqual(
            unmeasured, defaultWidth,
            "An unmeasured grid must lay out exactly as the default-width sidebar does, so the first " +
            "frame doesn't visibly re-flow once the real width arrives."
        )
        XCTAssertGreaterThan(
            unmeasured.columnCount, 1,
            "The fallback must produce a real multi-column grid, not the 1-column degenerate case."
        )
    }

    func test_favoritesGridView_resolvesTheSameMetricsTheseTestsDrive() {
        let view = FavoritesGridView(spaceID: SpaceID(), theme: SpaceTheme())

        for width in contentWidths {
            XCTAssertEqual(
                view.metrics(for: width), FavoritesGridMetrics(availableWidth: width),
                "FavoritesGridView.metrics(for:) must resolve exactly FavoritesGridMetrics at \(width)pt, " +
                "or every assertion in this file is exercising a type the view no longer lays out from."
            )
        }
    }
}
