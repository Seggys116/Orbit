import SwiftUI
import XCTest

@testable import Orbit

@MainActor
final class IncognitoSidebarVariantTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        env.isSidebarVisible = true
        env.isSidebarHoverRevealed = false
        env.state = OrbitState()
    }

    private static let renderSize = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: 520)

    private func favorites(_ count: Int) -> [Favorite] {
        (0..<count).map { Favorite(url: URL(string: "https://example\($0).com")!, title: "Example \($0)") }
    }

    // MARK: - Which sidebar gets chosen

    func test_isIncognito_isTrueForASpaceMarkedEphemeralAtCreation() {
        let profile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
        var state = OrbitState()
        state.profiles = [Profile(name: "Personal"), profile]
        let space = Space(name: "Incognito", profileID: profile.id, isEphemeral: true)
        state.spaces = [space]
        env.state = state

        XCTAssertTrue(env.isIncognito(space))
    }

    func test_isIncognito_isTrueForALegacySpaceRecognisedThroughItsProfile() {
        let profile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
        var state = OrbitState()
        state.profiles = [Profile(name: "Personal"), profile]
        let space = Space(name: "Incognito", profileID: profile.id)
        state.spaces = [space]
        env.state = state

        XCTAssertFalse(space.isEphemeral, "fixture must not carry the marker, or this proves nothing")
        XCTAssertTrue(env.isIncognito(space))
    }

    func test_isIncognito_isFalseForAnOrdinarySpace() {
        let profile = Profile(name: "Personal")
        var state = OrbitState()
        state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        state.spaces = [space]
        env.state = state

        XCTAssertFalse(env.isIncognito(space))
    }

    // MARK: - Incognito renders the ordinary sidebar

    private func renderSidebar(incognito: Bool, favoriteCount: Int) -> RenderedImage {
        let profile = incognito
            ? Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
            : Profile(name: "Personal")
        var state = OrbitState()
        state.profiles = [profile]
        let theme = SpaceTheme(
            style: .solid,
            colors: [ThemeColor(red: 0.92, green: 0.92, blue: 0.94)],
            grain: 0,
            followsSystemAppearance: false,
            prefersDarkContent: false
        )
        let space = Space(
            name: "Personal",
            theme: theme,
            profileID: profile.id,
            favorites: favorites(favoriteCount),
            isEphemeral: incognito
        )
        state.spaces = [space]
        state.activeSpaceID = space.id
        env.state = state

        let view = SidebarView(paintsOwnBackground: true, space: space)
            .environment(env)
            // ImageRenderer paints `.draggable`-decorated views as a corrupted band.
            .environment(\.orbitScreenshotModeDragDisabled, true)
        return render(view, size: Self.renderSize, appearance: .aqua)
    }

    private func imagesAreIdentical(_ lhs: RenderedImage, _ rhs: RenderedImage, tolerance: Double = 0.04) -> Bool {
        let width = Int(Self.renderSize.width.rounded(.down))
        let height = Int(Self.renderSize.height.rounded(.down))
        for y in 0..<height {
            for x in 0..<width where !lhs.color(atX: x, y: y).isApproximately(rhs.color(atX: x, y: y), tolerance: tolerance) {
                return false
            }
        }
        return true
    }

    func test_incognitoSidebar_isPixelIdenticalToTheOrdinarySidebar() {
        let incognito = renderSidebar(incognito: true, favoriteCount: 3)
        let ordinary = renderSidebar(incognito: false, favoriteCount: 3)

        XCTAssertTrue(
            imagesAreIdentical(incognito, ordinary),
            """
            An Incognito window's sidebar no longer matches an ordinary \
            window's, so Incognito-specific sidebar chrome has come back. \
            The user's instruction was explicit — "Why does incognito have \
            the URL and window controls on the sidebar, please fucking put \
            it back to normal?" — and it outranks \
            refs/reference/arc-incognito-sidebar.png. Nav controls and the \
            URL field belong to the per-pane ToolbarView in every window \
            mode; SidebarView.content(for:) must not branch on \
            env.isIncognito(_:) at all.
            """
        )
    }

    func test_incognitoSidebar_rendersItsFavouritesGrid() {
        let withFavorites = renderSidebar(incognito: true, favoriteCount: 3)
        let withoutFavorites = renderSidebar(incognito: true, favoriteCount: 0)

        XCTAssertFalse(
            imagesAreIdentical(withFavorites, withoutFavorites),
            """
            Adding Favourites made no difference to an Incognito window's \
            sidebar, so either the Favourites grid is still being branched \
            away for Incognito or this file's fixture never populates \
            Favourites — in which case the pixel-identity assertion above \
            proves nothing either.
            """
        )
    }

    func test_ordinarySidebar_stillRendersItsFavouritesGrid() {
        let withFavorites = renderSidebar(incognito: false, favoriteCount: 3)
        let withoutFavorites = renderSidebar(incognito: false, favoriteCount: 0)

        XCTAssertFalse(
            imagesAreIdentical(withFavorites, withoutFavorites),
            """
            Adding Favourites made no difference to an ordinary Space's \
            sidebar either, which means this file's fixture never populates \
            Favourites and the assertions above prove nothing.
            """
        )
    }
}
