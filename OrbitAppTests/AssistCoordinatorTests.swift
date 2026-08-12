import XCTest
@testable import Orbit

// MARK: - Recorded provider

private final class RecordedSink: @unchecked Sendable {
    private(set) var requests: [AssistRequest] = []
    var reply = "Tidied"
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
final class TidyTabTitlesCoordinatorTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var suite: UserDefaults!
    private var spaceID: SpaceID!

    private let longTitle = "Mezcal and Mole with a Local Chef in Oaxaca City | Airbnb Experiences"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "TidyTabTitlesCoordinatorTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
        AssistSettings.isTidyTabTitlesEnabled = true
        spaceID = env.spaces.first!.id
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        super.tearDown()
    }

    private func makeTab(title: String) -> TabID {
        let id = env.openTab(url: URL(string: "https://www.airbnb.com/experiences/12345")!, in: spaceID)
        env.store.state.tabs[id]?.title = title
        return id
    }

    // MARK: shouldRequest

    func test_shouldRequest_isFalseForATitleShortEnoughToAlreadyFit() {
        let coordinator = TidyTabTitlesCoordinator()
        XCTAssertFalse(
            coordinator.shouldRequest(tabID: UUID(), rawTitle: "Short"),
            "There is nothing to shorten, and Orbit must not spend a request finding that out"
        )
    }

    func test_shouldRequest_isTrueForALongTitle() {
        let coordinator = TidyTabTitlesCoordinator()
        XCTAssertTrue(coordinator.shouldRequest(tabID: UUID(), rawTitle: longTitle))
    }

    // MARK: tidy

    func test_tidy_writesTheShortenedTitleThroughApply() async {
        let coordinator = TidyTabTitlesCoordinator()
        let provider = RecordedSink()
        provider.reply = "Mezcal and Mole"
        var applied: [TabID: String?] = [:]

        let result = await coordinator.tidy(
            tabID: UUID(),
            rawTitle: longTitle,
            url: URL(string: "https://www.airbnb.com/experiences/12345")!,
            sink: provider.sink
        ) { id, value in applied[id] = value }

        XCTAssertEqual(result, "Mezcal and Mole")
        XCTAssertEqual(applied.values.first, "Mezcal and Mole")
        XCTAssertEqual(provider.requests.count, 1)
    }

    func test_tidy_appliesNilWhenTheProviderFails_soTheRealTitleStays() async {
        let coordinator = TidyTabTitlesCoordinator()
        let provider = RecordedSink()
        provider.failure = .http(status: 500, body: "boom")
        var applied: [TabID: String?] = [:]

        let result = await coordinator.tidy(
            tabID: UUID(),
            rawTitle: longTitle,
            url: URL(string: "https://example.com")!,
            sink: provider.sink
        ) { id, value in applied[id] = value }

        XCTAssertNil(result)
        XCTAssertEqual(applied.count, 1)
        XCTAssertNil(applied.values.first ?? nil, "A failed rename must leave the real title on screen, never a substitute")
    }

    // MARK: the pin trigger — Arc's actual trigger

    func test_pinningATabWithNoProviderConfiguredChangesNothing() {
        let coordinator = TidyTabTitlesCoordinator()
        let tabID = makeTab(title: longTitle)

        coordinator.tabWasPinned(tabID: tabID, env: env)

        XCTAssertNil(env.tab(tabID)?.tidiedTitle, "With no provider there is nothing to write")
        XCTAssertEqual(env.tab(tabID)?.displayTitle, longTitle)
    }

    func test_pinningPostsTheNotificationTheCoordinatorListensFor() {
        let tabID = makeTab(title: longTitle)
        let expectation = expectation(forNotification: .orbitTabDidPin, object: nil) { note in
            (note.userInfo?["tabID"] as? TabID) == tabID
        }

        env.pinTab(tabID)

        wait(for: [expectation], timeout: 2)
    }

    func test_unpinningRestoresTheRealTitle() {
        let tabID = makeTab(title: longTitle)
        env.pinTab(tabID)
        env.store.setTidiedTitle("Mezcal and Mole", forTab: tabID)
        XCTAssertEqual(env.tab(tabID)?.displayTitle, "Mezcal and Mole")

        env.unpinTab(tabID)

        XCTAssertNil(env.tab(tabID)?.tidiedTitle)
        XCTAssertEqual(env.tab(tabID)?.displayTitle, longTitle, "Unpinning gives the tab its real title back")
    }

    func test_clearAllTidiedTitles_isWhatSwitchingTheFeatureOffDoes() {
        let a = makeTab(title: longTitle)
        let b = makeTab(title: longTitle)
        env.store.setTidiedTitle("A", forTab: a)
        env.store.setTidiedTitle("B", forTab: b)

        env.store.clearAllTidiedTitles()

        XCTAssertNil(env.tab(a)?.tidiedTitle)
        XCTAssertNil(env.tab(b)?.tidiedTitle)
    }

    // MARK: navigating a pinned tab away

    func test_shouldClearOnCommit_whenAPinnedTabNavigatesAwayFromItsPinnedURL() {
        var tab = Tab(
            spaceID: UUID(),
            section: .pinned,
            url: URL(string: "https://example.com/a")!,
            title: "t",
            pinnedURL: URL(string: "https://example.com/a")!,
            tidiedTitle: "Tidied"
        )
        XCTAssertTrue(
            TidyTabTitlesCoordinator.shouldClearOnCommit(tab: tab, committedURL: URL(string: "https://example.com/somewhere-else")!)
        )
        XCTAssertFalse(
            TidyTabTitlesCoordinator.shouldClearOnCommit(tab: tab, committedURL: URL(string: "https://example.com/a")!),
            "Reloading the pinned page is not navigating away"
        )
        XCTAssertFalse(
            TidyTabTitlesCoordinator.shouldClearOnCommit(tab: tab, committedURL: URL(string: "https://example.com/a/")!),
            "One trailing slash is ignored, matching the rule behind the `/` affordance"
        )

        tab.section = .today
        XCTAssertFalse(
            TidyTabTitlesCoordinator.shouldClearOnCommit(tab: tab, committedURL: URL(string: "https://example.com/elsewhere")!),
            "An unpinned tab has no tidied title to invalidate"
        )
    }
}
