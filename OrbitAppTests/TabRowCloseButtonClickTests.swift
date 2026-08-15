// Defect (reported three times): pressing the row's "-" on the ACTIVE bookmarked tab must leave
// no active tab (the new-tab page). Model-level fix (BrowserStore.closeTabKeepingPin /
// AppEnvironment.closeTabKeepingBookmark) is provably correct on its own — see
// CloseTabPathsTests.swift, which calls the API directly and passes. This file instead drives a
// real NSEvent click at the real on-screen position of TabRowView's "-" control, inside a real
// NSWindow, to prove or refute whether the row's own `.onTapGesture` (env.activateTab(tab.id))
// also fires for the same click and reactivates the tab that was just closed.
//
// Mouse sequence is `.leftMouseDown` immediately followed by `.leftMouseUp` at the same point —
// never a synthesized `.leftMouseDragged`, which would start an uncompletable AppKit drag session
// against this row's drag source and hang the process (see SpacePagerClickReliabilityTests.swift).

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class TabRowCloseButtonClickTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?
    private var spaceID: SpaceID!

    private let rowWidth: CGFloat = 260

    override func setUp() {
        super.setUp()
        env._test_webContentsFactory = { _, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Row Click Scratch", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID
        )
        env.selectSpace(spaceID)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        spaceID = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Hosts a real `TabRowView` for `tab` at its real production row height/padding, forced into
    /// its hovered appearance so the close control is actually visible and hit-testable — exactly
    /// as it is once a real user has hovered the row before clicking "-".
    private func hostRow(tab: Orbit.Tab, theme: SpaceTheme) -> (window: NSWindow, closeButtonCentre: NSPoint, rowBodyCentre: NSPoint) {
        let size = CGSize(width: rowWidth, height: OrbitMetrics.sidebarRowHeight)

        let content = TabRowView(tab: tab, theme: theme, forcesHoveredAppearanceForTesting: true)
            .environment(env)
            .frame(width: size.width, height: size.height, alignment: .topLeading)

        let hostView = NSHostingView(rootView: content)
        hostView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        self.window = window

        let trailingInset = OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset
        let closeCentre = NSPoint(
            x: size.width - trailingInset - OrbitMetrics.sidebarCloseButtonSize / 2,
            y: size.height / 2
        )
        let rowBodyCentre = NSPoint(x: size.width * 0.3, y: size.height / 2)
        return (window, closeCentre, rowBodyCentre)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        window.sendEvent(mouseEvent(.leftMouseDown, at: point, in: window))
        window.sendEvent(mouseEvent(.leftMouseUp, at: point, in: window))
    }

    // MARK: - 1. The reported defect, reproduced with a real click

    func test_realClick_onMinusOfActiveBookmarkedTab_leavesNoActiveTabAndDoesNotReactivateIt() {
        var materializedTabIDs: [TabID] = []
        env._test_webContentsFactory = { tabID, url in
            materializedTabIDs.append(tabID)
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }

        let bookmarkTabID = env.openTab(url: URL(string: "https://bookmark-row-click.example.com")!, in: spaceID, section: .pinned)
        env.activateTab(bookmarkTabID)
        XCTAssertEqual(env.activeTabID, bookmarkTabID, "precondition: the bookmarked tab is on screen")
        guard let tab = env.tab(bookmarkTabID) else { return XCTFail("test precondition: tab missing") }

        let (window, closeCentre, _) = hostRow(tab: tab, theme: SpaceTheme())

        materializedTabIDs = []

        click(at: closeCentre, in: window)
        pump(seconds: 0.3)

        XCTAssertNil(
            env.activeTabID,
            "A real click on the row's '-' must leave no active tab — the new-tab-page state — " +
            "exactly like calling env.closeTabKeepingBookmark(_:) directly does."
        )
        XCTAssertTrue(
            materializedTabIDs.isEmpty,
            "The click must not re-materialise (reload) the tab it just closed — got a WebContents " +
            "factory call for \(materializedTabIDs), which is the reported 'force reloads that tab' " +
            "symptom: the row's own .onTapGesture firing for the same click that closed it."
        )
        XCTAssertNil(env.webContents[bookmarkTabID], "the closed tab's renderer must stay released")
        XCTAssertEqual(env.tab(bookmarkTabID)?.section, .pinned, "the bookmark itself must survive")
    }

    // MARK: - 2. Clicking the row body must still select the tab

    // .today, not .pinned: a pinned row's title carries its own separate .onTapGesture(count: 2)
    // (double-click to rename), an unrelated pre-existing gesture whose own recognition timing
    // this test must not get tangled up in — it is not what this file is proving or fixing.
    func test_realClick_onRowBody_stillActivatesTheTab() {
        let firstTabID = env.openTab(url: URL(string: "https://row-body-click-first.example.com")!, in: spaceID, section: .today)
        let secondTabID = env.openTab(url: URL(string: "https://row-body-click-second.example.com")!, in: spaceID, section: .today, activate: false)
        env.activateTab(firstTabID)
        XCTAssertEqual(env.activeTabID, firstTabID, "precondition")
        guard let secondTab = env.tab(secondTabID) else { return XCTFail("test precondition: tab missing") }

        let (window, _, rowBodyCentre) = hostRow(tab: secondTab, theme: SpaceTheme())

        click(at: rowBodyCentre, in: window)
        pump(seconds: 0.3)

        XCTAssertEqual(env.activeTabID, secondTabID, "clicking a row's body must still select that tab")
    }

    // MARK: - 3. Closing a NON-active bookmarked tab must behave exactly as before

    func test_realClick_onMinusOfNonActiveBookmarkedTab_leavesTheOtherTabActiveAndOnlyClosesTheClickedOne() {
        let activeTabID = env.openTab(url: URL(string: "https://non-active-close-stays-active.example.com")!, in: spaceID, section: .pinned)
        let otherTabID = env.openTab(url: URL(string: "https://non-active-close-target.example.com")!, in: spaceID, section: .pinned, activate: false)
        env.activateTab(activeTabID)
        XCTAssertEqual(env.activeTabID, activeTabID, "precondition")
        XCTAssertNotNil(env.webContents[otherTabID], "precondition: the other tab is open, not just bookmarked")
        guard let otherTab = env.tab(otherTabID) else { return XCTFail("test precondition: tab missing") }

        let (window, closeCentre, _) = hostRow(tab: otherTab, theme: SpaceTheme())

        click(at: closeCentre, in: window)
        pump(seconds: 0.3)

        XCTAssertEqual(env.activeTabID, activeTabID, "closing a non-active bookmarked tab must not disturb what is on screen")
        XCTAssertNil(env.webContents[otherTabID], "the clicked tab's renderer must be released")
        XCTAssertEqual(env.tab(otherTabID)?.section, .pinned, "the clicked tab keeps its bookmark")
    }
}
