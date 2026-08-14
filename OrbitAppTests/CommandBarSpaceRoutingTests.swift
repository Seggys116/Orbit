//  Typing a URL must never move the user between Spaces; picking a cross-Space row must.

import XCTest
@testable import Orbit

@MainActor
final class CommandBarSpaceRoutingTests: XCTestCase {

    private var env: AppEnvironment!
    private var currentSpaceID: SpaceID!
    private var otherSpaceID: SpaceID!

    private let pageURL = URL(string: "https://reporting.example.com/dashboard")!

    override func setUp() {
        super.setUp()
        env = AppEnvironment.demo
        let profileID = env.createDefaultProfileIfNeeded()
        let theme = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0)
        currentSpaceID = env.createSpace(name: "Current", icon: "circle", iconIsEmoji: false, theme: theme, profileID: profileID)
        otherSpaceID = env.createSpace(name: "Other", icon: "circle", iconIsEmoji: false, theme: theme, profileID: profileID)
        env.state.tabs = [:]
        env.state.activeSpaceID = currentSpaceID
        env.commandBarMode = .newTab
        env._test_webContentsFactory = { _, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }
    }

    override func tearDown() {
        env = nil
        currentSpaceID = nil
        otherSpaceID = nil
        super.tearDown()
    }

    @discardableResult
    private func openInOtherSpace() -> TabID {
        let tabID = env.openTab(url: pageURL, in: otherSpaceID, activate: false)
        env.renameTab(tabID, to: "Quarterly Reporting")
        return tabID
    }

    private func results(_ query: String) -> [CommandResult] {
        CommandBarEngine.results(
            query: query,
            mode: env.commandBarMode,
            env: env,
            suggestions: [],
            searchEngine: env.searchEngine,
            siteSearch: env.siteSearchStore.state(active: nil)
        )
    }

    private func describe(_ rows: [CommandResult]) -> String {
        rows.map { "  [\(String(format: "%.1f", $0.score))] \($0.id) — \($0.title)" }.joined(separator: "\n")
    }

    private func crossSpaceRow(in rows: [CommandResult]) -> CommandResult? {
        rows.first { if case .tabInOtherSpace = $0.kind { return true } else { return false } }
    }

    // MARK: - Committing a URL stays put

    func test_typedURLOpenOnlyInAnotherSpace_opensHereAndLeavesTheActiveSpaceAlone() throws {
        let otherTabID = openInOtherSpace()
        let rows = results("reporting.example.com")
        let top = try XCTUnwrap(rows.first, "The typed address produced no rows at all.")
        guard case .typedURL = top.kind else {
            return XCTFail("The default row for a typed address must be the address itself:\n\(describe(rows))")
        }

        let before = env.state.tabs.count
        CommandBarActivation.activate(top, in: env)

        XCTAssertEqual(
            env.activeSpace?.id, currentSpaceID,
            "Typing an address moved the user to the Space that already had the page open — Spaces are separate contexts."
        )
        XCTAssertEqual(env.state.tabs.count, before + 1, "The address must open a tab here.")
        let opened = try XCTUnwrap(
            env.state.tabs.values.first { $0.spaceID == currentSpaceID && $0.url.host() == pageURL.host() },
            "No tab for the typed address exists in the current Space."
        )
        XCTAssertNotEqual(opened.id, otherTabID, "The other Space's tab must be left where it is.")
        XCTAssertEqual(env.activeTabID, opened.id)
    }

    func test_partialDomainMatchingOnlyAnotherSpacesTab_isNeverTheDefaultRow() throws {
        openInOtherSpace()
        let rows = results("reporting")
        let top = try XCTUnwrap(rows.first)
        if case .tabInOtherSpace = top.kind {
            return XCTFail("A tab in another Space held the default selection, so Enter alone would jump Spaces:\n\(describe(rows))")
        }
        guard case .searchSuggestion(let text) = top.kind, text == "reporting" else {
            return XCTFail("The default row must be what the user typed:\n\(describe(rows))")
        }

        CommandBarActivation.activate(top, in: env)

        XCTAssertEqual(env.activeSpace?.id, currentSpaceID)
        XCTAssertTrue(
            env.state.tabs.values.contains { $0.spaceID == currentSpaceID },
            "Committing the typed text must land in the current Space."
        )
    }

    func test_matchingTabInTheCurrentSpaceIsSwitchedTo_notDuplicated() throws {
        let localTabID = env.openTab(url: pageURL, in: currentSpaceID, activate: false)
        env.renameTab(localTabID, to: "Quarterly Reporting")

        let rows = results("reporting")
        let row = try XCTUnwrap(
            rows.first { if case .openTab = $0.kind { return true } else { return false } },
            "A matching tab in the current Space must still be offered as a switch:\n\(describe(rows))"
        )

        let before = env.state.tabs.count
        CommandBarActivation.activate(row, in: env)

        XCTAssertEqual(env.state.tabs.count, before, "Reusing the tab in this Space must not open a duplicate.")
        XCTAssertEqual(env.activeTabID, localTabID)
        XCTAssertEqual(env.activeSpace?.id, currentSpaceID)
    }

    // MARK: - Cross-Space search still works, deliberately

    func test_crossSpaceTabIsStillFound_andNamesTheSpaceItLivesIn() throws {
        let otherTabID = openInOtherSpace()
        let rows = results("reporting")
        let row = try XCTUnwrap(
            crossSpaceRow(in: rows),
            "Search must still span every Space — the other Space's tab was not offered at all:\n\(describe(rows))"
        )

        guard case .tabInOtherSpace(let tabID, let spaceID) = row.kind else { return XCTFail("Unreachable.") }
        XCTAssertEqual(tabID, otherTabID)
        XCTAssertEqual(spaceID, otherSpaceID)
        XCTAssertEqual(
            row.subtitle, "Other · reporting.example.com",
            "A row that would move the user must say which Space it belongs to."
        )
    }

    func test_choosingTheCrossSpaceRow_switchesSpaceAndSelectsThatTab() throws {
        let otherTabID = openInOtherSpace()
        let row = try XCTUnwrap(crossSpaceRow(in: results("reporting")))

        guard case .switchToSpaceAndTab(let targetSpaceID, let targetTabID) = row.kind.activationIntent else {
            return XCTFail("A cross-Space row must activate as an explicit Space switch, got \(row.kind.activationIntent).")
        }
        XCTAssertEqual(targetSpaceID, otherSpaceID)
        XCTAssertEqual(targetTabID, otherTabID)

        let before = env.state.tabs.count
        CommandBarActivation.activate(row, in: env)

        XCTAssertEqual(env.activeSpace?.id, otherSpaceID, "Deliberately picking a result in another Space must take the user there.")
        XCTAssertEqual(env.activeTabID, otherTabID)
        XCTAssertEqual(env.state.tabs.count, before, "Switching to an existing tab must not open a duplicate.")
    }
}
