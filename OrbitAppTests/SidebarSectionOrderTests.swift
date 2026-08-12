import SwiftUI
import XCTest

@testable import Orbit

@MainActor
final class SidebarSectionOrderTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        env.isSidebarVisible = true
        env.isSidebarHoverRevealed = false
        env.state = OrbitState()
    }

    // MARK: - Fixture

    private static let renderSize = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: 520)

    private func makeState(name: String, favoriteCount: Int) -> OrbitState {
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        state.profiles = [profile]

        let favorites = (0..<favoriteCount).map { index in
            Favorite(
                url: URL(string: "https://example\(index).com")!,
                title: "Example \(index)"
            )
        }
        let theme = SpaceTheme(
            style: .solid,
            colors: [ThemeColor(red: 0.92, green: 0.92, blue: 0.94)],
            grain: 0,
            followsSystemAppearance: false,
            prefersDarkContent: false
        )
        let space = Space(
            name: name,
            theme: theme,
            profileID: profile.id,
            favorites: favorites
        )
        state.spaces = [space]
        state.activeSpaceID = space.id
        return state
    }

    private func renderSidebar(name: String, favoriteCount: Int) -> RenderedImage {
        let env = self.env
        env.state = makeState(name: name, favoriteCount: favoriteCount)
        guard let space = env.spaces.first else {
            XCTFail("Fixture failed to seed a Space.")
            return render(Color.clear, size: Self.renderSize)
        }
        let view = SidebarView(paintsOwnBackground: true, space: space)
            .environment(env)
            // ImageRenderer paints a .draggable-decorated view as a corrupted band; suppressed here.
            .environment(\.orbitScreenshotModeDragDisabled, true)
        return render(view, size: Self.renderSize, appearance: .aqua)
    }

    // MARK: - Diffing

    /// The tightest rectangle enclosing every pixel where `lhs` and `rhs`
    /// differ by more than `tolerance`; nil when the images are identical.
    private func differenceBounds(_ lhs: RenderedImage, _ rhs: RenderedImage, tolerance: Double = 0.04) -> CGRect? {
        let width = Int(Self.renderSize.width.rounded(.down))
        let height = Int(Self.renderSize.height.rounded(.down))
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<height {
            for x in 0..<width {
                guard !lhs.color(atX: x, y: y).isApproximately(rhs.color(atX: x, y: y), tolerance: tolerance) else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + 1)
                maxY = max(maxY, y + 1)
            }
        }
        guard minX != Int.max else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - The regression itself

    func test_spaceTitle_rendersAboveTheFavoritesGrid() throws {
        let withNameAndFavorites = renderSidebar(name: "Personal", favoriteCount: 3)
        let withoutName = renderSidebar(name: "", favoriteCount: 3)
        let withoutFavorites = renderSidebar(name: "Personal", favoriteCount: 0)

        let titleBounds = try XCTUnwrap(
            differenceBounds(withNameAndFavorites, withoutName),
            """
            Rendering the sidebar with and without a Space name produced \
            identical images, so the Space title could not be located at all. \
            Either SpaceTitleRow stopped drawing its name, or the render is \
            blank — check the diagnostic PNGs before treating the ordering \
            assertion below as meaningful.
            """
        )

        let favoritesInfluenceBounds = try XCTUnwrap(
            differenceBounds(withNameAndFavorites, withoutFavorites),
            """
            Rendering the sidebar with and without Favourites produced \
            identical images, so the Favourites grid could not be located at \
            all — it appears not to be rendering.
            """
        )

        if favoritesInfluenceBounds.minY < titleBounds.maxY {
            withNameAndFavorites.writeDiagnosticPNG(named: "SidebarSectionOrder-FAILED-withFavorites")
            withoutFavorites.writeDiagnosticPNG(named: "SidebarSectionOrder-FAILED-withoutFavorites")
        }

        XCTAssertGreaterThanOrEqual(
            favoritesInfluenceBounds.minY, titleBounds.maxY,
            """
            The Space title renders BELOW (or overlapping) whatever the \
            Favourites grid displaces, which means the grid precedes the \
            title again. The user's own direct instruction, verbatim: \
            "Either way, the active space should be at the very top of the \
            sidebar. This is how the sidebar should look, with bookmarks, \
            folders and AT THE VERY TOP USING A EMOJI NOT A FUCKING \
            DOWNWARDS ARROW THE SPACE!" This overrides the earlier \
            Favourites-first reading of refs/reference/arc-bookmarks-structure.png \
            — see Orbit/UI/Sidebar/SidebarView.swift's own header for the \
            full record. Do not reinstate the old order from that screenshot \
            without a new, equally direct instruction to do so.
            """
        )
    }

    func test_spaceTitle_isStillPresentAfterTheReorder() throws {
        let withNameAndFavorites = renderSidebar(name: "Personal", favoriteCount: 3)
        let withoutName = renderSidebar(name: "", favoriteCount: 3)

        let titleBounds = try XCTUnwrap(
            differenceBounds(withNameAndFavorites, withoutName),
            "The Space name drew no pixels at all — SpaceTitleRow is missing from the sidebar."
        )
        XCTAssertGreaterThan(
            titleBounds.height, 0,
            "The Space title's measured bounding box has no height."
        )
        XCTAssertGreaterThan(
            titleBounds.minY, OrbitMetrics.sidebarTopRowHeight * 0.5,
            """
            The Space title was found overlapping the sidebar's own top row \
            (traffic lights / sidebar toggle), which means the render is not \
            laid out the way this test assumes and the ordering assertion in \
            this file cannot be trusted.
            """
        )
    }
}
