//  content:: learns visibility from AppKit occlusion notifications, which answer
//  HIDDEN for SwiftUI's windowless NSViewRepresentable container -- tests run on real compositor pixels.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumPaneVisibilityLiveTests: XCTestCase {

    private static let pageHTML = "<html><body style=\"margin:0;background:#112233\"></body></html>"
    private static let captureSize = CGSize(width: 320, height: 240)
    private static let paneRect = NSRect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - Real pixels

    private static func centrePixel(of contents: ChromiumWebContents) async -> (red: Int, green: Int, blue: Int)? {
        guard let image = await contents.capturePreview(rect: nil, size: captureSize),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let colour = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                  .usingColorSpace(.deviceRGB)
        else { return nil }
        return (
            Int((colour.redComponent * 255).rounded()),
            Int((colour.greenComponent * 255).rounded()),
            Int((colour.blueComponent * 255).rounded())
        )
    }

    // #112233 == (17, 34, 51), with room for colour management.
    private static func isPageColour(_ pixel: (red: Int, green: Int, blue: Int)?) -> Bool {
        guard let pixel else { return false }
        return abs(pixel.red - 17) <= 12 && abs(pixel.green - 34) <= 12 && abs(pixel.blue - 51) <= 12
    }

    private static func waitForPageColour(_ contents: ChromiumWebContents, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if isPageColour(await centrePixel(of: contents)) { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func waitUntilNoPageColour(_ contents: ChromiumWebContents, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if !isPageColour(await centrePixel(of: contents)) { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - The two container shapes a pane puts the engine view in

    private static func makeOnScreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: paneRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: paneRect)
        window.orderFrontRegardless()
        return window
    }

    // The same adoption LiveWebContentsHostView.embed(_:in:) performs.
    private static func adopt(_ view: NSView, into container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
    }

    // MARK: - Tests

    /// Carries its own negative control: `wentDark` proves AppKit really does
    /// take the frame away, so `cameBack` proves the declaration works, not that nothing went wrong.
    func testAdoptionIntoAWindowlessContainerDarkensTheTabUntilThePaneDeclaresItVisible() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let outcome = try LiveChromiumEngineHost.runLive(timeout: 180) { () -> (Bool, Bool, Bool) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            let window = Self.makeOnScreenWindow()
            defer { window.orderOut(nil) }
            let pane = NSView(frame: Self.paneRect)
            window.contentView?.addSubview(pane)
            Self.adopt(contents.view, into: pane)
            contents.setVisible(true)

            contents.loadHTML(Self.pageHTML, baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let renderedOnScreen = await Self.waitForPageColour(contents, timeout: .seconds(20))

            // Exactly the shape NSViewRepresentable.makeNSView hands a pane:
            // a container that is not in a window, and may never be put in one.
            let windowless = NSView(frame: Self.paneRect)
            Self.adopt(contents.view, into: windowless)
            let wentDark = await Self.waitUntilNoPageColour(contents, timeout: .seconds(15))

            contents.setVisible(true)
            let cameBack = await Self.waitForPageColour(contents, timeout: .seconds(20))

            return (renderedOnScreen, wentDark, cameBack)
        }

        XCTAssertTrue(
            outcome.0,
            "test precondition: the tab never rendered its own background colour while its view was in an on-screen window"
        )
        XCTAssertTrue(
            outcome.1,
            "negative control: moving the engine view into a windowless container no longer takes the tab's frame away, so this test can no longer tell a working declaration from a defect that has gone latent — re-derive it before trusting the assertion below"
        )
        XCTAssertTrue(
            outcome.2,
            "the pane declared the contents visible and the compositor never produced a frame again — a tab in this state paints nothing and capturePreview returns nil, which is exactly the blank content pane"
        )
    }

    /// The defect is intermittent in the app since it depends on where the
    /// engine view happens to be when AppKit decides; repeating it makes the ordering happen every time.
    func testTwentyConsecutiveWindowlessAdoptionsAllKeepTheTabRendering() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let outcome = try LiveChromiumEngineHost.runLive(timeout: 480) { () -> (darkened: Int, failures: [Int]) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            let window = Self.makeOnScreenWindow()
            defer { window.orderOut(nil) }
            let pane = NSView(frame: Self.paneRect)
            window.contentView?.addSubview(pane)
            Self.adopt(contents.view, into: pane)
            contents.setVisible(true)

            contents.loadHTML(Self.pageHTML, baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            _ = await Self.waitForPageColour(contents, timeout: .seconds(20))

            var failures: [Int] = []
            var darkened = 0
            for iteration in 1...20 {
                let windowless = NSView(frame: Self.paneRect)
                Self.adopt(contents.view, into: windowless)
                // Waited for on purpose: capturing before AppKit's answer
                // landed would pass without the declaration below doing anything.
                if await Self.waitUntilNoPageColour(contents, timeout: .seconds(6)) {
                    darkened += 1
                }
                contents.setVisible(true)
                if await !Self.waitForPageColour(contents, timeout: .seconds(10)) {
                    failures.append(iteration)
                }
                Self.adopt(contents.view, into: pane)
                contents.setVisible(true)
            }
            return (darkened, failures)
        }

        XCTAssertGreaterThan(
            outcome.darkened,
            0,
            "negative control: not one of the 20 adoptions into a windowless container took the tab's frame away, so this test proved nothing about the declaration that follows each one"
        )
        XCTAssertEqual(
            outcome.failures,
            [],
            "the tab stopped rendering after being adopted into a pane container that had no window yet, on these iterations"
        )
    }
}
