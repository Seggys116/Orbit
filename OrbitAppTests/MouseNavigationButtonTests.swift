import XCTest
@testable import Orbit

final class MouseNavigationButtonTests: XCTestCase {

    func testSideButtonsMapToBackAndForward() {
        XCTAssertEqual(MouseNavigationButton.direction(forButtonNumber: 3), .back)
        XCTAssertEqual(MouseNavigationButton.direction(forButtonNumber: 4), .forward)
    }

    func testMiddleAndOtherButtonsDoNotNavigate() {
        for buttonNumber in [0, 1, 2, 5, 6, 7] {
            XCTAssertNil(MouseNavigationButton.direction(forButtonNumber: buttonNumber), "button \(buttonNumber)")
        }
    }

    @MainActor
    func testAClickInAWindowThatIsNotABrowserWindowPassesThrough() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .otherMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        XCTAssertNotNil(MouseNavigationButton.handle(event), "A window Orbit does not navigate in must still receive the click.")
    }
}
