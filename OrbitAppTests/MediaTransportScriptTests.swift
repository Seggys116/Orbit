import JavaScriptCore
import XCTest
@testable import Orbit

final class MediaTransportScriptTests: XCTestCase {

    // MARK: - A minimal page

    private final class PageStub {
        let context = JSContext()!

        private(set) var passedThroughActions: [String] = []

        private(set) var elements: JSValue!

        init(mediaElements: [(paused: Bool, readyState: Int, currentTime: Double)] = []) {
            context.exceptionHandler = { _, exception in
                XCTFail("JavaScript exception: \(exception?.toString() ?? "unknown")")
            }

            // JSC has no `window`; bind it before the script runs.
            context.evaluateScript("var window = this;")

            let recordPassThrough: @convention(block) (String) -> Void = { [weak self] action in
                self?.passedThroughActions.append(action)
            }
            context.setObject(recordPassThrough, forKeyedSubscript: "__recordPassThrough" as NSString)

            context.evaluateScript("""
            var navigator = {
              mediaSession: {
                setActionHandler: function(action, handler) {
                  __recordPassThrough(action);
                  this.__real = this.__real || {};
                  if (handler) { this.__real[action] = handler; } else { delete this.__real[action]; }
                }
              }
            };
            var __elements = [];
            var document = {
              querySelectorAll: function() { return __elements; }
            };
            """)

            let literals = mediaElements.map { element in
                """
                { paused: \(element.paused), readyState: \(element.readyState), \
                currentTime: \(element.currentTime), playCount: 0, pauseCount: 0, \
                play: function() { this.playCount++; this.paused = false; return null; }, \
                pause: function() { this.pauseCount++; this.paused = true; } }
                """
            }
            context.evaluateScript("__elements = [\(literals.joined(separator: ", "))];")
            elements = context.objectForKeyedSubscript("__elements")

            context.evaluateScript(MediaTransportScript.source)
        }

        func invoke(_ action: MediaTransportScript.Action) -> Bool {
            context.evaluateScript(MediaTransportScript.invocation(for: action))?.toBool() ?? false
        }

        func registerHandler(for action: String) {
            context.evaluateScript("""
            window.__ran = window.__ran || [];
            navigator.mediaSession.setActionHandler('\(action)', function(details) {
              window.__ran.push(details && details.action ? details.action : '\(action)');
            });
            """)
        }

        var handlersThatRan: [String] {
            context.evaluateScript("window.__ran || []")?.toArray() as? [String] ?? []
        }

        func element(_ index: Int) -> JSValue {
            elements.atIndex(index)
        }
    }

    // MARK: - Previous / next track

    func test_nextTrack_invokesTheHandlerThePageRegistered() {
        let page = PageStub()
        page.registerHandler(for: "nexttrack")

        XCTAssertTrue(page.invoke(.nextTrack), "The page registered a nexttrack handler, so the invocation must report success.")
        XCTAssertEqual(page.handlersThatRan, ["nexttrack"], "The page's own next-track handler must be the thing that ran.")
    }

    func test_previousTrack_invokesTheHandlerThePageRegistered() {
        let page = PageStub()
        page.registerHandler(for: "previoustrack")

        XCTAssertTrue(page.invoke(.previousTrack))
        XCTAssertEqual(page.handlersThatRan, ["previoustrack"])
    }

    func test_nextTrack_withNoHandlerRegistered_reportsFailureRatherThanPretending() {
        let page = PageStub(mediaElements: [(paused: false, readyState: 4, currentTime: 12)])

        XCTAssertFalse(page.invoke(.nextTrack), "There is no DOM equivalent of 'next track'; reporting success here would be a lie.")
        XCTAssertTrue(page.handlersThatRan.isEmpty)
        XCTAssertEqual(
            page.element(0).forProperty("pauseCount")?.toInt32(), 0,
            "A failed next-track must not fall back to touching playback at all."
        )
    }

    func test_handlerRegisteredAfterInjection_isStillCaptured() {
        let page = PageStub()
        XCTAssertFalse(page.invoke(.nextTrack), "Nothing is registered yet.")

        page.registerHandler(for: "nexttrack")

        XCTAssertTrue(page.invoke(.nextTrack), "A handler registered later must be reachable.")
    }

    func test_theSitesOwnSetActionHandlerIsStillCalled() {
        let page = PageStub()
        page.registerHandler(for: "nexttrack")
        page.registerHandler(for: "play")

        XCTAssertEqual(
            page.passedThroughActions, ["nexttrack", "play"],
            "The wrapper must pass every registration through, or Orbit breaks the site's own media-key handling."
        )
    }

    func test_clearingAHandler_removesItAgain() {
        let page = PageStub()
        page.registerHandler(for: "nexttrack")
        XCTAssertTrue(page.invoke(.nextTrack))

        page.context.evaluateScript("navigator.mediaSession.setActionHandler('nexttrack', null);")

        XCTAssertFalse(page.invoke(.nextTrack), "A handler the page removed must not keep being invoked.")
    }

    // MARK: - Play / pause

    func test_pause_fallsBackToThePlayingMediaElement_whenTheSiteRegistersNoHandler() {
        let page = PageStub(mediaElements: [(paused: false, readyState: 4, currentTime: 30)])

        XCTAssertTrue(page.invoke(.pause))
        XCTAssertEqual(page.element(0).forProperty("pauseCount")?.toInt32(), 1)
        XCTAssertTrue(page.element(0).forProperty("paused")!.toBool())
    }

    func test_play_fallsBackToThePausedMediaElement_whenTheSiteRegistersNoHandler() {
        let page = PageStub(mediaElements: [(paused: true, readyState: 4, currentTime: 30)])

        XCTAssertTrue(page.invoke(.play))
        XCTAssertEqual(page.element(0).forProperty("playCount")?.toInt32(), 1)
        XCTAssertFalse(page.element(0).forProperty("paused")!.toBool())
    }

    func test_pause_prefersTheSitesHandlerOverTheElementFallback() {
        let page = PageStub(mediaElements: [(paused: false, readyState: 4, currentTime: 30)])
        page.registerHandler(for: "pause")

        XCTAssertTrue(page.invoke(.pause))
        XCTAssertEqual(page.handlersThatRan, ["pause"])
        XCTAssertEqual(
            page.element(0).forProperty("pauseCount")?.toInt32(), 0,
            "The DOM fallback must not run when the site handled it."
        )
    }

    func test_pause_withNothingPlaying_reportsFailure() {
        let page = PageStub(mediaElements: [(paused: true, readyState: 4, currentTime: 0)])

        XCTAssertFalse(page.invoke(.pause), "Nothing was playing, so nothing was paused.")
    }

    // MARK: - Injection shape

    func test_userScript_isInjectedAtDocumentStartAsJavaScript() {
        let script = MediaTransportScript.userScript

        XCTAssertEqual(script.injectionTime, .documentStart)
        XCTAssertEqual(script.kind, .javaScript)
        XCTAssertEqual(script.id, MediaTransportScript.scriptID, "A stable id is what stops a session accumulating duplicates.")
    }

    func test_runningTheScriptTwice_doesNotDoubleWrapSetActionHandler() {
        let page = PageStub()
        page.context.evaluateScript(MediaTransportScript.source)
        page.registerHandler(for: "nexttrack")

        XCTAssertEqual(
            page.passedThroughActions, ["nexttrack"],
            "A doubled wrapper would forward the same registration more than once."
        )
        XCTAssertTrue(page.invoke(.nextTrack))
    }

    func test_invocation_onAPageWithoutTheScript_evaluatesToFalse() {
        let bare = JSContext()!
        bare.evaluateScript("var window = this;")

        let result = bare.evaluateScript(MediaTransportScript.invocation(for: .nextTrack))

        XCTAssertNil(bare.exception, "The invocation must not throw on a page the script never reached.")
        XCTAssertFalse(result?.toBool() ?? true)
    }

    func test_everyActionHasItsOwnMediaSessionName() {
        let names = MediaTransportScript.Action.allCases.map(\.rawValue)

        XCTAssertEqual(Set(names).count, names.count, "Two actions sharing a name would make one of the buttons drive the other.")
        XCTAssertEqual(Set(names), ["play", "pause", "previoustrack", "nexttrack"], "These are Media Session's own action names and the page keys its handlers by them.")
    }
}
