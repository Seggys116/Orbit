import XCTest
import AppKit
import SwiftUI
@testable import Orbit

@MainActor
private final class OnboardingInsetProbe {
    var topSafeAreaInset: CGFloat?
}

private struct OnboardingChromeProbeView: View {
    let probe: OnboardingInsetProbe

    var body: some View {
        GeometryReader { proxy in
            Color.black
                .onAppear { probe.topSafeAreaInset = proxy.safeAreaInsets.top }
        }
    }
}

@MainActor
final class OnboardingWindowChromeTests: XCTestCase {

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

    private func makeProbeWindow() -> (window: NSWindow, probe: OnboardingInsetProbe) {
        let window = OnboardingWindowController.makeWindow()
        window.isReleasedWhenClosed = false
        windows.append(window)
        let probe = OnboardingInsetProbe()
        OnboardingWindowController.installContentView(
            window: window,
            rootView: OnboardingChromeProbeView(probe: probe)
        )
        return (window, probe)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    func testOnboardingWindowGivesItsContentAZeroTopSafeAreaInset() {
        let (window, probe) = makeProbeWindow()
        settle(window)
        guard let inset = probe.topSafeAreaInset else {
            return XCTFail("the SwiftUI content never laid out, so no inset was measured")
        }
        XCTAssertEqual(
            inset, 0,
            "The onboarding window's SwiftUI content must start at the window's top edge. A non-zero top inset (\(inset)pt) is the reported defect exactly: the artwork panel begins below the titlebar with a band of plain window background cutting across the top of it."
        )
    }

    func testOnboardingWindowHoldsTheSizeItWasBuiltAt() {
        let (window, _) = makeProbeWindow()
        settle(window)
        XCTAssertEqual(
            window.frame.size, NSSize(width: 880, height: 560),
            "Removing the safe-area inset must not cost the window its size: 880x560 is what OnboardingView's root frame is drawn at, and anything taller means the hosting view is driving the window's layout instead of the other way round."
        )
    }

    func testOnboardingWindowKeepsAUsableCloseButtonOverTheLeftPanel() {
        let (window, _) = makeProbeWindow()
        settle(window)
        guard let close = window.standardWindowButton(.closeButton) else {
            return XCTFail("the onboarding window has no close button, so closing it — the documented way to skip the rest of setup — is unreachable")
        }
        XCTAssertFalse(close.isHidden, "The close button is the skip path (see OnboardingWindowController's header); it must never be hidden.")
        XCTAssertTrue(close.isEnabled, "A close button that cannot be clicked is no way out of the flow.")
        let inWindow = close.convert(close.bounds, to: nil)
        XCTAssertLessThanOrEqual(
            inWindow.maxX, 420,
            "The close button must sit over OnboardingView's 420pt-wide text column, not over the artwork panel."
        )
        XCTAssertGreaterThan(
            inWindow.minY, window.frame.height - 44,
            "The close button must stay in the window's top strip rather than being pushed down into the content."
        )
    }
}
