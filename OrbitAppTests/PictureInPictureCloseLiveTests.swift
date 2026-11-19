import AppKit
import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class PictureInPictureCloseLiveTests: LiveEnvironmentTestCase {

    private static let pageHTML =
        "<!DOCTYPE html><html><body><video id=\"v\" src=\"/v.webm\" muted loop playsinline></video></body></html>"

    private struct AfterClose {
        var entered: Bool
        var parked: Bool
        var hostWindowsLeft: Int
        var webViewAlive: Bool
        var webViewHasWindow: Bool
        var webViewHasSuperview: Bool
        var mediaStillPlaying: Bool
        var pageStillFloating: Bool
        var contentsAlive: Bool
    }

    private func waitUntil(timeout: Duration = .seconds(15), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private static func pageBool(_ webView: WKWebView, _ expression: String) async -> Bool? {
        try? await webView.evaluateJavaScript(expression) as? Bool
    }

    private static func visibleHostWindows() -> Int {
        NSApp.windows.filter { $0 is PictureInPictureHostWindow && $0.isVisible }.count
    }

    private enum Closing {
        case closeTab
        case archive
        case closeTabFromAnotherWindow
        case closeTheWindowHoldingIt
        case deleteSpace
    }

    private func closeWhileFloating(backgroundBeforeClosing: Bool, closing: Closing = .closeTab) throws -> AfterClose {
        try WebKitLiveEngineHost.runLive(timeout: 90) { () -> AfterClose in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.pageHTML),
                "/v.webm": LiveHTTPTestServer.Route(
                    contentType: "video/webm", data: LiveMediaFixtures.videoWebM, supportsRangeRequests: true
                ),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            engine.addUserScript(MediaSessionObserverScript.userScript, session: engine.defaultSession)
            var contents: WebKitWebContents? = try await WebKitLiveEngineHost.makeContents(engine: engine)
            weak var weakContents = contents
            weak var weakWebView = contents?.webView
            let pane = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            pane.isReleasedWhenClosed = false
            pane.contentView = contents!.view
            pane.orderFront(nil)
            defer {
                pane.orderOut(nil)
                pane.contentView = nil
            }

            let spaces = self.env.spaces
            XCTAssertGreaterThan(spaces.count, 1, "deleting a Space needs another to remain")
            let spaceID = try XCTUnwrap(closing == .deleteSpace ? spaces.last?.id : spaces.first?.id)
            let tabID = self.env.openTab(url: server.baseURL, in: spaceID, activate: false)
            let otherWindow = AppEnvironment.makeWindowScoped(
                sharing: self.env, activeSpaceID: spaceID, isIndependentStandardWindow: true
            )
            let holder = closing == .closeTheWindowHoldingIt ? otherWindow : self.env
            holder._test_attachWebContents(contents!, for: tabID)
            contents!.delegate = holder

            contents!.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents!)
            _ = try await contents!.evaluateJavaScript("""
            var v = document.getElementById('v');
            window.__playing = false;
            v.addEventListener('playing', function() { window.__playing = true; });
            v.play();
            true;
            """)
            let playing = await self.waitUntil {
                (try? await contents!.evaluateJavaScript("window.__playing === true") as? Bool) == true
            }
            XCTAssertTrue(playing, "the fixture video never started playing")

            contents!.togglePictureInPicture()
            let entered = await self.waitUntil {
                (try? await contents!.evaluateJavaScript("!!document.pictureInPictureElement") as? Bool) == true
            }
            _ = await self.waitUntil { contents!.mediaState.isPictureInPictureActive }

            var parked = false
            if backgroundBeforeClosing {
                contents!.setVisible(false)
                pane.contentView = nil
                contents!.mediaState.isPictureInPictureActive = false
                contents!.mediaState.isPictureInPictureActive = true
                parked = contents!.webView.window is PictureInPictureHostWindow
            }

            switch closing {
            case .closeTab: self.env.closeTab(tabID)
            case .archive: self.env.archiveTab(tabID)
            case .closeTabFromAnotherWindow: otherWindow.closeTab(tabID)
            case .closeTheWindowHoldingIt: otherWindow.disposeWindowSession()
            case .deleteSpace: self.env.deleteSpace(spaceID)
            }
            XCTAssertNil(holder.webContents[tabID], "the window that held the page still lists it after the close")
            contents = nil

            try await Task.sleep(for: .seconds(2))

            let webView = weakWebView
            var stillPlaying = false
            var stillFloating = false
            if let webView {
                stillPlaying = await Self.pageBool(webView, "!document.getElementById('v').paused") ?? false
                stillFloating = await Self.pageBool(webView, "!!document.pictureInPictureElement") ?? false
            }
            return AfterClose(
                entered: entered,
                parked: parked,
                hostWindowsLeft: Self.visibleHostWindows(),
                webViewAlive: webView != nil,
                webViewHasWindow: webView?.window != nil,
                webViewHasSuperview: webView?.superview != nil,
                mediaStillPlaying: stillPlaying,
                pageStillFloating: stillFloating,
                contentsAlive: weakContents != nil
            )
        }
    }

    private func assertFullyReleased(_ outcome: AfterClose, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(outcome.entered, "the page never entered picture-in-picture, so this test proved nothing", file: file, line: line)
        XCTAssertEqual(outcome.hostWindowsLeft, 0, "a PictureInPictureHostWindow outlived the closed tab", file: file, line: line)
        XCTAssertFalse(outcome.webViewHasWindow, "the closed tab's web view is still in a window", file: file, line: line)
        XCTAssertFalse(outcome.webViewHasSuperview, "the closed tab's web view still has a superview", file: file, line: line)
        XCTAssertFalse(outcome.mediaStillPlaying, "the closed tab's video is still playing", file: file, line: line)
        XCTAssertFalse(outcome.pageStillFloating, "the closed tab's video is still in picture-in-picture", file: file, line: line)
        XCTAssertFalse(outcome.webViewAlive, "the closed tab's WKWebView was never deallocated", file: file, line: line)
        XCTAssertFalse(outcome.contentsAlive, "the closed tab's WebKitWebContents was never deallocated", file: file, line: line)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testClosingTheVisibleTabEndsPictureInPictureAndReleasesThePage
    func testClosingTheVisibleTabEndsPictureInPictureAndReleasesThePage() throws {
        assertFullyReleased(try closeWhileFloating(backgroundBeforeClosing: false))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testClosingAParkedBackgroundTabEndsPictureInPictureAndReleasesThePage
    func testClosingAParkedBackgroundTabEndsPictureInPictureAndReleasesThePage() throws {
        assertParkedAndFullyReleased(try closeWhileFloating(backgroundBeforeClosing: true))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testArchivingAParkedBackgroundTabEndsPictureInPictureAndReleasesThePage
    func testArchivingAParkedBackgroundTabEndsPictureInPictureAndReleasesThePage() throws {
        assertParkedAndFullyReleased(try closeWhileFloating(backgroundBeforeClosing: true, closing: .archive))
    }

    /// The page lives in the window that last showed it, and the tab can be closed from another window's sidebar.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testClosingTheTabFromAnotherWindowEndsPictureInPictureAndReleasesThePage
    func testClosingTheTabFromAnotherWindowEndsPictureInPictureAndReleasesThePage() throws {
        assertParkedAndFullyReleased(try closeWhileFloating(backgroundBeforeClosing: true, closing: .closeTabFromAnotherWindow))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testClosingTheWindowHoldingThePageEndsPictureInPictureAndReleasesIt
    func testClosingTheWindowHoldingThePageEndsPictureInPictureAndReleasesIt() throws {
        assertParkedAndFullyReleased(try closeWhileFloating(backgroundBeforeClosing: true, closing: .closeTheWindowHoldingIt))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testDeletingTheSpaceEndsPictureInPictureAndReleasesThePage
    func testDeletingTheSpaceEndsPictureInPictureAndReleasesThePage() throws {
        assertParkedAndFullyReleased(try closeWhileFloating(backgroundBeforeClosing: true, closing: .deleteSpace))
    }

    private func assertParkedAndFullyReleased(_ outcome: AfterClose, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(outcome.parked, "the background tab was never parked in its stand-in window, so this test proved nothing", file: file, line: line)
        assertFullyReleased(outcome, file: file, line: line)
    }
}
