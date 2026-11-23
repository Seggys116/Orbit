//  A click on a pane of a split pair in the sidebar must open that pane's page. It goes through the window's own event path
//  (NSWindow.sendEvent, then OrbitWindowContentView's hit test and click recovery) over the sidebar's own Today section in a scroll view, because
//  SwiftUI wraps the rows in views of its own (PlatformGroupContainer) that the pane's click catcher sits behind.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SidebarSplitRowRealClickTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?
    private var spaceID: SpaceID!

    override func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        if let spaceID { env.deleteSpace(spaceID) }
        spaceID = nil
        super.tearDown()
    }

    private func catchers(in view: NSView) -> [OrbitActionButtonClickCatchingView] {
        var found: [OrbitActionButtonClickCatchingView] = []
        if let catcher = view as? OrbitActionButtonClickCatchingView, catcher.firesOnRelease { found.append(catcher) }
        for sub in view.subviews { found += catchers(in: sub) }
        return found
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint) throws {
        let window = try XCTUnwrap(self.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        ))
        window.sendEvent(event)
    }

    func test_everyRowInTheTodaySection_opensItsPage_includingEachPaneOfASplit() throws {
        let profileID = env.createDefaultProfileIfNeeded()
        let theme = SpaceTheme()
        spaceID = env.createSpace(name: "Split Click Scratch", icon: "circle", iconIsEmoji: false, theme: theme, profileID: profileID)
        env.selectSpace(spaceID)
        let first = env.openTab(url: URL(string: "https://one.example.com")!, in: spaceID, section: .today, activate: false)
        let left = env.openTab(url: URL(string: "https://two.example.com")!, in: spaceID, section: .today, activate: false)
        let right = env.openTab(url: URL(string: "https://three.example.com")!, in: spaceID, section: .today, activate: false)
        let last = env.openTab(url: URL(string: "https://four.example.com")!, in: spaceID, section: .today, activate: false)
        env.createSplit(existingTabID: left, newTabID: right, edge: .right)

        let size = CGSize(width: 260, height: 400)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ScrollView { TodaySectionView(spaceID: spaceID, theme: theme) }.environment(env))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let container = OrbitWindowContentView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(host)
        window.contentView = container
        window.orderFront(nil)
        self.window = window
        settle()

        let targets = catchers(in: container).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 20 }
        XCTAssertGreaterThanOrEqual(targets.count, 4, "The section showed \(targets.count) click targets; expected a row for each of the two single tabs and a pane for each half of the split.")

        var opened = Set<TabID>()
        for catcher in targets {
            let frame = catcher.convert(catcher.bounds, to: nil)
            let point = NSPoint(x: frame.midX, y: frame.midY)
            let handedTo = container.hitTest(container.convert(point, from: nil))
            XCTAssertTrue(handedTo === catcher, "A click at \(point) was handed to \(String(describing: handedTo.map { type(of: $0) })) instead of the row's click catcher.")
            // from two starting pages, so the row of the page already showing is not taken for a click that did nothing
            for start in [first, last] {
                env.activateTab(start)
                try send(.leftMouseDown, at: point)
                try send(.leftMouseUp, at: point)
                if let now = env.activeTabID, now != start { opened.insert(now) }
            }
        }
        XCTAssertEqual(opened, [first, left, right, last], "Clicking each row opened \(opened.count) of the 4 pages.")
    }
}
