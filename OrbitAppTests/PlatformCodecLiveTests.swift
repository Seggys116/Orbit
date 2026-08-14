//  Live coverage for the macOS-native decoders: what the engine reports for H.264/HEVC/AAC,
//  that WebCodecs really decodes AAC-LC to non-silent PCM through AudioToolbox in the GPU
//  process, and that an H.264+AAC and an HEVC+AAC MP4 really play. Nothing is bundled: if a
//  decoder is missing these fail rather than fall back.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class PlatformCodecLiveTests: XCTestCase {

    private func waitUntilTrue(
        _ contents: ChromiumWebContents,
        _ expression: String,
        timeout: Duration = .seconds(20)
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

    // MARK: - Support reporting

    func testEngineReportsExactlyTheCodecsItCanDecode() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let answers = try LiveChromiumEngineHost.runLive { () -> [String: Any] in
            // Served over http://127.0.0.1, not loadHTML: a data: origin is opaque, so [SecureContext] APIs are absent.
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-codec-support</body></html>"),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let result = try await contents.evaluateJavaScript("""
            (function() {
              var v = document.createElement('video');
              function can(type) { return v.canPlayType(type) !== ''; }
              return {
                canH264Baseline: can('video/mp4; codecs="avc1.42E01E"'),
                canH264Main: can('video/mp4; codecs="avc1.4D401E"'),
                canH264High: can('video/mp4; codecs="avc1.64001E"'),
                canH264High10: can('video/mp4; codecs="avc1.6E001E"'),
                canH264High422: can('video/mp4; codecs="avc1.7A001E"'),
                canH264High444: can('video/mp4; codecs="avc1.F4001E"'),
                canAacLc: can('audio/mp4; codecs="mp4a.40.2"'),
                canHeAac: can('audio/mp4; codecs="mp4a.40.5"'),
                canHeAacV2: can('audio/mp4; codecs="mp4a.40.29"'),
                canOpus: can('audio/webm; codecs="opus"'),
                canVorbis: can('audio/webm; codecs="vorbis"'),
                canFlac: can('audio/flac'),
                canMp3: can('audio/mpeg'),
                canWav: can('audio/wav; codecs="1"'),
                canVp8: can('video/webm; codecs="vp8"'),
                canVp9: can('video/webm; codecs="vp9"'),
                canAv1: can('video/mp4; codecs="av01.0.04M.08"'),
                canHevc: can('video/mp4; codecs="hvc1.1.6.L93.B0"'),
                mseAvcAac: MediaSource.isTypeSupported('video/mp4; codecs="avc1.42c01e,mp4a.40.2"'),
                mseAacLc: MediaSource.isTypeSupported('audio/mp4; codecs="mp4a.40.2"'),
                mseH264High10: MediaSource.isTypeSupported('video/mp4; codecs="avc1.6E001E"'),
                mseHevcAac: MediaSource.isTypeSupported('video/mp4; codecs="hvc1.1.6.L30.90,mp4a.40.2"'),
                isSecureContext: window.isSecureContext,
                hasWebCodecsAudioDecoder: typeof AudioDecoder === 'function',
                hasWebCodecsVideoDecoder: typeof VideoDecoder === 'function',
                hasWebCodecsVideoFrame: typeof VideoFrame === 'function',
                hasWebCodecsEncodedAudioChunk: typeof EncodedAudioChunk === 'function'
              };
            })();
            """)
            return (result as? [String: Any]) ?? [:]
        }

        func reported(_ key: String) -> Bool { (answers[key] as? NSNumber)?.boolValue ?? false }

        XCTAssertTrue(reported("canAacLc"), "AAC-LC must be reported supported: AudioToolbox decodes it and most web video has no other audio track")
        XCTAssertTrue(reported("canHeAac"), "HE-AAC must be reported supported -- it shares mp4a.40's AudioType with AAC-LC and AudioToolbox decodes it")
        XCTAssertTrue(reported("canHeAacV2"), "HE-AACv2 must be reported supported -- parametric stereo decodes through AudioToolbox")

        XCTAssertTrue(reported("canH264Baseline"), "VideoToolbox decodes H.264 Baseline")
        XCTAssertTrue(reported("canH264Main"), "VideoToolbox decodes H.264 Main")
        XCTAssertTrue(reported("canH264High"), "VideoToolbox decodes H.264 High")
        XCTAssertFalse(reported("canH264High10"), "H.264 High 10 has no VideoToolbox profile and no software fallback -- claiming it produces a mid-playback failure")
        XCTAssertFalse(reported("canH264High422"), "H.264 High 4:2:2 has no decoder in this build")
        XCTAssertFalse(reported("canH264High444"), "H.264 High 4:4:4 Predictive has no decoder in this build")

        XCTAssertTrue(reported("canOpus"))
        XCTAssertTrue(reported("canVorbis"))
        XCTAssertTrue(reported("canFlac"))
        XCTAssertTrue(reported("canMp3"))
        XCTAssertTrue(reported("canWav"))
        XCTAssertTrue(reported("canVp8"))
        XCTAssertTrue(reported("canVp9"))
        XCTAssertTrue(reported("canAv1"))
        XCTAssertTrue(reported("canHevc"), "HEVC Main decodes through VideoToolbox and is enabled by proprietary_codecs on macOS")

        XCTAssertTrue(reported("mseAvcAac"), "MediaSource must accept H.264+AAC-LC: this single answer is what most streaming players branch on")
        XCTAssertTrue(reported("mseAacLc"))
        XCTAssertTrue(reported("mseHevcAac"))
        XCTAssertFalse(reported("mseH264High10"))
        XCTAssertTrue(reported("isSecureContext"), "http://127.0.0.1 is potentially trustworthy -- if this is false every [SecureContext] API is missing and the WebCodecs assertions below are meaningless")
        XCTAssertTrue(reported("hasWebCodecsAudioDecoder"))
        XCTAssertTrue(reported("hasWebCodecsVideoDecoder"))
        XCTAssertTrue(reported("hasWebCodecsVideoFrame"))
        XCTAssertTrue(reported("hasWebCodecsEncodedAudioChunk"))
    }

    /// AudioDecoder is `[SecureContext]` and VideoFrame is not, which separates a missing secure context from a missing build.
    func testWebCodecsIsExposedOnLocalhostAndWithheldFromAnOpaqueDataOrigin() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let probe = """
        (function() {
          return {
            secure: window.isSecureContext,
            audioDecoder: typeof AudioDecoder === 'function',
            videoFrame: typeof VideoFrame === 'function',
            subtleCrypto: !!(window.crypto && window.crypto.subtle),
            serviceWorker: 'serviceWorker' in navigator
          };
        })();
        """

        let (overHTTP, overData) = try LiveChromiumEngineHost.runLive { () -> ([String: Any], [String: Any]) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-secure-context</body></html>"),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()

            let served = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { served.close() }
            served.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(served)
            let http = (try await served.evaluateJavaScript(probe)) as? [String: Any] ?? [:]

            let inlined = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { inlined.close() }
            inlined.loadHTML("<html><body>orbit-secure-context</body></html>", baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(inlined)
            let data = (try await inlined.evaluateJavaScript(probe)) as? [String: Any] ?? [:]

            return (http, data)
        }

        func flag(_ answers: [String: Any], _ key: String) -> Bool { (answers[key] as? NSNumber)?.boolValue ?? false }

        XCTAssertTrue(flag(overHTTP, "secure"), "a page served from http://127.0.0.1 must be a secure context")
        XCTAssertTrue(flag(overHTTP, "audioDecoder"), "AudioDecoder must exist on a secure origin -- the bindings are linked into the shipped framework and nothing runtime-gates them")
        XCTAssertTrue(flag(overHTTP, "videoFrame"))
        XCTAssertTrue(flag(overHTTP, "subtleCrypto"))
        XCTAssertTrue(flag(overHTTP, "serviceWorker"))

        XCTAssertFalse(flag(overData, "secure"), "loadHTML(baseURL: nil) commits a data: URL, whose origin is opaque and therefore never potentially trustworthy")
        XCTAssertFalse(flag(overData, "audioDecoder"), "AudioDecoder is [SecureContext]: an opaque origin must not see it, and a test that loads its page this way is testing nothing")
        XCTAssertFalse(flag(overData, "subtleCrypto"))
        XCTAssertFalse(flag(overData, "serviceWorker"))
        XCTAssertTrue(flag(overData, "videoFrame"), "VideoFrame is not [SecureContext] -- it stays exposed on an opaque origin, proving WebCodecs is built in and only the secure-context gate withheld AudioDecoder")
    }

    // MARK: - Real AAC decode through AudioToolbox

    /// WebCodecs reaches the same GPU-process decoder the media pipeline uses, without the
    /// autoplay policy in the way, so this proves decode rather than mere capability reporting.
    func testWebCodecsDecodesRealAacLcToNonSilentPcm() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let result = try decodeAacWithWebCodecs()

        XCTAssertEqual(result["configSupported"] as? Bool, true, "AudioDecoder.isConfigSupported rejected mp4a.40.2. diagnostics: \(result)")
        XCTAssertNil(result["error"] as? String, "WebCodecs AudioDecoder errored decoding real AAC-LC: \(result["error"] ?? "")")
        XCTAssertEqual((result["sampleRate"] as? NSNumber)?.intValue, LivePlatformCodecFixtures.aacLcSampleRate, "decoded PCM came out at the wrong sample rate")
        XCTAssertEqual((result["channels"] as? NSNumber)?.intValue, LivePlatformCodecFixtures.aacLcChannels, "decoded PCM came out with the wrong channel count")

        let frames = (result["frames"] as? NSNumber)?.doubleValue ?? 0
        let expected = LivePlatformCodecFixtures.durationSeconds * Double(LivePlatformCodecFixtures.aacLcSampleRate)
        XCTAssertGreaterThan(frames, expected * 0.8, "far fewer PCM frames than the ~2s encode holds -- the decoder stopped early")
        XCTAssertLessThan(frames, expected * 1.3, "far more PCM frames than the ~2s encode holds")

        let peak = (result["peak"] as? NSNumber)?.doubleValue ?? 0
        XCTAssertGreaterThan(peak, 0.01, "decoded AAC-LC was silence -- a decoder that reports success and emits zeroes is the exact failure this test exists for")
    }

    private func decodeAacWithWebCodecs() throws -> [String: Any] {
        let adts = LivePlatformCodecFixtures.aacLcADTS.base64EncodedString()
        let description = LivePlatformCodecFixtures.aacLcAudioSpecificConfig.map(String.init).joined(separator: ",")

        return try LiveChromiumEngineHost.runLive { () -> [String: Any] in
            // AudioDecoder is [SecureContext]; a loadHTML data: origin is opaque and would not expose it.
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-webcodecs-aac</body></html>"),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            window.__orbitAac = { done: false, frames: 0, peak: 0, sampleRate: 0, channels: 0, error: null, configSupported: null };
            (async function() {
              var state = window.__orbitAac;
              try {
                var raw = atob('\(adts)');
                var bytes = new Uint8Array(raw.length);
                for (var i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i); }

                // Strip each ADTS header: WebCodecs with a `description` expects raw access units.
                var packets = [];
                var offset = 0;
                while (offset + 7 <= bytes.length) {
                  if (bytes[offset] !== 0xFF || (bytes[offset + 1] & 0xF6) !== 0xF0) { break; }
                  var length = ((bytes[offset + 3] & 0x03) << 11) | (bytes[offset + 4] << 3) | (bytes[offset + 5] >> 5);
                  if (length < 7 || offset + length > bytes.length) { break; }
                  var header = (bytes[offset + 1] & 0x01) ? 7 : 9;
                  packets.push(bytes.subarray(offset + header, offset + length));
                  offset += length;
                }
                if (packets.length === 0) { state.error = 'no ADTS frames parsed'; state.done = true; return; }

                var config = {
                  codec: 'mp4a.40.2',
                  sampleRate: \(LivePlatformCodecFixtures.aacLcSampleRate),
                  numberOfChannels: \(LivePlatformCodecFixtures.aacLcChannels),
                  description: new Uint8Array([\(description)])
                };
                var support = await AudioDecoder.isConfigSupported(config);
                state.configSupported = !!support.supported;

                var decoder = new AudioDecoder({
                  output: function(data) {
                    state.frames += data.numberOfFrames;
                    state.sampleRate = data.sampleRate;
                    state.channels = data.numberOfChannels;
                    var samples = new Float32Array(data.numberOfFrames);
                    data.copyTo(samples, { planeIndex: 0, format: 'f32-planar' });
                    for (var i = 0; i < samples.length; i++) {
                      var v = Math.abs(samples[i]);
                      if (v > state.peak) { state.peak = v; }
                    }
                    data.close();
                  },
                  error: function(e) { state.error = String(e); state.done = true; }
                });
                decoder.configure(config);

                var timestamp = 0;
                var frameDuration = 1024 * 1000000 / \(LivePlatformCodecFixtures.aacLcSampleRate);
                for (var p = 0; p < packets.length; p++) {
                  decoder.decode(new EncodedAudioChunk({
                    type: 'key', timestamp: Math.round(timestamp), data: packets[p]
                  }));
                  timestamp += frameDuration;
                }
                await decoder.flush();
                decoder.close();
              } catch (e) {
                state.error = String(e);
              }
              state.done = true;
            })();
            true;
            """)

            try await self.waitUntilTrue(contents, "window.__orbitAac.done === true", timeout: .seconds(30))
            let result = try await contents.evaluateJavaScript("window.__orbitAac")
            return (result as? [String: Any]) ?? [:]
        }
    }

    // MARK: - Real playback

    private struct PlaybackResult {
        let reachedPlaying: Bool
        let firstCurrentTime: Double
        let secondCurrentTime: Double
        let videoWidth: Int
        let videoHeight: Int
        let duration: Double
        let diagnostics: String
    }

    private func playMuted(routePath: String, data: Data) throws -> PlaybackResult {
        try LiveChromiumEngineHost.runLive { () -> PlaybackResult in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body style=\"margin:0\"><video id=\"m\" muted playsinline src=\"\(routePath)\"></video></body></html>"
                ),
                routePath: LiveHTTPTestServer.Route(contentType: "video/mp4", data: data, supportsRangeRequests: true),
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
            window.__orbitEvents = [];
            var m = document.getElementById('m');
            m.muted = true;
            ['playing', 'loadedmetadata', 'error', 'stalled', 'waiting', 'suspend', 'abort'].forEach(function(name) {
              m.addEventListener(name, function() { window.__orbitEvents.push(name); });
            });
            m.play().catch(function(e) { window.__orbitPlayError = String(e); });
            true;
            """)
            try await self.waitUntilTrue(
                contents,
                "window.__orbitEvents.indexOf('playing') !== -1 || window.__orbitEvents.indexOf('error') !== -1 || !!window.__orbitPlayError",
                timeout: .seconds(25)
            )

            let reachedPlaying = ((try await contents.evaluateJavaScript("window.__orbitEvents.indexOf('playing') !== -1")) as? Bool) ?? false
            let metadata = try await contents.evaluateJavaScript("""
            (function() {
              var m = document.getElementById('m');
              return { width: m.videoWidth, height: m.videoHeight, duration: m.duration };
            })();
            """)
            let metadataDictionary = (metadata as? [String: Any]) ?? [:]

            let firstTime = ((try await contents.evaluateJavaScript("document.getElementById('m').currentTime")) as? NSNumber)?.doubleValue ?? -1
            var secondTime = firstTime
            let deadline = ContinuousClock.now + .seconds(10)
            while secondTime <= firstTime && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(150))
                secondTime = ((try await contents.evaluateJavaScript("document.getElementById('m').currentTime")) as? NSNumber)?.doubleValue ?? -1
            }

            let diagnostics = try await contents.evaluateJavaScript("""
            (function() {
              var m = document.getElementById('m');
              return JSON.stringify({
                readyState: m.readyState, networkState: m.networkState, paused: m.paused,
                error: m.error ? (m.error.code + ':' + m.error.message) : null,
                events: window.__orbitEvents, playError: window.__orbitPlayError || null,
                audioTracks: m.audioTracks ? m.audioTracks.length : null
              });
            })();
            """)

            return PlaybackResult(
                reachedPlaying: reachedPlaying,
                firstCurrentTime: firstTime,
                secondCurrentTime: secondTime,
                videoWidth: (metadataDictionary["width"] as? NSNumber)?.intValue ?? -1,
                videoHeight: (metadataDictionary["height"] as? NSNumber)?.intValue ?? -1,
                duration: (metadataDictionary["duration"] as? NSNumber)?.doubleValue ?? -1,
                diagnostics: (diagnostics as? String) ?? "no diagnostics"
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testH264WithAacAudioPlaysAndAdvances
    func testH264WithAacAudioPlaysAndAdvances() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let result = try playMuted(routePath: "/avc-aac.mp4", data: LivePlatformCodecFixtures.avcAacMP4)

        XCTAssertTrue(result.reachedPlaying, "a real H.264+AAC-LC MP4 never reached 'playing'. Both tracks must decode for the pipeline to start. diagnostics: \(result.diagnostics)")
        XCTAssertGreaterThan(result.secondCurrentTime, result.firstCurrentTime, "currentTime never advanced -- decoding stalled. diagnostics: \(result.diagnostics)")
        XCTAssertEqual(result.videoWidth, LivePlatformCodecFixtures.frameWidth, "VideoToolbox did not decode the real encoded frame width")
        XCTAssertEqual(result.videoHeight, LivePlatformCodecFixtures.frameHeight)
        XCTAssertEqual(result.duration, LivePlatformCodecFixtures.durationSeconds, accuracy: 0.5)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testHevcWithAacAudioPlaysAndAdvances
    func testHevcWithAacAudioPlaysAndAdvances() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let result = try playMuted(routePath: "/hevc-aac.mp4", data: LivePlatformCodecFixtures.hevcAacMP4)

        XCTAssertTrue(result.reachedPlaying, "a real HEVC Main + AAC-LC MP4 never reached 'playing'. diagnostics: \(result.diagnostics)")
        XCTAssertGreaterThan(result.secondCurrentTime, result.firstCurrentTime, "currentTime never advanced. diagnostics: \(result.diagnostics)")
        XCTAssertEqual(result.videoWidth, LivePlatformCodecFixtures.frameWidth, "VideoToolbox did not decode the real encoded HEVC frame width")
        XCTAssertEqual(result.videoHeight, LivePlatformCodecFixtures.frameHeight)
        XCTAssertEqual(result.duration, LivePlatformCodecFixtures.durationSeconds, accuracy: 0.5)
    }
}
