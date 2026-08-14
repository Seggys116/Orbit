//  A tab the content pane can restore must have a sidebar row to go with it.
//  Every store here is backed by a scratch temp directory, never the real
//  ~/Library/Application Support/Orbit/State/.

import XCTest

@MainActor
final class SidebarSurvivesRelaunchTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-Relaunch-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> BrowserStore {
        BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
    }

    /// A second BrowserStore over the same directory is what a relaunch is.
    private func relaunch() -> BrowserStore {
        makeStore()
    }

    // MARK: - The reported bug

    func test_aNavigatedTabIsRestoredIntoTheSidebarWithItsURLSectionAndSpace() throws {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://example.com")!, in: space.id)
        store.state.tabs[tabID]?.url = URL(string: "https://example.com/article")!
        store.state.tabs[tabID]?.title = "An Article"
        try store.saveNow()

        let restored = relaunch()

        let row = restored.todayTabs(in: space.id).first { $0.id == tabID }
        XCTAssertNotNil(row, "The tab was saved but is not in the restored sidebar's Today list.")
        XCTAssertEqual(row?.url, URL(string: "https://example.com/article")!)
        XCTAssertEqual(row?.section, .today)
        XCTAssertEqual(row?.spaceID, space.id)
        XCTAssertEqual(restored.activeTabBySpaceForTesting(space.id), tabID)
    }

    func test_aTabDroppedFromItsSpacesTodayListIsBackInTheSidebarAfterARelaunch() throws {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://dropped.example.com")!, in: space.id)

        // What a sync merge that censored the id out of Today leaves behind: the
        // tab and the active pointer survive, the membership row does not.
        store.state.spaces[0].today.removeAll { $0 == tabID }
        try store.saveNow()

        let restored = relaunch()

        XCTAssertTrue(
            restored.todayTabs(in: space.id).map(\.id).contains(tabID),
            "The content pane would restore this page while the sidebar had no row for it."
        )
        XCTAssertEqual(restored.tab(tabID)?.section, .today)
    }

    func test_anArchivedTabThatIsStillTheActiveTabIsGivenItsRowBackOnRelaunch() throws {
        let store = makeStore()
        let space = store.activeSpace!
        let keptID = store.openTab(url: URL(string: "https://kept.example.com")!, in: space.id)
        let strandedID = store.openTab(url: URL(string: "https://stranded.example.com")!, in: space.id)

        store.archiveTab(strandedID)
        store.state.activeTabBySpace[space.id] = strandedID
        try store.saveNow()

        let restored = relaunch()

        XCTAssertEqual(restored.activeTabBySpaceForTesting(space.id), strandedID, "precondition: the pane still restores this tab")
        XCTAssertEqual(restored.tab(strandedID)?.section, .today)
        XCTAssertTrue(
            restored.todayTabs(in: space.id).map(\.id).contains(strandedID),
            "The restored active tab renders in the pane with no sidebar row — exactly the reported symptom."
        )
        XCTAssertTrue(restored.todayTabs(in: space.id).map(\.id).contains(keptID), "The untouched tab must not be disturbed by the repair.")
    }

    func test_aDeliberatelyArchivedTabIsNotDraggedBackIntoTheSidebar() throws {
        let store = makeStore()
        let space = store.activeSpace!
        _ = store.openTab(url: URL(string: "https://kept.example.com")!, in: space.id)
        let archivedID = store.openTab(url: URL(string: "https://archived.example.com")!, in: space.id, activate: false)

        store.archiveTab(archivedID)
        try store.saveNow()

        let restored = relaunch()

        XCTAssertEqual(restored.tab(archivedID)?.section, .archived, "The repair must only rescue tabs that have nowhere to be shown, not empty the Archive.")
        XCTAssertFalse(restored.todayTabs(in: space.id).map(\.id).contains(archivedID))
    }

    func test_selectingAnArchivedTabPutsItsSidebarRowBack() {
        let store = makeStore()
        let space = store.activeSpace!
        _ = store.openTab(url: URL(string: "https://other.example.com")!, in: space.id)
        let tabID = store.openTab(url: URL(string: "https://favourite.example.com")!, in: space.id, activate: false)
        store.archiveTab(tabID)

        store.selectTab(tabID)

        XCTAssertEqual(store.tab(tabID)?.section, .today, "Selecting a tab is a request to look at it, so it has to have a row.")
        XCTAssertTrue(store.todayTabs(in: space.id).map(\.id).contains(tabID))
        XCTAssertEqual(store.activeTabBySpaceForTesting(space.id), tabID)
    }

    // MARK: - Idle time counts real use, not just re-selection

    func test_navigatingInATabKeepsItOutOfTheArchiveSweep() {
        let store = makeStore()
        let space = store.activeSpace!
        store.setArchivePolicy(.after12Hours, forProfile: space.profileID)
        let tabID = store.openTab(url: URL(string: "https://in-use.example.com")!, in: space.id, activate: false)
        store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-13 * 3600)

        store.noteTabAccessed(tabID)
        store.runArchiveSweep(now: Date())

        XCTAssertEqual(store.tab(tabID)?.section, .today, "A tab navigated moments ago is in use, however long ago it was last clicked in the sidebar.")
    }

    func test_noteTabAccessedNeverWindsLastAccessedBackwards() {
        let store = makeStore()
        let space = store.activeSpace!
        let tabID = store.openTab(url: URL(string: "https://now.example.com")!, in: space.id)
        let recorded = store.tab(tabID)!.lastAccessedAt

        store.noteTabAccessed(tabID, at: recorded.addingTimeInterval(-3600))

        XCTAssertEqual(store.tab(tabID)?.lastAccessedAt, recorded)
    }

    // MARK: - The debounced write must actually happen

    func test_aDebouncedSaveIsNotStarvedByMutationsFasterThanTheDebounce() async throws {
        let stateStore = StateStore(
            rootDirectory: scratchDirectory,
            debounceDuration: .milliseconds(200),
            maximumSaveDelay: .milliseconds(600)
        )

        let profile = Profile(name: "Starvation")
        var state = OrbitState()
        state.profiles = [profile]
        state.spaces = [Space(name: "Home", profileID: profile.id)]

        // Never quiet for a whole debounce period — the pre-fix trailing timer
        // was cancelled and rescheduled forever and nothing ever reached disk.
        for tick in 0..<20 {
            state.spaces[0].name = "Home \(tick)"
            await stateStore.scheduleSave(state)
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateStore.stateFileURL.path),
            "One second of sustained mutation and state.json was never written — the debounce is starved."
        )
    }

    func test_aPendingDebouncedSaveNeverLandsOnTopOfALaterSaveNow() async throws {
        let stateStore = StateStore(rootDirectory: scratchDirectory, debounceDuration: .milliseconds(300))

        let profile = Profile(name: "Ordering")
        var pending = OrbitState()
        pending.profiles = [profile]
        pending.spaces = [Space(name: "Stale", profileID: profile.id)]

        var atQuit = pending
        atQuit.spaces[0].name = "Written at quit"

        await stateStore.scheduleSave(pending)
        try stateStore.saveNow(atQuit)
        try await Task.sleep(for: .milliseconds(800))

        let loaded = try stateStore.load()
        XCTAssertEqual(
            loaded.spaces.first?.name, "Written at quit",
            "The debounced snapshot fired after the termination-time save and overwrote it."
        )
    }
}
