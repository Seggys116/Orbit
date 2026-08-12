//  Live Blink coverage not reached elsewhere: document-end scripts,
//  stylesheet injection, the match-pattern matcher, and the full native media bridge round trip.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class BoostsAndObserverScriptsLiveTests: XCTestCase {

    // MARK: - Document-end user scripts (the Boost-JavaScript path)

    /// A compiled Boost's JavaScript half is always `.documentEnd` (see
    /// BoostCompiler.compile); proven live for the first time here.
    func testDocumentEndUserScriptRunsAfterDOMContentLoaded() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let result = try LiveChromiumEngineHost.runLive { () -> Any? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let probe = UserScript(
                kind: .javaScript,
                source: "window.__orbitDocumentEndProbe = 'ran';",
                injectionTime: .documentEnd,
                matchPatterns: ["<all_urls>"],
                allFrames: false
            )
            engine.addUserScript(probe, session: engine.defaultSession)
            defer { engine.removeUserScript(id: probe.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            return try await contents.evaluateJavaScript("window.__orbitDocumentEndProbe")
        }
        XCTAssertEqual(result as? String, "ran", "a .documentEnd UserScript -- exactly what a Boost's JavaScript compiles to -- never ran")
    }

    // MARK: - Stylesheet user scripts (the Boost-CSS path)

    /// Proves WebDocument::InsertStyleSheet reaches computed style, not just
    /// that RunDocumentStartScripts's non-stylesheet branch runs -- first live proof of CSS delivery.
    func testAllURLsStylesheetUserScriptReachesComputedStyle() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let backgroundColor = try LiveChromiumEngineHost.runLive { () -> Any? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            // Removed before this test returns: the engine is shared by every
            // live suite, and a leftover !important background repaints every later page.
            let sheet = UserScript(
                kind: .stylesheet,
                source: "body { background-color: rgb(11, 22, 33) !important; }",
                injectionTime: .documentStart,
                matchPatterns: ["<all_urls>"],
                allFrames: false
            )
            engine.addUserScript(sheet, session: engine.defaultSession)
            defer { engine.removeUserScript(id: sheet.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            return try await contents.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        }
        XCTAssertEqual(
            backgroundColor as? String, "rgb(11, 22, 33)",
            "an <all_urls> stylesheet UserScript did not reach the live page's computed style"
        )
    }

    /// A host-restricted stylesheet must not leak onto a non-matching page,
    /// proven against the real C++ matcher, not Swift's own mirror.
    func testHostRestrictedStylesheetDoesNotApplyToANonMatchingPage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let backgroundColor = try LiveChromiumEngineHost.runLive { () -> Any? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let sheet = UserScript(
                kind: .stylesheet,
                source: "body { background-color: rgb(44, 55, 66) !important; }",
                injectionTime: .documentStart,
                matchPatterns: ["https://orbit-boost-live-test.example/*"],
                allFrames: false
            )
            engine.addUserScript(sheet, session: engine.defaultSession)
            defer { engine.removeUserScript(id: sheet.id, session: engine.defaultSession) }

            // about:blank's scheme can never satisfy an https:// pattern --
            // a genuine non-match, not a stand-in for one.
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            return try await contents.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        }
        XCTAssertNotEqual(
            backgroundColor as? String, "rgb(44, 55, 66)",
            "a stylesheet scoped to a different host leaked onto a page it must not match"
        )
    }

    // MARK: - LinkHoverObserverScript

    @MainActor
    private final class HoverRecordingDelegate: WebContentsDelegate {
        private(set) var lastHoveredURL: URL??
        func webContents(_ contents: WebContents, didHoverLink url: URL?) {
            lastHoveredURL = url
        }
    }

    func testLinkHoverObserverScriptReportsAndClearsTheHoveredLink() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (hoveredURL, clearedURL) = try LiveChromiumEngineHost.runLive { () -> (URL??, URL??) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            engine.addUserScript(LinkHoverObserverScript.chromiumUserScript, session: engine.defaultSession)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            let delegate = HoverRecordingDelegate()
            contents.delegate = delegate

            _ = try await contents.evaluateJavaScript("""
            var a = document.createElement('a');
            a.href = 'https://orbit-live-test.example/target';
            a.textContent = 'link';
            document.body.appendChild(a);
            a.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
            true;
            """)

            let deadline = ContinuousClock.now + .seconds(10)
            while delegate.lastHoveredURL == nil {
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let hovered = delegate.lastHoveredURL

            _ = try await contents.evaluateJavaScript("""
            document.querySelector('a').dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: document.body }));
            true;
            """)
            let clearDeadline = ContinuousClock.now + .seconds(10)
            while delegate.lastHoveredURL == hovered {
                guard ContinuousClock.now < clearDeadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            return (hovered, delegate.lastHoveredURL)
        }

        XCTAssertEqual(
            (try XCTUnwrap(hoveredURL))?.absoluteString, "https://orbit-live-test.example/target",
            "hovering a real <a href> never reached WebContentsDelegate.didHoverLink"
        )
        XCTAssertEqual(
            try XCTUnwrap(clearedURL), URL?.none,
            "mousing back out never cleared the hovered link"
        )
    }

    // MARK: - MediaTransportScript

    /// Native-initiated: unlike MediaSessionObserverScript (page reports to
    /// native), this is native invoking `window.__orbitMediaTransport` as the mini player's buttons do.
    func testMediaTransportScriptDOMFallbackPlaysAPausedElement() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let played = try LiveChromiumEngineHost.runLive { () -> Any? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            engine.addUserScript(MediaTransportScript.userScript, session: engine.defaultSession)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            _ = try await contents.evaluateJavaScript("""
            var audio = document.createElement('audio');
            audio.id = 'orbitLiveTestAudio';
            document.body.appendChild(audio);
            true;
            """)

            return try await contents.evaluateJavaScript(MediaTransportScript.invocation(for: .play))
        }
        XCTAssertEqual(
            played as? Bool, true,
            "__orbitMediaTransport('play') did not find and play the paused <audio> element"
        )
    }

    // MARK: - Full native media bridge round trip: real playback -> AppEnvironment -> native command -> real playback

    /// A real playing <video> reports state through MediaSessionObserverScript
    /// into AppEnvironment.mediaStates, and mediaTransport(_:for:) commands genuinely control it back.
    func testAppEnvironmentMediaBridgeRoundTripReportsRealPlaybackAndNativeCommandsControlIt() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive { () -> (
            reportedTitle: String?, reportedArtist: String?, reportedPlayingAfterStart: Bool, reportedHasVideo: Bool,
            pausedAfterNativePause: Bool, reportedPlayingAfterNativePause: Bool,
            resumedAfterNativePlay: Bool, reportedPlayingAfterNativePlay: Bool,
            nextTrackInvoked: Bool
        ) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            engine.addUserScript(MediaSessionObserverScript.chromiumUserScript, session: engine.defaultSession)
            engine.addUserScript(MediaTransportScript.userScript, session: engine.defaultSession)

            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><video id=\"v\" src=\"/v.webm\"></video></body></html>"
                ),
                "/v.webm": LiveHTTPTestServer.Route(contentType: "video/webm", data: LiveMediaFixtures.videoWebM),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)

            let env = AppEnvironment.demo
            let spaceID = env.state.spaces.first?.id
                ?? env.createSpace(name: "Media Bridge Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
            let tab = Tab(spaceID: spaceID, section: .today, url: server.baseURL, title: "")
            env.state.tabs[tab.id] = tab
            env._test_attachWebContents(contents, for: tab.id)
            contents.delegate = env
            defer {
                env._test_detachWebContents(for: tab.id)
                env.state.tabs.removeValue(forKey: tab.id)
            }

            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            var v = document.getElementById('v');
            v.muted = true;
            window.__orbitNextTrackCalled = false;
            navigator.mediaSession.metadata = new MediaMetadata({ title: 'Orbit Bridge Track', artist: 'Orbit Bridge Artist' });
            navigator.mediaSession.setActionHandler('play', function() { v.play(); });
            navigator.mediaSession.setActionHandler('pause', function() { v.pause(); });
            navigator.mediaSession.setActionHandler('nexttrack', function() { window.__orbitNextTrackCalled = true; });
            v.addEventListener('playing', function() { navigator.mediaSession.playbackState = 'playing'; });
            v.addEventListener('pause', function() { navigator.mediaSession.playbackState = 'paused'; });
            v.play();
            true;
            """)

            let startDeadline = ContinuousClock.now + .seconds(15)
            while env.mediaStates[tab.id]?.nowPlayingTitle != "Orbit Bridge Track" || env.mediaStates[tab.id]?.isPlaying != true {
                guard ContinuousClock.now < startDeadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let stateAfterStart = env.mediaStates[tab.id]

            let pauseAcknowledged = await env.mediaTransport(.pause, for: tab.id)
            XCTAssertTrue(pauseAcknowledged, "AppEnvironment.mediaTransport(.pause) reported no handler ran, but the page registered one")
            let pausedNow = (try await contents.evaluateJavaScript("document.getElementById('v').paused")) as? Bool ?? false
            let pauseDeadline = ContinuousClock.now + .seconds(10)
            while env.mediaStates[tab.id]?.isPlaying != false {
                guard ContinuousClock.now < pauseDeadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let playingAfterPause = env.mediaStates[tab.id]?.isPlaying ?? true

            let playAcknowledged = await env.mediaTransport(.play, for: tab.id)
            XCTAssertTrue(playAcknowledged, "AppEnvironment.mediaTransport(.play) reported no handler ran, but the page registered one")
            let pausedDeadlineAfterPlay = ContinuousClock.now + .seconds(10)
            var pausedAfterPlayCall = true
            while true {
                pausedAfterPlayCall = (try await contents.evaluateJavaScript("document.getElementById('v').paused")) as? Bool ?? true
                if !pausedAfterPlayCall { break }
                guard ContinuousClock.now < pausedDeadlineAfterPlay else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let playDeadline = ContinuousClock.now + .seconds(10)
            while env.mediaStates[tab.id]?.isPlaying != true {
                guard ContinuousClock.now < playDeadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let playingAfterResume = env.mediaStates[tab.id]?.isPlaying ?? false

            _ = await env.mediaTransport(.nextTrack, for: tab.id)
            let nextTrackDeadline = ContinuousClock.now + .seconds(10)
            var nextTrackCalled = false
            while true {
                nextTrackCalled = (try await contents.evaluateJavaScript("window.__orbitNextTrackCalled")) as? Bool ?? false
                if nextTrackCalled { break }
                guard ContinuousClock.now < nextTrackDeadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }

            return (
                stateAfterStart?.nowPlayingTitle, stateAfterStart?.nowPlayingArtist,
                stateAfterStart?.isPlaying ?? false, stateAfterStart?.hasVideo ?? false,
                pausedNow, playingAfterPause,
                !pausedAfterPlayCall, playingAfterResume,
                nextTrackCalled
            )
        }

        XCTAssertEqual(outcome.reportedTitle, "Orbit Bridge Track", "the real page's MediaMetadata title never reached AppEnvironment.mediaStates")
        XCTAssertEqual(outcome.reportedArtist, "Orbit Bridge Artist", "the real page's MediaMetadata artist never reached AppEnvironment.mediaStates")
        XCTAssertTrue(outcome.reportedPlayingAfterStart, "a real playing <video> with an active Media Session never reported isPlaying through to AppEnvironment.mediaStates")
        XCTAssertTrue(outcome.reportedHasVideo, "a page with a real <video> element never reported hasVideo through to AppEnvironment.mediaStates")

        XCTAssertTrue(outcome.pausedAfterNativePause, "AppEnvironment.mediaTransport(.pause, for:) -- exactly what the mini player's pause button calls -- did not actually pause the real playing <video>")
        XCTAssertFalse(outcome.reportedPlayingAfterNativePause, "after a native pause command actually paused the video, AppEnvironment.mediaStates never reported isPlaying == false")

        XCTAssertTrue(outcome.resumedAfterNativePlay, "AppEnvironment.mediaTransport(.play, for:) -- exactly what the mini player's play button calls -- did not resume the real paused <video>")
        XCTAssertTrue(outcome.reportedPlayingAfterNativePlay, "after a native play command resumed the video, AppEnvironment.mediaStates never reported isPlaying == true again")

        XCTAssertTrue(outcome.nextTrackInvoked, "AppEnvironment.mediaTransport(.nextTrack, for:) never reached the page's own navigator.mediaSession.setActionHandler('nexttrack', ...) -- there is no DOM fallback for next/previous, so this only works if handler capture and native invocation both work")
    }

    /// The test above proves the fallback against an <audio> that never
    /// played. This proves it against a real, decoding <video> with no registered Media Session handler.
    func testMediaTransportScriptDOMFallbackPausesARealPlayingVideoWithNoRegisteredHandler() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (acknowledgedByScript, pausedAfterCommand) = try LiveChromiumEngineHost.runLive { () -> (Bool, Bool) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            engine.addUserScript(MediaTransportScript.userScript, session: engine.defaultSession)

            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><video id=\"v\" src=\"/v.webm\"></video></body></html>"
                ),
                "/v.webm": LiveHTTPTestServer.Route(contentType: "video/webm", data: LiveMediaFixtures.videoWebM),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            var v = document.getElementById('v');
            v.muted = true;
            window.__orbitReachedPlaying = false;
            v.addEventListener('playing', function() { window.__orbitReachedPlaying = true; });
            v.play();
            true;
            """)
            let deadline = ContinuousClock.now + .seconds(15)
            while (try await contents.evaluateJavaScript("window.__orbitReachedPlaying")) as? Bool != true {
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }

            let result = try await contents.evaluateJavaScript(MediaTransportScript.invocation(for: .pause))
            let paused = (try await contents.evaluateJavaScript("document.getElementById('v').paused")) as? Bool ?? false
            return ((result as? Bool) ?? false, paused)
        }

        XCTAssertTrue(acknowledgedByScript, "__orbitMediaTransport('pause') reported it found nothing to pause on a page with a real playing <video> and no registered handler")
        XCTAssertTrue(pausedAfterCommand, "the DOM fallback pause did not actually pause the real playing <video>")
    }
}
