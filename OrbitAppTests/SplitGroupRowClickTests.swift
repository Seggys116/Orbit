//  A split pair's panes in the sidebar must take a click like any ordinary tab row: the click has to reach the pane's catcher through the window's click recovery, and releasing it has to select that pane's tab.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
@MainActor
final class SplitGroupRowClickTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var spaceID: SpaceID {
        env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
    }

    private func makeTab(url: String, title: String) -> Orbit.Tab {
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: title)
        env.state.tabs[tab.id] = tab
        return tab
    }

    private struct Fixture {
        var window: NSWindow
        var content: NSView
        var tabs: [Orbit.Tab]
        var group: SplitGroup
        var size: CGSize
    }

    private func host(paneCount: Int, wrapInDropTarget: Bool) -> Fixture? {
        let tabs = (0..<paneCount).map { makeTab(url: "https://p\($0).example.com", title: "Pane \($0)") }
        guard env.store.createSplit(with: tabs.map(\.id), axis: .horizontal) != nil,
              let group = env.splitGroup(for: tabs[0].id) else {
            XCTFail("Failed to create a split group.")
            return nil
        }
        env.activateTab(tabs[0].id)

        let size = CGSize(width: 400, height: OrbitMetrics.sidebarRowHeight)
        let row = SplitGroupRowView(group: group, tabs: tabs, theme: SpaceTheme())
        let hosted: AnyView = wrapInDropTarget
            ? AnyView(
                SidebarDropTarget(
                    payload: SidebarDragPayload(nodeID: tabs[0].id, kind: .todayTab, spaceID: spaceID),
                    rowID: tabs[0].id,
                    isFolder: false,
                    accentColor: .blue,
                    rejectDropIDs: Set(tabs.map(\.id)),
                    ownsDragSource: false,
                    onDrop: { _, _ in }
                ) { row }
            )
            : AnyView(row)
        let hostView = NSHostingView(rootView: hosted.environment(env))
        hostView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostView
        window.orderFront(nil)
        hostView.layoutSubtreeIfNeeded()
        // Let SwiftUI install its representables.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostView.layoutSubtreeIfNeeded()
        return Fixture(window: window, content: hostView, tabs: tabs, group: group, size: size)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    // The point (window coordinates, bottom-left origin) at the centre of the pane.
    private func paneCentre(_ fixture: Fixture, index: Int) -> NSPoint {
        let panes = CGFloat(fixture.tabs.count)
        let x = fixture.size.width * (CGFloat(index) + 0.5) / panes
        return NSPoint(x: x, y: fixture.size.height / 2)
    }

    // The window's own hit test: a plain AppKit walk, then OrbitWindowContentView's click recovery when that walk lands on a SwiftUI container.
    private func resolve(_ fixture: Fixture, at point: NSPoint) -> NSView? {
        let resolved = fixture.content.hitTest(point)
        guard OrbitWindowContentView.isSwiftUIContainer(resolved) else { return resolved }
        return OrbitWindowContentView.topmostClickCatcher(in: fixture.content, atPointInWindow: point) ?? resolved
    }

    private func click(_ fixture: Fixture, at point: NSPoint) -> NSView? {
        guard let target = resolve(fixture, at: point) else { return nil }
        target.mouseDown(with: event(.leftMouseDown, at: point, in: fixture.window))
        target.mouseUp(with: event(.leftMouseUp, at: point, in: fixture.window))
        return target
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickingTheSecondPane_selectsItsTab
    func test_clickingTheSecondPane_selectsItsTab() {
        guard let fixture = host(paneCount: 2, wrapInDropTarget: true) else { return }
        defer { fixture.window.orderOut(nil); env.store.dissolveSplit(fixture.group.id) }
        XCTAssertEqual(env.activeTabID, fixture.tabs[0].id)

        let target = click(fixture, at: paneCentre(fixture, index: 1))

        XCTAssertNotNil(target, "Nothing in the hosted row claimed a click on the second pane.")
        XCTAssertEqual(env.activeTabID, fixture.tabs[1].id, "Clicking the second pane must select that pane's tab; resolved to \(String(describing: target.map { type(of: $0) })).")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickingTheFirstPaneAfterTheSecond_selectsItsTab
    func test_clickingTheFirstPaneAfterTheSecond_selectsItsTab() {
        guard let fixture = host(paneCount: 2, wrapInDropTarget: true) else { return }
        defer { fixture.window.orderOut(nil); env.store.dissolveSplit(fixture.group.id) }

        _ = click(fixture, at: paneCentre(fixture, index: 1))
        _ = click(fixture, at: paneCentre(fixture, index: 0))

        XCTAssertEqual(env.activeTabID, fixture.tabs[0].id)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_everyPaneOfAThreePaneSplitTakesAClick
    func test_everyPaneOfAThreePaneSplitTakesAClick() {
        guard let fixture = host(paneCount: 3, wrapInDropTarget: true) else { return }
        defer { fixture.window.orderOut(nil); env.store.dissolveSplit(fixture.group.id) }

        for index in [2, 1, 0] {
            let point = paneCentre(fixture, index: index)
            let target = click(fixture, at: point)
            XCTAssertNotNil(target, "Pane \(index) was not hit.")
            let frame = target.map { fixture.content.convert($0.bounds, from: $0) }
            XCTAssertEqual(
                env.activeTabID, fixture.tabs[index].id,
                "Clicking pane \(index) at \(point) did not select it; it resolved to \(String(describing: target.map { type(of: $0) })) covering \(String(describing: frame))."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aPressThatTurnsIntoADragDoesNotSelectThePane
    func test_aPressThatTurnsIntoADragDoesNotSelectThePane() {
        guard let fixture = host(paneCount: 2, wrapInDropTarget: true) else { return }
        defer { fixture.window.orderOut(nil); env.store.dissolveSplit(fixture.group.id) }
        let start = paneCentre(fixture, index: 1)
        guard let target = resolve(fixture, at: start) else { return XCTFail("Nothing claimed the press.") }

        target.mouseDown(with: event(.leftMouseDown, at: start, in: fixture.window))
        target.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: start.x + 40, y: start.y), in: fixture.window))

        XCTAssertEqual(env.activeTabID, fixture.tabs[0].id, "A press released far from where it began is a drag, and must leave the selected tab alone.")
    }
}

// The page's split drop target must never take a click, whatever a stale drag record says.
@MainActor
final class SplitPaneDropCatcherClaimTests: XCTestCase {

    func test_noDragInFlight_neverClaimsAnything() {
        for type: NSEvent.EventType? in [nil, .leftMouseDragged, .leftMouseDown, .mouseMoved] {
            XCTAssertFalse(SplitPaneDropCatcherView.claimsHit(duringEvent: type, dragInFlight: false), "\(String(describing: type))")
        }
    }

    func test_aClickPassesThroughEvenWhileADragRecordExists() {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp] {
            XCTAssertFalse(
                SplitPaneDropCatcherView.claimsHit(duringEvent: type, dragInFlight: true),
                "A \(type) must reach the page, or a leftover drag record makes every pane unclickable."
            )
        }
    }

    func test_scrollsAndHoversPassThroughToo() {
        XCTAssertFalse(SplitPaneDropCatcherView.claimsHit(duringEvent: .scrollWheel, dragInFlight: true))
        XCTAssertFalse(SplitPaneDropCatcherView.claimsHit(duringEvent: .mouseMoved, dragInFlight: true))
    }

    func test_theEventThatStartedADragIsNotAClickOnThePage() {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .mouseMoved, .scrollWheel, .keyDown] {
            XCTAssertTrue(
                SplitPaneDropCatcherView.claimsHit(duringEvent: type, eventAge: 2, dragInFlight: true),
                "An old \(type) is how the drag began, not a press on the page."
            )
        }
    }

    func test_holdingCommandMidDragDoesNotHandTheDragBack() {
        XCTAssertTrue(SplitPaneDropCatcherView.claimsHit(duringEvent: .flagsChanged, eventAge: 0, dragInFlight: true))
    }

    func test_aRealDragOverThePageIsStillClaimed() {
        XCTAssertTrue(SplitPaneDropCatcherView.claimsHit(duringEvent: .leftMouseDragged, dragInFlight: true))
        XCTAssertTrue(SplitPaneDropCatcherView.claimsHit(duringEvent: nil, dragInFlight: true), "Drag-destination lookups can run with no current event.")
    }
}
