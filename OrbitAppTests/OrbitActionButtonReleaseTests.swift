import AppKit
import XCTest
@testable import Orbit

/// A row that can be dragged must not act when it is pressed, or the drag's own press switches the tab being dragged.
@MainActor
final class OrbitActionButtonReleaseTests: XCTestCase {

    private func event(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    private func view(firesOnRelease: Bool) -> (OrbitActionButtonClickCatchingView, counts: () -> [Int]) {
        var fired: [Int] = []
        let view = OrbitActionButtonClickCatchingView()
        view.clickCountAction = { fired.append($0) }
        view.firesOnRelease = firesOnRelease
        return (view, { fired })
    }

    func test_aPressAloneDoesNothingWhenFiringOnRelease() {
        let (view, fired) = view(firesOnRelease: true)

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 10, y: 10)))

        XCTAssertEqual(fired(), [], "The press that may become a drag must not activate the row.")
    }

    func test_aPressAndReleaseInPlaceFiresOnceOnRelease() {
        let (view, fired) = view(firesOnRelease: true)

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 11, y: 10)))

        XCTAssertEqual(fired(), [1])
    }

    func test_theClickCountOfTheReleaseIsReported() {
        let (view, fired) = view(firesOnRelease: true)

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 10, y: 10), clickCount: 2))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 10, y: 10), clickCount: 2))

        XCTAssertEqual(fired(), [2], "Double-click rename still needs to see the second click.")
    }

    func test_aReleaseAfterRealMovementIsNotAClick() {
        let (view, fired) = view(firesOnRelease: true)

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 10 + OrbitActionButtonClickCatchingView.clickSlop + 1, y: 10)))

        XCTAssertEqual(fired(), [])
    }

    func test_aReleaseWithoutAPressDoesNothing() {
        let (view, fired) = view(firesOnRelease: true)

        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 10, y: 10)))

        XCTAssertEqual(fired(), [])
    }

    func test_otherButtonsStillFireOnPress() {
        let (view, fired) = view(firesOnRelease: false)

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 10, y: 10)))

        XCTAssertEqual(fired(), [1], "Controls that cannot start a drag keep firing the moment they are pressed.")
    }
}
