import XCTest
import AppKit
import SwiftUI
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class WindowControllerResizeRegressionTests: XCTestCase {

    private var window: NSWindow?
    private var controller: OrbitWindowController?

    override func tearDown() {
        tearDownWindow()
        super.tearDown()
    }

    private func makeRealWindow() -> NSWindow {
        let window = OrbitWindowController.makeWindow()
        window.isReleasedWhenClosed = false
        let controller = OrbitWindowController(window: window)
        controller.installContentView(window: window)
        self.window = window
        self.controller = controller
        return window
    }

    private func tearDownWindow() {
        guard let window else {
            controller = nil
            return
        }
        window.orderOut(nil)
        window.delegate = nil
        window.contentView = nil
        controller?.window = nil
        window.close()
        self.controller = nil
        self.window = nil
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realWindowAndRealContentView_acceptsBeingResizedTo800x500ContentSize

    func test_realWindowAndRealContentView_acceptsBeingResizedTo800x500ContentSize() {
        let window = makeRealWindow()

        let target = NSSize(width: 800, height: 500)
        XCTAssertGreaterThanOrEqual(target.width, window.minSize.width, "test precondition: target must be within the window's own declared minSize")
        XCTAssertGreaterThanOrEqual(target.height, window.minSize.height, "test precondition: target must be within the window's own declared minSize")

        window.setContentSize(target)
        settle(window)

        XCTAssertEqual(
            window.contentView?.frame.size, target,
            "P0 regression: the real OrbitWindowController-built window must still be 800×500 after a layout pass, not have grown back a titlebar height at a time."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realWindowAndRealContentView_canBeShrunkBelowItsOwnOpeningHeight

    func test_realWindowAndRealContentView_canBeShrunkBelowItsOwnOpeningHeight() {
        let window = makeRealWindow()

        let openingHeight = window.frame.height
        XCTAssertGreaterThan(openingHeight, 500, "test precondition: the window's own default opening height (840, per makeWindow()) must be taller than the target this test shrinks it to")

        window.setContentSize(NSSize(width: 800, height: 500))
        settle(window)

        XCTAssertLessThan(
            window.frame.height, openingHeight,
            "The window must actually shrink when asked to, and still be shrunk once layout has run."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realWindow_shrinksMonotonically_underASimulatedLiveResizeDrag

    func test_realWindow_shrinksMonotonically_underASimulatedLiveResizeDrag() {
        let window = makeRealWindow()

        var heights: [CGFloat] = [window.frame.height]
        for _ in 0..<8 {
            var next = window.frame
            next.size.height -= 20
            window.setFrame(next, display: true)
            settle(window)
            heights.append(window.frame.height)
        }

        for (index, pair) in zip(heights, heights.dropFirst()).enumerated() {
            let (before, after) = pair
            XCTAssertLessThan(
                after, before,
                """
                Drag tick \(index) asked the window to be 20pt shorter than \(before)pt and it \
                came back \(after)pt. The window is growing while the user drags it smaller. \
                Full sequence: \(heights.map { Int($0) }). Unfixed, this reads \
                [840, 884, 928, 972, 1016, 1060, 1104, 1148, 1192] — the runaway documented in \
                OrbitWindowController.installContentView(window:).
                """
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realWindow_hostingViewStillFillsTheFullContentArea_noTitlebarInset

    func test_realWindow_hostingViewStillFillsTheFullContentArea_noTitlebarInset() {
        let window = makeRealWindow()
        window.setContentSize(NSSize(width: 900, height: 600))
        settle(window)

        guard let container = window.contentView else {
            return XCTFail("no content view installed")
        }
        guard let hosting = container.subviews.first(where: { String(describing: type(of: $0)).contains("NSHostingView") }) else {
            return XCTFail("the SwiftUI hosting view is not installed inside the window's content view; subviews were \(container.subviews.map { String(describing: type(of: $0)) })")
        }

        XCTAssertEqual(
            hosting.frame, container.bounds,
            "The SwiftUI hosting view must fill the window's whole content area edge to edge."
        )

        guard let hostingView = hosting as? NSHostingView<OrbitWindowRootView> else {
            return XCTFail("the installed view is not an NSHostingView<OrbitWindowRootView>: \(type(of: hosting))")
        }
        XCTAssertEqual(
            hostingView.safeAreaRegions, [],
            """
            The hosting view must opt out of safe area regions entirely, or SwiftUI insets Orbit's \
            edge-to-edge chrome by a titlebar the app does not draw. Removing this also stops the resize \
            runaway, which makes it a tempting non-fix — the wrapper view is what fixes the runaway, this \
            setting is what keeps the chrome edge to edge, and both are required.
            """
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realWindow_hostingViewTracksTheWindowByAutoresizing_notConstraints

    func test_realWindow_hostingViewTracksTheWindowByAutoresizing_notConstraints() {
        let window = makeRealWindow()
        guard let container = window.contentView,
              let hosting = container.subviews.first(where: { String(describing: type(of: $0)).contains("NSHostingView") }) else {
            return XCTFail("the SwiftUI hosting view is not installed inside the window's content view")
        }

        XCTAssertTrue(
            hosting.translatesAutoresizingMaskIntoConstraints,
            "NSHostingView turns this off on itself; installContentView must turn it back on, or the autoresizing mask below is ignored entirely and the view is sized by a constraint solve on every live-resize tick instead."
        )
        XCTAssertEqual(
            hosting.autoresizingMask, [.width, .height],
            "The hosting view must follow the window's content view by autoresizing arithmetic."
        )
        XCTAssertTrue(
            container.constraints.isEmpty,
            "The content view should carry no constraints at all — any constraint here is solved on every live-resize tick, and a size constraint is how this window got pinned open in the first place. Found: \(container.constraints)."
        )

        guard let hostingView = hosting as? NSHostingView<OrbitWindowRootView> else {
            return XCTFail("the installed view is not an NSHostingView<OrbitWindowRootView>: \(type(of: hosting))")
        }
        XCTAssertEqual(
            hostingView.sizingOptions, [],
            "The hosting view must publish no size of its own. Left at AppKit's default (.standardBounds) it publishes the SwiftUI tree's ideal size as required Auto Layout constraints, which pins the window open at that height."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noAbandonedHostingViewIsLeftInAnyWindow

    func test_noAbandonedHostingViewIsLeftInAnyWindow() {
        let window = makeRealWindow()
        XCTAssertNotNil(window.contentView, "test precondition: the real content view is installed")
        XCTAssertTrue(
            NSApp.windows.contains(window),
            "test precondition: a real window built through the production path is registered with the application"
        )

        tearDownWindow()

        XCTAssertNil(
            window.contentView,
            "The window still holds its NSHostingView, so every later SwiftUI render in this process keeps invalidating a window nothing owns."
        )
        XCTAssertFalse(window.isVisible, "The window is still on screen after teardown.")

        func containsHostingView(_ view: NSView) -> Bool {
            if String(describing: type(of: view)).contains("NSHostingView") { return true }
            return view.subviews.contains(where: containsHostingView)
        }
        let leakedOrbitWindows = NSApp.windows.filter { candidate in
            guard String(describing: type(of: candidate)).contains("Orbit") else { return false }
            guard let contentView = candidate.contentView else { return false }
            return containsHostingView(contentView)
        }
        XCTAssertTrue(
            leakedOrbitWindows.isEmpty,
            """
            \(leakedOrbitWindows.count) Orbit window(s) in this process still have an \
            NSHostingView installed as their contentView: \
            \(leakedOrbitWindows.map { String(describing: type(of: $0)) }.joined(separator: ", ")). \
            Every subsequent SwiftUI render drives another constraint-update pass into each of \
            them until AppKit throws an uncaught NSGenericException and terminates the whole \
            xctest process, which XCTest then attributes to whichever test was running at the \
            time. Whichever suite built the window must dismantle it — order out, clear \
            contentView, close — the way this file's tearDownWindow() does.
            """
        )
    }
}
