//  Methods are `throws`, not `async throws`: XCTest's async-test wait nests a
//  run loop mode Task resumption never fires in. runLive(_:) pumps `.defaultMode` instead.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitJavaScriptAndUserScriptLiveTests: XCTestCase {

    // MARK: - JavaScript execution

    func testEvaluateJavaScriptMainWorldReturnsRealNumber() throws {
        let result = try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            return try await contents.evaluateJavaScript("21 * 2")
        }
        XCTAssertEqual((result as? NSNumber)?.intValue, 42)
    }

    func testEvaluateJavaScriptMainWorldRoundTripsObjectAndArray() throws {
        let result = try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            return try await contents.evaluateJavaScript("({a: 1, b: [true, 'x']})")
        }
        let dictionary = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual((dictionary["a"] as? NSNumber)?.intValue, 1)
        let array = try XCTUnwrap(dictionary["b"] as? [Any])
        XCTAssertEqual((array.first as? NSNumber)?.boolValue, true)
        XCTAssertEqual(array.last as? String, "x")
    }

    func testEvaluateJavaScriptMainWorldSeesThePage() throws {
        let title = try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            _ = try await contents.evaluateJavaScript("document.title = 'orbit-js-eval-probe'")
            return try await contents.evaluateJavaScript("document.title")
        }
        XCTAssertEqual(title as? String, "orbit-js-eval-probe")
    }

    /// Proves the isolated world is a real, separate global: a value set
    /// there must be invisible to code run in the main world afterward.
    func testIsolatedWorldIsInvisibleToMainWorld() throws {
        let (seenFromMainWorld, seenFromIsolatedWorld) = try WebKitLiveEngineHost.runLive { () -> (Any?, Any?) in
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            _ = try await contents.evaluateJavaScript("window.__orbitIsolationProbe = 123", inIsolatedWorld: true)
            let fromMainWorld = try await contents.evaluateJavaScript("typeof window.__orbitIsolationProbe")
            let fromIsolatedWorld = try await contents.evaluateJavaScript(
                "window.__orbitIsolationProbe", inIsolatedWorld: true
            )
            return (fromMainWorld, fromIsolatedWorld)
        }
        XCTAssertEqual(seenFromMainWorld as? String, "undefined")
        XCTAssertEqual((seenFromIsolatedWorld as? NSNumber)?.intValue, 123)
    }

    // MARK: - Document-start user scripts + the postMessage channel

    /// End-to-end: document-start injection -> real navigator.mediaSession ->
    /// setInterval poll -> window.__orbitPostMessage -> WebKitWebContents.mediaState. No step is mocked.
    func testMediaSessionUserScriptPostsMessageBackToMediaState() throws {
        let mediaState = try WebKitLiveEngineHost.runLive { () -> MediaState in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            engine.addUserScript(MediaSessionObserverScript.userScript, session: engine.defaultSession)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            _ = try await contents.evaluateJavaScript("""
            navigator.mediaSession.metadata = new MediaMetadata({ title: 'Orbit Live Test Track', artist: 'Orbit Live Test Artist' });
            navigator.mediaSession.playbackState = 'playing';
            true;
            """)

            let deadline = ContinuousClock.now + .seconds(10)
            while contents.mediaState.nowPlayingTitle != "Orbit Live Test Track" {
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            return contents.mediaState
        }

        XCTAssertEqual(mediaState.nowPlayingTitle, "Orbit Live Test Track")
        XCTAssertEqual(mediaState.nowPlayingArtist, "Orbit Live Test Artist")
        XCTAssertTrue(mediaState.hasActiveMediaSession)
        XCTAssertTrue(mediaState.isPlaying)
    }
}
