//  A page keeps the slot, and so the host, it was in when panes arrive in front of it, between it and another, or leave ahead of it.
//  Panes were keyed by position, so each of those moved every later page into a different host, which showed blank until WebKit painted it again.

import XCTest
@testable import Orbit

final class SplitPaneSlotsTests: XCTestCase {

    private let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())

    func test_theFirstLayoutGetsTheSlotsInOrder() {
        XCTAssertEqual(SplitPaneSlots().keys(for: [a, b, c]), [0, 1, 2])
    }

    func test_aPaneArrivingBeforeAPage_leavesThatPageInItsSlot() {
        let slots = SplitPaneSlots()
        let before = slots.keys(for: [a])
        let after = slots.keys(for: [b, a])
        XCTAssertEqual(after[1], before[0], "the page that was there keeps its slot")
        XCTAssertNotEqual(after[0], before[0], "the arriving pane gets a slot of its own")
    }

    func test_aPaneArrivingBetweenTwo_leavesBothInTheirSlots() {
        let slots = SplitPaneSlots()
        let before = slots.keys(for: [a, b])
        let after = slots.keys(for: [a, c, b])
        XCTAssertEqual(after[0], before[0])
        XCTAssertEqual(after[2], before[1], "the page after the arrival is not moved into another host")
        XCTAssertFalse(before.contains(after[1]))
    }

    func test_aPaneLeavingAheadOfOthers_leavesThemInTheirSlots() {
        let slots = SplitPaneSlots()
        let before = slots.keys(for: [a, b, c])
        let after = slots.keys(for: [b, c])
        XCTAssertEqual(after, [before[1], before[2]])
    }

    func test_aLonePaneShowingAnotherTab_keepsTheSameSlot() {
        let slots = SplitPaneSlots()
        let before = slots.keys(for: [a])
        XCTAssertEqual(slots.keys(for: [b]), before, "switching tabs swaps the page inside the same host")
        XCTAssertEqual(slots.keys(for: [c]), before)
    }

    func test_aSlotIsNotReusedForALaterArrival() {
        let slots = SplitPaneSlots()
        _ = slots.keys(for: [a, b])
        let afterLeave = slots.keys(for: [b])
        let afterArrive = slots.keys(for: [b, c])
        XCTAssertEqual(afterArrive[0], afterLeave[0])
        XCTAssertFalse(afterLeave.contains(afterArrive[1]), "the arriving pane is not given the slot of the pane that stayed")
    }

    func test_askingAgainForTheSameLayout_changesNothing() {
        let slots = SplitPaneSlots()
        let first = slots.keys(for: [a, b, c])
        XCTAssertEqual(slots.keys(for: [a, b, c]), first)
    }

    func test_reorderingPanes_movesTheSlotsWithThePages() {
        let slots = SplitPaneSlots()
        let before = slots.keys(for: [a, b])
        let after = slots.keys(for: [b, a])
        XCTAssertEqual(after, [before[1], before[0]])
    }
}

final class SplitPaneMotionTests: XCTestCase {

    private let (a, b, c) = (UUID(), UUID(), UUID())
    private let divider: CGFloat = 0

    private func motion(arriving: TabID, progress: CGFloat, edge: SplitEdge = .right) -> SplitMotion {
        SplitMotion(arrivingTabID: arriving, edge: edge, progress: progress)
    }

    /// Three panes of 300 in a span of 900 (no divider), the second of which has just arrived.
    private func middle(_ progress: CGFloat, _ index: Int, reduceMotion: Bool = false) -> SplitViewContainer.PaneMotion {
        SplitViewContainer.paneMotion(motion: motion(arriving: c, progress: progress), index: index, tabIDs: [a, c, b], lengths: [300, 300, 300], divider: divider, reduceMotion: reduceMotion)
    }

    func test_nothingMovesWhenNoPaneIsArriving() {
        let none = SplitViewContainer.paneMotion(motion: nil, index: 0, tabIDs: [a, b], lengths: [450, 450], divider: 0, reduceMotion: false)
        XCTAssertFalse(none.isMoving)
        XCTAssertEqual(none.opacity, 1)
    }

    func test_whenTheArrivalHasLanded_everyPaneIsWhereItBelongs() {
        for index in 0..<3 {
            let landed = middle(1, index)
            XCTAssertEqual(landed.shift, 0, accuracy: 0.001)
            XCTAssertEqual(landed.extraLength, 0, accuracy: 0.001)
            XCTAssertEqual(landed.opacity, 1)
        }
    }

    func test_atTheStart_theArrivingPaneIsInvisible_andThePanesAreDrawnWhereTheyWere() {
        XCTAssertEqual(middle(0, 1).opacity, 0)
        // before the arrival the two panes were 450 each: the first started at 0, the second (now third) at 450
        let first = middle(0, 0)
        XCTAssertEqual(first.shift, 0, accuracy: 0.001)
        let last = middle(0, 2)
        XCTAssertEqual(last.shift, 450 - 600, accuracy: 0.001, "the last pane was drawn at 450 and now sits at 600")
        XCTAssertEqual(first.extraLength, 0, accuracy: 0.001, "with three panes none is resized per frame, they are only slid aside")
        XCTAssertEqual(last.extraLength, 0, accuracy: 0.001)
    }

    func test_aPaneArrivingBeforeAPage_pushesThatPageFromWhereItWas() {
        // a lone page of 900 gets a pane before it: [new, a], each 450
        let page = SplitViewContainer.paneMotion(motion: motion(arriving: b, progress: 0, edge: .left), index: 1, tabIDs: [b, a], lengths: [450, 450], divider: 0, reduceMotion: false)
        XCTAssertEqual(page.shift, -450, accuracy: 0.001, "it was drawn from the left edge and now sits at 450")
        XCTAssertEqual(page.extraLength, 450, accuracy: 0.001, "it was 900 wide and now has 450")
    }

    func test_halfwayThroughTheArrival_thePanesAreHalfwayThere() {
        let half = middle(0.5, 2)
        XCTAssertEqual(half.shift, -75, accuracy: 0.001)
        XCTAssertEqual(half.extraLength, 0, accuracy: 0.001)
    }

    func test_withReducedMotion_thePanesStayAndOnlyTheArrivalFades() {
        XCTAssertFalse(middle(0, 0, reduceMotion: true).isMoving)
        XCTAssertFalse(middle(0, 2, reduceMotion: true).isMoving)
        XCTAssertEqual(middle(0, 1, reduceMotion: true).opacity, 0)
    }

    func test_aSecondPane_squeezesTheOnePageThatWasThere() {
        // a lone page of 900 gets a pane after it: [a, new], each 450
        let page = SplitViewContainer.paneMotion(motion: motion(arriving: b, progress: 0), index: 0, tabIDs: [a, b], lengths: [450, 450], divider: 0, reduceMotion: false)
        XCTAssertEqual(page.shift, 0, accuracy: 0.001)
        XCTAssertEqual(page.extraLength, 450, accuracy: 0.001, "it was 900 wide and has 450")
    }

    func test_dividersAreAccountedFor() {
        // two panes of 445 and a 10 divider make a span of 900; a third arrives between: 3 panes of 293.3 and two dividers
        let lengths: [CGFloat] = [880.0 / 3, 880.0 / 3, 880.0 / 3]
        let page = SplitViewContainer.paneMotion(motion: motion(arriving: c, progress: 0), index: 2, tabIDs: [a, c, b], lengths: lengths, divider: 10, reduceMotion: false)
        XCTAssertEqual(page.shift, 455 - (2 * (880.0 / 3 + 10)), accuracy: 0.01)
    }
}
