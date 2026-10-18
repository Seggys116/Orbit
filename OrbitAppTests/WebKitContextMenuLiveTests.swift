//  A real right-click on a real page: what the engine reports about the clicked target, from the top frame
//  and from frames inside it, and how that report maps onto the context Orbit's menu is built from.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class WebKitContextMenuLiveTests: XCTestCase {

    // MARK: - Fixtures

    @MainActor
    private final class MenuRecorder: WebContentsDelegate {
        private(set) var contexts: [ContextMenuContext] = []

        func webContents(_ contents: WebContents, showContextMenu context: ContextMenuContext) -> Bool {
            contexts.append(context)
            return true
        }
    }

    private static let fill = "position:fixed;left:0;top:0;width:100%;height:100%;margin:0;border:0;display:block"

    /// Right-clicks the page's centre until a menu is reported, so a click that lands before the page is hit-testable is retried.
    private func contextForRightClick(
        html: String,
        extraRoutes: [String: LiveHTTPTestServer.Route] = [:],
        configure: ((WebKitWebContents) async throws -> Void)? = nil
    ) async throws -> ContextMenuContext {
        var routes = extraRoutes
        routes["/"] = LiveHTTPTestServer.Route(contentType: "text/html; charset=utf-8", body: html)
        let server = try LiveHTTPTestServer(routes: routes)
        defer { server.stop() }
        let contents = try await WebKitLiveEngineHost.makeContents()
        defer { contents.close() }
        let recorder = MenuRecorder()
        contents.delegate = recorder
        let window = LiveContextMenuGesture.host(contents)
        defer { window.orderOut(nil) }
        contents.load(server.baseURL)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        try await Task.sleep(for: .milliseconds(500))
        try await configure?(contents)

        let deadline = ContinuousClock.now + .seconds(20)
        while recorder.contexts.isEmpty {
            window.contentView?.layoutSubtreeIfNeeded()
            LiveContextMenuGesture.rightClickCentre(of: contents, in: window)
            try await Task.sleep(for: .milliseconds(600))
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "a right-click never produced a context menu request")
            }
        }
        var context = try XCTUnwrap(recorder.contexts.first)
        context.pageURL = context.pageURL ?? server.baseURL
        return context
    }

    // MARK: - Top frame targets

    func testRightClickOnALinkReportsItsDestinationTitleAndFrame() throws {
        let context = try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.contextForRightClick(
                html: "<html><body><a href=\"/destination\" title=\"The destination\" style=\"\(Self.fill)\">go</a></body></html>"
            )
        }
        XCTAssertEqual(context.linkURL?.path, "/destination")
        XCTAssertEqual(context.unfilteredLinkURL?.path, "/destination")
        XCTAssertEqual(context.titleText, "The destination")
        XCTAssertEqual(context.frameURL, context.pageURL, "a top-frame click reports the page as its frame")
        XCTAssertEqual(context.mediaKind, .none)
        XCTAssertFalse(context.isEditable)
    }

    func testRightClickOnAnImageReportsItsSourceAndKind() throws {
        let context = try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.contextForRightClick(
                html: "<html><body><img src=\"/pic.png\" style=\"\(Self.fill);object-fit:contain\"></body></html>",
                extraRoutes: ["/pic.png": LiveHTTPTestServer.Route(contentType: "image/png", data: LiveMediaFixtures.png)]
            )
        }
        XCTAssertEqual(context.mediaKind, .image)
        XCTAssertEqual(context.sourceURL?.path, "/pic.png")
        XCTAssertNil(context.linkURL)
    }

    func testRightClickOnAVideoReportsAVideoWithItsSource() throws {
        let context = try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.contextForRightClick(
                html: "<html><body><video src=\"/clip.webm\" muted style=\"\(Self.fill)\"></video></body></html>",
                extraRoutes: ["/clip.webm": LiveHTTPTestServer.Route(contentType: "video/webm", data: LiveMediaFixtures.videoWebM, supportsRangeRequests: true)]
            )
        }
        XCTAssertEqual(context.mediaKind, .video)
        XCTAssertEqual(context.sourceURL?.path, "/clip.webm")
    }

    func testRightClickOnSelectedTextReportsTheSelection() throws {
        let context = try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.contextForRightClick(
                html: "<html><body style=\"margin:0\"><p id=\"p\" style=\"\(Self.fill);display:flex;align-items:center;justify-content:center;font-size:60px\">orbit selection text</p></body></html>"
            ) { contents in
                _ = try await contents.evaluateJavaScript(
                    "var r = document.createRange(); r.selectNodeContents(document.getElementById('p')); var s = getSelection(); s.removeAllRanges(); s.addRange(r); 1"
                )
            }
        }
        XCTAssertEqual(context.selectionText, "orbit selection text")
    }

    func testRightClickInAMisspelledEditableFieldReportsTheWordAndSuggestions() throws {
        let context = try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.contextForRightClick(
                html: "<html><body><textarea spellcheck=\"true\" style=\"\(Self.fill);font-size:40px\">teh</textarea></body></html>"
            ) { contents in
                // The caret ends the word, which is where a right-click below the text lands it.
                _ = try await contents.evaluateJavaScript(
                    "var t = document.querySelector('textarea'); t.focus(); t.setSelectionRange(3, 3); 1"
                )
            }
        }
        XCTAssertTrue(context.isEditable)
        XCTAssertEqual(context.misspelledWord, "teh")
        XCTAssertTrue(context.dictionarySuggestions.contains("the"), "suggestions were \(context.dictionarySuggestions)")
    }

    // MARK: - Frames

    func testRightClickInASameOriginFrameReportsTheFramesOwnTargetAndURL() throws {
        let context = try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.contextForRightClick(
                html: "<html><body><iframe src=\"/inner\" style=\"\(Self.fill)\"></iframe></body></html>",
                extraRoutes: ["/inner": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: "<html><body style=\"margin:0\"><a href=\"/inner-target\" style=\"\(Self.fill)\">in frame</a></body></html>"
                )]
            )
        }
        XCTAssertEqual(context.linkURL?.path, "/inner-target", "the link inside the frame was not reported")
        XCTAssertEqual(context.frameURL?.path, "/inner")
        XCTAssertEqual(context.pageURL?.path, "/", "the page is the top document, not the frame")
    }

    func testRightClickInACrossOriginFrameIsReportedLikeAnyOther() throws {
        let context = try WebKitLiveEngineHost.runLive(timeout: 90) {
            let other = try LiveHTTPTestServer(routes: [
                "/inner": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: "<html><body style=\"margin:0\"><a href=\"/foreign-target\" title=\"Foreign\" style=\"\(Self.fill)\">elsewhere</a></body></html>"
                ),
            ])
            defer { other.stop() }
            return try await self.contextForRightClick(
                html: "<html><body><iframe src=\"\(other.baseURL.absoluteString)/inner\" style=\"\(Self.fill)\"></iframe></body></html>"
            )
        }
        XCTAssertEqual(context.linkURL?.path, "/foreign-target", "a cross-origin frame hid its target from the menu")
        XCTAssertEqual(context.titleText, "Foreign")
        XCTAssertEqual(context.frameURL?.path, "/inner")
        XCTAssertNotEqual(context.frameURL?.port, context.pageURL?.port, "the frame should be on a different origin than the page")
    }

    // MARK: - Point probe

    func testProbingAPointFindsAudioAndCanvasTargets() throws {
        let kinds = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (audio: ContextMenuContext, canvas: ContextMenuContext) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html; charset=utf-8", body: """
                <html><body style="margin:0">
                <audio controls src="/clip.webm" style="position:absolute;left:0;top:0;width:300px;height:54px"></audio>
                <canvas style="position:absolute;left:0;top:120px;width:200px;height:100px"></canvas>
                </body></html>
                """),
                "/clip.webm": LiveHTTPTestServer.Route(contentType: "audio/webm", data: LiveMediaFixtures.audioWebM, supportsRangeRequests: true),
            ])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            let recorder = MenuRecorder()
            contents.delegate = recorder
            let window = LiveContextMenuGesture.host(contents)
            defer { window.orderOut(nil) }
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            contents.openContextMenu(atCSS: CGPoint(x: 20, y: 20))
            contents.openContextMenu(atCSS: CGPoint(x: 50, y: 150))
            let deadline = ContinuousClock.now + .seconds(10)
            while recorder.contexts.count < 2 {
                guard ContinuousClock.now < deadline else {
                    throw EngineError(code: .engineUnavailable, underlyingDescription: "the point probes never reported")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let audio = try XCTUnwrap(recorder.contexts.first { $0.mediaKind == .audio })
            let canvas = try XCTUnwrap(recorder.contexts.first { $0.mediaKind == .canvas })
            return (audio, canvas)
        }
        XCTAssertEqual(kinds.audio.sourceURL?.path, "/clip.webm")
        XCTAssertNil(kinds.canvas.sourceURL)
    }

    // MARK: - Report mapping

    func testReportMapsEveryFieldOntoTheMenuContext() {
        let context = WebKitWebContents.contextMenuContext(
            from: [
                "href": "https://example.com/a",
                "src": "https://example.com/v.mp4",
                "media": "video",
                "selection": "chosen words",
                "editable": true,
                "title": "A title",
                "frame": "https://frames.example.com/f",
                "word": "wrod",
            ],
            pageURL: URL(string: "https://example.com/page"),
            location: CGPoint(x: 12, y: 34),
            spelling: { word in (word, ["word", "wood"]) }
        )
        XCTAssertEqual(context.pageURL?.absoluteString, "https://example.com/page")
        XCTAssertEqual(context.frameURL?.absoluteString, "https://frames.example.com/f")
        XCTAssertEqual(context.linkURL?.absoluteString, "https://example.com/a")
        XCTAssertEqual(context.unfilteredLinkURL?.absoluteString, "https://example.com/a")
        XCTAssertEqual(context.sourceURL?.absoluteString, "https://example.com/v.mp4")
        XCTAssertEqual(context.mediaKind, .video)
        XCTAssertEqual(context.selectionText, "chosen words")
        XCTAssertEqual(context.titleText, "A title")
        XCTAssertTrue(context.isEditable)
        XCTAssertEqual(context.misspelledWord, "wrod")
        XCTAssertEqual(context.dictionarySuggestions, ["word", "wood"])
        XCTAssertEqual(context.location, CGPoint(x: 12, y: 34))
    }

    func testReportOmitsEmptyFieldsAndOnlySpellChecksEditableTargets() {
        var checked: [String] = []
        let spelling: (String) -> (word: String, suggestions: [String])? = { word in
            checked.append(word)
            return (word, [])
        }
        let plain = WebKitWebContents.contextMenuContext(
            from: ["href": "", "src": "", "media": "", "selection": "", "editable": false, "title": "", "frame": "", "word": "wrod"],
            pageURL: nil,
            location: .zero,
            spelling: spelling
        )
        XCTAssertNil(plain.linkURL)
        XCTAssertNil(plain.sourceURL)
        XCTAssertNil(plain.selectionText)
        XCTAssertNil(plain.titleText)
        XCTAssertNil(plain.frameURL)
        XCTAssertEqual(plain.mediaKind, .none)
        XCTAssertNil(plain.misspelledWord, "a word outside an editable field is never spell-checked")
        XCTAssertTrue(checked.isEmpty)

        let correct = WebKitWebContents.contextMenuContext(
            from: ["editable": true, "word": "word"], pageURL: nil, location: .zero, spelling: { _ in nil }
        )
        XCTAssertNil(correct.misspelledWord, "a correctly spelled word reports no misspelling")
        XCTAssertEqual(correct.dictionarySuggestions, [])
    }

    func testSpellingVerdictFlagsANonsenseWordAndAcceptsARealOne() {
        XCTAssertNil(WebKitWebContents.spellingVerdict(for: "word"))
        let verdict = WebKitWebContents.spellingVerdict(for: "wrodzx")
        XCTAssertEqual(verdict?.word, "wrodzx")
    }
}
