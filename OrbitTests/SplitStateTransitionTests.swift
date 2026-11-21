//  How the document's selection and tab order behave around a split: a tab opened from a pane, a tab chosen from outside, and the way back. Backed by a fresh StateStore in a scratch directory.

import XCTest

@MainActor
final class SplitStateTransitionTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-SplitState-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
        scratchDirectory = nil
        super.tearDown()
    }

    private func url(_ name: String) -> URL { URL(string: "https://\(name).example.com")! }

    /// A store whose Space holds tabs a, b, c, d in that order and nothing else, with a and b split.
    private func makeSplitStore() -> (store: BrowserStore, space: SpaceID, a: TabID, b: TabID, c: TabID, d: TabID) {
        let store = BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
        let space = store.activeSpace!.id
        for seeded in store.space(space)?.today ?? [] { store.archiveTab(seeded) }
        let a = store.openTab(url: url("a"), in: space)
        let b = store.openTab(url: url("b"), in: space)
        let c = store.openTab(url: url("c"), in: space)
        let d = store.openTab(url: url("d"), in: space)
        XCTAssertNotNil(store.createSplit(with: [a, b], axis: .horizontal))
        store.selectTab(a)
        return (store, space, a, b, c, d)
    }

    private func rows(_ store: BrowserStore, _ space: SpaceID) -> [[TabID]] {
        groupedSidebarRows(store.todayTabs(in: space), splitGroup: { store.splitGroup(for: $0) }).map { row in
            switch row {
            case .single(let tab): [tab.id]
            case .split(_, let members): members.map(\.id)
            }
        }
    }

    // A link that opens a tab from a split pane used to slot the new tab straight after that pane, which is between the panes, and the sidebar stopped drawing the split as one row.
    func test_aTabOpenedFromAFirstPane_landsAfterTheWholeSplit_andTheSplitStaysOneRow() {
        let fixture = makeSplitStore()

        let opened = fixture.store.openTab(url: url("link"), in: fixture.space, activate: true)

        XCTAssertEqual(rows(fixture.store, fixture.space), [[fixture.a, fixture.b], [opened], [fixture.c], [fixture.d]])
        XCTAssertEqual(fixture.store.activeTabBySpaceForTesting(fixture.space), opened)
    }

    func test_aTabOpenedFromALastPane_landsAfterTheWholeSplit_andTheSplitStaysOneRow() {
        let fixture = makeSplitStore()
        fixture.store.selectTab(fixture.b)

        let opened = fixture.store.openTab(url: url("link"), in: fixture.space, activate: true)

        XCTAssertEqual(rows(fixture.store, fixture.space), [[fixture.a, fixture.b], [opened], [fixture.c], [fixture.d]])
    }

    func test_chosingAnotherTabAndThenAPaneOfTheSplit_makesThatPaneTheActiveTabEachTime() {
        let fixture = makeSplitStore()

        for round in 0..<4 {
            fixture.store.selectTab(fixture.c)
            XCTAssertEqual(fixture.store.activeTabBySpaceForTesting(fixture.space), fixture.c, "round \(round): the other tab is chosen")
            XCTAssertNil(fixture.store.activeTab(in: fixture.space).flatMap { fixture.store.splitGroup(for: $0.id) }, "round \(round): no split is active with it")

            let pane = round % 2 == 0 ? fixture.a : fixture.b
            fixture.store.selectTab(pane)
            XCTAssertEqual(fixture.store.activeTabBySpaceForTesting(fixture.space), pane, "round \(round): the pane is chosen")
            XCTAssertNotNil(fixture.store.activeTab(in: fixture.space).flatMap { fixture.store.splitGroup(for: $0.id) }, "round \(round): the split is active again")
        }
    }

    func test_aTabOpenedFromAPaneThenClosed_handsTheSelectionBackToTheSplit() {
        let fixture = makeSplitStore()
        let opened = fixture.store.openTab(url: url("link"), in: fixture.space, activate: true)

        fixture.store.closeTab(opened)

        let active = fixture.store.activeTabBySpaceForTesting(fixture.space)
        XCTAssertTrue(active == fixture.a || active == fixture.b, "closing the tab opened from the split returns to the split, not to a stranger: \(String(describing: active))")
    }
}
