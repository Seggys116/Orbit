// Guards id/discoverability only, never perform's implementation. CommandBarModel.swift
// is symlinked into this host-less, Sparkle-free target: a direct UpdaterController.shared
// call would fail to compile here and take every test sharing the symlink down with it.

import XCTest

final class CommandBarCheckForUpdatesActionTests: XCTestCase {

    private static let expectedActionID = "check-for-updates"

    private func checkForUpdatesAction() throws -> CommandAction {
        try XCTUnwrap(
            CommandBarEngine.allActions().first { $0.id == Self.expectedActionID },
            "CommandBarEngine.allActions() has no action with id \"\(Self.expectedActionID)\" yet. If the UI team's concurrent work on Orbit/UI/CommandBar/CommandBarModel.swift has not landed this, that is the expected state of this failure, not a bug in this test."
        )
    }

    func test_anActionWithExactlyTheRequiredID_exists() throws {
        _ = try checkForUpdatesAction()
    }

    func test_theActionIsDiscoverableByASensibleQuery() throws {
        let action = try checkForUpdatesAction()
        let env = AppEnvironment()
        env.state.profiles = [Profile(name: "Personal")]
        let space = Space(name: "Personal", profileID: env.state.profiles[0].id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id

        let results = CommandBarEngine.results(query: "check for updates", mode: .newTab, env: env, suggestions: [])
        let offered = results.contains { result in
            if case .action(let candidate) = result.kind { return candidate.id == action.id }
            return false
        }
        XCTAssertTrue(
            offered,
            "typing \"check for updates\" must surface the check-for-updates action — an action present only in allActions() but never matched by its own title/keywords is present but not actually wired into the bar a user types into."
        )
    }

    func test_theActionHasATitleContainingUpdate() throws {
        let action = try checkForUpdatesAction()
        XCTAssertFalse(action.title.isEmpty)
        XCTAssertTrue(
            action.title.localizedCaseInsensitiveContains("update"),
            "the check-for-updates action's title (\"\(action.title)\") does not mention \"update\" at all"
        )
    }
}
