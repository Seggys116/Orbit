import XCTest
@testable import Orbit

// MARK: - Recorded provider

private final class RecordedSink: @unchecked Sendable {
    private(set) var requests: [AssistRequest] = []
    var reply = ""
    var failure: AssistError?

    var sink: AssistSink {
        AssistSink(
            generate: { [self] request in
                requests.append(request)
                if let failure { throw failure }
                return reply
            },
            pageText: { nil }
        )
    }
}

@MainActor
// Whole suite excluded on GitHub-hosted runners: needs a real running app, not a headless VM.
final class TidyTabsCoordinatorTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var suite: UserDefaults!
    private var coordinator: TidyTabsCoordinator!
    private var provider: RecordedSink!

    private var spaceID: SpaceID!
    private var tabIDs: [TabID] = []

    private static let fixture: [(title: String, url: String)] = [
        ("Best time to visit Oaxaca", "https://www.lonelyplanet.com/mexico/oaxaca"),
        ("Oaxaca flights in April", "https://www.google.com/flights?q=oaxaca"),
        ("Mezcal tasting tour", "https://www.airbnb.com/experiences/9021"),
        ("Swift concurrency roadmap", "https://forums.swift.org/t/concurrency"),
        ("Sendable and actor isolation", "https://www.google.com/search?q=sendable"),
        ("WWDC session on Observation", "https://developer.apple.com/videos/1234"),
        ("Kitchen extension quotes", "https://www.checkatrade.com/quotes"),
        ("Council planning portal", "https://planning.example.gov.uk/app"),
    ]

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "TidyTabsCoordinatorTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
        AssistSettings.isTidyTabsEnabled = true
        coordinator = TidyTabsCoordinator()
        provider = RecordedSink()

        spaceID = env.state.spaces.first?.id
        XCTAssertNotNil(spaceID, "The demo environment must come with a Space to put tabs in.")
        for tab in env.todayTabs(in: spaceID) { env.store.closeTab(tab.id) }
        tabIDs = Self.fixture.map { env.store.openTab(url: URL(string: $0.url)!, in: spaceID, activate: false) }
        for (index, id) in tabIDs.enumerated() {
            env.store.state.tabs[id]?.title = Self.fixture[index].title
        }
        pinnedFolderNamesAtSetUp = pinnedFolderNames()
    }

    override func tearDown() {
        AssistSettings.defaults = OrbitDefaults.standard
        suite = nil
        coordinator = nil
        provider = nil
        tabIDs = []
        spaceID = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private var pinnedFolderNamesAtSetUp: Set<String> = []

    private func pinnedFolderNames() -> Set<String> {
        Set(env.pinnedNodes(in: spaceID).compactMap { node -> String? in
            if case .folder(let folder) = node { return folder.name }
            return nil
        })
    }

    private func todayShape() -> [(title: String, group: String?)] {
        env.todayTabs(in: spaceID).map { ($0.displayTitle, $0.tidyGroup) }
    }

    private func candidates() -> [AssistRuntime.TidyTabCandidate] {
        TidyTabsCoordinator.candidates(from: env.todayTabs(in: spaceID))
    }

    private func runTidy() async -> Result<[AssistRuntime.TidyTabGroup], AssistError> {
        await coordinator.tidy(spaceID: spaceID, candidates: candidates(), sink: provider.sink) { groups in
            env.applyTidyTabGroups(groups, in: spaceID)
        }
    }

    // MARK: - The feature working

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aScriptedReplyReordersTodayUnderModelNamedHeaders

    func test_aScriptedReplyReordersTodayUnderModelNamedHeaders() async {
        provider.reply = """
            GROUP: Oaxaca Trip | 1, 2, 3
            GROUP: Swift Concurrency | 4, 5, 6
            GROUP: Building Work | 7, 8
            """

        let result = await runTidy()

        guard case .success = result else { return XCTFail("Expected success, got \(result).") }
        XCTAssertEqual(
            todayShape().map(\.group),
            ["Oaxaca Trip", "Oaxaca Trip", "Oaxaca Trip",
             "Swift Concurrency", "Swift Concurrency", "Swift Concurrency",
             "Building Work", "Building Work"],
            "Every Today tab must be labelled and the groups must be contiguous, or headers cannot render as runs."
        )
        XCTAssertEqual(env.todayTabs(in: spaceID).count, 8, "Arc: 'Your other tabs will not be affected.' Nothing leaves Today.")
        XCTAssertEqual(
            pinnedFolderNames(), pinnedFolderNamesAtSetUp,
            """
            Tidy Tabs makes inline headers, not folders — Arc's own capture shows the groups \
            inside Today. No folder may appear in Pinned as a result of a tidy. (Compared \
            against the folders the demo document already had, not against emptiness.)
            """
        )
        XCTAssertFalse(Set(todayShape().compactMap(\.group)).contains("Google"))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_ungroupedTabsAreOrderedAboveTheFirstHeader

    func test_ungroupedTabsAreOrderedAboveTheFirstHeader() async {
        provider.reply = "GROUP: Oaxaca Trip | 1, 2, 3"

        _ = await runTidy()

        let shape = todayShape()
        XCTAssertEqual(
            shape.suffix(3).map(\.group), ["Oaxaca Trip", "Oaxaca Trip", "Oaxaca Trip"],
            "The one named group goes to the bottom of the list."
        )
        XCTAssertEqual(
            shape.prefix(5).compactMap(\.group), [],
            "Everything the model did not name is ungrouped and sits above the first header."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_removeHeaderUngroupsWithoutClosingOrReorderingAnything

    func test_removeHeaderUngroupsWithoutClosingOrReorderingAnything() async {
        provider.reply = """
            GROUP: Oaxaca Trip | 1, 2, 3
            GROUP: Swift Concurrency | 4, 5, 6
            """
        _ = await runTidy()
        let orderBefore = env.todayTabs(in: spaceID).map(\.id)

        env.removeTidyGroup(named: "Oaxaca Trip", in: spaceID)

        XCTAssertEqual(env.todayTabs(in: spaceID).map(\.id), orderBefore, "Removing a header must not reorder the list.")
        XCTAssertEqual(env.todayTabs(in: spaceID).count, 8, "Removing a header must close nothing.")
        XCTAssertFalse(todayShape().compactMap(\.group).contains("Oaxaca Trip"))
        XCTAssertEqual(
            todayShape().filter { $0.group == "Swift Concurrency" }.count, 3,
            "Only the named header goes."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_convertToFolderPinsTheGroupAndTheHeaderDisappearsWithIt

    func test_convertToFolderPinsTheGroupAndTheHeaderDisappearsWithIt() async {
        provider.reply = "GROUP: Oaxaca Trip | 1, 2, 3"
        _ = await runTidy()

        env.convertTidyGroupToFolder(named: "Oaxaca Trip", in: spaceID)

        let added = Set(pinnedFolderNames()).subtracting(pinnedFolderNamesAtSetUp)
        XCTAssertEqual(added, ["Oaxaca Trip"], "Exactly one new folder, and it takes the header's name.")
        let folder = env.pinnedNodes(in: spaceID).compactMap { node -> Folder? in
            if case .folder(let candidate) = node, candidate.name == "Oaxaca Trip" { return candidate }
            return nil
        }.first
        XCTAssertEqual(folder?.allTabIDs.count, 3, "All three tabs move into it.")
        XCTAssertEqual(env.todayTabs(in: spaceID).count, 5, "Those three left Today.")
        XCTAssertEqual(
            todayShape().compactMap(\.group), [],
            "A pinned tab must not keep a Today header — nothing renders it and nothing could clear it."
        )
    }

    // MARK: - Failure: say so, change nothing

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aFailedRequestLeavesTheSidebarUntouchedAndReportsTheError

    func test_aFailedRequestLeavesTheSidebarUntouchedAndReportsTheError() async {
        let orderBefore = env.todayTabs(in: spaceID).map(\.id)
        provider.failure = .http(status: 500, body: "boom")

        let result = await runTidy()

        guard case .failure(let error) = result else { return XCTFail("Expected a failure, got \(result).") }
        XCTAssertEqual(error, .http(status: 500, body: "boom"))
        XCTAssertEqual(env.todayTabs(in: spaceID).map(\.id), orderBefore, "A failed tidy must not reorder anything.")
        XCTAssertEqual(todayShape().compactMap(\.group), [], "A failed tidy must not label anything.")

        guard case .failed(let message) = coordinator.phase(for: spaceID) else {
            return XCTFail("A failure must be shown, not swallowed. Phase was \(coordinator.phase(for: spaceID)).")
        }
        XCTAssertTrue(message.contains("500"), "The message shown must be the real one. Got: \(message)")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aFailedRequestDoesNotSilentlyFallBackToHostGrouping

    func test_aFailedRequestDoesNotSilentlyFallBackToHostGrouping() async {
        provider.failure = .transport("offline")

        _ = await runTidy()

        XCTAssertEqual(
            todayShape().compactMap(\.group), [],
            """
            The host fallback produces headers named after sites, and this fixture has two \
            tabs on www.google.com — so a silent fallback would show a `Google` header here. \
            There must be none.
            """
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aReplyWithNothingUsableInItIsAFailureNotAnEmptySuccess

    func test_aReplyWithNothingUsableInItIsAFailureNotAnEmptySuccess() async {
        provider.reply = "Sorry, I can't organise these."

        let result = await runTidy()

        guard case .failure(let error) = result else { return XCTFail("Expected a failure, got \(result).") }
        XCTAssertEqual(error, .emptyCompletion)
        XCTAssertEqual(todayShape().compactMap(\.group), [])
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theStoreRefusesTabsThatAreNotTodayTabsOfThisSpace

    func test_theStoreRefusesTabsThatAreNotTodayTabsOfThisSpace() {
        let stranger = env.store.openTab(url: URL(string: "https://example.com/pinned")!, in: spaceID, section: .pinned, activate: false)

        let applied = env.store.applyTidyTabGroups(
            [(name: "Sneaky", tabIDs: [stranger, tabIDs[0], tabIDs[1]])],
            in: spaceID
        )

        XCTAssertEqual(applied, ["Sneaky"])
        XCTAssertNil(
            env.tab(stranger)?.tidyGroup,
            "A pinned tab must not be labelled. Arc: 'Tidy Tabs only organizes Today Tabs.'"
        )
        XCTAssertEqual(
            Set(env.todayTabs(in: spaceID).map(\.id)), Set(tabIDs),
            """
            Naming an outside tab must not drag it into Today either. Without the guard the \
            reorder puts every named id into `Space.today`, so a pinned tab ends up listed in \
            two places at once — which is the invariant `removeFromAllContainers` exists to \
            keep and the one thing this write is capable of breaking.
            """
        )
        XCTAssertEqual(env.tab(stranger)?.section, .pinned, "It must still be pinned.")
        XCTAssertEqual(env.tab(tabIDs[0])?.tidyGroup, "Sneaky")
    }

    // MARK: - Nothing leaves an incognito window

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anIncognitoSpaceIsRefusedAndNothingIsSent

    func test_anIncognitoSpaceIsRefusedAndNothingIsSent() async {
        let index = try! XCTUnwrap(env.state.spaces.firstIndex { $0.id == spaceID })
        let incognitoProfile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
        env.store.state.profiles.append(incognitoProfile)
        env.store.state.spaces[index].profileID = incognitoProfile.id
        env.store.state.spaces[index].isEphemeral = true
        XCTAssertTrue(env.isIncognito(env.state.spaces[index]), "Fixture check: the Space must actually read as Incognito.")

        coordinator.tidy(spaceID: spaceID, env: env)

        guard case .failed(let message) = coordinator.phase(for: spaceID) else {
            return XCTFail("An Incognito tidy must fail visibly. Phase was \(coordinator.phase(for: spaceID)).")
        }
        XCTAssertEqual(message, AssistError.incognito.localizedDescription)
        XCTAssertEqual(todayShape().compactMap(\.group), [], "Nothing may be grouped, because nothing may be sent.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theProductionEntryPointRefusesWhenTheSwitchIsOff

    func test_theProductionEntryPointRefusesWhenTheSwitchIsOff() {
        AssistSettings.isTidyTabsEnabled = false

        coordinator.tidy(spaceID: spaceID, env: env)

        guard case .failed(let message) = coordinator.phase(for: spaceID) else {
            return XCTFail("A switched-off feature must say so.")
        }
        XCTAssertEqual(message, AssistError.featureDisabled("Tidy Tabs").localizedDescription)
        XCTAssertEqual(todayShape().compactMap(\.group), [])
    }

    // MARK: - The model-free path is still there

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theHostFallbackStillGroupsTodayTabsBySiteWithNoProvider

    func test_theHostFallbackStillGroupsTodayTabsBySiteWithNoProvider() {
        AssistSettings.isTidyTabsEnabled = false

        let applied = env.tidyTodayTabsByHost(in: spaceID)

        XCTAssertEqual(applied, ["Google.Com"], "Only google.com has two tabs in this fixture; a group of one is not a group.")
        XCTAssertEqual(
            todayShape().suffix(2).map(\.group), ["Google.Com", "Google.Com"],
            "The grouped tabs go to the bottom, under their header, exactly like the model path."
        )
        XCTAssertEqual(env.todayTabs(in: spaceID).count, 8, "Grouping by site must not close or move anything out of Today.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_shouldUseModelIsGatedOnTheSwitchAndTheThreshold

    func test_shouldUseModelIsGatedOnTheSwitchAndTheThreshold() {
        AssistSettings.isTidyTabsEnabled = true
        AssistSettings.baseURLString = "https://api.example-provider.test/v1"
        AssistSettings.model = "test-model"
        AssistKeychain.inMemoryOverride = [AssistKeychain.account(for: AssistSettings.providerKind): "test-key"]
        defer { AssistKeychain.inMemoryOverride = nil }

        XCTAssertTrue(TidyTabsCoordinator.shouldUseModel(todayTabCount: 7))
        XCTAssertFalse(TidyTabsCoordinator.shouldUseModel(todayTabCount: 6), "Arc: 'more than six'.")

        AssistSettings.isTidyTabsEnabled = false
        XCTAssertFalse(TidyTabsCoordinator.shouldUseModel(todayTabCount: 7))
    }
}
