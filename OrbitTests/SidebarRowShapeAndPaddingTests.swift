import XCTest
import SwiftUI

@MainActor
final class SidebarRowShapeAndPaddingTests: XCTestCase {

    // MARK: - R16: row corner radius is near-rectangular, not a pill

    func test_R16_rowCornerRadius_isLessThanHalfTheRowHeight() {
        XCTAssertLessThan(
            OrbitMetrics.sidebarRowCornerRadius * 2, OrbitMetrics.sidebarRowHeight,
            "A corner radius of half the row height or more (\(OrbitMetrics.sidebarRowHeight / 2)pt at the " +
            "current \(OrbitMetrics.sidebarRowHeight)pt row height) draws a true capsule/pill, not the " +
            "near-rectangular shape refs/reference/arc-window-sidebar-folders.png and " +
            "arc-sidebar-today-list-clear.png both show. Found \(OrbitMetrics.sidebarRowCornerRadius)pt."
        )
    }

    // MARK: - R17: an empty section contributes zero space

    func test_R17_favoritesGridView_withNoFavorites_contributesZeroHeightAboveItsNextSibling() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let markerHeight: CGFloat = 20
        let canvasHeight: CGFloat = 120
        let markerFill = Color.red

        let markerAloneRendered = render(
            Rectangle().fill(markerFill).frame(height: markerHeight),
            size: CGSize(width: 200, height: markerHeight)
        )
        let referenceColor = markerAloneRendered.color(atX: 100, y: 3)

        let stack = VStack(alignment: .leading, spacing: 0) {
            FavoritesGridView(spaceID: SpaceID(), theme: theme)
            Rectangle()
                .fill(markerFill)
                .frame(height: markerHeight)
        }
        .environment(env)

        let rendered = render(stack, size: CGSize(width: 200, height: canvasHeight))

        let sampled = rendered.color(atX: 100, y: 3)
        if !sampled.isApproximately(referenceColor, tolerance: 0.05) {
            rendered.writeDiagnosticPNG(named: "R17-favoritesEmpty-FAILED")
        }
        XCTAssertTrue(
            sampled.isApproximately(referenceColor, tolerance: 0.05),
            "refs/DEFECTS.md R17: with zero favourites, FavoritesGridView must contribute zero height " +
            "above its next sibling in the sidebar's VStack — expected the marker's own rendered colour " +
            "(\(referenceColor), from an isolated reference render) at (100, 3), 3pt below the top edge, " +
            "but found \(sampled). Before this fix the always-applied top+bottom " +
            "favoriteGridVerticalPadding band (\(OrbitMetrics.favoriteGridVerticalPadding)pt each) pushed " +
            "the marker down even with nothing in the grid — exactly the 'weird padding underneath " +
            "them... should only pad if there are items there' the user flagged. See the diagnostic PNG " +
            "if this fails."
        )
    }

    func test_R17_favoritesGridView_withOneFavorite_stillReservesSpaceAboveItsNextSibling() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let spaceID = SpaceID()
        var space = Space(id: spaceID, name: "Test", profileID: UUID())
        space.favorites = [Favorite(id: UUID(), url: URL(string: "https://example.com")!, title: "Example")]
        env.state.spaces = [space]

        let stack = VStack(alignment: .leading, spacing: 0) {
            FavoritesGridView(spaceID: spaceID, theme: theme)
            Rectangle()
                .fill(Color.red)
                .frame(height: 20)
        }
        .environment(env)
        .environment(\.orbitScreenshotModeDragDisabled, true)

        let rendered = render(stack, size: CGSize(width: 200, height: 160))

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "R17-favoritesPopulated-FAILED-empty")
            XCTFail("Expected a populated FavoritesGridView plus its marker to draw something.")
            return
        }

        XCTAssertGreaterThan(
            box.minY, 1,
            "With at least one favourite, FavoritesGridView must still reserve real vertical space above " +
            "its next sibling (found the drawn content's own top edge at y=\(box.minY)pt) — R17's fix must " +
            "only collapse the *empty* case to zero height, not every case."
        )
    }
}
