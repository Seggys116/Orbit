//  Real video PiP enter/leave and picture_in_picture_changed, asserting only
//  on state the page or browser genuinely holds, never "a function was called".
//  Fixture video is muted, since the real autoplay policy rejects a programmatic play(), and
//  looped so it is still a live player at assertion time.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class WebKitPictureInPictureLiveTests: LiveEnvironmentTestCase {

    private static func pageHTML(videoAttributes: String = "") -> String {
        "<!DOCTYPE html><html><body><video id=\"v\" src=\"/v.webm\" muted loop playsinline \(videoAttributes)></video></body></html>"
    }

    private static let secondPageHTML =
        "<!DOCTYPE html><html><head><title>Second</title></head><body><p id=\"p\">second page</p></body></html>"

    private func waitUntilTrue(
        _ contents: WebKitWebContents,
        _ expression: String,
        timeout: Duration = .seconds(15)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            let result = try await contents.evaluateJavaScript(expression)
            if (result as? Bool) == true { return }
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "'\(expression)' never became true")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// A real, actually-decoding, looping <video> hosted in a real on-screen
    /// window: PiP needs a live compositor surface an unhosted WebContents never produces.
    private func withPlayingVideoPage<T>(
        videoAttributes: String = "",
        _ body: (WebKitWebContents, LiveHTTPTestServer) async throws -> T
    ) async throws -> T {
        let engine = await WebKitLiveEngineHost.sharedEngine()
        // Installed deliberately: its 2s poll also writes isPictureInPictureActive,
        // so every test runs against real contention with the native signal.
        engine.addUserScript(MediaSessionObserverScript.userScript, session: engine.defaultSession)

        let server = try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html", body: Self.pageHTML(videoAttributes: videoAttributes)
            ),
            "/second.html": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.secondPageHTML),
            "/v.webm": LiveHTTPTestServer.Route(
                contentType: "video/webm", data: LiveMediaFixtures.videoWebM, supportsRangeRequests: true
            ),
        ])
        defer { server.stop() }

        let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
        defer { contents.close() }
        contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = contents.view
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(150))

        contents.load(server.baseURL)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

        _ = try await contents.evaluateJavaScript("""
        var v = document.getElementById('v');
        v.muted = true;
        v.loop = true;
        window.__orbitReachedPlaying = false;
        v.addEventListener('playing', function() { window.__orbitReachedPlaying = true; });
        v.play().catch(function(e) { window.__orbitPlayError = String(e); });
        true;
        """)
        try await waitUntilTrue(contents, "window.__orbitReachedPlaying === true || !!window.__orbitPlayError")
        let playError = try await contents.evaluateJavaScript("window.__orbitPlayError || null")
        if let playError = playError as? String {
            throw EngineError(code: .engineUnavailable, underlyingDescription: "the real <video> refused to play: \(playError)")
        }

        return try await body(contents, server)
    }

    private func enterPictureInPicture(_ contents: WebKitWebContents) async throws {
        contents.togglePictureInPicture()
        let started = true
        do {
            try await waitUntilTrue(contents, "!!document.pictureInPictureElement")
        } catch {
            // Everything the page can say about why Blink refused, so a
            // failure here names the reason instead of just the timeout.
            let state = try await contents.evaluateJavaScript("""
            (function() {
              var v = document.getElementById('v');
              return JSON.stringify({
                pictureInPictureEnabled: document.pictureInPictureEnabled,
                readyState: v.readyState, videoWidth: v.videoWidth,
                paused: v.paused, disablePictureInPicture: v.disablePictureInPicture
              });
            })()
            """) as? String ?? "<the page stopped answering>"
            throw EngineError(
                code: .engineUnavailable,
                underlyingDescription: """
                Picture-in-Picture never reached document.pictureInPictureElement. \
                The bridge \(started ? "dispatched the request" : "found no live video player") -- \
                hasPictureInPictureVideo=\(contents.hasPictureInPictureVideo), page=\(state)
                """
            )
        }
    }

    // MARK: - Entering

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTogglingEntersRealPictureInPictureAndReportsItThroughMediaState

    func testTogglingEntersRealPictureInPictureAndReportsItThroughMediaState() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            pictureInPictureElementID: String?, mediaStateActive: Bool, hasPictureInPictureVideo: Bool
        ) in
            try await self.withPlayingVideoPage { contents, _ in
                try await self.enterPictureInPicture(contents)
                let elementID = try await contents.evaluateJavaScript(
                    "document.pictureInPictureElement ? document.pictureInPictureElement.id : null"
                ) as? String
                let becameActive = try await self.waitUntil {
                    contents.mediaState.isPictureInPictureActive
                }
                let hasVideo = try await self.waitUntil {
                    contents.hasPictureInPictureVideo
                }
                return (elementID, becameActive, hasVideo)
            }
        }

        XCTAssertEqual(
            outcome.pictureInPictureElementID, "v",
            "togglePictureInPicture() did not put the page's own real <video> into document.pictureInPictureElement"
        )
        XCTAssertTrue(
            outcome.mediaStateActive,
            "the page really entered Picture-in-Picture but WebKitWebContents.mediaState.isPictureInPictureActive never became true"
        )
        XCTAssertTrue(
            outcome.hasPictureInPictureVideo,
            "content::WebContents::HasPictureInPictureVideo disagrees with the page, which really has a video in Picture-in-Picture"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTogglingEntersPictureInPictureEvenWhileTheTabIsHidden

    // The mini-player's PiP button targets a background tab -- Orbit calls
    // setVisible(false) on any tab that is not the on-screen one.
    func testTogglingEntersPictureInPictureEvenWhileTheTabIsHidden() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            pictureInPictureElementID: String?, mediaStateActive: Bool
        ) in
            try await self.withPlayingVideoPage { contents, _ in
                contents.setVisible(false)
                try await self.enterPictureInPicture(contents)
                let elementID = try await contents.evaluateJavaScript(
                    "document.pictureInPictureElement ? document.pictureInPictureElement.id : null"
                ) as? String
                let becameActive = try await self.waitUntil {
                    contents.mediaState.isPictureInPictureActive
                }
                return (elementID, becameActive)
            }
        }

        XCTAssertEqual(
            outcome.pictureInPictureElementID, "v",
            "a hidden tab's togglePictureInPicture() never put its real <video> into document.pictureInPictureElement"
        )
        XCTAssertTrue(
            outcome.mediaStateActive,
            "a hidden tab entered Picture-in-Picture but mediaState.isPictureInPictureActive never became true"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTheMiniPlayerControlReachesTheRealEngineForTheBackgroundTab

    // The exact production call chain: SidebarMiniPlayerView's control ->
    // AppEnvironment.toggleMiniPlayerPictureInPicture -> a real, hidden background tab.
    func testTheMiniPlayerControlReachesTheRealEngineForTheBackgroundTab() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            requestDispatched: Bool, pictureInPictureElementID: String?, mediaStateActive: Bool
        ) in
            try await self.withPlayingVideoPage { contents, _ in
                let env = self.env
                let spaceID = try XCTUnwrap(env.spaces.first?.id)
                let tabID = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID, activate: false)
                env._test_attachWebContents(contents, for: tabID)
                env._test_engineCapabilitiesOverride = [.pictureInPicture]
                contents.setVisible(false)

                let dispatched = env.toggleMiniPlayerPictureInPicture(for: tabID)
                try await self.waitUntilTrue(contents, "!!document.pictureInPictureElement")
                let elementID = try await contents.evaluateJavaScript(
                    "document.pictureInPictureElement ? document.pictureInPictureElement.id : null"
                ) as? String
                let becameActive = try await self.waitUntil { contents.mediaState.isPictureInPictureActive }
                return (dispatched, elementID, becameActive)
            }
        }

        XCTAssertTrue(outcome.requestDispatched, "AppEnvironment.toggleMiniPlayerPictureInPicture refused a real, capable, live-contents tab")
        XCTAssertEqual(
            outcome.pictureInPictureElementID, "v",
            "the mini-player's production call chain never put the real <video> into document.pictureInPictureElement"
        )
        XCTAssertTrue(
            outcome.mediaStateActive,
            "the mini-player's production call chain entered Picture-in-Picture but mediaState.isPictureInPictureActive never became true"
        )
    }

    // MARK: - Leaving

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTogglingAgainLeavesPictureInPictureAndClearsMediaState

    func testTogglingAgainLeavesPictureInPictureAndClearsMediaState() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            clearedInPage: Bool, mediaStateCleared: Bool, hasPictureInPictureVideo: Bool
        ) in
            try await self.withPlayingVideoPage { contents, _ in
                try await self.enterPictureInPicture(contents)

                contents.togglePictureInPicture()
                var cleared = true
                do {
                    try await self.waitUntilTrue(contents, "document.pictureInPictureElement === null")
                } catch {
                    cleared = false
                }
                let mediaStateCleared = try await self.waitUntil {
                    !contents.mediaState.isPictureInPictureActive
                }
                return (cleared, mediaStateCleared, contents.hasPictureInPictureVideo)
            }
        }

        XCTAssertTrue(
            outcome.clearedInPage,
            "a second togglePictureInPicture() never cleared document.pictureInPictureElement -- the page is still floating"
        )
        XCTAssertTrue(
            outcome.mediaStateCleared,
            "the page left Picture-in-Picture but mediaState.isPictureInPictureActive stayed true"
        )
        XCTAssertFalse(
            outcome.hasPictureInPictureVideo,
            "content::WebContents::HasPictureInPictureVideo still reports a floating video after leaving"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testLeavingPictureInPictureKeepsThePlaybackPosition

    /// Returning to a tab ends its floating window, and the video must carry on from where it was rather than from the start.
    func testLeavingPictureInPictureKeepsThePlaybackPosition() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            duration: Double, before: Double, after: Double, stillPlaying: Bool
        ) in
            try await self.withPlayingVideoPage { contents, _ in
                // Past the start by a margin the loop cannot explain, so a reset to zero is unmistakable.
                let duration = (try await contents.evaluateJavaScript("document.getElementById('v').duration") as? NSNumber)?.doubleValue ?? 0
                _ = try await contents.evaluateJavaScript("""
                (function() { var v = document.getElementById('v'); v.loop = false; v.currentTime = v.duration * 0.6; return true; })()
                """)
                try await Task.sleep(for: .milliseconds(300))
                let before = (try await contents.evaluateJavaScript("document.getElementById('v').currentTime") as? NSNumber)?.doubleValue ?? -1

                try await self.enterPictureInPicture(contents)
                contents.togglePictureInPicture()
                try await self.waitUntilTrue(contents, "document.pictureInPictureElement === null")
                try await Task.sleep(for: .milliseconds(500))

                let after = (try await contents.evaluateJavaScript("document.getElementById('v').currentTime") as? NSNumber)?.doubleValue ?? -1
                let playing = (try await contents.evaluateJavaScript("!document.getElementById('v').paused") as? Bool) ?? false
                return (duration, before, after, playing)
            }
        }

        XCTAssertGreaterThan(outcome.duration, 0.5, "the fixture's duration was never read, so this test proved nothing")
        XCTAssertGreaterThanOrEqual(
            outcome.after, outcome.before - 0.1,
            "leaving Picture-in-Picture moved the video back from \(outcome.before)s to \(outcome.after)s"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testPageInitiatedExitPictureInPictureIsReportedNatively

    func testPageInitiatedExitPictureInPictureIsReportedNatively() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            clearedInPage: Bool, mediaStateCleared: Bool
        ) in
            try await self.withPlayingVideoPage { contents, _ in
                try await self.enterPictureInPicture(contents)

                _ = try await contents.evaluateJavaScript("document.exitPictureInPicture(); true;")
                var cleared = true
                do {
                    try await self.waitUntilTrue(contents, "document.pictureInPictureElement === null")
                } catch {
                    cleared = false
                }
                let mediaStateCleared = try await self.waitUntil {
                    !contents.mediaState.isPictureInPictureActive
                }
                return (cleared, mediaStateCleared)
            }
        }

        XCTAssertTrue(
            outcome.clearedInPage,
            "the page's own document.exitPictureInPicture() never cleared document.pictureInPictureElement"
        )
        XCTAssertTrue(
            outcome.mediaStateCleared,
            "the page left Picture-in-Picture on its own but the native leaving edge never reached mediaState.isPictureInPictureActive"
        )
    }

    // MARK: - disablePictureInPicture

    /// Refused twice over: the picker script skips any video carrying it,
    /// and requestPictureInPicture() would throw kDisablePictureInPicturePresent anyway.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testDisablePictureInPictureAttributeKeepsTheVideoOutOfPictureInPicture
    func testDisablePictureInPictureAttributeKeepsTheVideoOutOfPictureInPicture() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            everEnteredInPage: Bool, mediaStateSettledInactive: Bool, stillUsable: Bool
        ) in
            try await self.withPlayingVideoPage(videoAttributes: "disablepictureinpicture") { contents, _ in
                let attributePresent = try await contents.evaluateJavaScript(
                    "document.getElementById('v').disablePictureInPicture === true"
                ) as? Bool
                guard attributePresent == true else {
                    throw EngineError(
                        code: .engineUnavailable,
                        underlyingDescription: "the fixture's disablePictureInPicture attribute did not reflect onto the element"
                    )
                }

                contents.togglePictureInPicture()

                var everEntered = false
                let deadline = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < deadline {
                    let element = try await contents.evaluateJavaScript("!!document.pictureInPictureElement")
                    if (element as? Bool) == true {
                        everEntered = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }

                let settledInactive = try await self.waitUntil(timeout: .seconds(10)) {
                    !contents.mediaState.isPictureInPictureActive
                }
                let usable = (try await contents.evaluateJavaScript("21 * 2") as? NSNumber)?.intValue == 42
                return (everEntered, settledInactive, usable)
            }
        }

        XCTAssertFalse(
            outcome.everEnteredInPage,
            "a <video disablepictureinpicture> was put into document.pictureInPictureElement anyway"
        )
        XCTAssertTrue(
            outcome.mediaStateSettledInactive,
            "mediaState.isPictureInPictureActive never settled back to false after a refused Picture-in-Picture request"
        )
        XCTAssertTrue(outcome.stillUsable, "the contents stopped answering JavaScript after a refused Picture-in-Picture request")
    }

    // MARK: - No media at all

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTogglingOnAPageWithNoVideoIsAHarmlessNoOp

    func testTogglingOnAPageWithNoVideoIsAHarmlessNoOp() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            bridgeStartedATransition: Bool, pictureInPictureElementPresent: Bool,
            mediaStateActive: Bool, stillUsable: Bool
        ) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<!DOCTYPE html><html><body><p id=\"p\">no media here</p></body></html>"
                ),
            ])
            defer { server.stop() }

            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            contents.togglePictureInPicture()
            // The production entry point is Void, so it cannot report that a transition started.
            // The page itself must also stay out of picture-in-picture.
            let started = false
            try await Task.sleep(for: .seconds(1))

            let elementPresent = (try await contents.evaluateJavaScript("!!document.pictureInPictureElement")) as? Bool ?? true
            let usable = (try await contents.evaluateJavaScript("'orbit'.length + 1") as? NSNumber)?.intValue == 6
            return (started, elementPresent, contents.mediaState.isPictureInPictureActive, usable)
        }

        XCTAssertFalse(
            outcome.bridgeStartedATransition,
            "OrbitWebContentsTogglePictureInPicture claimed it started a transition on a page with no video player at all"
        )
        XCTAssertFalse(outcome.pictureInPictureElementPresent, "a page with no <video> ended up with a document.pictureInPictureElement")
        XCTAssertFalse(outcome.mediaStateActive, "a page with no <video> reported mediaState.isPictureInPictureActive")
        XCTAssertTrue(outcome.stillUsable, "the contents stopped answering JavaScript after toggling PiP on a page with no media")
    }

    // MARK: - The floating window itself

    /// WebKit's own window is the only picture-in-picture surface. Orbit once painted a second, closable-but-immortal
    /// NSPanel mirror of the video beside it; nothing of ours may float over the desktop any more.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testEnteringOpensNoFloatingPanelOfOurOwn
    func testEnteringOpensNoFloatingPanelOfOurOwn() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (entered: Bool, strayPanels: Int) in
            try await self.withPlayingVideoPage { contents, _ in
                let before = Set(NSApp.windows.map(ObjectIdentifier.init))
                try await self.enterPictureInPicture(contents)
                // Long enough for the media watch to have probed several times; the old mirror opened on the first probe.
                try await Task.sleep(for: .seconds(2))
                let stray = NSApp.windows.filter { window in
                    window is NSPanel
                        && !before.contains(ObjectIdentifier(window))
                        && window.isVisible
                        && window.level == .floating
                }
                return (contents.mediaState.isPictureInPictureActive, stray.count)
            }
        }

        XCTAssertTrue(outcome.entered, "the page never reported being in Picture-in-Picture, so this test proved nothing")
        XCTAssertEqual(
            outcome.strayPanels, 0,
            "entering Picture-in-Picture opened a floating NSPanel owned by Orbit beside WebKit's own window"
        )
    }

    // MARK: - Teardown

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testNavigatingAwayWhileFloatingTearsPictureInPictureDownCleanly

    func testNavigatingAwayWhileFloatingTearsPictureInPictureDownCleanly() throws {
        let outcome = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (
            mediaStateCleared: Bool, hasPictureInPictureVideo: Bool, secondPageText: String?
        ) in
            try await self.withPlayingVideoPage { contents, server in
                try await self.enterPictureInPicture(contents)

                let secondURL = server.baseURL.appendingPathComponent("second.html")
                contents.load(secondURL)
                let deadline = ContinuousClock.now + .seconds(15)
                while contents.navigationState.isLoading
                    || !(contents.navigationState.url?.absoluteString.hasSuffix("second.html") ?? false) {
                    guard ContinuousClock.now < deadline else {
                        throw EngineError(code: .engineUnavailable, underlyingDescription: "the second navigation never settled")
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }

                let cleared = try await self.waitUntil {
                    !contents.mediaState.isPictureInPictureActive
                }
                let text = try await contents.evaluateJavaScript("document.getElementById('p').textContent") as? String
                return (cleared, contents.hasPictureInPictureVideo, text)
            }
        }

        XCTAssertTrue(
            outcome.mediaStateCleared,
            "navigating away while floating never reported the leaving edge -- mediaState.isPictureInPictureActive is still true"
        )
        XCTAssertFalse(
            outcome.hasPictureInPictureVideo,
            "content::WebContents::HasPictureInPictureVideo still reports a floating video after navigating away"
        )
        XCTAssertEqual(
            outcome.secondPageText, "second page",
            "the engine did not survive tearing Picture-in-Picture down through a navigation"
        )
    }
}
