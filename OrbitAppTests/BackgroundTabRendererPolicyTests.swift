import XCTest
@testable import Orbit

@MainActor
final class BackgroundTabRendererPolicyTests: XCTestCase {

    // MARK: - Harness

    private final class RendererRecorder {
        var requests: [(tabID: TabID, url: URL)] = []
        var contentsByTab: [TabID: MockWebContents] = [:]

        var lastRequestedURL: URL? { requests.last?.url }
    }

    private func makeEnvironment() -> (AppEnvironment, RendererRecorder) {
        let env = AppEnvironment.demo
        let recorder = RendererRecorder()
        env._test_webContentsFactory = { tabID, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            recorder.requests.append((tabID, url))
            recorder.contentsByTab[tabID] = contents
            return contents
        }
        return (env, recorder)
    }

    @discardableResult
    private func makeLiveTab(
        _ env: AppEnvironment,
        in spaceID: SpaceID,
        url: String,
        idleSeconds: TimeInterval
    ) -> TabID {
        let tabID = env.store.openTab(url: URL(string: url)!, in: spaceID, activate: false)
        env.materializeWebContents(for: tabID, url: URL(string: url)!)
        env.store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-idleSeconds)
        return tabID
    }

    private func firstSpaceID(_ env: AppEnvironment) -> SpaceID {
        env.store.state.spaces[0].id
    }

    // MARK: - The core claim

    func testAnIdleBackgroundTabActuallyReleasesItsWebContents() throws {
        let (env, recorder) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let coldTabID = makeLiveTab(env, in: spaceID, url: "https://example.com/cold", idleSeconds: 3600)
        let contents = try XCTUnwrap(recorder.contentsByTab[coldTabID])

        XCTAssertNotNil(env.webContents[coldTabID], "precondition: the tab has a renderer")
        XCTAssertEqual(env.store.tab(coldTabID)?.isUnloaded, false, "precondition: and is not flagged unloaded")

        let released = env.releaseBackgroundRenderers(.memoryPressureWarning(idleThreshold: 60))

        XCTAssertEqual(released, [coldTabID])
        XCTAssertTrue(contents.isClosed, "the renderer must be closed, not just dropped from the map")
        XCTAssertNil(env.webContents[coldTabID])
        XCTAssertEqual(env.store.tab(coldTabID)?.isUnloaded, true, "Tab.isUnloaded must finally mean what it says")
        XCTAssertNil(env.navigationStates[coldTabID], "state describing a dead renderer must not outlive it")
    }

    func testSelectingAnUnloadedTabRestoresItOnItsLastCommittedPage() throws {
        let (env, recorder) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let tabID = makeLiveTab(env, in: spaceID, url: "https://example.com/opened-here", idleSeconds: 3600)
        let original = try XCTUnwrap(recorder.contentsByTab[tabID])

        let landedOn = URL(string: "https://example.com/read-this-one")!
        original.navigationState = NavigationState(url: landedOn, title: "Read This One")
        env.webContentsDidChangeNavigationState(original)
        XCTAssertEqual(env.store.tab(tabID)?.url, landedOn, "precondition: the navigation reached the document")

        env.releaseBackgroundRenderers(.memoryPressureCritical)
        XCTAssertTrue(original.isClosed, "precondition: it really was unloaded")
        XCTAssertEqual(env.store.tab(tabID)?.isUnloaded, true)

        env.activateTab(tabID)

        let restored = try XCTUnwrap(env.webContents[tabID], "selecting an unloaded tab must give it a renderer again")
        XCTAssertFalse(restored === original, "and a genuinely new one — the old one was closed")
        XCTAssertEqual(
            recorder.lastRequestedURL, landedOn,
            "the tab must come back on its last committed page, not on the URL it was opened with"
        )
        XCTAssertEqual(env.store.tab(tabID)?.isUnloaded, false, "and must no longer be flagged unloaded")
        XCTAssertEqual(env.store.tab(tabID)?.title, "Read This One", "its title survived the unload")
    }

    // MARK: - The invariants the archive sweep already honours

    func testTheActiveTabOfEverySpaceIsNeverReleased() {
        let (env, _) = makeEnvironment()
        let profileID = env.store.state.profiles[0].id
        let firstSpace = firstSpaceID(env)
        let secondSpace = env.store.createSpace(name: "Second", profileID: profileID)

        let firstActive = makeLiveTab(env, in: firstSpace, url: "https://example.com/a", idleSeconds: 9999)
        let secondActive = makeLiveTab(env, in: secondSpace, url: "https://example.com/b", idleSeconds: 9999)
        env.store.state.activeTabBySpace[firstSpace] = firstActive
        env.store.state.activeTabBySpace[secondSpace] = secondActive
        // Assigning the active pointers above does not stamp `lastAccessedAt`.
        env.store.state.tabs[firstActive]?.lastAccessedAt = Date().addingTimeInterval(-9999)
        env.store.state.tabs[secondActive]?.lastAccessedAt = Date().addingTimeInterval(-9999)

        let released = env.releaseBackgroundRenderers(.memoryPressureCritical)

        XCTAssertTrue(released.isEmpty, "critical pressure must still spare every Space's active tab")
        XCTAssertNotNil(env.webContents[firstActive])
        XCTAssertNotNil(
            env.webContents[secondActive],
            "the active tab of a Space that is not frontmost is just as protected"
        )
    }

    func testATabInASplitGroupIsNeverReleased() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let splitTabID = makeLiveTab(env, in: spaceID, url: "https://example.com/split", idleSeconds: 9999)
        env.store.state.tabs[splitTabID]?.splitGroupID = UUID()

        let released = env.releaseBackgroundRenderers(.memoryPressureCritical)

        XCTAssertFalse(released.contains(splitTabID))
        XCTAssertNotNil(env.webContents[splitTabID])
    }

    func testATabPlayingMediaIsNeverReleased() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let playingTabID = makeLiveTab(env, in: spaceID, url: "https://example.com/radio", idleSeconds: 9999)
        let silentTabID = makeLiveTab(env, in: spaceID, url: "https://example.com/quiet", idleSeconds: 9999)
        env.mediaStates[playingTabID] = MediaState(isAudible: true, isPlaying: true)

        let released = env.releaseBackgroundRenderers(.memoryPressureCritical)

        XCTAssertFalse(released.contains(playingTabID), "a tab playing media keeps its renderer")
        XCTAssertNotNil(env.webContents[playingTabID])
        XCTAssertTrue(released.contains(silentTabID), "while an equally idle silent tab does not")
    }

    func testATabThatIsStillLoadingIsNeverReleased() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let loadingTabID = makeLiveTab(env, in: spaceID, url: "https://example.com/slow", idleSeconds: 9999)
        env.navigationStates[loadingTabID] = NavigationState(url: URL(string: "https://example.com/slow"), isLoading: true)

        let released = env.releaseBackgroundRenderers(.memoryPressureCritical)

        XCTAssertFalse(released.contains(loadingTabID))
        XCTAssertNotNil(env.webContents[loadingTabID])
    }

    // MARK: - The three triggers

    func testTheInactivitySweepSuspendsOnlyTabsLeftAloneForAPeriod() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let recentlyRead = makeLiveTab(
            env, in: spaceID, url: "https://example.com/recent",
            idleSeconds: AppEnvironment.inactivitySuspendThreshold / 4
        )
        let abandoned = makeLiveTab(
            env, in: spaceID, url: "https://example.com/abandoned",
            idleSeconds: AppEnvironment.inactivitySuspendThreshold * 2
        )

        let released = env.runInactivitySweep()

        XCTAssertEqual(released, [abandoned], "the tab left alone past the period is suspended")
        XCTAssertNil(env.webContents[abandoned])
        XCTAssertEqual(env.store.tab(abandoned)?.isUnloaded, true)
        XCTAssertNotNil(
            env.webContents[recentlyRead],
            "a tab read well inside the period has not been inactive for one"
        )
    }

    // MARK: - The other two triggers

    func testWarningPressureSparesARecentlyUsedTabAndCriticalDoesNot() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let warmTabID = makeLiveTab(env, in: spaceID, url: "https://example.com/warm", idleSeconds: 5)
        let coldTabID = makeLiveTab(env, in: spaceID, url: "https://example.com/cold", idleSeconds: 3600)

        let afterWarning = env.releaseBackgroundRenderers(.memoryPressureWarning(idleThreshold: 600))
        XCTAssertEqual(afterWarning, [coldTabID], "only the cold tab goes at warning level")
        XCTAssertNotNil(env.webContents[warmTabID])

        let afterCritical = env.releaseBackgroundRenderers(.memoryPressureCritical)
        XCTAssertEqual(afterCritical, [warmTabID], "critical level takes the warm one too")
        XCTAssertNil(env.webContents[warmTabID])
    }

    func testACriticalKernelMemoryPressureEventRunsARelease() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let tabID = makeLiveTab(env, in: spaceID, url: "https://example.com/x", idleSeconds: 1)

        env.handleMemoryPressure(.critical)

        XCTAssertNil(env.webContents[tabID], "a critical event frees eligible tabs regardless of idle time")
        XCTAssertEqual(env.store.tab(tabID)?.isUnloaded, true)
    }

    func testANormalMemoryPressureEventFreesNothing() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let tabID = makeLiveTab(env, in: spaceID, url: "https://example.com/x", idleSeconds: 9999)

        env.handleMemoryPressure(.normal)

        XCTAssertNotNil(env.webContents[tabID])
    }

    func testMaterialisingPastTheBudgetFreesTheColdestTab() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        env.liveRendererBudget = 2

        let coldest = makeLiveTab(env, in: spaceID, url: "https://example.com/1", idleSeconds: 9999)
        let middle = makeLiveTab(env, in: spaceID, url: "https://example.com/2", idleSeconds: 5000)
        XCTAssertEqual(env.webContents.count, 2, "precondition: exactly at budget")

        let newest = makeLiveTab(env, in: spaceID, url: "https://example.com/3", idleSeconds: 1000)

        XCTAssertNil(env.webContents[coldest], "the least-recently-used tab is the one that pays")
        XCTAssertNotNil(env.webContents[middle])
        XCTAssertNotNil(env.webContents[newest], "and never the tab that was just opened")
        XCTAssertEqual(env.webContents.count, 2, "the live set is back inside the budget")
    }

    func testTheBudgetWillNotFreeATabTheUserJustUsed() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        env.liveRendererBudget = 1

        let recentlyUsed = makeLiveTab(env, in: spaceID, url: "https://example.com/1", idleSeconds: 1)
        _ = makeLiveTab(env, in: spaceID, url: "https://example.com/2", idleSeconds: 1)

        XCTAssertNotNil(
            env.webContents[recentlyUsed],
            "over budget, but both tabs are inside the idle threshold, so neither is taken"
        )
        XCTAssertEqual(env.webContents.count, 2)
    }

    // MARK: - Ordering and eligibility, at the store

    func testCandidatesAreOrderedLeastRecentlyUsedFirst() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let oldest = makeLiveTab(env, in: spaceID, url: "https://example.com/1", idleSeconds: 9000)
        let middle = makeLiveTab(env, in: spaceID, url: "https://example.com/2", idleSeconds: 5000)
        let newest = makeLiveTab(env, in: spaceID, url: "https://example.com/3", idleSeconds: 1000)

        let ordered = env.store.tabsToReleaseRenderers(
            liveTabIDs: Set(env.webContents.keys),
            policy: TabRendererReleasePolicy(minimumIdle: 0, limit: nil)
        )

        XCTAssertEqual(ordered, [oldest, middle, newest])
    }

    func testAnArchivedTabIsNotACandidate() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let tabID = makeLiveTab(env, in: spaceID, url: "https://example.com/x", idleSeconds: 9999)
        env.store.archiveTab(tabID)

        XCTAssertFalse(env.store.isEligibleForRendererRelease(tabID))
        XCTAssertTrue(
            env.store.tabsToReleaseRenderers(
                liveTabIDs: [tabID],
                policy: TabRendererReleasePolicy(minimumIdle: 0, limit: nil)
            ).isEmpty
        )
    }

    // Guards against every materialisation of an already-loaded tab rewriting state.json.
    func testMarkingAnAlreadyLoadedTabAsLiveChangesNothing() {
        let (env, _) = makeEnvironment()
        let spaceID = firstSpaceID(env)
        let tabID = makeLiveTab(env, in: spaceID, url: "https://example.com/x", idleSeconds: 10)
        XCTAssertEqual(env.store.tab(tabID)?.isUnloaded, false)

        let before = env.store.tab(tabID)
        env.store.setRendererLive(tabID, true)

        XCTAssertEqual(env.store.tab(tabID), before, "a no-op must be a genuine no-op")
    }
}
