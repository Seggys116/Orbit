//  Escape and click-outside dismissal, driven through real NSEvents via NSApp.sendEvent(_:) —
//  no modal is presented, so nothing here can block on a human.

import XCTest
import SwiftUI
import AppKit

@MainActor
final class OrbitHoverPopoverDismissalTests: XCTestCase {

    private var window: NSWindow!



    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        super.tearDown()
    }

    private var previewContent: OrbitHoverPopover<AnyView>.Coordinator.HostedContent {
        OrbitHoverPopoverHostedContent(content: AnyView(Text("Content")), environment: EnvironmentValues())
    }

    private func makeCoordinator() -> OrbitHoverPopover<AnyView>.Coordinator {
        let binding = Binding<Bool>(get: { self.presented }, set: { self.presented = $0 })
        return OrbitHoverPopover<AnyView>.Coordinator(isPresented: binding, preferredEdge: .maxX)
    }

    private var presented = true

    private var visiblePopoverWindowCount: Int {
        NSApp.windows.filter { "\(type(of: $0))".contains("Popover") && $0.isVisible }.count
    }

    private var popoverWindow: NSWindow? {
        NSApp.windows.first { "\(type(of: $0))".contains("Popover") && $0.isVisible }
    }

    private func syntheticKeyDown(keyCode: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func syntheticMouseDown(at locationInWindow: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // Real AppKit geometry, not a hand-picked offset: correct regardless of exact title bar height.
    private func pointInsideAnchor(_ anchor: NSView) -> NSPoint {
        anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
    }

    private func pointFarFromAnchor(in window: NSWindow) -> NSPoint {
        guard let contentView = window.contentView else { return NSPoint(x: 580, y: 380) }
        return contentView.convert(NSPoint(x: contentView.bounds.maxX - 10, y: contentView.bounds.maxY - 10), to: nil)
    }

    // MARK: - Escape

    // Excluded on GitHub-hosted runners: XCTest's own exception interception segfaults there on Xcode 26. Passes on a real Mac.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_escapeKeyDown_dismissesTheOpenPopoverAndClearsIsPresented

    func test_escapeKeyDown_dismissesTheOpenPopoverAndClearsIsPresented() {
        presented = true
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        let coordinator = makeCoordinator()

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "Fixture setup: the popover must actually be showing first.")

        NSApp.sendEvent(syntheticKeyDown(keyCode: 53, in: window)) // kVK_Escape

        XCTAssertEqual(visiblePopoverWindowCount, before, "Escape must close the popover.")
        XCTAssertFalse(presented, "Escape must also clear the isPresented binding, or the caller's own state disagrees with what is on screen.")
    }

    // MARK: - Click outside

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickOutsideTheAnchorAndThePopover_dismissesAndClearsIsPresented

    func test_clickOutsideTheAnchorAndThePopover_dismissesAndClearsIsPresented() {
        presented = true
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        let coordinator = makeCoordinator()

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "Fixture setup: the popover must actually be showing first.")

        NSApp.sendEvent(syntheticMouseDown(at: pointFarFromAnchor(in: window), in: window))

        XCTAssertEqual(visiblePopoverWindowCount, before, "A click elsewhere in the same (still key) window must dismiss the popover — this is the reported 'clicking outside does not dismiss' defect.")
        XCTAssertFalse(presented)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickOutside_doesNotConsumeTheEvent

    func test_clickOutside_doesNotConsumeTheEvent() {
        presented = true
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        let coordinator = makeCoordinator()
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)

        var observedByAnotherMonitor = false
        let probe = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            observedByAnotherMonitor = true
            return event
        }
        defer { NSEvent.removeMonitor(probe) }

        NSApp.sendEvent(syntheticMouseDown(at: pointFarFromAnchor(in: window), in: window))

        XCTAssertTrue(
            observedByAnotherMonitor,
            "The dismissing monitor must return the event unmodified (unlike .transient's own monitor, which eats the very click that dismisses it) so whatever else the click hit still runs."
        )
    }

    // MARK: - A click back on the anchor itself is not treated as 'outside'

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickOnTheAnchorItself_doesNotTriggerTheOutsideDismiss

    func test_clickOnTheAnchorItself_doesNotTriggerTheOutsideDismiss() {
        presented = true
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        let coordinator = makeCoordinator()

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "Fixture setup: the popover must actually be showing first.")

        // Squarely inside the anchor's own frame — the click a caller's own button toggle logic must be left to arbitrate.
        NSApp.sendEvent(syntheticMouseDown(at: pointInsideAnchor(anchor), in: window))

        XCTAssertEqual(
            visiblePopoverWindowCount, before + 1,
            "A click back on the anchor's own region must not be treated as an outside click — re-presenting from a caller's own toggle logic must decide what happens, not a dismiss-then-orphaned-reopen race here."
        )
        XCTAssertTrue(presented)
        coordinator.dismiss()
    }

    // MARK: - A click inside the popover's own window does not dismiss it

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickInsideThePopoversOwnWindow_doesNotDismissIt

    func test_clickInsideThePopoversOwnWindow_doesNotDismissIt() throws {
        presented = true
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        let coordinator = makeCoordinator()

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "Fixture setup: the popover must actually be showing first.")

        let popoverWindow = try XCTUnwrap(popoverWindow, "No popover window appeared to click inside of.")
        NSApp.sendEvent(syntheticMouseDown(at: NSPoint(x: 5, y: 5), in: popoverWindow))

        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "A click inside the popover's own window must never be treated as an outside click.")
        XCTAssertTrue(presented)
        coordinator.dismiss()
    }

    // MARK: - keepsOpenWhilePointerInside: the pointer may travel from the anchor into the popover

    func test_pointerZone_coversTheAnchorThePopoverAndTheStripBetweenThem() {
        let anchor = NSRect(x: 0, y: 100, width: 200, height: 30)
        let popover = NSRect(x: 214, y: 20, width: 240, height: 200)

        XCTAssertTrue(OrbitHoverPopoverPointerZone.contains(NSPoint(x: 100, y: 115), anchor: anchor, popover: popover), "On the anchor.")
        XCTAssertTrue(OrbitHoverPopoverPointerZone.contains(NSPoint(x: 300, y: 50), anchor: anchor, popover: popover), "Inside the popover, even below the anchor's own height.")
        XCTAssertTrue(OrbitHoverPopoverPointerZone.contains(NSPoint(x: 207, y: 110), anchor: anchor, popover: popover), "In the gap between them, level with the anchor: the crossing the user makes.")
        XCTAssertFalse(OrbitHoverPopoverPointerZone.contains(NSPoint(x: 207, y: 60), anchor: anchor, popover: popover), "The gap lower down belongs to neither.")
        XCTAssertFalse(OrbitHoverPopoverPointerZone.contains(NSPoint(x: 100, y: 60), anchor: anchor, popover: popover), "The row below the anchor is another row.")
        XCTAssertFalse(OrbitHoverPopoverPointerZone.contains(NSPoint(x: 600, y: 115), anchor: anchor, popover: popover), "Beyond the popover.")
    }

    func test_pointerGrace_lapsesOnlyAfterTheGracePeriod() {
        let start = Date()
        XCTAssertFalse(OrbitHoverPopoverPointerZone.hasLapsed(lastInside: start, now: start.addingTimeInterval(OrbitHoverPopoverPointerZone.grace * 0.5)))
        XCTAssertTrue(OrbitHoverPopoverPointerZone.hasLapsed(lastInside: start, now: start.addingTimeInterval(OrbitHoverPopoverPointerZone.grace + 0.01)))
    }

    // The reported defect: the preview closed the instant the pointer left the row, so a tab in it could never be reached.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aPopoverThatKeepsItselfOpen_staysWhileThePointerIsOnItAndClosesAfterTheGraceOnceItLeaves

    func test_aPopoverThatKeepsItselfOpen_staysWhileThePointerIsOnItAndClosesAfterTheGraceOnceItLeaves() throws {
        presented = true
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        let coordinator = makeCoordinator()
        coordinator.keepsOpenWhilePointerInside = true

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "Fixture setup: the popover must actually be showing first.")
        let popoverWindow = try XCTUnwrap(popoverWindow)

        let start = Date()
        coordinator.pointerLocation = { NSPoint(x: popoverWindow.frame.midX, y: popoverWindow.frame.midY) }
        coordinator.evaluatePointer(now: start)
        coordinator.evaluatePointer(now: start.addingTimeInterval(5))
        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "A pointer resting on the popover must keep it open however long it rests.")
        XCTAssertTrue(presented)

        coordinator.pointerLocation = { NSPoint(x: popoverWindow.frame.maxX + 400, y: popoverWindow.frame.maxY + 400) }
        coordinator.evaluatePointer(now: start.addingTimeInterval(5.05))
        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "Leaving is forgiven for the grace period, so a pointer clipping a corner does not lose the popover.")

        coordinator.evaluatePointer(now: start.addingTimeInterval(5.05 + OrbitHoverPopoverPointerZone.grace + 0.05))
        XCTAssertEqual(visiblePopoverWindowCount, before, "Once the pointer has been away for the grace period the popover must close.")
        XCTAssertFalse(presented, "Closing must clear isPresented, or the caller's own state disagrees with what is on screen.")
    }

    // The popover's own window taking key status is the user clicking into it, not Orbit losing focus.
    func test_resignKey_isNotFocusLostWhenThePopoverWindowIsTheKeyOne() {
        XCTAssertTrue(OrbitHoverPopoverPointerZone.holdsFocus(popoverWindowIsKey: true))
        XCTAssertFalse(OrbitHoverPopoverPointerZone.holdsFocus(popoverWindowIsKey: false))
    }
}
