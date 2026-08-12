import XCTest
import AppKit

final class SidebarTearOffDecisionTests: XCTestCase {

    // MARK: - Fixtures

    private func payload(kind: SidebarDragPayload.Kind = .pinnedNode, spaceID: SpaceID = UUID()) -> SidebarDragPayload {
        SidebarDragPayload(nodeID: UUID(), kind: kind, spaceID: spaceID)
    }

    private let mainWindowFrame = NSRect(x: 100, y: 100, width: 800, height: 600)

    private let secondWindowFrame = NSRect(x: 1000, y: 100, width: 640, height: 480)

    private let pointOutsideEveryWindow = NSPoint(x: 50, y: 900)

    // MARK: - Consumption always wins

    func test_falseWhenTheDropWasConsumedByAnInAppTarget() {
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(),
            releasedAt: pointOutsideEveryWindow,
            windowFrames: [mainWindowFrame],
            wasConsumed: true
        )
        XCTAssertFalse(
            result,
            "a drag an in-app drop target already consumed must never also tear off, even when released well outside every window"
        )
    }

    func test_consumedOverridesEveryOtherSignal() {
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(kind: .todayTab),
            releasedAt: NSPoint(x: -500, y: -500),
            windowFrames: [],
            wasConsumed: true
        )
        XCTAssertFalse(result)
    }

    // MARK: - Inside any window frame means "not a tear-off"

    func test_falseWhenReleasePointIsInsideTheOnlyWindow() {
        let insidePoint = NSPoint(x: mainWindowFrame.midX, y: mainWindowFrame.midY)
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(),
            releasedAt: insidePoint,
            windowFrames: [mainWindowFrame],
            wasConsumed: false
        )
        XCTAssertFalse(result)
    }

    func test_falseWhenReleasePointIsExactlyOnAWindowsEdge() {
        let edgePoint = NSPoint(x: mainWindowFrame.minX, y: mainWindowFrame.minY)
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(),
            releasedAt: edgePoint,
            windowFrames: [mainWindowFrame],
            wasConsumed: false
        )
        XCTAssertFalse(result, "a release point exactly on a window's own edge must count as inside that window")
    }

    func test_falseWhenReleasePointIsInsideANonFrontmostSecondWindow() {
        let insideSecondWindow = NSPoint(x: secondWindowFrame.midX, y: secondWindowFrame.midY)
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(),
            releasedAt: insideSecondWindow,
            windowFrames: [mainWindowFrame, secondWindowFrame],
            wasConsumed: false
        )
        XCTAssertFalse(result, "a point inside the second window in the array was treated as outside every window")
    }

    // MARK: - The genuine tear-off: outside every frame, nothing consumed it

    func test_trueOnlyWhenPointIsOutsideEveryFrameAndNothingConsumedIt() {
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(),
            releasedAt: pointOutsideEveryWindow,
            windowFrames: [mainWindowFrame, secondWindowFrame],
            wasConsumed: false
        )
        XCTAssertTrue(result)
    }

    func test_todayTabKind_tearsOffLikePinnedNode() {
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(kind: .todayTab),
            releasedAt: pointOutsideEveryWindow,
            windowFrames: [mainWindowFrame],
            wasConsumed: false
        )
        XCTAssertTrue(result, ".todayTab is a real tab in the tearing-off sense, exactly like .pinnedNode")
    }

    // MARK: - A favourite tile is not a tab

    func test_falseForAFavoritePayloadKind_evenReleasedWellOutsideEveryWindow() {
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(kind: .favorite),
            releasedAt: pointOutsideEveryWindow,
            windowFrames: [mainWindowFrame],
            wasConsumed: false
        )
        XCTAssertFalse(result, "a favourite tile is not a browser tab and must never tear off into its own window")
    }

    func test_falseForAFavoritePayloadKind_withNoWindowsOpenAtAll() {
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(kind: .favorite),
            releasedAt: pointOutsideEveryWindow,
            windowFrames: [],
            wasConsumed: false
        )
        XCTAssertFalse(result, "the favourite-kind exclusion must hold even with an empty windowFrames array, not rely on a frame existing to fail on")
    }

    // MARK: - No windows open at all

    func test_emptyWindowFrames_stillTearsOffAnEligiblePayloadThatWasNotConsumed() {
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(kind: .pinnedNode),
            releasedAt: NSPoint(x: 0, y: 0),
            windowFrames: [],
            wasConsumed: false
        )
        XCTAssertTrue(result, "with no window frames at all, an unconsumed, eligible-kind drag has nothing to be 'inside' and must tear off")
    }

    func test_emptyWindowFrames_stillRefusesAConsumedDrag() {
        let result = SidebarTearOffDetector.shouldTearOff(
            payload: payload(kind: .pinnedNode),
            releasedAt: NSPoint(x: 0, y: 0),
            windowFrames: [],
            wasConsumed: true
        )
        XCTAssertFalse(result)
    }
}
