//  Live coverage for capturePreview, zoom, find-in-page, cookies. Each test
//  proves the real C++ round trip, not just that the Swift call returns without throwing.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitEngineSurfaceLiveTests: XCTestCase {

    // MARK: - capturePreview

    func testCapturePreviewCapturesTheRealRenderedPageColor() throws {
        let sampled = try WebKitLiveEngineHost.runLive { () -> (width: Int, height: Int, red: Int, green: Int, blue: Int)? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)

            contents.loadHTML("<html><body style=\"margin:0;background:#112233\"></body></html>", baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            // capturePreview reads the compositor's latest surface, which can
            // lag one or two frames behind the DOM commit above.
            try await Task.sleep(for: .milliseconds(300))

            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: 320, height: 240)) else { return nil }
            guard let sample = ImagePixelSampler.sample(image) else { return nil }
            return (sample.width, sample.height, sample.pixel.red, sample.pixel.green, sample.pixel.blue)
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
        try WebKitLiveEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-zoom-test</body></html>"),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer {
                contents.setZoomFactor(1.0)
                contents.close()
            }
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
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
        let (firstMatchCount, firstOrdinal, secondOrdinal, caseSensitiveMatchCount) = try WebKitLiveEngineHost.runLive {
            () -> (Int, Int, Int, Int) in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
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
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

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

    // MARK: - Find walk

    private static func find(
        _ contents: WebKitWebContents,
        _ delegate: FindResultRecordingDelegate,
        _ text: String,
        forward: Bool = true,
        matchCase: Bool = false,
        findNext: Bool
    ) async throws -> FindResult {
        delegate.reset()
        contents.find(text, options: FindOptions(forward: forward, matchCase: matchCase, findNext: findNext))
        let deadline = ContinuousClock.now + .seconds(10)
        while delegate.results.last?.isFinalUpdate != true {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "find(\(text)) never produced a final result")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try XCTUnwrap(delegate.results.last)
    }

    private static func loadFindPage(_ html: String) async throws -> (WebKitWebContents, FindResultRecordingDelegate) {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
        let delegate = FindResultRecordingDelegate()
        contents.delegate = delegate
        contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        contents.loadHTML(html, baseURL: nil)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        return (contents, delegate)
    }

    func testFindWalksForwardAndBackwardAndWrapsAtBothEnds() throws {
        let ordinals = try WebKitLiveEngineHost.runLive { () -> (forward: [Int], backward: [Int], counts: Set<Int>) in
            let (contents, delegate) = try await Self.loadFindPage(
                "<html><body><p>orbitneedle one</p><p>two Orbitneedle</p><p>three ORBITNEEDLE</p></body></html>"
            )
            defer { contents.close() }
            var forward: [Int] = []
            var counts: Set<Int> = []
            let first = try await Self.find(contents, delegate, "orbitneedle", findNext: false)
            forward.append(first.activeMatchOrdinal)
            counts.insert(first.matchCount)
            for _ in 0..<3 {
                let next = try await Self.find(contents, delegate, "orbitneedle", findNext: true)
                forward.append(next.activeMatchOrdinal)
                counts.insert(next.matchCount)
            }
            var backward: [Int] = []
            for _ in 0..<3 {
                let previous = try await Self.find(contents, delegate, "orbitneedle", forward: false, findNext: true)
                backward.append(previous.activeMatchOrdinal)
                counts.insert(previous.matchCount)
            }
            return (forward, backward, counts)
        }
        XCTAssertEqual(ordinals.forward, [1, 2, 3, 1], "forward find must visit each match in order and wrap from the last to the first")
        XCTAssertEqual(ordinals.backward, [3, 2, 1], "backward find from the first match wraps to the last, then walks back")
        XCTAssertEqual(ordinals.counts, [3], "the match count must stay the real number of occurrences")
    }

    func testFindCountsMatchesAcrossFormattingAndIgnoresHiddenText() throws {
        let counted = try WebKitLiveEngineHost.runLive { () -> (visible: Int, split: Int, none: FindResult) in
            let (contents, delegate) = try await Self.loadFindPage(
                """
                <html><body><p>orbit<b>need</b>le</p><p>orbitneedle</p>
                <p style="display:none">orbitneedle</p><script>var hidden = "orbitneedle";</script>
                <p>orbit      needle</p></body></html>
                """
            )
            defer { contents.close() }
            let visible = try await Self.find(contents, delegate, "orbitneedle", findNext: false)
            contents.stopFinding(clearSelection: true)
            let split = try await Self.find(contents, delegate, "orbit needle", findNext: false)
            contents.stopFinding(clearSelection: true)
            let none = try await Self.find(contents, delegate, "absent-from-this-page", findNext: false)
            return (visible.matchCount, split.matchCount, none)
        }
        XCTAssertEqual(counted.visible, 2, "text split across inline elements counts once; hidden text and script text never count")
        XCTAssertEqual(counted.split, 1, "collapsed whitespace in the page matches a single space in the query")
        XCTAssertEqual(counted.none, FindResult(activeMatchOrdinal: 0, matchCount: 0, isFinalUpdate: true))
    }

    func testFindResultResolutionAdvancesWithoutASelectionAndWraps() {
        typealias Resolved = (count: Int, ordinal: Int)
        func resolve(_ counted: Resolved?, previous: Int, count: Int = 0, forward: Bool) -> Resolved {
            WebKitWebContents.resolveFindResult(counted: counted, previousOrdinal: previous, previousCount: count, forward: forward)
        }
        XCTAssertTrue(resolve((3, 2), previous: 1, forward: true) == (3, 2), "the page's own answer wins")
        XCTAssertTrue(resolve((3, 0), previous: 0, forward: true) == (3, 1), "no tracked position starts at the first match")
        XCTAssertTrue(resolve((3, 0), previous: 3, forward: true) == (3, 1), "forward wraps from the last match")
        XCTAssertTrue(resolve((3, 0), previous: 1, forward: false) == (3, 3), "backward wraps from the first match")
        XCTAssertTrue(resolve((3, 0), previous: 2, forward: false) == (3, 1))
        XCTAssertTrue(resolve(nil, previous: 0, forward: true) == (1, 1), "WebKit found a match the walker cannot see: report one, never none")
    }

    // MARK: - Cookies

    func testSetCookiesRoundTripsThroughTheRealCookieStoreAndDeleteRemovesIt() throws {
        try WebKitLiveEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-cookie-test</body></html>"),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
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
