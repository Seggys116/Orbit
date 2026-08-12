import XCTest
import SwiftUI
import AppKit

@MainActor
final class OrbitHoverPopoverAnchorLifecycleTests: XCTestCase {

    // MARK: - Fixtures

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
        window?.close()
        window = nil
        super.tearDown()
    }

    private var previewContent: OrbitHoverPopover<AnyView>.Coordinator.HostedContent {
        OrbitHoverPopoverHostedContent(
            content: AnyView(
                VStack(spacing: 4) {
                    Text("Folder preview")
                    Text("Q4 Roadmap")
                }
                .padding()
                .frame(width: OrbitMetrics.folderPreviewWidth)
            ),
            environment: EnvironmentValues()
        )
    }

    private func makeCoordinator(
        isPresented: Bool = true
    ) -> (coordinator: OrbitHoverPopover<AnyView>.Coordinator, presented: Box<Bool>) {
        let box = Box(isPresented)
        let binding = Binding<Bool>(get: { box.value }, set: { box.value = $0 })
        return (OrbitHoverPopover<AnyView>.Coordinator(isPresented: binding, preferredEdge: .maxX), box)
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private var visiblePopoverWindowCount: Int {
        NSApp.windows.filter { "\(type(of: $0))".contains("Popover") && $0.isVisible }.count
    }

    // MARK: - Requirement 1: the crash

    func test_present_whenTheAnchorLeavesItsWindowAsItsRectIsRead_doesNotShowAndDoesNotCrash() {
        let anchor = DetachingAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        XCTAssertNotNil(anchor.window, "Fixture setup: the anchor must start out genuinely in a window.")
        anchor.detachesOnNextBoundsRead = true

        let (coordinator, _) = makeCoordinator()
        let before = visiblePopoverWindowCount

        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)

        XCTAssertGreaterThan(
            anchor.boundsReadsWhileArmed, 0,
            "The anchor's bounds were never read, so this test did not exercise the ordering it exists to " +
            "protect. present(from:content:) must still take its positioning rect from the anchor; if it stopped " +
            "doing so, rewrite this reproduction against whatever it reads instead rather than deleting it."
        )
        XCTAssertNil(anchor.window, "Fixture: the anchor must actually have left its window when its bounds were read.")
        XCTAssertEqual(
            visiblePopoverWindowCount, before,
            "A popover was shown against an anchor that had left its window. That call is exactly " +
            "'-[NSPopover showRelativeToRect:ofView:preferredEdge:]: view has no window' — an Objective-C " +
            "exception Swift cannot catch, which terminates the app. It must never be reached."
        )
    }

    func test_present_afterRefusingToShowOnADetachedAnchor_canStillPresentLater() {
        let anchor = DetachingAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        anchor.detachesOnNextBoundsRead = true

        let (coordinator, _) = makeCoordinator()
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        XCTAssertNil(anchor.window)

        anchor.detachesOnNextBoundsRead = false
        window.contentView?.addSubview(anchor)
        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)

        XCTAssertEqual(
            visiblePopoverWindowCount, before + 1,
            "Refusing to show against a detached anchor must not poison the coordinator: once the anchor is back " +
            "in a window, the next update has to present normally. A coordinator that recorded a popover it never " +
            "showed would take update(isPresented:anchor:content:)'s 'already presented' branch forever and the " +
            "preview would be dead for the life of that row."
        )
        coordinator.dismiss()
    }

    // MARK: - Requirement 2: a deferred presentation actually resumes

    func test_present_withAnchorNotYetInAWindow_defersAndResumesWhenTheAnchorLandsInOne() {
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        let (coordinator, _) = makeCoordinator()
        anchor.onWindowChange = { [weak coordinator] in coordinator?.anchorWindowDidChange($0) }
        XCTAssertNil(anchor.window, "Fixture setup: the anchor must start out with no window.")

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        XCTAssertEqual(
            visiblePopoverWindowCount, before,
            "Nothing may be shown while the anchor has no window — that call would terminate the app."
        )

        window.contentView?.addSubview(anchor)

        XCTAssertEqual(
            visiblePopoverWindowCount, before + 1,
            "The held presentation must resume the instant the anchor lands in a window " +
            "(OrbitHoverPopoverAnchorView.viewDidMoveToWindow -> Coordinator.anchorWindowDidChange). Silently " +
            "dropping it is the measured 'the hover preview never appears' half of this defect."
        )
        coordinator.dismiss()
    }

    func test_deferredPresentation_isAbandonedIfTheCallerStopsWantingItBeforeTheAnchorLandsInAWindow() {
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        let (coordinator, presented) = makeCoordinator()
        anchor.onWindowChange = { [weak coordinator] in coordinator?.anchorWindowDidChange($0) }

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        presented.value = false

        window.contentView?.addSubview(anchor)

        XCTAssertEqual(
            visiblePopoverWindowCount, before,
            "isPresented went false while the presentation was held, so it must be abandoned — not run late, " +
            "under a pointer that has already left the row."
        )
    }

    func test_dismiss_abandonsAHeldPresentation_evenWithNoPopoverOpen() {
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        let (coordinator, _) = makeCoordinator()
        anchor.onWindowChange = { [weak coordinator] in coordinator?.anchorWindowDidChange($0) }

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        coordinator.dismiss()

        window.contentView?.addSubview(anchor)

        XCTAssertEqual(
            visiblePopoverWindowCount, before,
            "dismiss() must clear a held presentation before its `popover != nil` early return, or a dismissed " +
            "preview reappears the moment its anchor is installed."
        )
    }

    // MARK: - Requirement 3: a dismantled anchor is never presented against

    func test_present_againstAnAnchorSwiftUIHasDismantled_doesNotShow() {
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        window.contentView?.addSubview(anchor)
        let (coordinator, _) = makeCoordinator()

        OrbitHoverPopover<AnyView>.dismantleNSView(anchor, coordinator: coordinator)
        XCTAssertTrue(anchor.isDismantled, "dismantleNSView must mark the anchor, since anchor.window cannot express it.")

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)

        XCTAssertEqual(
            visiblePopoverWindowCount, before,
            "A popover was attached to an anchor SwiftUI had already torn out of the view tree. Even where that " +
            "does not throw outright (it does the moment AppKit's deferred removal lands), it leaves an " +
            "NSPopover on screen anchored to nothing, with the coordinator that would have dismissed it already " +
            "torn down."
        )
    }

    func test_anchorLeavingItsWindowWhilePresented_closesThePopover() {
        let anchor = OrbitHoverPopoverAnchorView(frame: NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight))
        let (coordinator, _) = makeCoordinator()
        anchor.onWindowChange = { [weak coordinator] in coordinator?.anchorWindowDidChange($0) }
        window.contentView?.addSubview(anchor)

        let before = visiblePopoverWindowCount
        coordinator.update(isPresented: true, anchor: anchor, content: previewContent)
        XCTAssertEqual(visiblePopoverWindowCount, before + 1, "Fixture setup: the popover must actually be showing first.")

        anchor.removeFromSuperview()

        XCTAssertEqual(
            visiblePopoverWindowCount, before,
            "A preview must not outlive the row it belongs to. When the sidebar's tree is rebuilt underneath an " +
            "open preview, the anchor leaves the window and the popover has to go with it."
        )
    }
}

// MARK: - Test-only anchor that detaches at the exact instant its rect is read

private final class DetachingAnchorView: NSView {
    var detachesOnNextBoundsRead = false
    private(set) var boundsReadsWhileArmed = 0

    override var bounds: NSRect {
        get {
            let value = super.bounds
            if detachesOnNextBoundsRead, superview != nil {
                boundsReadsWhileArmed += 1
                removeFromSuperview()
            }
            return value
        }
        set { super.bounds = newValue }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
