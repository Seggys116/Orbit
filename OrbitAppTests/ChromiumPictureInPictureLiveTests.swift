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
final class ChromiumPictureInPictureLiveTests: LiveEnvironmentTestCase {

    private static func pageHTML(videoAttributes: String = "") -> String {
        "<!DOCTYPE html><html><body><video id=\"v\" src=\"/v.webm\" muted loop playsinline \(videoAttributes)></video></body></html>"
    }

    private static let secondPageHTML =
        "<!DOCTYPE html><html><head><title>Second</title></head><body><p id=\"p\">second page</p></body></html>"

    private func waitUntilTrue(
        _ contents: ChromiumWebContents,
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
        _ body: (ChromiumWebContents, LiveHTTPTestServer) async throws -> T
    ) async throws -> T {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        // Installed deliberately: its 2s poll also writes isPictureInPictureActive,
        // so every test runs against real contention with the native signal.
        engine.addUserScript(MediaSessionObserverScript.chromiumUserScript, session: engine.defaultSession)

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

        let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
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
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

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

    struct PanelFrame {
        var saturatedFraction: Double
        var nearBlackFraction: Double
        var checksum: Int

        // Thresholds measured against the fixture (0.17-0.26 saturated, 0.0
        // near-black). Every layer behind the video surface paints black, so an empty panel is entirely near-black.
        var isShowingVideo: Bool { nearBlackFraction < 0.1 && saturatedFraction > 0.1 }
    }

    /// dlsym'd because CGWindowListCreateImage is deprecated in the SDK;
    /// asking only for a window this process owns needs no screen-recording grant.
    private static func readPanelPixels(_ panel: NSPanel) -> PanelFrame? {
        typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard
            let handle = dlopen(nil, RTLD_NOW),
            let symbol = dlsym(handle, "CGWindowListCreateImage"),
            panel.windowNumber > 0
        else { return nil }
        let create = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        guard
            let image = create(.null, 1 << 3, UInt32(panel.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
        else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard bitmap.pixelsWide > 8, bitmap.pixelsHigh > 8 else { return nil }

        // The middle half, away from the rounded corners and the title row.
        let left = bitmap.pixelsWide / 4
        let top = bitmap.pixelsHigh / 4
        var saturated = 0
        var nearBlack = 0
        var sampled = 0
        var checksum = 0
        for y in stride(from: top, to: top + bitmap.pixelsHigh / 2, by: 3) {
            for x in stride(from: left, to: left + bitmap.pixelsWide / 2, by: 3) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                let brightest = channels.max() ?? 0
                if brightest - (channels.min() ?? 0) > 0.3 { saturated += 1 }
                if brightest < 0.08 { nearBlack += 1 }
                sampled += 1
                checksum = checksum &* 31 &+ Int((channels.reduce(0, +) / 3) * 255)
            }
        }
        guard sampled > 0 else { return nil }
        return PanelFrame(
            saturatedFraction: Double(saturated) / Double(sampled),
            nearBlackFraction: Double(nearBlack) / Double(sampled),
            checksum: checksum
        )
    }

    private func enterPictureInPicture(_ contents: ChromiumWebContents) async throws {
        let started = OrbitChromiumBridge.shared.togglePictureInPicture(contents.chromiumHandle)
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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
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
            "the page really entered Picture-in-Picture but ChromiumWebContents.mediaState.isPictureInPictureActive never became true"
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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
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

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testPageInitiatedExitPictureInPictureIsReportedNatively

    func testPageInitiatedExitPictureInPictureIsReportedNatively() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
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

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            contents.togglePictureInPicture()
            // The same call again, straight through the bridge, for its return
            // value: the production entry point is Void by protocol.
            let started = OrbitChromiumBridge.shared.togglePictureInPicture(contents.chromiumHandle)
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

    /// A real NSPanel this process owns, so it's in NSApp.windows.
    /// contentAspectRatio only updates once the real decoded natural size is known, so 96:64 proves the real fixture.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testEnteringOpensARealFloatingPanelSizedToTheRealVideoAndClosesItOnExit
    func testEnteringOpensARealFloatingPanelSizedToTheRealVideoAndClosesItOnExit() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
            foundPanel: Bool, aspectRatio: Double, minWidth: Double, minHeight: Double, hiddenAfterExit: Bool,
            frames: [PanelFrame]
        ) in
            try await self.withPlayingVideoPage { contents, _ in
                let before = Set(NSApp.windows.map(ObjectIdentifier.init))
                try await self.enterPictureInPicture(contents)

                var panel: NSPanel?
                _ = try await self.waitUntil {
                    panel = NSApp.windows.first { window in
                        guard let candidate = window as? NSPanel else { return false }
                        return !before.contains(ObjectIdentifier(candidate))
                            && candidate.isVisible
                            && candidate.level == .floating
                    } as? NSPanel
                    return panel != nil
                }
                guard let panel else {
                    return (false, 0, 0, 0, false, [])
                }

                var ratio = 0.0
                _ = try await self.waitUntil(timeout: .seconds(10)) {
                    let size = panel.contentAspectRatio
                    guard size.height > 0 else { return false }
                    ratio = Double(size.width / size.height)
                    return true
                }
                let minSize = panel.contentMinSize

                // Polled, not sampled once: the panel orders in before its
                // first frame composites, so collection starts from the first frame showing video.
                var frames: [PanelFrame] = []
                let deadline = ContinuousClock.now + .seconds(10)
                while ContinuousClock.now < deadline {
                    if let frame = Self.readPanelPixels(panel) {
                        if !frames.isEmpty || frame.isShowingVideo {
                            frames.append(frame)
                        }
                        if frames.count >= 2, frames[0].checksum != frames[frames.count - 1].checksum {
                            break
                        }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }

                contents.togglePictureInPicture()
                let hidden = try await self.waitUntil(timeout: .seconds(10)) { !panel.isVisible }

                return (true, ratio, Double(minSize.width), Double(minSize.height), hidden, frames)
            }
        }

        XCTAssertTrue(
            outcome.foundPanel,
            "entering Picture-in-Picture never produced a visible floating NSPanel in this process"
        )
        XCTAssertEqual(
            outcome.aspectRatio, 1.5, accuracy: 0.01,
            "the floating panel's contentAspectRatio is not the real decoded 96x64 natural size of the video that entered"
        )
        XCTAssertEqual(outcome.minWidth, 284, accuracy: 0.5, "the floating panel's minimum content width is not the one it is built with")
        XCTAssertEqual(outcome.minHeight, 160, accuracy: 0.5, "the floating panel's minimum content height is not the one it is built with")
        XCTAssertFalse(
            outcome.frames.isEmpty,
            """
            the floating panel never showed the video's own pixels: within 10s of opening, every capture of its \
            real screen content was still the black it paints behind the video surface, so the viz surface never reached it
            """
        )
        XCTAssertNotEqual(
            outcome.frames.first?.checksum, outcome.frames.last?.checksum,
            "the floating panel is showing one frozen frame: the surface arrived but is not being updated as the video plays"
        )
        XCTAssertTrue(
            outcome.hiddenAfterExit,
            "leaving Picture-in-Picture left the floating panel on screen"
        )
    }

    // MARK: - Teardown

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testNavigatingAwayWhileFloatingTearsPictureInPictureDownCleanly

    func testNavigatingAwayWhileFloatingTearsPictureInPictureDownCleanly() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> (
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
