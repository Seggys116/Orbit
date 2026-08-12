//  Regression cover: hover used to set selection and selection-change used to
//  recentre the scroll, so each fed the other in a loop.

import XCTest
import SwiftUI
@testable import Orbit

final class CommandBarPointerHoverTests: XCTestCase {

    func test_contentMovingUnderAStationaryPointerIsNotAMovement() {
        let resting = CGPoint(x: 420, y: 300)
        XCTAssertFalse(
            CommandBarView.pointerDidMove(from: resting, to: resting),
            "A hover reported at the same screen point the pointer was already at is the list moving, not the pointer — it must not change the selection."
        )
    }

    func test_aRealPointerMovementIsAMovement() {
        XCTAssertTrue(CommandBarView.pointerDidMove(from: CGPoint(x: 420, y: 300), to: CGPoint(x: 420, y: 344)))
        XCTAssertTrue(
            CommandBarView.pointerDidMove(from: CGPoint(x: 420, y: 300), to: CGPoint(x: 421, y: 300)),
            "A single point of travel is still travel — this must not need a threshold to feel responsive."
        )
    }

    func test_theFirstHoverEverSeenOnlyArmsTheTracker() {
        XCTAssertFalse(
            CommandBarView.pointerDidMove(from: nil, to: CGPoint(x: 420, y: 300)),
            "With no previously observed location there is nothing to have moved from; the first sighting must only record the position."
        )
    }
}
