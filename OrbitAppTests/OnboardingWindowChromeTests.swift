import XCTest
import AppKit
import SwiftUI
@testable import Orbit

// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
@MainActor
final class OnboardingWindowChromeTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
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

    private func makeOnboardingWindow() -> (window: NSWindow, hosting: NSView) {
        let window = OnboardingWindowController.makeWindow()
        window.isReleasedWhenClosed = false
        windows.append(window)
        let hosting = OnboardingWindowController.installContentView(
            window: window,
            rootView: OnboardingRootView(onFinished: {}, environment: env)
        )
        window.makeKeyAndOrderFront(nil)
        settle(window)
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            window.contentView?.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// CGWindowListCreateImage is obsoleted in the macOS 15 SDK but still live, hence dlsym; needs no Screen Recording grant for own windows.
    private func captureBitmap(of window: NSWindow) -> NSBitmapImageRep? {
        typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard
            let handle = dlopen(nil, RTLD_NOW),
            let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        let create = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    private func capture(_ window: NSWindow) -> RenderedImage? {
        guard let bitmap = captureBitmap(of: window) else { return nil }
        return RenderedImage(bitmap: bitmap, pointSize: window.frame.size, scale: window.backingScaleFactor)
    }

    /// Nothing is painted behind the text column above the first glyph, so (2, 40) is bare window background.
    private func windowBackground(_ image: RenderedImage) -> RGBA { image.color(atX: 2, y: 40) }

    private func isOnboardingContent(_ color: RGBA, background: RGBA) -> Bool {
        !color.isApproximately(background, tolerance: 0.03)
    }

    private func artLeftEdge(_ image: RenderedImage, width: Int, background: RGBA) -> Int? {
        let rows = Array(stride(from: 60, to: 500, by: 4))
        for x in 0..<width {
            var differing = 0
            for y in rows where isOnboardingContent(image.color(atX: x, y: y), background: background) {
                differing += 1
            }
            if Double(differing) / Double(rows.count) > 0.9 { return x }
        }
        return nil
    }

    /// Continue carries `.keyboardShortcut(.defaultAction)`, so this is the real advance path without needing a key window.
    private func pressDefaultButton(in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else { return }
        _ = window.contentView?.performKeyEquivalent(with: event)
    }

    private func makeOnboardingWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        windows.append(window)
        OnboardingWindowController.installContentView(
            window: window,
            rootView: OnboardingRootView(onFinished: {}, environment: env)
        )
        window.makeKeyAndOrderFront(nil)
        settle(window)
        return window
    }

    /// Repeats until two captures agree: the art panel's blurs and starfield can be caught part-drawn on a loaded machine.
    private func settledMeasurement(_ window: NSWindow) -> (edge: Int, signature: UInt64)? {
        var previousEdge: Int?
        var last: (edge: Int, signature: UInt64)?
        let deadline = Date().addingTimeInterval(4)
        repeat {
            guard let image = capture(window) else { return nil }
            let background = windowBackground(image)
            guard let edge = artLeftEdge(image, width: Int(window.frame.width), background: background) else {
                settle(window, seconds: 0.15)
                continue
            }
            last = (edge, columnSignature(image, background: background))
            if edge == previousEdge { return last }
            previousEdge = edge
            settle(window, seconds: 0.15)
        } while Date() < deadline
        return last
    }

    private func columnSignature(_ image: RenderedImage, background: RGBA) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for y in stride(from: 60, to: 520, by: 6) {
            for x in stride(from: 20, to: 400, by: 6) {
                let bit: UInt64 = isOnboardingContent(image.color(atX: x, y: y), background: background) ? 1 : 0
                hash = (hash ^ bit) &* 0x100000001b3
            }
        }
        return hash
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingArtPanelStaysOffTheControlColumnAtEveryStep

    func testOnboardingArtPanelStaysOffTheControlColumnAtEveryStep() throws {
        let (window, _) = makeOnboardingWindow()
        var signatures: [UInt64] = []
        var edges: [Int] = []

        for step in 0..<OnboardingStep.allCases.count {
            guard let measured = settledMeasurement(window) else {
                throw TestStopped("Could not capture this process's own window pixels on this machine.")
            }
            signatures.append(measured.signature)
            edges.append(measured.edge)
            // Layout contract: column = clamp(half the window, 380...460); the stage starts at its trailing edge.
            let expectedColumn = Int(min(460, max(380, window.frame.width * 0.5)))
            XCTAssertTrue(
                (380...460).contains(measured.edge),
                "Step \(step): the art panel starts at x=\(measured.edge), outside the 380...460 column range. Measured edges so far: \(edges)."
            )
            XCTAssertEqual(
                measured.edge, expectedColumn, accuracy: 1,
                "Step \(step): the art panel starts at x=\(measured.edge), not at the column's trailing edge x=\(expectedColumn): the two overlap or leave a gap. Measured edges so far: \(edges)."
            )
            if step < OnboardingStep.allCases.count - 1 {
                pressDefaultButton(in: window)
                settle(window, seconds: 1.0)
            }
        }

        XCTAssertEqual(
            Set(signatures).count, OnboardingStep.allCases.count,
            "The control column rendered identically on \(OnboardingStep.allCases.count - Set(signatures).count + 1) of the \(OnboardingStep.allCases.count) passes, so the sweep never advanced through every step and the measurements above are not per-step."
        )
    }

    /// True when every sampled pixel in the rectangle matches `background` (the column surface).
    private func isFlat(_ image: RenderedImage, xs: Range<Int>, ys: [Int], background: RGBA) -> Bool {
        for x in xs {
            for y in ys where isOnboardingContent(image.color(atX: x, y: y), background: background) {
                return false
            }
        }
        return true
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingStageHidesBelow640AndTheColumnFillsTheWindow

    func testOnboardingStageHidesBelow640AndTheColumnFillsTheWindow() throws {
        let width = 600
        let window = makeOnboardingWindow(width: CGFloat(width), height: 560)
        guard let image = capture(window) else {
            throw TestStopped("Could not capture this process's own window pixels on this machine.")
        }
        // (2, 40) is bare column surface. With the stage hidden, the right-hand strip is the same surface.
        let background = windowBackground(image)
        let rows = Array(stride(from: 60, to: 500, by: 4))
        XCTAssertTrue(
            isFlat(image, xs: (width - 60)..<(width - 6), ys: rows, background: background),
            "In a \(width)pt-wide window (below the 640pt stage threshold) the right edge still shows stage artwork instead of the control column filling the window."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingStageShowsAt640WithAColumnInRange

    func testOnboardingStageShowsAt640WithAColumnInRange() throws {
        let width = 640
        let window = makeOnboardingWindow(width: CGFloat(width), height: 560)
        guard let measured = settledMeasurement(window) else {
            throw TestStopped("Could not capture this process's own window pixels on this machine.")
        }
        XCTAssertEqual(
            measured.edge, 380, accuracy: 1,
            "At \(width)pt the column should be its 380pt floor (half the window is 320); the art starts at x=\(measured.edge)."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingNothingClipsAtTheMinimumWindowSize

    func testOnboardingNothingClipsAtTheMinimumWindowSize() throws {
        let width = 420
        let height = 400
        let window = makeOnboardingWindow(width: CGFloat(width), height: CGFloat(height))
        guard let image = capture(window) else {
            throw TestStopped("Could not capture this process's own window pixels on this machine.")
        }
        let background = windowBackground(image)

        // The 28pt column padding must stay clear of content on both sides: anything touching the edge is clipped.
        let rows = Array(stride(from: 60, to: height - 40, by: 4))
        XCTAssertTrue(
            isFlat(image, xs: (width - 14)..<(width - 2), ys: rows, background: background),
            "Content reaches the right edge of a \(width)x\(height) window: the column is clipping."
        )
        XCTAssertTrue(
            isFlat(image, xs: 2..<14, ys: rows, background: background),
            "Content reaches the left edge of a \(width)x\(height) window: the column is clipping."
        )

        // The navigation row lives in the bottom strip and must still be drawn there.
        var navigationDrawn = false
        for y in stride(from: height - 70, to: height - 10, by: 2) {
            for x in stride(from: 20, to: width - 20, by: 2)
            where isOnboardingContent(image.color(atX: x, y: y), background: background) {
                navigationDrawn = true
            }
        }
        XCTAssertTrue(navigationDrawn, "The navigation row is not visible in the bottom strip of a \(width)x\(height) window: it is clipped off.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingArtworkPanelStartsAtTheWindowsVeryTopEdge
    func testOnboardingArtworkPanelStartsAtTheWindowsVeryTopEdge() throws {
        let (window, _) = makeOnboardingWindow()
        guard let image = capture(window) else {
            throw TestStopped("Could not capture this process's own window pixels on this machine.")
        }

        let background = windowBackground(image)
        let sampleX = 700
        var firstArtworkRow: Int?
        for y in 0..<80 where isOnboardingContent(image.color(atX: sampleX, y: y), background: background) {
            firstArtworkRow = y
            break
        }

        guard let firstArtworkRow else {
            return XCTFail("No artwork found in the top 80pt at x=\(sampleX): the artwork panel is not drawn at all.")
        }
        XCTAssertLessThanOrEqual(
            firstArtworkRow, 1,
            "Artwork starts at y=\(firstArtworkRow)pt; rows above it are bare window background \(background)."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingWindowAndOnboardingViewAgreeOn880x560
    func testOnboardingWindowAndOnboardingViewAgreeOn880x560() throws {
        let (window, hosting) = makeOnboardingWindow()
        XCTAssertEqual(window.frame.size, NSSize(width: 880, height: 560), "window is \(window.frame.size)")
        XCTAssertEqual(
            hosting.frame.size, window.contentRect(forFrameRect: window.frame).size,
            "hosting view is \(hosting.frame.size), content rect is \(window.contentRect(forFrameRect: window.frame).size)"
        )

        guard let image = capture(window) else {
            throw TestStopped("Could not capture this process's own window pixels on this machine.")
        }
        // Inset from the window's rounded corner, which captures as transparent.
        let corner = image.color(atX: 856, y: 536)
        XCTAssertTrue(
            isOnboardingContent(corner, background: windowBackground(image)),
            "The bottom-right corner read \(corner), the bare window background: OnboardingView is drawn smaller than the window."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingWindowKeepsAUsableCloseButtonOverTheLeftPanel
    func testOnboardingWindowKeepsAUsableCloseButtonOverTheLeftPanel() throws {
        let (window, _) = makeOnboardingWindow()
        guard let close = window.standardWindowButton(.closeButton) else {
            return XCTFail("The onboarding window has no close button, so the documented skip path is unreachable.")
        }
        XCTAssertFalse(close.isHidden, "The close button is the skip path; it must never be hidden.")
        XCTAssertTrue(close.isEnabled, "The close button is disabled, so there is no way out of the flow.")

        // Read from the render, never a hardcoded 420: a copied literal keeps passing after the real column narrows.
        guard let measured = settledMeasurement(window) else {
            throw TestStopped("Could not capture this process's own window pixels on this machine.")
        }

        let inWindow = close.convert(close.bounds, to: nil)
        XCTAssertLessThanOrEqual(
            inWindow.maxX, CGFloat(measured.edge),
            "The close button ends at x=\(inWindow.maxX), past the artwork panel's real left edge x=\(measured.edge)."
        )
        XCTAssertGreaterThan(
            inWindow.minY, window.frame.height - 44,
            "The close button sits at y=\(inWindow.minY), below the window's top strip."
        )
    }
}
