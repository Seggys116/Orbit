import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class WindowAcrylicChromeTests: XCTestCase {

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

    private func backdrop(in window: NSWindow) throws -> OrbitAcrylicBackdropView {
        let container = try XCTUnwrap(window.contentView, "the window has no content view installed")
        let found = container.subviews.compactMap { $0 as? OrbitAcrylicBackdropView }
        return try XCTUnwrap(
            found.first,
            "no OrbitAcrylicBackdropView in the window's content view; subviews were \(container.subviews.map { String(describing: type(of: $0)) })"
        )
    }

    // MARK: - (1) The window paints nothing opaque of its own

    func test_window_isNotOpaqueAndPaintsNoBackgroundOfItsOwn() {
        let window = makeRealWindow()

        XCTAssertFalse(
            window.isOpaque,
            "An opaque window composites against a solid surface, so the behind-window blur underneath its content has nothing to show — the whole window stops being acrylic."
        )
        XCTAssertEqual(
            window.backgroundColor.alphaComponent, 0, accuracy: 0.001,
            "The window's own background colour must be fully transparent: anything painted there sits between the blur and the desktop, which is the one place nothing can be see-through."
        )
    }

    // MARK: - (2) A real blur fills the content area, under the SwiftUI tree

    func test_installContentView_putsTheAcrylicBackdropUnderTheHostingView() throws {
        let window = makeRealWindow()
        let container = try XCTUnwrap(window.contentView)
        let backdrop = try self.backdrop(in: window)

        let hostingIndex = try XCTUnwrap(
            container.subviews.firstIndex { String(describing: type(of: $0)).contains("NSHostingView") },
            "the SwiftUI hosting view is not installed; subviews were \(container.subviews.map { String(describing: type(of: $0)) })"
        )
        let backdropIndex = try XCTUnwrap(container.subviews.firstIndex(of: backdrop))

        XCTAssertLessThan(
            backdropIndex, hostingIndex,
            "The backdrop must sit below the hosting view in subview order. Above it, it would blur — and hide — Orbit's own content instead of what is behind the window, and would take every click before SwiftUI saw it."
        )
        XCTAssertEqual(
            backdrop.frame, container.bounds,
            "The backdrop must fill the whole content area; anywhere it does not reach is a region of the window with no blur under it at all."
        )
        XCTAssertEqual(
            backdrop.autoresizingMask, [.width, .height],
            "The backdrop must track the window by autoresizing, like the hosting view above it — otherwise resizing the window leaves un-blurred content outside its stale frame."
        )
    }

    func test_acrylicBackdrop_isConfiguredAsABehindWindowBlurThatStaysActive() throws {
        let window = makeRealWindow()
        let backdrop = try self.backdrop(in: window)

        XCTAssertEqual(
            backdrop.blendingMode, .behindWindow,
            "`.withinWindow` would blur Orbit's own content rather than the desktop behind the window — the opposite of what a window-level acrylic backdrop is for."
        )
        XCTAssertEqual(
            backdrop.material, .hudWindow,
            """
            The material is load-bearing, not decorative — this is the half of the acrylic that decides \
            whether any of it is visible. It shipped once as `.underWindowBackground` (the obvious choice \
            by name) and the user could see no transparency at all: that material is the least see-through \
            one AppKit offers, and under Orbit's own tint almost nothing survived it. `.hudWindow` is the \
            most transparent standard material. See OrbitAcrylicBackdropView and OrbitAcrylic.
            """
        )
        XCTAssertEqual(
            backdrop.state, .active,
            "`.followsWindowActiveState` would collapse the blur to a flat fill whenever focus moved to another app, changing the whole window's appearance for a reason the user never asked for."
        )
    }

    /// `NSVisualEffectView` answers hit tests with itself by default, which would swallow a
    /// click rather than falling through to the window background.
    func test_acrylicBackdrop_neverClaimsAClick() throws {
        let window = makeRealWindow()
        let backdrop = try self.backdrop(in: window)

        XCTAssertNil(backdrop.hitTest(NSPoint(x: backdrop.bounds.midX, y: backdrop.bounds.midY)))
    }

    // MARK: - (3) The tint over it is genuinely translucent

    /// Ranges, not values: both numbers are tuned by eye.
    func test_acrylicTints_areTranslucentButStillPaintTheSpaceTheme() {
        for (name, value) in [
            ("OrbitAcrylic.windowTintOpacity", OrbitAcrylic.windowTintOpacity),
            ("OrbitAcrylic.panelTintOpacity", OrbitAcrylic.panelTintOpacity),
        ] {
            XCTAssertLessThan(
                value, 1,
                "\(name) at 1 paints the Space gradient fully opaque, which hides the blur underneath it completely — the surface is no longer acrylic, whatever else is configured."
            )
            XCTAssertGreaterThan(
                value, 0,
                "\(name) at 0 removes the Space theme from the surface entirely, leaving bare system material with no Space identity at all."
            )
        }
    }
}
