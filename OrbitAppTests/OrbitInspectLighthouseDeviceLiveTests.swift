// Runs Lighthouse against a real responsive page in the pane exactly as the app composes it (inspector, device stage,
// web view), and checks that the page is laid out, measured and photographed at the chosen device's viewport, and
// that the tab is put back afterwards: size, user agent, zoom and scroll position.

import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class OrbitInspectLighthouseDeviceLiveTests: XCTestCase {

    /// Below 600 CSS px the page turns red and grows a 700 px wide strip; above it, it is blue and fits. Every load
    /// appends what it saw to sessionStorage, which survives the run's reloads, so the test can read what the page
    /// itself measured while the run had it.
    private static let pageHTML = """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8"><title>Responsive fixture</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="A responsive page for the Lighthouse device test">
    <style>
      html, body { margin: 0; padding: 0; }
      body { background: rgb(0, 0, 255); min-height: 3000px; }
      #wide { display: none; }
      @media (max-width: 600px) {
        body { background: rgb(255, 0, 0); }
        #wide { display: block; width: 700px; height: 4px; background: rgb(255, 0, 0); }
      }
    </style></head>
    <body><main><div id="wide"></div></main>
    <script>
      var seen = JSON.parse(sessionStorage.getItem('seen') || '[]');
      seen.push([innerWidth, innerHeight, matchMedia('(max-width: 600px)').matches, navigator.userAgent]);
      sessionStorage.setItem('seen', JSON.stringify(seen));
    </script></body></html>
    """

    private func waitUntil(
        _ description: String, timeout: Duration = .seconds(10), _ predicate: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for: \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private struct TabState: Equatable {
        var innerWidth: Double
        var innerHeight: Double
        var scrollY: Double
        var userAgent: String
        var customUserAgent: String?
        var pageZoom: CGFloat
    }

    private func tabState(_ session: OrbitInspectSession, _ contents: WebKitWebContents) async throws -> TabState {
        let values = try await session.evaluate("[innerWidth, innerHeight, scrollY, navigator.userAgent]") as? [Any]
        let list = try XCTUnwrap(values)
        return TabState(
            innerWidth: (list[0] as? NSNumber)?.doubleValue ?? -1,
            innerHeight: (list[1] as? NSNumber)?.doubleValue ?? -1,
            scrollY: (list[2] as? NSNumber)?.doubleValue ?? -1,
            userAgent: list[3] as? String ?? "",
            customUserAgent: contents.webView.customUserAgent,
            pageZoom: contents.webView.pageZoom
        )
    }

    /// What every load of the page recorded: [innerWidth, innerHeight, narrow media query matched, user agent].
    private func pageLog(_ session: OrbitInspectSession) async throws -> [[Any]] {
        let json = try await session.evaluate("sessionStorage.getItem('seen') || '[]'") as? String
        let data = try XCTUnwrap(json?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[Any]])
    }

    /// The colour at the middle of the picture, as 0-255 sRGB.
    private func centreColour(_ jpeg: Data) throws -> (r: Double, g: Double, b: Double) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        let colour = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return (Double(colour.redComponent) * 255, Double(colour.greenComponent) * 255, Double(colour.blueComponent) * 255)
    }

    private func imageSize(_ jpeg: Data) throws -> CGSize {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    /// Hosts the tab in the real page pane, opens Lighthouse, zooms and scrolls the page so the restore has something to prove, runs once, and hands over the report with the tab states before and after.
    private func runLighthouse(
        device: LHDevice,
        _ check: @escaping (LHReport, OrbitInspectSession, _ before: TabState, _ after: TabState) async throws -> Void
    ) throws {
        try WebKitLiveEngineHost.runLive(timeout: 150) {
            let server = try LiveHTTPTestServer(routes: ["/": .init(contentType: "text/html; charset=utf-8", body: Self.pageHTML)])
            let contents = try await WebKitLiveEngineHost.makeContents()
            let size = NSSize(width: 1000, height: 900)
            let host = NSHostingView(rootView: WebContentsHostView(contents: contents).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            contents.setVisible(true)
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            let lighthouse = session.lighthouse
            let savedDevice = lighthouse.device
            defer {
                lighthouse.device = savedDevice
                OrbitDevToolsStore.shared.close(contents)
                server.stop()
                window.orderOut(nil)
                contents.close()
            }
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("agent hello") { session.pageURL.hasPrefix("http") }
            OrbitDevToolsStore.shared.open(contents, panel: .lighthouse, inspectAt: nil, armPicker: false)
            session.dock = .bottom
            session.select(panel: .lighthouse)
            if session.device.isActive { session.toggleDeviceToolbar() }

            contents.webView.pageZoom = 1.1
            _ = try await session.evaluate("window.scrollTo(0, 400); 1")
            try await self.waitUntil("the page scrolled") { try await self.tabState(session, contents).scrollY >= 399 }
            let before = try await self.tabState(session, contents)
            XCTAssertGreaterThan(before.innerWidth, 600, "the pane must start wider than the phone breakpoint")
            XCTAssertFalse(before.userAgent.contains("iPhone"))

            lighthouse.device = device
            lighthouse.runMode = .navigation
            lighthouse.runCount = 1
            lighthouse.startRun()
            try await self.waitUntil("the report", timeout: .seconds(90)) {
                if case .failed(let reason) = lighthouse.runState {
                    XCTFail("the run failed: \(reason)")
                    throw CancellationError()
                }
                return lighthouse.currentReport != nil
            }
            let report = try XCTUnwrap(lighthouse.currentReport)
            XCTAssertFalse(session.device.isActive, "the device toolbar must be off again, as it was before the run")
            XCTAssertFalse(session.device.isBorrowed)
            try await self.waitUntil("the tab's own layout back", timeout: .seconds(5)) {
                let now = try await self.tabState(session, contents)
                return abs(now.innerWidth - before.innerWidth) < 1 && abs(now.scrollY - before.scrollY) < 1
            }
            let after = try await self.tabState(session, contents)
            try await check(report, session, before, after)
        }
    }

    func testMobileRunRendersMeasuresAndCapturesThePhoneLayoutThenRestoresTheTab() throws {
        try runLighthouse(device: .mobile) { report, session, before, after in
            XCTAssertEqual(report.device, .mobile)

            // What the page itself measured while the run had it.
            let log = try await self.pageLog(session)
            let during = try XCTUnwrap(log.first { ($0[0] as? NSNumber)?.doubleValue == 412 }, "no load saw a 412 px viewport: \(log)")
            XCTAssertEqual((during[1] as? NSNumber)?.doubleValue, 823)
            XCTAssertEqual(during[2] as? Bool, true, "the phone media query must match during the run")
            XCTAssertTrue((during[3] as? String)?.contains("iPhone") == true, "the run's reload must send the mobile user agent")
            let last = try XCTUnwrap(log.last)
            XCTAssertEqual((last[0] as? NSNumber)?.doubleValue ?? 0, before.innerWidth, accuracy: 1, "the page was not reloaded back at its own size")
            XCTAssertFalse((last[3] as? String)?.contains("iPhone") == true, "the page the user is left with must come from the desktop user agent")

            let emulation = try XCTUnwrap(report.emulation)
            XCTAssertTrue(emulation.viewportApplied, "measured \(emulation.measuredWidth) x \(emulation.measuredHeight)")
            XCTAssertEqual(emulation.measuredWidth, 412)
            XCTAssertEqual(emulation.measuredHeight, 823)
            XCTAssertEqual(emulation.measuredDPR, 1.75)
            XCTAssertTrue(emulation.measuredMobileAgent)
            XCTAssertGreaterThan(emulation.measuredTouchPoints, 0)
            XCTAssertEqual(emulation.problems, [])

            // The preview is the emulated rendering: phone-shaped, at the phone's pixel ratio, in the phone's colours.
            let shot = try XCTUnwrap(report.visuals?.screenshot, report.visuals?.note ?? "no screenshot")
            XCTAssertEqual(shot.viewportWidth, 412)
            XCTAssertEqual(shot.pixelWidth, 721, "412 CSS px at DPR 1.75")
            XCTAssertEqual(Double(shot.pixelHeight) / Double(shot.pixelWidth), 823.0 / 412.0, accuracy: 0.02)
            let colour = try self.centreColour(shot.jpeg)
            XCTAssertGreaterThan(colour.r, 200, "the screenshot shows the desktop layout: \(colour)")
            XCTAssertLessThan(colour.b, 60, "the screenshot shows the desktop layout: \(colour)")

            let frames = try XCTUnwrap(report.visuals?.filmstrip, "no filmstrip")
            XCTAssertFalse(frames.isEmpty)
            let lastFrame = try self.imageSize(try XCTUnwrap(frames.last).jpeg)
            XCTAssertEqual(lastFrame.height / lastFrame.width, 823.0 / 412.0, accuracy: 0.03, "the filmstrip must be the phone viewport")
            XCTAssertGreaterThan(try self.centreColour(try XCTUnwrap(frames.last).jpeg).r, 200)

            // Layout-dependent audits now describe the phone: the 700 px strip overflows a 412 px viewport.
            let width = try XCTUnwrap(report.audits.first { $0.id == "content-width" })
            XCTAssertEqual(width.status, .fail, width.displayValue)
            XCTAssertEqual(width.numericValue ?? 0, 700, accuracy: 1)
            XCTAssertTrue(width.items.contains { $0.selector?.contains("wide") == true && ($0.nodeID ?? 0) > 0 },
                          "the strip must be listed and revealable: \(width.items.map { $0.selector ?? "" })")

            XCTAssertEqual(after.innerWidth, before.innerWidth, accuracy: 1)
            XCTAssertEqual(after.innerHeight, before.innerHeight, accuracy: 1)
            XCTAssertEqual(after.scrollY, before.scrollY, accuracy: 1)
            XCTAssertEqual(after.userAgent, before.userAgent)
            XCTAssertEqual(after.customUserAgent, before.customUserAgent)
            XCTAssertEqual(after.pageZoom, before.pageZoom, accuracy: 0.001)
            let emulatedDPR = try await session.evaluate("devicePixelRatio") as? Double
            XCTAssertNotEqual(emulatedDPR, 1.75, "the emulated pixel ratio was left on the page")
        }
    }

    func testDesktopRunRendersAtTheDesktopViewportThenRestoresTheTab() throws {
        try runLighthouse(device: .desktop) { report, session, before, after in
            XCTAssertEqual(report.device, .desktop)

            let log = try await self.pageLog(session)
            let during = try XCTUnwrap(log.first { ($0[0] as? NSNumber)?.doubleValue == 1350 }, "no load saw a 1350 px viewport: \(log)")
            XCTAssertEqual((during[1] as? NSNumber)?.doubleValue, 940)
            XCTAssertEqual(during[2] as? Bool, false)
            XCTAssertFalse((during[3] as? String)?.contains("iPhone") == true)

            let emulation = try XCTUnwrap(report.emulation)
            XCTAssertTrue(emulation.viewportApplied, "measured \(emulation.measuredWidth) x \(emulation.measuredHeight)")
            XCTAssertEqual(emulation.measuredDPR, 1)
            XCTAssertFalse(emulation.measuredMobileAgent)
            XCTAssertEqual(emulation.problems, [])

            let shot = try XCTUnwrap(report.visuals?.screenshot, report.visuals?.note ?? "no screenshot")
            XCTAssertEqual(shot.viewportWidth, 1350)
            XCTAssertEqual(shot.pixelWidth, 1350)
            XCTAssertEqual(Double(shot.pixelHeight) / Double(shot.pixelWidth), 940.0 / 1350.0, accuracy: 0.02)
            let colour = try self.centreColour(shot.jpeg)
            XCTAssertGreaterThan(colour.b, 200, "the screenshot does not show the desktop layout: \(colour)")
            XCTAssertLessThan(colour.r, 60, "the screenshot does not show the desktop layout: \(colour)")

            XCTAssertEqual(report.audits.first { $0.id == "content-width" }?.status, .pass)
            XCTAssertEqual(report.audits.first { $0.id == "font-size" }?.status, .notApplicable)

            XCTAssertEqual(after.innerWidth, before.innerWidth, accuracy: 1)
            XCTAssertEqual(after.scrollY, before.scrollY, accuracy: 1)
            XCTAssertEqual(after.userAgent, before.userAgent)
            XCTAssertEqual(after.customUserAgent, before.customUserAgent)
            XCTAssertEqual(after.pageZoom, before.pageZoom, accuracy: 0.001)
        }
    }

    /// Cancelling mid-run must put the tab back at once, not when the cancelled task next wakes.
    func testCancellingAMobileRunRestoresTheTab() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let server = try LiveHTTPTestServer(routes: ["/": .init(contentType: "text/html; charset=utf-8", body: Self.pageHTML)])
            let contents = try await WebKitLiveEngineHost.makeContents()
            let size = NSSize(width: 1000, height: 900)
            let host = NSHostingView(rootView: WebContentsHostView(contents: contents).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            contents.setVisible(true)
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            let lighthouse = session.lighthouse
            let savedDevice = lighthouse.device
            defer {
                lighthouse.device = savedDevice
                OrbitDevToolsStore.shared.close(contents)
                server.stop()
                window.orderOut(nil)
                contents.close()
            }
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("agent hello") { session.pageURL.hasPrefix("http") }
            OrbitDevToolsStore.shared.open(contents, panel: .lighthouse, inspectAt: nil, armPicker: false)
            session.dock = .bottom
            session.select(panel: .lighthouse)
            let before = try await self.tabState(session, contents)

            lighthouse.device = .mobile
            lighthouse.runMode = .navigation
            lighthouse.startRun()
            try await self.waitUntil("the phone layout", timeout: .seconds(15)) {
                (try await session.evaluate("innerWidth") as? Double) == 412
            }
            lighthouse.cancelRun()
            XCTAssertFalse(session.device.isActive, "cancel must end the emulation at once")
            XCTAssertNil(contents.webView.customUserAgent.flatMap { $0.contains("iPhone") ? $0 : nil }, "the phone user agent was left on the tab")
            try await self.waitUntil("the tab's own layout back", timeout: .seconds(15)) {
                let now = try await self.tabState(session, contents)
                return abs(now.innerWidth - before.innerWidth) < 1 && !now.userAgent.contains("iPhone") && !contents.webView.isLoading
            }
            if case .running = lighthouse.runState { XCTFail("the run is still going after Cancel") }
        }
    }
}
