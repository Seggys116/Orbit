import XCTest
import SwiftUI
@testable import Orbit

@MainActor
final class CommandBarStaleResultsTests: XCTestCase {

    // MARK: - The token

    func test_onlyTheNewestRefreshMayWrite() {
        let generation = CommandBarView.QueryGeneration()
        let first = generation.begin()
        XCTAssertTrue(generation.isCurrent(first), "A refresh with nothing after it is entitled to write.")

        let second = generation.begin()
        XCTAssertFalse(generation.isCurrent(first), "A superseded refresh must not write, however late it finishes.")
        XCTAssertTrue(generation.isCurrent(second))
    }

    func test_twoRefreshesOfTheSameTextStillSupersede() {
        let generation = CommandBarView.QueryGeneration()
        let stale = generation.begin()
        let current = generation.begin()
        XCTAssertFalse(generation.isCurrent(stale))
        XCTAssertTrue(generation.isCurrent(current))
    }

    func test_theEmptyQueryPassIssuedOnAppearIsSupersededByTyping() {
        let generation = CommandBarView.QueryGeneration()
        let onAppearPass = generation.begin()          // refreshResults(for: "")
        for _ in "wikipedia " { _ = generation.begin() } // one refresh per keystroke
        XCTAssertFalse(
            generation.isCurrent(onAppearPass),
            "The empty-query pass finished last and wrote the recents list over a typed query — the exact reported failure."
        )
    }

    // MARK: - What that pass would have written

    func test_aTypedQueryNeverProducesTheNoQueryRecentsList() {
        let env = AppEnvironment.demo
        let profileID = env.createDefaultProfileIfNeeded()
        let spaceID = env.createSpace(
            name: "Stale",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
        env.state.activeSpaceID = spaceID

        let empty = CommandBarEngine.results(query: "", mode: .newTab, env: env, suggestions: [])
        XCTAssertFalse(empty.isEmpty, "Precondition: the no-query list is the recents/favourites list, and the demo environment has both.")
        XCTAssertTrue(
            empty.allSatisfy { $0.id.hasPrefix("recent-") || $0.id.hasPrefix("fav-") },
            "Precondition: the no-query list is made only of `recent-`/`fav-` rows."
        )

        let typed = CommandBarEngine.results(query: "wikipedia", mode: .newTab, env: env, suggestions: [])
        XCTAssertFalse(
            typed.contains { $0.id.hasPrefix("recent-") },
            "A typed query must never emit a `recent-` row — those exist only for the empty query, and their presence under typed text is the signature of a stale write."
        )
    }
}
