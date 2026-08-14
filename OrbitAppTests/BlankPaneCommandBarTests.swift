import Foundation
import XCTest
@testable import Orbit

@MainActor
final class BlankPaneCommandBarTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var spaceID: SpaceID {
        env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
    }

    @discardableResult
    private func makeTab(url: String) -> Orbit.Tab {
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    // MARK: - What counts as a blank pane

    func test_blankPaneMode_recognisesEveryPaneWithNoURLWorthPreFilling() {
        let blank = makeTab(url: "orbit://new-tab")
        let page = makeTab(url: "https://example.com")
        let note = makeTab(url: "orbit://note/\(UUID().uuidString)")
        let easel = makeTab(url: "orbit://easel/\(UUID().uuidString)")
        let viewSource = makeTab(url: "view-source:https://example.com")

        XCTAssertEqual(env.blankPaneMode(for: blank.id), .blankPane(blank.id))
        XCTAssertEqual(
            env.blankPaneMode(for: note.id), .blankPane(note.id),
            "A Note has no URL worth pre-filling — its address field reads `untitled`, so the bar must open blank rather than seeded with `orbit://note/<uuid>`."
        )
        XCTAssertEqual(
            env.blankPaneMode(for: easel.id), .blankPane(easel.id),
            "An Easel is the same case as a Note, and the two must never diverge."
        )
        XCTAssertNil(env.blankPaneMode(for: page.id), "A real page is edited with `.editURL`, not filled in from blank.")
        XCTAssertNil(
            env.blankPaneMode(for: viewSource.id),
            "`view-source:` carries a real, meaningful URL the user may well want to edit — it is internal chrome, but it is not a document page."
        )
        XCTAssertNil(env.blankPaneMode(for: TabID()), "An unknown tab is not a blank pane.")
    }

    func test_addressBarShortcut_onANoteOrEasel_opensTheBlankBar_notItsInternalURL() {
        for raw in ["orbit://note/\(UUID().uuidString)", "orbit://easel/\(UUID().uuidString)"] {
            let document = makeTab(url: raw)
            env.activeTabID = document.id
            env.isCommandBarPresented = false

            _ = env.perform(.addressBarCommandBar)

            XCTAssertTrue(env.isCommandBarPresented, "\(raw): the bar must open.")
            XCTAssertEqual(
                env.commandBarMode, .blankPane(document.id),
                "\(raw): must open the blank bar for this pane, never `.editURL` pre-filled with the internal URL."
            )
        }
    }

    func test_blankPaneMode_opensWithAnEmptyQuery_notTheOrbitNewTabURL() {
        let blank = makeTab(url: "orbit://new-tab")

        XCTAssertEqual(CommandBarMode.blankPane(blank.id).initialQuery, "")
        XCTAssertEqual(
            CommandBarMode.editURL(blank.url).initialQuery, "orbit://new-tab",
            "Pinned as the contrast case: `.editURL` on a blank pane is exactly the state the user reported ('references the newpage url'), which is why blank panes must not use it."
        )
    }

    // MARK: - Forcing the bar

    func test_presentBlankPaneCommandBar_presentsTheBarForThatPane() {
        let blank = makeTab(url: "orbit://new-tab")
        XCTAssertFalse(env.isCommandBarPresented, "test precondition: no bar up")

        env.presentBlankPaneCommandBar(blank.id)

        XCTAssertTrue(env.isCommandBarPresented, "A blank pane must force the Command Bar rather than sit empty.")
        XCTAssertEqual(env.commandBarMode, .blankPane(blank.id))
    }

    func test_presentBlankPaneCommandBar_ignoresAPaneThatHasARealPage() {
        let page = makeTab(url: "https://example.com")

        env.presentBlankPaneCommandBar(page.id)

        XCTAssertFalse(env.isCommandBarPresented, "A pane showing a real page must never force the Command Bar open.")
    }

    func test_presentBlankPaneCommandBar_doesNotDisturbABarThatIsAlreadyOpen() {
        let blank = makeTab(url: "orbit://new-tab")
        env.commandBarMode = .newTab
        env.isCommandBarPresented = true

        env.presentBlankPaneCommandBar(blank.id)

        XCTAssertEqual(env.commandBarMode, .newTab, "An already-open Command Bar must keep its own mode (and therefore the query the user is typing).")
    }

    // MARK: - `⌘L` on a blank pane

    func test_addressBarShortcut_onABlankPane_opensTheBlankBar() {
        let blank = makeTab(url: "orbit://new-tab")
        env.activateTab(blank.id)

        _ = env.perform(.addressBarCommandBar)

        XCTAssertTrue(env.isCommandBarPresented)
        XCTAssertEqual(env.commandBarMode, .blankPane(blank.id))
    }

    func test_addressBarShortcut_onARealPage_stillPreFillsThatURL() {
        let page = makeTab(url: "https://example.com/article")
        env.activateTab(page.id)

        _ = env.perform(.addressBarCommandBar)

        XCTAssertEqual(env.commandBarMode, .editURL(page.url))
    }

    // MARK: - The split-pane route

    func test_addSplit_leavesTheNewPaneBlank_whichIsWhatForcesTheBar() {
        let existing = makeTab(url: "https://example.com")
        env.activateTab(existing.id)

        _ = env.perform(.addSplit)

        guard let group = env.splitGroup(for: existing.id) else {
            return XCTFail("Add Split View did not create a split group.")
        }
        guard let blankTabID = group.tabIDs.first(where: { $0 != existing.id }) else {
            return XCTFail("The split has no second pane.")
        }
        XCTAssertEqual(env.tab(blankTabID)?.url.absoluteString, "orbit://new-tab")
        XCTAssertEqual(
            env.blankPaneMode(for: blankTabID), .blankPane(blankTabID),
            "The pane a split starts with must be one the Command Bar will offer to fill in."
        )
    }

    // MARK: - What the bar offers

    func test_results_excludeTheBlankPaneTheBarWasOpenedFor() {
        let blank = makeTab(url: "orbit://new-tab")
        blankTitleWorkaround(blank)
        let other = makeTab(url: "https://example.com/orbit-test-page")
        env.state.tabs[other.id]?.title = "Orbit Test Page"

        let results = CommandBarEngine.results(query: "orbit", mode: .blankPane(blank.id), env: env, suggestions: [])
        let switchTargets = results.compactMap { result -> TabID? in
            switch result.kind.activationIntent {
            case .switchToTab(let id): return id
            case .switchToSpaceAndTab(_, let id): return id
            default: return nil
            }
        }

        XCTAssertFalse(switchTargets.contains(blank.id), "The blank pane must not be offered as a result in its own Command Bar.")
        XCTAssertTrue(switchTargets.contains(other.id), "Every other open tab must still be offered — this excludes one tab, not the tab list.")
    }

    // Gives the blank pane a title that would match the query if the exclusion were missing.
    private func blankTitleWorkaround(_ tab: Orbit.Tab) {
        env.state.tabs[tab.id]?.title = "orbit blank pane"
    }
}
