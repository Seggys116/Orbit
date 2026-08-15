import XCTest

// Regression coverage for the "loading archived tabs with a lot of archived tabs is sluggish" fix.
//
// Measured root causes, with a few thousand archived tabs:
//   - BrowserStore.archivedTabs(in:) rescanned and resorted the entire state.tabs dictionary on
//     every call, and was called at least twice per Library render (LibraryRootView's badge count,
//     then LibraryArchivedTabsView's own list) — fixed by BrowserStore.archivedTabsCache, invalidated
//     on state's didSet, the one chokepoint every mutation (archive, restore, the auto-archive sweep,
//     iCloud sync) passes through.
//   - LibraryDateGrouping.group(_:date:) called the DateFormatter-backed title(for:) once per item
//     to compute a bucket key, when items sharing a calendar day always produce the same title —
//     fixed by bucketing on startOfDay first and formatting the title once per resulting group.
//   - LibraryArchivedTabsView's `filtered`/`groups` are plain computed properties with no caching of
//     their own, so every one of the above ran again on every SwiftUI body evaluation, including ones
//     triggered by state changes unrelated to the archive. 30 simulated re-renders of a 3,000-tab
//     archive measured ~4000ms before this fix; ~515-833ms after.
@MainActor
final class LibraryArchivePerformanceTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-LibraryArchivePerf-\(UUID().uuidString)", isDirectory: true)
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

    @discardableResult
    private func populateArchive(
        _ store: BrowserStore,
        archivedCount: Int,
        spaceID: SpaceID,
        folderEveryNth: Int = 8,
        folderCount: Int = 24,
        dayDepth: Int = 120
    ) -> [TabID] {
        let crumbs: [ArchivedFolderCrumb] = (0..<max(folderCount, 1)).map {
            ArchivedFolderCrumb(id: FolderID(), name: "Folder \($0)", icon: nil, iconIsEmoji: false)
        }
        var tabs = store.state.tabs
        var ids: [TabID] = []
        ids.reserveCapacity(archivedCount)
        let now = Date()
        for index in 0..<archivedCount {
            var tab = Tab(
                spaceID: spaceID,
                section: .archived,
                url: URL(string: "https://site\(index % 500).example/page/\(index)")!,
                title: "Archived Page \(index) — a reasonably long real-world tab title so string work is realistic"
            )
            tab.archivedAt = now.addingTimeInterval(-Double(index % max(dayDepth, 1)) * 86_400 - Double(index % 3600))
            tab.lastAccessedAt = tab.archivedAt!
            if folderEveryNth > 0, index % folderEveryNth == 0 {
                tab.archivedFolderTrail = [crumbs[index % crumbs.count]]
            }
            tabs[tab.id] = tab
            ids.append(tab.id)
        }
        var newState = store.state
        newState.tabs = tabs
        store.state = newState
        return ids
    }

    private func milliseconds(_ work: () -> Void) -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    private func onePipelinePass(_ store: BrowserStore) {
        let all = store.archivedTabs()
        let groups = LibraryDateGrouping.group(all, date: { $0.archivedAt ?? $0.lastAccessedAt })
        for group in groups {
            _ = ArchivedTabTreeBuilder.build(from: group.items)
        }
    }

    // MARK: - BrowserStore.archivedTabs(in:) is cached, not rescanned on every call

    func testArchivedTabsIsCachedAcrossRepeatedCallsWithNoInterveningStateChange() {
        let store = makeStore()
        let space = store.activeSpace!
        populateArchive(store, archivedCount: 3000, spaceID: space.id)

        let firstCall = milliseconds { _ = store.archivedTabs() }
        var repeatedCalls: [Double] = []
        for _ in 0..<30 {
            repeatedCalls.append(milliseconds { _ = store.archivedTabs() })
        }
        let repeatedTotal = repeatedCalls.reduce(0, +)

        XCTAssertLessThan(
            repeatedTotal, firstCall,
            "30 repeated archivedTabs() calls with no state change between them cost \(repeatedTotal)ms " +
            "total, more than the single first call's \(firstCall)ms that had to actually scan " +
            "state.tabs — BrowserStore.archivedTabsCache is not being hit."
        )
        XCTAssertLessThan(
            repeatedTotal, 5,
            "30 cached archivedTabs() reads took \(repeatedTotal)ms total; a cache hit should cost " +
            "close to nothing, not rescan state.tabs.values again."
        )
    }

    func testArchivedTabsCacheIsInvalidatedByAnArchiveMutation() {
        let store = makeStore()
        let space = store.activeSpace!
        let ids = populateArchive(store, archivedCount: 50, spaceID: space.id)
        XCTAssertEqual(store.archivedTabs().count, 50)

        store.restoreFromArchive(ids[0], to: .today)

        XCTAssertEqual(
            store.archivedTabs().count, 49,
            "Restoring a tab out of the archive must be reflected immediately — the cache must not " +
            "outlive the state change that invalidated it."
        )
    }

    // MARK: - Opening the Archived Tabs page with a few thousand tabs

    func testOpeningTheArchiveWithThousandsOfTabsStaysWithinBudget() {
        let store = makeStore()
        let space = store.activeSpace!
        populateArchive(store, archivedCount: 3000, spaceID: space.id)

        let elapsed = milliseconds { onePipelinePass(store) }

        XCTAssertLessThan(
            elapsed, 300,
            "Opening the Archived Tabs page with 3,000 archived tabs (fetch + date-group + folder-tree " +
            "build) took \(elapsed)ms. Measured before the fix: ~124-150ms typical (up to 253ms under " +
            "load); after: ~40-65ms typical. 300ms leaves headroom for CI noise while still catching " +
            "the per-item DateFormatter allocation or the whole-dictionary rescan coming back."
        )
    }

    // MARK: - Re-rendering while the window stays open (the actual "sluggish" bug)

    func testRepeatedRenderingWhileTheWindowStaysOpenStaysCheap() {
        let store = makeStore()
        let space = store.activeSpace!
        populateArchive(store, archivedCount: 3000, spaceID: space.id)

        var passes: [Double] = []
        for _ in 0..<30 {
            passes.append(milliseconds { onePipelinePass(store) })
        }
        let total = passes.reduce(0, +)

        XCTAssertLessThan(
            total, 2000,
            "30 simulated re-renders of the Archived Tabs page (3,000 tabs, no state change between " +
            "them — what happens every time an unrelated part of the app mutates state while this " +
            "window is open) took \(total)ms total (avg \(total / 30)ms/pass). Measured before the " +
            "fix: ~4000-4370ms total (avg ~134-145ms/pass, nothing cached); after: ~515-833ms. 2000ms " +
            "leaves CI headroom while still failing if the archivedTabs() cache or the DateFormatter " +
            "fix regresses."
        )
    }

    // MARK: - Hundreds of archived tabs, not just thousands

    func testOpeningTheArchiveWithHundredsOfTabsIsFast() {
        let store = makeStore()
        let space = store.activeSpace!
        populateArchive(store, archivedCount: 600, spaceID: space.id)

        let elapsed = milliseconds { onePipelinePass(store) }

        XCTAssertLessThan(
            elapsed, 100,
            "Opening the Archived Tabs page with 600 archived tabs took \(elapsed)ms; measured around " +
            "10-17ms after the fix, ~32ms before it."
        )
    }

    // MARK: - LibraryDateGrouping.group calls the DateFormatter-backed title(for:) once per
    // distinct day, not once per item

    func testGroupingCallsTheExpensiveTitleFormatterOncePerDayNotOncePerItem() {
        let store = makeStore()
        let space = store.activeSpace!
        populateArchive(store, archivedCount: 3000, spaceID: space.id, dayDepth: 120)
        let all = store.archivedTabs()

        let groupTime = milliseconds {
            _ = LibraryDateGrouping.group(all, date: { $0.archivedAt ?? $0.lastAccessedAt })
        }

        XCTAssertLessThan(
            groupTime, 60,
            "Grouping 3,000 archived tabs into date buckets took \(groupTime)ms. Measured before the " +
            "startOfDay-bucketing fix: ~133ms (one DateFormatter-backed title(for:) call per item); " +
            "after: ~14-21ms (one call per distinct day — ~120 of them in this corpus)."
        )
    }
}
