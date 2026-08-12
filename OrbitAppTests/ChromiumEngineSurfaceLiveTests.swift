//  Live coverage for capturePreview, zoom, find-in-page, cookies. Each test
//  proves the real C++ round trip, not just that the Swift call returns without throwing.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumEngineSurfaceLiveTests: XCTestCase {

    // MARK: - capturePreview

    func testCapturePreviewCapturesTheRealRenderedPageColor() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let sampled = try LiveChromiumEngineHost.runLive { () -> (width: Int, height: Int, red: Int, green: Int, blue: Int)? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)

            contents.loadHTML("<html><body style=\"margin:0;background:#112233\"></body></html>", baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            // capturePreview reads the compositor's latest surface, which can
            // lag one or two frames behind the DOM commit above.
            try await Task.sleep(for: .milliseconds(300))

            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: 320, height: 240)) else { return nil }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            let x = bitmap.pixelsWide / 2
            let y = bitmap.pixelsHigh / 2
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
            return (
                bitmap.pixelsWide, bitmap.pixelsHigh,
                Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded())
            )
        }

        let result = try XCTUnwrap(sampled, "capturePreview returned nil, or its image could not be read back as a bitmap")
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
        // #112233 == (17, 34, 51); a few units of tolerance for colour management.
        XCTAssertEqual(result.red, 17, accuracy: 12, "captured pixel red channel did not match the page's real background colour")
        XCTAssertEqual(result.green, 34, accuracy: 12, "captured pixel green channel did not match the page's real background colour")
        XCTAssertEqual(result.blue, 51, accuracy: 12, "captured pixel blue channel did not match the page's real background colour")
    }

    // MARK: - Zoom

    func testSetZoomFactorChangesTheRealHostZoomLevelAndReportsItBack() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-zoom-test</body></html>"),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer {
                contents.setZoomFactor(1.0)
                contents.close()
            }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            XCTAssertEqual(contents.zoomFactor, 1.0, accuracy: 0.01, "test precondition: default zoom")

            contents.setZoomFactor(1.5)
            let deadline = ContinuousClock.now + .seconds(10)
            while abs(contents.zoomFactor - 1.5) > 0.01 {
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(contents.zoomFactor, 1.5, accuracy: 0.01, "setZoomFactor(1.5) never reported back through zoomFactorChanged")
        }
    }

    // MARK: - Find in page

    @MainActor
    private final class FindResultRecordingDelegate: WebContentsDelegate {
        private(set) var results: [FindResult] = []
        func webContents(_ contents: WebContents, didUpdateFindResult result: FindResult) {
            results.append(result)
        }
        func reset() { results.removeAll() }
    }

    func testFindInPageReportsRealMatchCountsAndAdvancesBetweenMatches() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (firstMatchCount, firstOrdinal, secondOrdinal, caseSensitiveMatchCount) = try LiveChromiumEngineHost.runLive {
            () -> (Int, Int, Int, Int) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            let delegate = FindResultRecordingDelegate()
            contents.delegate = delegate
            // Blink's FindInPage::Find reports "0 matches, final" immediately
            // for a frame with no visible content (WebLocalFrameImpl::
            // HasVisibleContent requires view->Width() > 0 && Height() > 0) --
            // a zero-sized NSView never gets a real layout viewport, same
            // reason capturePreview above sets a frame before loading.
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)

            contents.loadHTML(
                "<html><body><p>orbitneedle bravo orbitneedle charlie orbitneedle</p></body></html>",
                baseURL: nil
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            contents.find("orbitneedle", options: FindOptions(forward: true, matchCase: false, findNext: false))
            let firstDeadline = ContinuousClock.now + .seconds(10)
            while delegate.results.isEmpty || delegate.results.last?.isFinalUpdate == false {
                guard ContinuousClock.now < firstDeadline else { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let first = try XCTUnwrap(delegate.results.last, "the first find(_:options:) never produced a find result")

            delegate.reset()
            contents.find("orbitneedle", options: FindOptions(forward: true, matchCase: false, findNext: true))
            let secondDeadline = ContinuousClock.now + .seconds(10)
            while delegate.results.isEmpty || delegate.results.last?.isFinalUpdate == false {
                guard ContinuousClock.now < secondDeadline else { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let second = try XCTUnwrap(delegate.results.last)

            contents.stopFinding(clearSelection: true)

            delegate.reset()
            contents.find("ORBITNEEDLE", options: FindOptions(forward: true, matchCase: true, findNext: false))
            let thirdDeadline = ContinuousClock.now + .seconds(10)
            while delegate.results.isEmpty || delegate.results.last?.isFinalUpdate == false {
                guard ContinuousClock.now < thirdDeadline else { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let third = try XCTUnwrap(delegate.results.last, "the case-sensitive, non-matching find(_:options:) never produced a find result")

            return (first.matchCount, first.activeMatchOrdinal, second.activeMatchOrdinal, third.matchCount)
        }

        XCTAssertEqual(firstMatchCount, 3, "the real page has exactly 3 occurrences of the search term")
        XCTAssertEqual(firstOrdinal, 1, "the first find must land on the first match")
        XCTAssertEqual(secondOrdinal, 2, "findNext must advance to the second match")
        XCTAssertEqual(caseSensitiveMatchCount, 0, "a case-sensitive search for the wrong case must match nothing on an all-lowercase page")
    }

    // MARK: - Cookies

    func testSetCookiesRoundTripsThroughTheRealCookieStoreAndDeleteRemovesIt() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-cookie-test</body></html>"),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let session = engine.defaultSession
            let cookieURL = server.baseURL

            let accepted = await session.setCookies([
                EngineCookie(name: "orbit_live_cookie", value: "orbit_live_value", domain: "127.0.0.1", path: "/"),
            ])
            XCTAssertEqual(accepted, 1, "the real cookie store refused a well-formed cookie")

            let read = await session.cookies(for: cookieURL)
            let match = try XCTUnwrap(read.first { $0.name == "orbit_live_cookie" }, "the cookie just set was not read back from the real cookie store")
            XCTAssertEqual(match.value, "orbit_live_value")

            await session.deleteCookies(for: cookieURL)
            let afterDelete = await session.cookies(for: cookieURL)
            XCTAssertFalse(afterDelete.contains { $0.name == "orbit_live_cookie" }, "deleteCookies did not remove the cookie from the real cookie store")
        }
    }
}
