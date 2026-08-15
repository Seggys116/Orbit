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

    /// `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK but still live, and captures this
    /// process's own windows under no Screen Recording grant — hence dlsym rather than a direct call.
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

    /// OnboardingView paints nothing behind its text column above the first glyph, so x=2, y=40 is
    /// the bare window background that an inset or an undersized root frame would also expose.
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
                throw XCTSkip("Could not capture this process's own window pixels on this machine.")
            }
            signatures.append(measured.signature)
            edges.append(measured.edge)
            XCTAssertEqual(
                measured.edge, 420,
                "Step \(step): the art panel starts at x=\(measured.edge), not the 420pt OnboardingView's control column is drawn at. Measured edges so far: \(edges)."
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

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingControlColumnKeepsItsWidthInAWindowNarrowerThan880

    func testOnboardingControlColumnKeepsItsWidthInAWindowNarrowerThan880() throws {
        let width = 600
        let window = makeOnboardingWindow(width: CGFloat(width), height: 560)
        guard let measured = settledMeasurement(window) else {
            throw XCTSkip("Could not capture this process's own window pixels on this machine.")
        }
        XCTAssertGreaterThanOrEqual(
            measured.edge, 415,
            "In a \(width)pt-wide window the art panel starts at x=\(measured.edge), taking \(width - measured.edge)pt of \(width): OnboardingView's root frame is centring an 880pt layout and clipping the control column instead of letting the art give up its own width."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testOnboardingArtworkPanelStartsAtTheWindowsVeryTopEdge
    func testOnboardingArtworkPanelStartsAtTheWindowsVeryTopEdge() throws {
        let (window, _) = makeOnboardingWindow()
        guard let image = capture(window) else {
            throw XCTSkip("Could not capture this process's own window pixels on this machine.")
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
            throw XCTSkip("Could not capture this process's own window pixels on this machine.")
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
            throw XCTSkip("Could not capture this process's own window pixels on this machine.")
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
