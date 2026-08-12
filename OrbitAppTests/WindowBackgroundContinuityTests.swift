//  The Space gradient must be one continuous surface across the whole
//  window; the sidebar sits on it, not on its own copy.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class WindowBackgroundContinuityTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private static let windowSize = CGSize(width: 1320, height: 840)
    private static let sidebarWidth: CGFloat = 240

    private static let rampTheme = SpaceTheme(
        style: .linear,
        colors: [
            ThemeColor(red: 0.05, green: 0.10, blue: 0.85),
            ThemeColor(red: 0.95, green: 0.85, blue: 0.10),
        ],
        angle: 90,
        grain: 0
    )

    private static let sampleY = Int(windowSize.height) - 3

    private static var sampleXRange: ClosedRange<Int> {
        let cardLeadingEdge = Int(sidebarWidth + OrbitMetrics.sidebarResizeHandleWidth + OrbitMetrics.cardInset)
        return 140...(cardLeadingEdge - 2)
    }

    func test_windowBackground_hasNoSeamAtTheSidebarsTrailingEdge() async {
        OrbitScreenshotFixtures.configure(env)
        env.isSidebarVisible = true
        env.isSidebarHoverRevealed = false
        env.sidebarWidth = Self.sidebarWidth
        guard let activeSpaceID = env.activeSpace?.id else {
            return XCTFail("The screenshot fixture is expected to leave a Space active — nothing to theme otherwise.")
        }
        env.updateSpaceTheme(activeSpaceID, theme: Self.rampTheme)

        let rendered = await renderForScreenshot(
            BrowserWindowView(skipOnboarding: true)
                .environment(env)
                .withScreenshotModeDragDisabled(),
            size: Self.windowSize
        )

        let samples = Self.sampleXRange.map { rendered.color(atX: $0, y: Self.sampleY) }

        let first = samples[0]
        let last = samples[samples.count - 1]
        XCTAssertFalse(
            first.isApproximately(last, tolerance: 0.02),
            """
            Sampled no gradient at all across x=\(Self.sampleXRange) — \
            first=\(first) last=\(last). Either the window background did not \
            render or something opaque is covering the sampled band; the seam \
            assertions below would be meaningless.
            """
        )

        var worstStep = 0.0
        var worstX = Self.sampleXRange.lowerBound
        for (offset, sample) in samples.enumerated().dropLast() {
            let next = samples[offset + 1]
            let step = max(abs(sample.r - next.r), abs(sample.g - next.g), abs(sample.b - next.b))
            if step > worstStep {
                worstStep = step
                worstX = Self.sampleXRange.lowerBound + offset
            }
        }

        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-window-background-continuity.png")
        let wrote = rendered.writePNG(to: dump)
        print("WindowBackgroundContinuityTests: \(wrote ? "wrote" : "FAILED to write") \(dump.path)")

        guard worstStep > 0.02 else { return }

        let jump = String(format: "%.3f", worstStep)
        let before = rendered.color(atX: worstX, y: Self.sampleY).description
        let after = rendered.color(atX: worstX + 1, y: Self.sampleY).description
        let dumpNote = wrote
            ? "Rendered window written to \(dump.path) — look at it."
            : "Could not write the render to \(dump.path)."

        let where_ = "between x=\(worstX) and x=\(worstX + 1) at y=\(Self.sampleY)"
        let measured = "channels jump by \(jump) in one point, \(before) -> \(after)."
        let diagnosis = """
            The sidebar's trailing edge is x=\(Int(Self.sidebarWidth)). A jump at or near it means \
            something inside the window is painting its own copy of the Space gradient sized to \
            its own bounds instead of sitting on BrowserWindowView.backgroundBleed — see this \
            file's header, and SidebarView.paintsOwnBackground's doc comment for the one \
            sanctioned exception (the hover-revealed floating panel, which is not on screen here).
            """

        XCTFail("Discontinuity in the window's Space gradient \(where_): \(measured)\n\n\(diagnosis)\n\n\(dumpNote)")
    }
}

private extension View {
    func withScreenshotModeDragDisabled() -> some View {
        #if DEBUG
        return environment(\.orbitScreenshotModeDragDisabled, true)
        #else
        return self
        #endif
    }
}
