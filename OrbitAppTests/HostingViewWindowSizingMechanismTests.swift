import XCTest
import AppKit
import SwiftUI

@MainActor
private final class InsetProbe {
    var topSafeAreaInset: CGFloat?
}

@MainActor
final class HostingViewWindowSizingMechanismTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.delegate = nil
            window.contentView = nil
            window.close()
        }
        windows = []
        super.tearDown()
    }

    private struct Probe: View {
        let probe: InsetProbe
        var body: some View {
            GeometryReader { proxy in
                Color.red
                    .onAppear { probe.topSafeAreaInset = proxy.safeAreaInsets.top }
            }
        }
    }

    private func makeWindow(wrapped: Bool, zeroSafeAreaRegions: Bool) -> (window: NSWindow, probe: InsetProbe) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 760, height: 480)
        windows.append(window)

        let probe = InsetProbe()
        let hosting = NSHostingView(rootView: Probe(probe: probe))
        hosting.sizingOptions = []
        if zeroSafeAreaRegions { hosting.safeAreaRegions = [] }

        if wrapped {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 1320, height: 840))
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            window.contentView = container
        } else {
            window.contentView = hosting
        }
        return (window, probe)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func settledHeight(after request: CGFloat, on window: NSWindow) -> CGFloat {
        window.setContentSize(NSSize(width: 800, height: request))
        settle(window)
        return window.frame.height
    }

    func test_mechanism_hostingViewAsContentViewWithNoSafeAreaRegions_growsDuringLayout() {
        let (window, _) = makeWindow(wrapped: false, zeroSafeAreaRegions: true)
        let settled = settledHeight(after: 500, on: window)
        XCTAssertGreaterThan(
            settled, 500,
            "Expected the unwrapped + safeAreaRegions=[] combination to reproduce the runaway growth this fix exists for. It settled at exactly the requested 500pt instead, so AppKit no longer behaves the way OrbitWindowController.installContentView(window:) documents."
        )
    }

    func test_mechanism_wrappedHostingViewWithNoSafeAreaRegions_holdsTheRequestedHeight() {
        let (window, _) = makeWindow(wrapped: true, zeroSafeAreaRegions: true)
        XCTAssertEqual(
            settledHeight(after: 500, on: window), 500,
            "A wrapped hosting view must let the window hold exactly the height it was asked for, through repeated layout passes."
        )
    }

    func test_mechanism_wrappedHostingViewWithDefaultSafeAreaRegions_alsoHoldsTheRequestedHeight() {
        let (window, _) = makeWindow(wrapped: true, zeroSafeAreaRegions: false)
        XCTAssertEqual(
            settledHeight(after: 500, on: window), 500,
            "Wrapping is what makes the window stable, independent of safeAreaRegions."
        )
    }

    func test_mechanism_hostingViewAsContentViewWithDefaultSafeAreaRegions_alsoHoldsTheRequestedHeight() {
        let (window, _) = makeWindow(wrapped: false, zeroSafeAreaRegions: false)
        XCTAssertEqual(
            settledHeight(after: 500, on: window), 500,
            "Leaving safeAreaRegions at its default also stops the growth — which is exactly why it is a tempting non-fix, and why the inset tests below exist to rule it out."
        )
    }

    func test_mechanism_defaultSafeAreaRegions_pushesSwiftUIContentDownByTheTitlebar() {
        let (window, probe) = makeWindow(wrapped: true, zeroSafeAreaRegions: false)
        settle(window)
        guard let inset = probe.topSafeAreaInset else {
            return XCTFail("the SwiftUI content never laid out, so no inset was measured")
        }
        XCTAssertGreaterThan(
            inset, 0,
            "Expected the default safeAreaRegions to give SwiftUI a non-zero top inset — that cost is the whole reason installContentView keeps safeAreaRegions = [] instead of dropping it to stop the growth."
        )
    }

    func test_mechanism_wrappedWithNoSafeAreaRegions_givesSwiftUIZeroTopInset() {
        let (window, probe) = makeWindow(wrapped: true, zeroSafeAreaRegions: true)
        settle(window)
        XCTAssertEqual(
            probe.topSafeAreaInset, 0,
            "The fix's arrangement must give SwiftUI a zero top safe-area inset; anything else means Orbit's own chrome is being pushed down by a titlebar it does not draw."
        )
    }
}
