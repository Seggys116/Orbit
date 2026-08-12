import XCTest

@MainActor
final class PinnedTabOriginStoreTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: BrowserStore!
    private var spaceID: SpaceID!

    private let pinnedURL = URL(string: "https://www.nytimes.com/2024/02/22/some-article")!
    private let wanderedURL = URL(string: "https://www.nytimes.com/section/world")!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-PinnedTabOriginStore-\(UUID().uuidString)", isDirectory: true)
        store = BrowserStore(
            stateStore: StateStore(rootDirectory: scratchDirectory, maxBackups: 0),
            autoArchiveInterval: nil
        )
        spaceID = store.activeSpace!.id
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        store = nil
        spaceID = nil
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTodayTab(url: URL? = nil, title: String = "The Article I Pinned") -> TabID {
        let id = store.openTab(url: url ?? pinnedURL, in: spaceID, activate: false)
        store.state.tabs[id]?.title = title
        return id
    }

    private func navigate(_ id: TabID, to url: URL, title: String) {
        store.state.tabs[id]?.url = url
        store.state.tabs[id]?.title = title
    }

    // MARK: - Capturing the origin

    func testPinningCapturesTheCurrentURLAndTitleAsTheOrigin() {
        let id = makeTodayTab()
        XCTAssertNil(store.tab(id)?.pinnedURL, "A Today tab has no pinned origin.")

        store.pin(id)

        XCTAssertEqual(store.tab(id)?.pinnedURL, pinnedURL)
        XCTAssertEqual(store.tab(id)?.pinnedTitle, "The Article I Pinned")
    }

    func testOpeningDirectlyIntoThePinnedSectionCapturesTheOrigin() {
        let id = store.openTab(url: pinnedURL, in: spaceID, section: .pinned, activate: false)

        XCTAssertEqual(store.tab(id)?.pinnedURL, pinnedURL)
        XCTAssertNil(store.tab(id)?.pinnedTitle, "Nothing has loaded yet, so there is no page title to remember.")
    }

    func testOpeningIntoTodayCapturesNoOrigin() {
        let id = store.openTab(url: pinnedURL, in: spaceID, activate: false)
        XCTAssertNil(store.tab(id)?.pinnedURL)
    }

    func testRePinningAfterAnUnpinRecapturesTheOriginAtTheNewPage() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")
        store.unpin(id)

        store.pin(id)

        XCTAssertEqual(store.tab(id)?.pinnedURL, wanderedURL, "An explicit re-pin points the origin at the page being pinned.")
        XCTAssertEqual(store.tab(id)?.pinnedTitle, "World News")
    }

    // MARK: - hasNavigatedAwayFromPinnedURL

    func testTabIsNotNavigatedAwayAtPinTimeAndIsAfterNavigating() {
        let id = makeTodayTab()
        store.pin(id)
        XCTAssertFalse(store.tab(id)!.hasNavigatedAwayFromPinnedURL)

        navigate(id, to: wanderedURL, title: "World News")

        XCTAssertTrue(store.tab(id)!.hasNavigatedAwayFromPinnedURL)
    }

    func testATrailingSlashAloneIsNotNavigatingAway() {
        let id = makeTodayTab(url: URL(string: "https://example.com")!)
        store.pin(id)

        navigate(id, to: URL(string: "https://example.com/")!, title: "Example")

        XCTAssertFalse(
            store.tab(id)!.hasNavigatedAwayFromPinnedURL,
            "https://example.com and https://example.com/ are the same page to a user."
        )
    }

    func testADifferentQueryStringIsNavigatingAway() {
        let id = makeTodayTab(url: URL(string: "https://example.com/search")!)
        store.pin(id)

        navigate(id, to: URL(string: "https://example.com/search?q=orbit")!, title: "Results")

        XCTAssertTrue(store.tab(id)!.hasNavigatedAwayFromPinnedURL)
    }

    func testAnUnpinnedTabIsNeverReportedAsNavigatedAway() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")
        XCTAssertTrue(store.tab(id)!.hasNavigatedAwayFromPinnedURL)

        store.unpin(id)

        XCTAssertNotNil(store.tab(id)?.pinnedURL, "unpin deliberately keeps the origin — see its doc comment.")
        XCTAssertFalse(store.tab(id)!.hasNavigatedAwayFromPinnedURL, "...but a Today row draws no slash and offers no reset.")
    }

    // MARK: - resetPinnedTab

    func testResettingPutsTheURLBackAndReturnsThePriorURL() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")

        let prior = store.resetPinnedTab(id)

        XCTAssertEqual(prior, wanderedURL, "The caller needs the page the user wandered to, or Command-click has nothing to open.")
        XCTAssertEqual(store.tab(id)?.url, pinnedURL)
        XCTAssertEqual(store.tab(id)?.title, "The Article I Pinned", "The row must not keep naming the page the user just left.")
        XCTAssertFalse(store.tab(id)!.hasNavigatedAwayFromPinnedURL, "After a reset the slash marker goes away.")
        XCTAssertEqual(store.tab(id)?.pinnedURL, pinnedURL, "Resetting does not consume the origin — it can be done again.")
    }

    func testResettingATabAlreadyOnItsOriginDoesNothing() {
        let id = makeTodayTab()
        store.pin(id)

        XCTAssertNil(store.resetPinnedTab(id))
        XCTAssertEqual(store.tab(id)?.url, pinnedURL)
    }

    func testResettingATabWithNoOriginDoesNothing() {
        let id = makeTodayTab()
        store.pin(id)
        store.state.tabs[id]?.pinnedURL = nil
        navigate(id, to: wanderedURL, title: "World News")

        XCTAssertNil(store.resetPinnedTab(id))
        XCTAssertEqual(store.tab(id)?.url, wanderedURL, "With nothing recorded there is nowhere to go back to.")
    }

    func testANonPinnedTabIsUnaffectedByEveryPinnedOriginMutation() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")
        store.unpin(id)

        XCTAssertNil(store.resetPinnedTab(id), "resetPinnedTab must refuse a tab that is not pinned.")
        XCTAssertEqual(store.tab(id)?.url, wanderedURL)

        store.replacePinnedURLWithCurrent(id)
        XCTAssertEqual(store.tab(id)?.pinnedURL, pinnedURL, "replacePinnedURLWithCurrent must refuse a tab that is not pinned.")

        store.setPinnedURL(id, to: URL(string: "https://example.com/typed")!)
        XCTAssertEqual(store.tab(id)?.pinnedURL, pinnedURL, "setPinnedURL must refuse a tab that is not pinned.")
    }

    // MARK: - Edit Pinned Page

    func testReplacePinnedURLWithCurrentMovesTheOriginToWhereTheTabIsNow() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")
        XCTAssertTrue(store.tab(id)!.hasNavigatedAwayFromPinnedURL)

        store.replacePinnedURLWithCurrent(id)

        XCTAssertEqual(store.tab(id)?.pinnedURL, wanderedURL)
        XCTAssertEqual(store.tab(id)?.pinnedTitle, "World News")
        XCTAssertFalse(store.tab(id)!.hasNavigatedAwayFromPinnedURL, "The page being viewed is now the pinned page, so no slash.")
        XCTAssertNil(store.resetPinnedTab(id), "And there is nothing left to reset back to.")
    }

    func testSetPinnedURLEditsTheOriginWithoutNavigating() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")

        let typed = URL(string: "https://www.nytimes.com/2020/01/01/a-different-article")!
        store.setPinnedURL(id, to: typed)

        XCTAssertEqual(store.tab(id)?.pinnedURL, typed)
        XCTAssertNil(store.tab(id)?.pinnedTitle, "A typed URL has never been loaded here, so the old title would be a lie.")
        XCTAssertEqual(store.tab(id)?.url, wanderedURL, "Editing where a tab resets to is not a navigation.")

        XCTAssertEqual(store.resetPinnedTab(id), wanderedURL)
        XCTAssertEqual(store.tab(id)?.url, typed, "And the edited URL is genuinely where a reset now goes.")
    }

    // MARK: - Round-tripping through close / reopen / move

    func testCloseAndReopenPreservesTheOriginRatherThanRecapturingIt() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")

        store.closeTab(id)
        XCTAssertEqual(store.tab(id)?.section, .today, "closeTab on a pinned tab unpins it.")

        store.reopenLastClosedTab()

        XCTAssertEqual(store.tab(id)?.section, .pinned)
        XCTAssertEqual(
            store.tab(id)?.pinnedURL, pinnedURL,
            "Cmd+Shift+T reverses closeTab exactly; it must not re-pin at whatever page the tab happened to be on."
        )
        XCTAssertEqual(store.tab(id)?.pinnedTitle, "The Article I Pinned")
        XCTAssertTrue(store.tab(id)!.hasNavigatedAwayFromPinnedURL, "And the tab is back in the state it was closed in.")
        XCTAssertEqual(store.resetPinnedTab(id), wanderedURL, "So resetting still works, and still goes to the right place.")
    }

    func testMovingAPinnedTabToAnotherSpaceKeepsTheOrigin() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")
        let otherSpaceID = store.createSpace(name: "Personal", profileID: store.state.profiles[0].id)

        store.moveTab(id, toSpace: otherSpaceID)

        XCTAssertEqual(store.tab(id)?.spaceID, otherSpaceID)
        XCTAssertEqual(store.tab(id)?.section, .pinned, "Pinned stays Pinned across a Space move.")
        XCTAssertEqual(store.tab(id)?.pinnedURL, pinnedURL)
        XCTAssertEqual(store.tab(id)?.pinnedTitle, "The Article I Pinned")
        XCTAssertEqual(store.resetPinnedTab(id), wanderedURL)
    }

    // MARK: - No automatic reversion

    func testNothingRevertsAPinnedTabAutomatically() {
        let id = makeTodayTab()
        store.pin(id)
        navigate(id, to: wanderedURL, title: "World News")

        let otherTabID = store.openTab(url: URL(string: "https://example.com/other")!, in: spaceID, activate: true)
        store.selectTab(otherTabID)
        store.selectTab(id)
        XCTAssertEqual(store.tab(id)?.url, wanderedURL, "Switching tabs must not Reset a Pinned Tab.")

        store.archiveTab(id)
        store.restoreFromArchive(id, to: .pinned)
        XCTAssertEqual(store.tab(id)?.section, .pinned)
        XCTAssertEqual(store.tab(id)?.url, wanderedURL, "Archiving and restoring must not Reset a Pinned Tab.")
        XCTAssertEqual(store.tab(id)?.pinnedURL, pinnedURL, "...and must not lose the origin either.")

        store.runArchiveSweep(now: Date().addingTimeInterval(60 * 60 * 24 * 365))
        XCTAssertEqual(store.tab(id)?.url, wanderedURL, "No timer in Orbit may Reset a Pinned Tab.")

        XCTAssertEqual(store.resetPinnedTab(id), wanderedURL)
        XCTAssertEqual(store.tab(id)?.url, pinnedURL)
    }
}
