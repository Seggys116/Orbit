import AppKit
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
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testAClickInAWindowThatIsNotABrowserWindowPassesThrough

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

// The side buttons are other buttons numbered 3 and 4, and NSEvent's public factories cannot set a button number: an event they
// build for an other button is always the middle button. A real press of button 3 or 4 therefore cannot be delivered from inside
// the process without a CGEvent, so what these tests pin down is the part that can be: with the monitor installed, a middle
// click delivered to a registered browser window still reaches the page and never navigates.
@MainActor
final class MouseNavigationButtonRealEventTests: XCTestCase {

    private final class RecordingView: NSView {
        var otherDowns = 0
        var otherUps = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func otherMouseDown(with event: NSEvent) { otherDowns += 1 }
        override func otherMouseUp(with event: NSEvent) { otherUps += 1 }
    }

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?
    private var tabID: TabID?
    private var windowEnvironment: AppEnvironment?

    override func tearDown() {
        GlobalKeyEventMonitor.shared.stop()
        if let tabID { windowEnvironment?._test_detachWebContents(for: tabID) }
        window?.orderOut(nil)
        window?.close()
        window = nil
        tabID = nil
        windowEnvironment = nil
        super.tearDown()
    }

    private func registerBrowserWindow() throws -> (view: RecordingView, window: NSWindow, contents: MockWebContents) {
        PeekState.shared.dismiss()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = view
        let controller = OrbitWindowController(window: window)
        controller.adopt(WindowSession.standard(on: env))
        window.delegate = controller
        OrbitWindowController._test_register(controller)
        window.orderFront(nil)
        self.window = window

        let registered = try XCTUnwrap(OrbitWindowController.environment(forWindow: window), "Precondition: the window is registered with OrbitWindowController.")
        let spaceID = registered.state.spaces.first?.id
            ?? registered.createSpace(name: "Mouse Nav Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: registered.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://example.com/")!, title: "")
        registered.state.tabs[tab.id] = tab
        registered.activeTabID = tab.id
        let contents = MockWebContents()
        registered._test_attachWebContents(contents, for: tab.id)
        tabID = tab.id
        windowEnvironment = registered
        return (view, window, contents)
    }

    private func middleButton(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .otherMouseDown ? 1 : 0
        ))
    }

    func test_aMiddleClickInABrowserWindow_reachesThePageAndNeverNavigates_withTheMonitorInstalled() throws {
        let (view, window, contents) = try registerBrowserWindow()
        GlobalKeyEventMonitor.shared.stop()
        GlobalKeyEventMonitor.shared.start()

        NSApp.sendEvent(try middleButton(.otherMouseDown, in: window))
        NSApp.sendEvent(try middleButton(.otherMouseUp, in: window))

        XCTAssertEqual(view.otherDowns, 1, "The middle button press never reached the page: the monitor swallowed a button that is not back or forward.")
        XCTAssertEqual(view.otherUps, 1, "The middle button release never reached the page.")
        XCTAssertEqual(contents.goBackCallCount, 0, "The middle button must not go back.")
        XCTAssertEqual(contents.goForwardCallCount, 0, "The middle button must not go forward.")
    }
}
