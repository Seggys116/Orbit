import AppKit
import XCTest
@testable import Orbit

@MainActor
final class SidebarNewTabRowTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func mouseDownEvent(at point: NSPoint = NSPoint(x: 5, y: 5)) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // MARK: - The action really does something

    func test_newTabRowAction_opensTheCommandBarInNewTabMode() {
        XCTAssertFalse(env.isCommandBarPresented, "Precondition: the Command Bar starts closed.")

        SidebarNewTabRowAction.perform(in: env)

        XCTAssertTrue(
            env.isCommandBarPresented,
            "The sidebar's '+ New Tab' row must present the Command Bar — this is the state BrowserWindowView reads to show it."
        )
        XCTAssertEqual(
            env.commandBarMode, CommandBarMode.newTab,
            "The Command Bar must open in new-tab mode, not editing the current URL."
        )
    }

    // MARK: - A real click really reaches the action

    func test_mouseDown_onTheRowsClickCatcher_opensTheCommandBar() {
        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 200, height: OrbitMetrics.sidebarRowHeight))
        view.action = { [env] in SidebarNewTabRowAction.perform(in: env) }

        XCTAssertFalse(env.isCommandBarPresented, "Precondition: the Command Bar starts closed.")

        view.mouseDown(with: mouseDownEvent())

        XCTAssertTrue(
            env.isCommandBarPresented,
            "A click on the '+ New Tab' row must open the Command Bar. If this fails the control is dead, which is the user's exact report."
        )
        XCTAssertEqual(env.commandBarMode, CommandBarMode.newTab)
    }

    func test_clickCatcher_isTheHitTestTargetForItsOwnBoundsAndNothingOutsideThem() {
        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))

        XCTAssertTrue(
            view.hitTest(NSPoint(x: 100, y: 18)) === view,
            "The row's click catcher must be the hit-test target inside its own bounds — otherwise whatever SwiftUI stacks above it can swallow the click, which is how this control died in the first place."
        )
        XCTAssertNil(
            view.hitTest(NSPoint(x: 400, y: 18)),
            "It must claim nothing outside its own bounds — the inverse bug (an NSView swallowing every click in a region it does not own) has shipped here before."
        )
    }

    func test_clickCatcher_isNeverAWindowDragHandle() {
        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "An OrbitActionButtonClickCatchingView must never report itself as a window-drag handle — doing so is precisely what let AppKit consume its mouseDown to move/zoom the window instead of delivering it to mouseDown(with:), which is the user's exact 'whole bar drags, buttons are dead' report."
        )
    }

    func test_clickCatcher_acceptsFirstMouse() {
        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        XCTAssertTrue(
            view.acceptsFirstMouse(for: mouseDownEvent()),
            "Opening a new tab in a background Orbit window must not cost a wasted first click."
        )
    }

    func test_clickCatcher_withNoActionYet_doesNotCrash() {
        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        view.mouseDown(with: mouseDownEvent())
    }

    // MARK: - The shipping row really is built from that mechanism

    func test_theRowIsBuiltFromTheAppKitClickCatcher_notAPlainSwiftUIButton() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Orbit/UI/Sidebar/TodaySectionView.swift"),
            encoding: .utf8
        )

        let marker = "private var newTabRow: some View {"
        let start = try XCTUnwrap(
            source.range(of: marker),
            "Could not find `newTabRow` in TodaySectionView.swift — this guard's own source walk is broken, or the property was renamed."
        )
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(
            rest.range(of: "\n    }\n"),
            "Could not find the end of `newTabRow` — this guard's own source walk is broken."
        )
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(
            body.contains("OrbitNSActionButton"),
            "TodaySectionView.newTabRow must be built with OrbitNSActionButton (a real NSView.mouseDown). See Orbit/UI/Sidebar/OrbitNSActionButton.swift's header for why a plain SwiftUI Button is not trusted to deliver this click in Orbit's hosting configuration."
        )
        XCTAssertTrue(
            body.contains("SidebarNewTabRowAction.perform"),
            "TodaySectionView.newTabRow must run SidebarNewTabRowAction.perform — the exact action the tests above assert against. An inlined closure here would make those tests prove nothing about the shipping row."
        )
    }
}
