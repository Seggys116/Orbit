import XCTest

@MainActor
final class CommandBarViewArchiveActionTests: XCTestCase {

    private func makeEnvironment() -> AppEnvironment {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id
        return env
    }

    private func viewArchiveAction() throws -> CommandAction {
        try XCTUnwrap(
            CommandBarEngine.allActions().first { $0.id == "view-archive" },
            "allActions() must offer Arc's own \"View Archive\" Command Bar action."
        )
    }

    private func offersViewArchive(for query: String, env: AppEnvironment) -> Bool {
        CommandBarEngine.results(query: query, mode: .newTab, env: env, suggestions: []).contains { result in
            if case .action(let candidate) = result.kind { return candidate.id == "view-archive" }
            return false
        }
    }

    func test_theBarOffersViewArchiveForArcsOwnPhrase() throws {
        let action = try viewArchiveAction()
        XCTAssertEqual(action.title, "View Archive", "Arc's Help Center tells people to type exactly this.")
        XCTAssertTrue(offersViewArchive(for: "view archive", env: makeEnvironment()))
    }

    func test_theBarOffersViewArchiveForTheOtherPhrasesArcUses() throws {
        let env = makeEnvironment()
        XCTAssertTrue(offersViewArchive(for: "archived tabs", env: env), "Arc's article heading is \"View Archived Tabs\".")
        XCTAssertTrue(offersViewArchive(for: "archive", env: env), "The bare word must find it as well.")
    }

    func test_runningViewArchive_issuesTheArchivedTabsCommand() throws {
        let env = makeEnvironment()
        let action = try viewArchiveAction()

        action.perform(env)

        XCTAssertEqual(
            env.recordedActions, ["perform(\(ShortcutCommandID.archivedTabs.rawValue))"],
            """
            "View Archive" must run the .archivedTabs command. Running .library or \
            .downloads instead would put the action's title in contradiction with \
            where it goes.
            """
        )
    }

    func test_theResultListNeverContainsAnArchivedTab() throws {
        let env = makeEnvironment()
        let space = try XCTUnwrap(env.state.spaces.first)

        let live = Tab(spaceID: space.id, section: .today, url: URL(string: "https://example.com/live")!, title: "Zebra Live")
        let archived = Tab(spaceID: space.id, section: .archived, url: URL(string: "https://example.com/archived")!, title: "Zebra Archived")
        env.state.tabs = [live.id: live, archived.id: archived]

        let results = CommandBarEngine.results(query: "zebra", mode: .newTab, env: env, suggestions: [])

        let offeredTabIDs: [TabID] = results.compactMap { result in
            switch result.kind {
            case .openTab(let id), .pinnedTab(let id), .tabInOtherSpace(let id, _): return id
            default: return nil
            }
        }
        XCTAssertTrue(offeredTabIDs.contains(live.id), "test precondition: the live tab must be offered, or this proves nothing")
        XCTAssertFalse(
            offeredTabIDs.contains(archived.id),
            """
            An archived tab was offered as a tab result. Arc does not do this — it \
            offers a "View Archive" action instead, and the searching lives in the \
            Library. See this file's header for the first-party sources.
            """
        )
        XCTAssertFalse(
            results.contains { $0.title == "Zebra Archived" },
            "…and it must not reach the list under any other row kind either."
        )
    }

    func test_aHistoryHitForAnArchivedPage_navigatesAndIsNotCaptionedAsATab() throws {
        let env = makeEnvironment()
        let space = try XCTUnwrap(env.state.spaces.first)
        let url = URL(string: "https://example.com/archived")!

        let archived = Tab(spaceID: space.id, section: .archived, url: url, title: "Zebra Archived")
        env.state.tabs = [archived.id: archived]
        env.historyEntries = [HistoryEntry(url: url, title: "Zebra Archived", profileID: space.profileID)]

        let results = CommandBarEngine.results(query: "zebra", mode: .newTab, env: env, suggestions: [])
        let row = try XCTUnwrap(
            results.first { if case .history = $0.kind { return true } else { return false } },
            "the archived page must still be reachable as an ordinary history hit"
        )

        guard case .navigate(let destination) = row.kind.activationIntent else {
            XCTFail("A history hit for an archived page must navigate, not switch to or restore a tab.")
            return
        }
        XCTAssertEqual(destination, url)
        XCTAssertFalse(
            results.contains { result in
                switch result.kind {
                case .openTab, .pinnedTab, .tabInOtherSpace: return true
                default: return false
                }
            },
            "No row may claim \"Switch to Tab\" for a page whose only tab is archived — there is no live tab to switch to."
        )
    }
}
