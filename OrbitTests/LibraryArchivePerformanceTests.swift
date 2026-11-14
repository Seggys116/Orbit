import XCTest

// Library views call archivedTabs() on every SwiftUI body evaluation, so a large archive stays responsive only if BrowserStore.archivedTabsCache serves repeat calls and is invalidated by state changes.
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
}
