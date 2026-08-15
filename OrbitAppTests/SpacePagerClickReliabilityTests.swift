import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// Defect: "sometimes clicking a space doesn't transfer me over... I have to spam press it."
//
// Root cause, found by direct measurement (temporarily instrumented, then removed — see this PR's
// own notes): each dot was a SwiftUI `Button` also decorated with `.draggable(...)`. A `Button`'s own
// tap gesture races a drag source for an ordinary click carrying a few points of incidental pointer
// jitter, and can lose that race outright — the tap silently never fires. `FavoritesGridView` already
// hit this exact failure with the exact same combination ("Plain .onTapGesture + .draggable, not
// sidebarRowDragSource: that catcher breaks both clicking and dragging here.") and its own fix is the
// same one applied here: a plain `.onTapGesture`, not `Button`, alongside the drag source. The drag
// source itself was also switched from `.draggable` to `.onDrag`, matching `SidebarDragDrop.swift`'s
// own established, tested pattern for a sidebar drag source that must coexist with a reliable click.
//
// NOTE ON THIS FILE'S OWN TESTING METHOD: injecting a synthetic `.leftMouseDragged` event into a
// window hosting an `.onDrag`-decorated view can start a *real* AppKit dragging session with no real
// mouse to ever complete it — in this offscreen host that hangs the test process outright. This file
// deliberately never does that; every mouse sequence below is `.leftMouseDown` immediately followed by
// `.leftMouseUp`, which is both safe and representative (ordinary click imprecision essentially never
// crosses the OS's own hardware dead-zone to synthesize a real `.leftMouseDragged` event at all).
//
// A second, related race lived in SpaceSwitchingSidebarContainer: a committed trackpad swipe applies
// its destination Space only once its settle animation's completion runs. If a click (e.g. on the
// pager) landed on a *different* Space while that animation was still in flight, the completion used
// to clobber it back to the swipe's own destination. Fixed with a guard, tested directly below.
//
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
@MainActor
final class SpacePagerClickReliabilityTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Hosts the real `SpaceSwitcherPagerView` at exactly its own ideal size (sizeScale 1, no
    /// GeometryReader-driven shrink), so every dot's centre is at a known, deterministic point.
    /// Drag decorations (`.onDrag`/`.dropDestination`) are left enabled — this is production shape.
    private func hostPager(spaceCount: Int) -> (window: NSWindow, dotCentre: (Int) -> NSPoint) {
        let width = SpaceSwitcherPagerView.idealWidth(forSpaceCount: spaceCount, scale: 1)
        let height = OrbitMetrics.spacePagerDotSize + OrbitMetrics.spacePagerContainerPadding * 2
        let size = CGSize(width: width, height: height)

        let content = SpaceSwitcherPagerView(theme: SpaceTheme())
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

        func dotCentre(_ index: Int) -> NSPoint {
            let leadingX = OrbitMetrics.spacePagerContainerPadding
                + CGFloat(index) * (OrbitMetrics.spacePagerDotSize + OrbitMetrics.spacePagerDotSpacing)
            let x = leadingX + OrbitMetrics.spacePagerDotSize / 2
            let y = height / 2
            return NSPoint(x: x, y: y)
        }
        return (window, dotCentre)
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

    // MARK: - 1. A plain click switches Spaces (baseline, production shape: drag decorations active)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_plainClick_onASecondDot_switchesSpace
    func test_plainClick_onASecondDot_switchesSpace() {
        let spaces = env.spaces
        guard spaces.count > 1, let startID = env.activeSpace?.id else {
            return XCTFail("test precondition: needs more than one Space and an active one.")
        }
        let target = spaces[1]
        XCTAssertNotEqual(target.id, startID, "test precondition: dot 1 must not already be the active Space.")

        let (window, dotCentre) = hostPager(spaceCount: spaces.count)
        click(at: dotCentre(1), in: window)
        pump(seconds: 0.3)

        XCTAssertEqual(
            env.activeSpace?.id, target.id,
            "A click on the second dot must switch to that Space — if this fails, the dot is back to " +
            "being a Button racing its own .onDrag decoration (see this file's own header)."
        )
    }

    // MARK: - 2. Clicking each dot in turn always lands on the space actually clicked

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickingEveryDotInTurn_alwaysSwitchesToThatExactSpace
    func test_clickingEveryDotInTurn_alwaysSwitchesToThatExactSpace() {
        let spaces = env.spaces
        guard spaces.count > 2 else {
            return XCTFail("test precondition: needs at least three Spaces.")
        }
        let (window, dotCentre) = hostPager(spaceCount: spaces.count)

        for (index, space) in spaces.enumerated() {
            click(at: dotCentre(index), in: window)
            pump(seconds: 0.15)
            XCTAssertEqual(env.activeSpace?.id, space.id, "Clicking dot \(index) must switch to \(space.name).")
        }
    }

    // MARK: - 3. commitDestinationIndex: pure logic behind the trackpad swipe's own commit decision

    func test_commitDestinationIndex_pastThreshold_leftward_commitsToNextIndex() {
        let destination = SpaceSwitchingSidebarContainer.commitDestinationIndex(
            finalTranslation: -400, velocity: 0, width: 300, activeIndex: 1, spaceCount: 3
        )
        XCTAssertEqual(destination, 2)
    }

    func test_commitDestinationIndex_pastThreshold_rightward_commitsToPreviousIndex() {
        let destination = SpaceSwitchingSidebarContainer.commitDestinationIndex(
            finalTranslation: 400, velocity: 0, width: 300, activeIndex: 1, spaceCount: 3
        )
        XCTAssertEqual(destination, 0)
    }

    func test_commitDestinationIndex_shortOfThreshold_springsBack() {
        let destination = SpaceSwitchingSidebarContainer.commitDestinationIndex(
            finalTranslation: -30, velocity: 0, width: 300, activeIndex: 1, spaceCount: 3
        )
        XCTAssertNil(destination)
    }

    func test_commitDestinationIndex_pastThresholdButNoNeighbour_returnsNil() {
        let destination = SpaceSwitchingSidebarContainer.commitDestinationIndex(
            finalTranslation: -400, velocity: 0, width: 300, activeIndex: 2, spaceCount: 3
        )
        XCTAssertNil(destination, "activeIndex 2 has no index 3 to commit into in a 3-Space pager.")
    }

    func test_commitDestinationIndex_fastFlickUnderDistanceThreshold_stillCommitsOnVelocity() {
        let destination = SpaceSwitchingSidebarContainer.commitDestinationIndex(
            finalTranslation: -20, velocity: -500, width: 300, activeIndex: 0, spaceCount: 3
        )
        XCTAssertEqual(destination, 1, "A fast flick short of the distance threshold must still commit on velocity alone.")
    }

    // MARK: - 4. shouldApplySwipeDestination: the "a later click must win" guard

    func test_shouldApplySwipeDestination_nothingElseChangedTheActiveSpace_appliesTheSwipe() {
        let origin = SpaceID()
        XCTAssertTrue(SpaceSwitchingSidebarContainer.shouldApplySwipeDestination(activeSpaceIDAtCompletion: origin, originSpaceID: origin))
    }

    func test_shouldApplySwipeDestination_aClickAlreadyMovedTheActiveSpace_skipsTheStaleSwipe() {
        let origin = SpaceID()
        let clicked = SpaceID()
        XCTAssertFalse(
            SpaceSwitchingSidebarContainer.shouldApplySwipeDestination(activeSpaceIDAtCompletion: clicked, originSpaceID: origin),
            "Once something else (a click) has already moved the active Space away from where the swipe started, the swipe's own stale destination must not be applied on top of it."
        )
    }

    // MARK: - 5. End-to-end shape of the guard, using real Spaces from AppEnvironment.demo

    func test_swipeCommitGuard_endToEnd_aClickDuringTheSettleAnimationWins() {
        let spaces = env.spaces
        guard spaces.count > 2, let originID = env.activeSpace?.id,
              let originIndex = spaces.firstIndex(where: { $0.id == originID }) else {
            return XCTFail("test precondition: needs at least three Spaces and an active one.")
        }
        let swipeDestinationIndex = (originIndex + 1) % spaces.count
        let swipeDestination = spaces[swipeDestinationIndex]
        let clickedSpace = spaces.first { $0.id != originID && $0.id != swipeDestination.id }
        guard let clickedSpace else {
            return XCTFail("test precondition: needs a third Space distinct from both the origin and the swipe's own destination.")
        }

        // The swipe committed to swipeDestination, but before its settle animation's completion
        // runs, the user clicks a different dot outright.
        env.selectSpace(clickedSpace.id)
        XCTAssertEqual(env.activeSpace?.id, clickedSpace.id, "test precondition: the click must have taken effect immediately.")

        // Production's completion handler now runs; per shouldApplySwipeDestination it must not
        // clobber the click with the swipe's stale destination.
        if SpaceSwitchingSidebarContainer.shouldApplySwipeDestination(activeSpaceIDAtCompletion: env.activeSpace?.id, originSpaceID: originID) {
            env.selectSpace(swipeDestination.id)
        }

        XCTAssertEqual(
            env.activeSpace?.id, clickedSpace.id,
            "A click made during an in-flight swipe's settle animation must be the one that sticks, not the swipe's own (now stale) destination."
        )
    }
}
