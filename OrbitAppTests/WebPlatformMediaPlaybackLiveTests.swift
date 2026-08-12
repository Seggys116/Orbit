//  Live coverage for real <video>/<audio> playback reaching 'playing', real decoded metadata, and
//  currentTime advancing/freezing. Autoplay policy exempts muted video but not audio (no gesture entry point).

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebPlatformMediaPlaybackLiveTests: XCTestCase {

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

    private struct PlaybackResult {
        let reachedPlaying: Bool
        let firstCurrentTime: Double
        let secondCurrentTime: Double
        let reachedPause: Bool
        let currentTimeAfterFirstPauseSample: Double
        let currentTimeAfterSecondPauseSample: Double
        let diagnostics: String
        /// Set when play() was rejected outright (autoplay policy, most
        /// often) rather than merely slow to reach 'playing'.
        let playErrorMessage: String?
    }

    private func drivePlayback(elementTag: String, routePath: String, contentType: String, data: Data) throws -> (PlaybackResult, [String: Any]) {
        try LiveChromiumEngineHost.runLive { () -> (PlaybackResult, [String: Any]) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><\(elementTag) id=\"m\" src=\"\(routePath)\"></\(elementTag)></body></html>"
                ),
                routePath: LiveHTTPTestServer.Route(contentType: contentType, data: data, supportsRangeRequests: true),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
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
            window.__orbitMediaEvents = [];
            var m = document.getElementById('m');
            m.muted = true;
            ['playing', 'pause', 'loadedmetadata', 'error', 'stalled', 'waiting', 'suspend', 'abort', 'ended'].forEach(function(name) {
              m.addEventListener(name, function() { window.__orbitMediaEvents.push(name); });
            });
            m.play().catch(function(e) { window.__orbitPlayError = String(e); });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitMediaEvents.indexOf('playing') !== -1 || !!window.__orbitPlayError", timeout: .seconds(20))

            let reachedPlaying = ((try await contents.evaluateJavaScript(
                "window.__orbitMediaEvents.indexOf('playing') !== -1"
            )) as? Bool) ?? false
            let playErrorMessage = (try await contents.evaluateJavaScript("window.__orbitPlayError || null")) as? String

            let metadata = try await contents.evaluateJavaScript("""
            (function() {
              var m = document.getElementById('m');
              return { duration: m.duration, videoWidth: m.videoWidth || null, videoHeight: m.videoHeight || null };
            })();
            """)
            let metadataDictionary = (metadata as? [String: Any]) ?? [:]

            guard reachedPlaying else {
                let result = PlaybackResult(
                    reachedPlaying: false, firstCurrentTime: -1, secondCurrentTime: -1, reachedPause: false,
                    currentTimeAfterFirstPauseSample: -1, currentTimeAfterSecondPauseSample: -1,
                    diagnostics: try await self.mediaDiagnostics(contents), playErrorMessage: playErrorMessage
                )
                return (result, metadataDictionary)
            }

            let firstTime = ((try await contents.evaluateJavaScript("document.getElementById('m').currentTime")) as? NSNumber)?.doubleValue ?? -1
            // Polled with a generous deadline: a busy machine can delay real decode start, and this
            // must only fail when currentTime truly never advances, not when it is merely slow to.
            var secondTime = firstTime
            let advanceDeadline = ContinuousClock.now + .seconds(10)
            while secondTime <= firstTime {
                guard ContinuousClock.now < advanceDeadline else { break }
                try await Task.sleep(for: .milliseconds(150))
                secondTime = ((try await contents.evaluateJavaScript("document.getElementById('m').currentTime")) as? NSNumber)?.doubleValue ?? -1
            }

            let diagnosticsBeforePause = try await self.mediaDiagnostics(contents)

            _ = try await contents.evaluateJavaScript("document.getElementById('m').pause(); true;")
            var reachedPause = false
            let pauseDeadline = ContinuousClock.now + .seconds(10)
            while !reachedPause {
                reachedPause = ((try await contents.evaluateJavaScript(
                    "window.__orbitMediaEvents.indexOf('pause') !== -1"
                )) as? Bool) ?? false
                if reachedPause { break }
                guard ContinuousClock.now < pauseDeadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let diagnosticsAfterPauseTimeout = reachedPause ? "" : try await self.mediaDiagnostics(contents)

            let afterPauseFirst = ((try await contents.evaluateJavaScript("document.getElementById('m').currentTime")) as? NSNumber)?.doubleValue ?? -1
            try await Task.sleep(for: .milliseconds(300))
            let afterPauseSecond = ((try await contents.evaluateJavaScript("document.getElementById('m').currentTime")) as? NSNumber)?.doubleValue ?? -1

            let result = PlaybackResult(
                reachedPlaying: reachedPlaying,
                firstCurrentTime: firstTime,
                secondCurrentTime: secondTime,
                reachedPause: reachedPause,
                currentTimeAfterFirstPauseSample: afterPauseFirst,
                currentTimeAfterSecondPauseSample: afterPauseSecond,
                diagnostics: reachedPause ? diagnosticsBeforePause : "before-pause: \(diagnosticsBeforePause) | after-pause-timeout: \(diagnosticsAfterPauseTimeout)",
                playErrorMessage: playErrorMessage
            )
            return (result, metadataDictionary)
        }
    }

    private func mediaDiagnostics(_ contents: ChromiumWebContents) async throws -> String {
        let result = try await contents.evaluateJavaScript("""
        (function() {
          var m = document.getElementById('m');
          return {
            paused: m.paused, readyState: m.readyState, networkState: m.networkState,
            error: m.error ? (m.error.code + ':' + m.error.message) : null,
            events: window.__orbitMediaEvents, currentTime: m.currentTime, duration: m.duration,
            playError: window.__orbitPlayError || null
          };
        })();
        """)
        guard let dictionary = result as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let json = String(data: data, encoding: .utf8) else { return "no diagnostics" }
        return json
    }

    func testVideoReachesPlayingStateAdvancesCurrentTimeAndPausesCleanly() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (result, metadata) = try drivePlayback(
            elementTag: "video", routePath: "/v.webm", contentType: "video/webm", data: LiveMediaFixtures.videoWebM
        )

        XCTAssertTrue(result.reachedPlaying, "a real muted <video> with a real VP8/Opus WebM src never fired 'playing'. diagnostics: \(result.diagnostics)")
        XCTAssertGreaterThan(result.secondCurrentTime, result.firstCurrentTime, "currentTime did not advance while the video was playing. diagnostics: \(result.diagnostics)")
        XCTAssertTrue(result.reachedPause, "video.pause() never fired the 'pause' event. diagnostics: \(result.diagnostics)")
        XCTAssertEqual(
            result.currentTimeAfterSecondPauseSample, result.currentTimeAfterFirstPauseSample, accuracy: 0.05,
            "currentTime kept advancing after pause() -- playback did not really stop"
        )

        XCTAssertEqual((metadata["videoWidth"] as? NSNumber)?.intValue, 96, "the decoded video's real width should be 96 (the real encoded frame size)")
        XCTAssertEqual((metadata["videoHeight"] as? NSNumber)?.intValue, 64, "the decoded video's real height should be 64 (the real encoded frame size)")
        XCTAssertEqual((metadata["duration"] as? NSNumber)?.doubleValue ?? -1, 2.0, accuracy: 0.5, "the decoded video's real duration should be close to the real ~2s encode")
    }

    /// Metadata (duration) is proven unconditionally before the play()-dependent assertions;
    /// a NotAllowedError from Chromium's real autoplay policy XCTSkips them instead of failing.
    // ORBIT-LIVE-ENGINE: MAY-SKIP testAudioReachesPlayingStateAdvancesCurrentTimeAndPausesCleanly
    func testAudioReachesPlayingStateAdvancesCurrentTimeAndPausesCleanly() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (result, metadata) = try drivePlayback(
            elementTag: "audio", routePath: "/a.webm", contentType: "audio/webm", data: LiveMediaFixtures.audioWebM
        )

        XCTAssertEqual((metadata["duration"] as? NSNumber)?.doubleValue ?? -1, 2.0, accuracy: 0.5, "the decoded audio's real duration should be close to the real ~2s encode")

        if !result.reachedPlaying, let playError = result.playErrorMessage, playError.contains("NotAllowedError") {
            throw XCTSkip(
                "play() on a plain <audio> element was correctly rejected by Chromium's real autoplay policy "
                    + "(only muted <video> is exempt from the user-activation requirement -- AutoplayPolicy::"
                    + "IsEligibleForAutoplayMuted requires IsA<HTMLVideoElement>()), and no bridge entry point "
                    + "carries a user gesture: OrbitWebContentsEvaluateJavaScript takes no such argument. "
                    + "Real error: \(playError)"
            )
        }

        XCTAssertTrue(result.reachedPlaying, "a real muted <audio> with a real Opus WebM src never fired 'playing'. diagnostics: \(result.diagnostics)")
        XCTAssertGreaterThan(result.secondCurrentTime, result.firstCurrentTime, "currentTime did not advance while the audio was playing. diagnostics: \(result.diagnostics)")
        XCTAssertTrue(result.reachedPause, "audio.pause() never fired the 'pause' event. diagnostics: \(result.diagnostics)")
        XCTAssertEqual(
            result.currentTimeAfterSecondPauseSample, result.currentTimeAfterFirstPauseSample, accuracy: 0.05,
            "currentTime kept advancing after pause() -- playback did not really stop"
        )
    }
}
