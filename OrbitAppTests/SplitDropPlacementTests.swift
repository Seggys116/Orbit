//  A tab dropped on a pane of a split lands beside that pane, on the edge that was highlighted: not at the start or end of the whole split.

import XCTest
@testable import Orbit

@MainActor
final class SplitDropPlacementTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var spaceID: SpaceID!

    override func setUp() {
        super.setUp()
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(name: "Split Placement Scratch", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        env.selectSpace(spaceID)
    }

    override func tearDown() {
        if let spaceID { env.deleteSpace(spaceID) }
        spaceID = nil
        super.tearDown()
    }

    private func tab(_ name: String) -> TabID {
        env.openTab(url: URL(string: "https://\(name).example.com")!, in: spaceID, section: .today, activate: false)
    }

    /// A split of `a` and `b`, in that order, and a third tab `c` waiting to be dropped.
    private func splitOfTwo() -> (a: TabID, b: TabID, c: TabID) {
        let (a, b, c) = (tab("a"), tab("b"), tab("c"))
        env.createSplit(existingTabID: a, newTabID: b, edge: .right)
        XCTAssertEqual(env.splitGroup(for: a)?.tabIDs, [a, b], "the starting split is a then b")
        return (a, b, c)
    }

    func test_droppedOnTheRightEdgeOfTheFirstPane_landsBetweenThePanes() {
        let (a, b, c) = splitOfTwo()
        env.createSplit(existingTabID: a, newTabID: c, edge: .right)
        XCTAssertEqual(env.splitGroup(for: a)?.tabIDs, [a, c, b])
    }

    func test_droppedOnTheLeftEdgeOfTheLastPane_landsBetweenThePanes() {
        let (a, b, c) = splitOfTwo()
        env.createSplit(existingTabID: b, newTabID: c, edge: .left)
        XCTAssertEqual(env.splitGroup(for: a)?.tabIDs, [a, c, b])
    }

    func test_droppedOnTheLeftEdgeOfTheFirstPane_landsFirst() {
        let (a, b, c) = splitOfTwo()
        env.createSplit(existingTabID: a, newTabID: c, edge: .left)
        XCTAssertEqual(env.splitGroup(for: a)?.tabIDs, [c, a, b])
    }

    func test_droppedOnTheRightEdgeOfTheLastPane_landsLast() {
        let (a, b, c) = splitOfTwo()
        env.createSplit(existingTabID: b, newTabID: c, edge: .right)
        XCTAssertEqual(env.splitGroup(for: a)?.tabIDs, [a, b, c])
    }

    func test_aNewSplitFromTwoTabs_putsTheDroppedTabOnTheEdgeItWasDroppedOn() {
        let (a, b) = (tab("a"), tab("b"))
        env.createSplit(existingTabID: a, newTabID: b, edge: .left)
        XCTAssertEqual(env.splitGroup(for: a)?.tabIDs, [b, a])
    }

    func test_withNoPaneNamed_aBlankPaneGoesAtThatEndOfTheSplit() throws {
        let (a, b, c) = splitOfTwo()
        let group = try XCTUnwrap(env.splitGroup(for: a))
        env.addToSplit(tabID: c, groupID: group.id, edge: .left)
        XCTAssertEqual(env.splitGroup(for: a)?.tabIDs, [c, a, b])
    }
}
