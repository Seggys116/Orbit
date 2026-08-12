//  Escape and click-outside dismissal, driven through real NSEvents via NSApp.sendEvent(_:) —
//  no modal is presented, so nothing here can block on a human.

import XCTest
import SwiftUI
import AppKit

@MainActor
final class OrbitHoverPopoverDismissalTests: XCTestCase {

    private var window: NSWindow!



    // Each test drains its own pool: the CI crash is a release inside XCTest's own
    // pool pop at the test boundary, not anything the test asserts.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

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
        window?.close()
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
}

