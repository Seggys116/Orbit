import XCTest
import AppKit

// MARK: - 1. SidebarHoverPhase: pure state-machine transitions

@MainActor
final class SidebarHoverPhaseTests: XCTestCase {

    // MARK: hoverChanged(_:)

    func test_hoverChanged_true_fromHidden_entersPeeking() {
        XCTAssertEqual(SidebarHoverPhase.hidden.hoverChanged(true), .peeking)
    }

    func test_hoverChanged_true_fromPeekingRevealedOrHiding_settlesToRevealed() {
        XCTAssertEqual(SidebarHoverPhase.peeking.hoverChanged(true), .revealed)
        XCTAssertEqual(SidebarHoverPhase.revealed.hoverChanged(true), .revealed)
        XCTAssertEqual(SidebarHoverPhase.hiding.hoverChanged(true), .revealed, "A fresh hover-in while `.hiding` must cancel the pending auto-hide and settle back to `.revealed`.")
    }

    func test_hoverChanged_false_fromHidden_staysHidden() {
        XCTAssertEqual(SidebarHoverPhase.hidden.hoverChanged(false), .hidden)
    }

    func test_hoverChanged_false_fromPeekingOrRevealed_movesToHiding() {
        XCTAssertEqual(SidebarHoverPhase.peeking.hoverChanged(false), .hiding)
        XCTAssertEqual(SidebarHoverPhase.revealed.hoverChanged(false), .hiding)
    }

    func test_hoverChanged_false_fromHiding_staysHiding() {
        XCTAssertEqual(SidebarHoverPhase.hiding.hoverChanged(false), .hiding, "A second hover-out while already `.hiding` must not restart or otherwise disturb the pending auto-hide.")
    }

    // MARK: revealAnimationCompleted()

    func test_revealAnimationCompleted_fromPeeking_movesToRevealed() {
        XCTAssertEqual(SidebarHoverPhase.peeking.revealAnimationCompleted(), .revealed)
    }

    func test_revealAnimationCompleted_fromAnyOtherPhase_isANoOp() {
        for phase: SidebarHoverPhase in [.hidden, .revealed, .hiding] {
            XCTAssertEqual(phase.revealAnimationCompleted(), phase, "revealAnimationCompleted() must be a no-op from \(phase).")
        }
    }

    // MARK: hideDelayElapsed()

    func test_hideDelayElapsed_fromHiding_movesToHidden() {
        XCTAssertEqual(SidebarHoverPhase.hiding.hideDelayElapsed(), .hidden)
    }

    func test_hideDelayElapsed_fromAnyOtherPhase_isANoOp() {
        for phase: SidebarHoverPhase in [.hidden, .peeking, .revealed] {
            XCTAssertEqual(phase.hideDelayElapsed(), phase, "hideDelayElapsed() must be a no-op from \(phase).")
        }
    }

    // MARK: isPanelPresented

    func test_isPanelPresented_falseOnlyWhenHidden() {
        XCTAssertFalse(SidebarHoverPhase.hidden.isPanelPresented)
        XCTAssertTrue(SidebarHoverPhase.peeking.isPanelPresented)
        XCTAssertTrue(SidebarHoverPhase.revealed.isPanelPresented)
        XCTAssertTrue(SidebarHoverPhase.hiding.isPanelPresented)
    }

    // MARK: - The state machine reaches .hidden from every state

    func test_reachesHidden_fromEveryState_viaHoverOutThenDelayElapsed() {
        for start: SidebarHoverPhase in [.hidden, .peeking, .revealed, .hiding] {
            let afterHoverOut = start.hoverChanged(false)
            let afterDelay = afterHoverOut.hideDelayElapsed()
            XCTAssertEqual(afterDelay, .hidden, "Starting from \(start), hoverChanged(false) then hideDelayElapsed() must reach .hidden — got \(afterDelay).")
        }
    }

    func test_hiddenToRevealed_viaHoverInThenAnimationCompleted() {
        let afterHoverIn = SidebarHoverPhase.hidden.hoverChanged(true)
        let afterAnimation = afterHoverIn.revealAnimationCompleted()
        XCTAssertEqual(afterAnimation, .revealed)
    }
}

// MARK: - 2. HoverTrackingView: real containment logic

@MainActor
final class HoverTrackingViewTests: XCTestCase {

    private func makeView(width: CGFloat = 260, height: CGFloat = 600) -> HoverTrackingView {
        HoverTrackingView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    func test_updateHover_pointInsideHotZone_reportsTrueExactlyOnce() {
        let view = makeView()
        view.hotZoneWidth = 8

        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.updateHover(atLocationInView: NSPoint(x: 3, y: 300))
        XCTAssertTrue(view.isInsideHotZone)
        XCTAssertEqual(reported, [true], "A point inside the hot zone must report exactly one hover-in edge.")

        view.updateHover(atLocationInView: NSPoint(x: 5, y: 305))
        XCTAssertEqual(reported, [true], "A second point still inside the hot zone must not report a duplicate edge.")
    }

    func test_updateHover_pointOutsideHotZone_neverReports() {
        let view = makeView()
        view.hotZoneWidth = 8
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.updateHover(atLocationInView: NSPoint(x: 150, y: 300))
        XCTAssertFalse(view.isInsideHotZone)
        XCTAssertTrue(reported.isEmpty, "A point outside the hot zone from a resting `false` state must not report anything.")
    }

    func test_updateHover_crossingOutOfHotZone_reportsFalse() {
        let view = makeView()
        view.hotZoneWidth = 8
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.updateHover(atLocationInView: NSPoint(x: 3, y: 300))
        view.updateHover(atLocationInView: NSPoint(x: 150, y: 300))

        XCTAssertEqual(reported, [true, false])
        XCTAssertFalse(view.isInsideHotZone)
    }

    // MARK: - The actual R21 regression: reevaluating on hotZoneWidth change

    func test_hotZoneWidthGrowing_underAStationaryPointer_reevaluatesImmediately() {
        let view = makeView()
        view.hotZoneWidth = 8
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.updateHover(atLocationInView: NSPoint(x: 150, y: 300))
        XCTAssertTrue(reported.isEmpty)

        view.hotZoneWidth = 260

        XCTAssertEqual(reported, [true], "Growing hotZoneWidth past a stationary pointer's last known position must report a hover-in immediately, without waiting for another real pointer move.")
        XCTAssertTrue(view.isInsideHotZone)
    }

    func test_hotZoneWidthShrinking_underAStationaryPointer_reevaluatesImmediately() {
        let view = makeView()
        view.hotZoneWidth = 260
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.updateHover(atLocationInView: NSPoint(x: 150, y: 300))
        XCTAssertEqual(reported, [true])

        view.hotZoneWidth = 8

        XCTAssertEqual(reported, [true, false], "Shrinking hotZoneWidth away from a stationary pointer's last known position must report a hover-out immediately.")
        XCTAssertFalse(view.isInsideHotZone)
    }

    func test_hotZoneWidthChange_beforeAnyPointerEvent_isHarmless() {
        let view = makeView()
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.hotZoneWidth = 8
        view.hotZoneWidth = 260

        XCTAssertTrue(reported.isEmpty)
        XCTAssertFalse(view.isInsideHotZone)
    }

    // MARK: - Never a hit-test target

    func test_hitTest_neverClaimsAnyPoint() {
        let view = makeView()
        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 130, y: 300), NSPoint(x: 259, y: 599)] {
            XCTAssertNil(view.hitTest(point), "HoverTrackingView.hitTest(\(point)) must return nil — a non-nil result means this invisible tracking view is swallowing a click meant for the SwiftUI content on top of it.")
        }
    }
}

// MARK: - 3. SidebarDismissIntent: pure pointer-intent rule

final class SidebarDismissIntentTests: XCTestCase {

    private typealias Sample = SidebarDismissIntent.Sample
    private let zone: CGFloat = 260

    func test_pointerInsideTheZoneNeverDismisses() {
        XCTAssertFalse(SidebarDismissIntent.shouldDismiss(previous: Sample(x: 100, time: 0), current: Sample(x: 250, time: 0.01), hotZoneWidth: zone))
    }

    func test_pointerJustOutsideAndSlowKeepsTheGraceDelay() {
        XCTAssertFalse(SidebarDismissIntent.shouldDismiss(previous: Sample(x: 270, time: 0), current: Sample(x: 280, time: 0.016), hotZoneWidth: zone))
    }

    func test_pointerFarFromTheZoneDismissesWithoutAnyVelocity() {
        XCTAssertTrue(SidebarDismissIntent.shouldDismiss(previous: nil, current: Sample(x: zone + SidebarDismissIntent.farDistance, time: 1), hotZoneWidth: zone))
    }

    func test_fastMovementAwayDismisses() {
        XCTAssertTrue(SidebarDismissIntent.shouldDismiss(previous: Sample(x: 262, time: 0), current: Sample(x: 300, time: 0.016), hotZoneWidth: zone))
    }

    func test_fastMovementTowardTheSidebarDoesNotDismiss() {
        XCTAssertFalse(SidebarDismissIntent.shouldDismiss(previous: Sample(x: 340, time: 0), current: Sample(x: 290, time: 0.016), hotZoneWidth: zone))
    }

    func test_fastMovementThatHasBarelyLeftTheZoneDoesNotDismiss() {
        XCTAssertFalse(SidebarDismissIntent.shouldDismiss(previous: Sample(x: 255, time: 0), current: Sample(x: 266, time: 0.004), hotZoneWidth: zone))
    }

    func test_aStaleSampleCannotProduceAVelocity() {
        XCTAssertFalse(SidebarDismissIntent.shouldDismiss(previous: Sample(x: 262, time: 0), current: Sample(x: 300, time: 2), hotZoneWidth: zone))
    }
}
