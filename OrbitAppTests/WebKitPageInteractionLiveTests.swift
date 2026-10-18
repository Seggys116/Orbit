//  Page-facing behaviour WebKit asks the embedder for: dialogs, the file chooser, window.close(), a dead
//  web process, element fullscreen and muting. Each asserts on what the page or the engine did, not on a call being made.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class WebKitPageInteractionLiveTests: XCTestCase {

    // MARK: - Recorder

    @MainActor
    private final class PageRecorder: WebContentsDelegate {
        var dialogs: [JavaScriptDialogRequest] = []
        var dialogAnswer: (JavaScriptDialogRequest) -> JavaScriptDialogResponse = { _ in JavaScriptDialogResponse(accepted: true) }

        struct OpenPanelCall: Equatable {
            var allowsMultiple: Bool
            var allowsDirectories: Bool
            var acceptedTypes: [String]
        }
        var openPanelCalls: [OpenPanelCall] = []
        var openPanelAnswer: [URL] = []

        var adopted: [any WebContents] = []
        var closeRequests = 0
        var crashes = 0
        var fullscreenChanges: [Bool] = []
        var mediaStates: [MediaState] = []

        func webContents(_ contents: WebContents, runJavaScriptDialog request: JavaScriptDialogRequest) async -> JavaScriptDialogResponse {
            dialogs.append(request)
            return dialogAnswer(request)
        }

        func webContents(
            _ contents: WebContents,
            runOpenPanelAllowingMultiple allowsMultiple: Bool,
            allowsDirectories: Bool,
            acceptedTypes: [String]
        ) async -> [URL] {
            openPanelCalls.append(OpenPanelCall(allowsMultiple: allowsMultiple, allowsDirectories: allowsDirectories, acceptedTypes: acceptedTypes))
            return openPanelAnswer
        }

        func webContents(_ contents: WebContents, requestsAdoptionOf pending: PendingWebContents) -> Bool {
            guard let opened = pending.adopt() else { return false }
            adopted.append(opened)
            return true
        }

        func webContentsDidRequestClose(_ contents: WebContents) { closeRequests += 1 }
        func webContentsDidCrash(_ contents: WebContents) { crashes += 1 }
        func webContents(_ contents: WebContents, didChangeFullscreen isFullscreen: Bool) { fullscreenChanges.append(isFullscreen) }
        func webContents(_ contents: WebContents, didChangeMediaState state: MediaState) { mediaStates.append(state) }

        func closeAdopted() {
            for contents in adopted { contents.close() }
            adopted.removeAll()
        }
    }

    private func waitUntil(
        _ description: @autoclosure @escaping () -> String,
        timeout: Duration = .seconds(10),
        _ predicate: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !predicate() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: description())
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func hostedPage(
        html: String,
        routes extra: [String: LiveHTTPTestServer.Route] = [:]
    ) async throws -> (contents: WebKitWebContents, recorder: PageRecorder, server: LiveHTTPTestServer, window: NSWindow) {
        var routes = extra
        routes["/"] = LiveHTTPTestServer.Route(contentType: "text/html; charset=utf-8", body: html)
        let server = try LiveHTTPTestServer(routes: routes)
        let contents = try await WebKitLiveEngineHost.makeContents()
        let recorder = PageRecorder()
        contents.delegate = recorder
        let window = LiveContextMenuGesture.host(contents)
        contents.load(server.baseURL)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        return (contents, recorder, server, window)
    }

    // MARK: - JavaScript dialogs

    func testAlertConfirmAndPromptReachTheDelegateAndTheirAnswersReachThePage() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let page = try await self.hostedPage(html: "<html><body>dialogs</body></html>")
            defer {
                page.server.stop()
                page.window.orderOut(nil)
                page.contents.close()
            }

            _ = try await page.contents.evaluateJavaScript("alert('hello from the page')")
            let alert = try XCTUnwrap(page.recorder.dialogs.last)
            XCTAssertEqual(alert.kind, .alert)
            XCTAssertEqual(alert.message, "hello from the page")
            XCTAssertEqual(alert.origin?.host, "127.0.0.1", "the dialog must say which origin is asking")

            page.recorder.dialogAnswer = { _ in JavaScriptDialogResponse(accepted: true) }
            let accepted = try await page.contents.evaluateJavaScript("confirm('Proceed?')") as? Bool
            XCTAssertEqual(accepted, true)
            XCTAssertEqual(page.recorder.dialogs.last?.kind, .confirm)

            page.recorder.dialogAnswer = { _ in JavaScriptDialogResponse(accepted: false) }
            let declined = try await page.contents.evaluateJavaScript("confirm('Proceed?')") as? Bool
            XCTAssertEqual(declined, false)

            page.recorder.dialogAnswer = { _ in JavaScriptDialogResponse(accepted: true, promptText: "Orbit") }
            let typed = try await page.contents.evaluateJavaScript("prompt('Name?', 'default name')") as? String
            XCTAssertEqual(typed, "Orbit")
            XCTAssertEqual(page.recorder.dialogs.last?.kind, .prompt)
            XCTAssertEqual(page.recorder.dialogs.last?.defaultPromptText, "default name")

            page.recorder.dialogAnswer = { _ in JavaScriptDialogResponse(accepted: false) }
            let cancelled = try await page.contents.evaluateJavaScript("String(prompt('Name?', 'x'))") as? String
            XCTAssertEqual(cancelled, "null", "cancelling a prompt must give the page null, not an empty string")
        }
    }

    // MARK: - File chooser

    func testFileInputsReachTheDelegateWithTheirConstraintsAndReceiveTheChosenFiles() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let page = try await self.hostedPage(html: """
            <html><body>
            <input id="plain" type="file" accept="image/png,.txt" multiple>
            <input id="folder" type="file" webkitdirectory>
            </body></html>
            """)
            defer {
                page.server.stop()
                page.window.orderOut(nil)
                page.contents.close()
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-filechooser-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("chosen.txt")
            try "orbit".write(to: file, atomically: true, encoding: .utf8)

            page.recorder.openPanelAnswer = [file]
            _ = try await page.contents.evaluateJavaScript("document.getElementById('plain').click()")
            try await self.waitUntil("the page never received the chosen file") {
                (try await page.contents.evaluateJavaScript("document.getElementById('plain').files.length") as? Int) == 1
            }
            let name = try await page.contents.evaluateJavaScript("document.getElementById('plain').files[0].name") as? String
            XCTAssertEqual(name, "chosen.txt")
            let call = try XCTUnwrap(page.recorder.openPanelCalls.first)
            XCTAssertTrue(call.allowsMultiple)
            XCTAssertFalse(call.allowsDirectories)
            XCTAssertTrue(call.acceptedTypes.contains("image/png"), "accept= MIME types were dropped: \(call.acceptedTypes)")
            XCTAssertTrue(call.acceptedTypes.contains(".txt"), "accept= extensions were dropped: \(call.acceptedTypes)")

            page.recorder.openPanelAnswer = []
            _ = try await page.contents.evaluateJavaScript("document.getElementById('folder').click()")
            try await self.waitUntil("a folder input never reached the delegate") { page.recorder.openPanelCalls.count == 2 }
            XCTAssertTrue(page.recorder.openPanelCalls[1].allowsDirectories, "a webkitdirectory input must let the panel choose folders")
            let chosen = try await page.contents.evaluateJavaScript("document.getElementById('folder').files.length") as? Int
            XCTAssertEqual(chosen, 0, "cancelling the panel must leave the input empty")
        }
    }

    // MARK: - window.close()

    func testWindowCloseInAScriptOpenedWindowAsksTheDelegateToCloseIt() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let page = try await self.hostedPage(html: "<html><body>opener</body></html>")
            defer {
                page.server.stop()
                page.window.orderOut(nil)
                page.recorder.closeAdopted()
                page.contents.close()
            }
            _ = try await page.contents.evaluateJavaScript("window.open('about:blank', '_blank')", userGesture: true)
            try await self.waitUntil("window.open produced no window") { !page.recorder.adopted.isEmpty }
            let popup = try XCTUnwrap(page.recorder.adopted.first as? WebKitWebContents)
            let popupRecorder = PageRecorder()
            popup.delegate = popupRecorder

            _ = try await popup.evaluateJavaScript("window.close()")
            try await self.waitUntil("window.close() never reached the delegate's close path") { popupRecorder.closeRequests == 1 }
        }
    }

    // MARK: - Crash recovery

    func testAKilledWebProcessIsReportedAsACrashAndReloadRecoversThePage() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let page = try await self.hostedPage(html: "<html><head><title>before crash</title></head><body>alive</body></html>")
            defer {
                page.server.stop()
                page.window.orderOut(nil)
                page.contents.close()
            }
            let kill = NSSelectorFromString("_killWebContentProcess")
            if page.contents.webView.responds(to: kill) {
                WebKitWebContents.voidMessage(page.contents.webView, "_killWebContentProcess")
            } else {
                page.contents.webViewWebContentProcessDidTerminate(page.contents.webView)
            }
            try await self.waitUntil("a dead web process was never reported to the delegate") { page.recorder.crashes == 1 }
            XCTAssertFalse(page.contents.navigationState.isLoading, "a crashed tab must not keep showing a load in progress")

            page.contents.reload(ignoringCache: false)
            try await self.waitUntil("reload never brought the page back after the crash", timeout: .seconds(20)) {
                (try? await page.contents.evaluateJavaScript("document.title")) as? String == "before crash"
            }
        }
    }

    // MARK: - Element fullscreen

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testElementFullscreenIsReportedBothWaysAndThePageReturnsToItsPane
    // The hosted runner never enters element fullscreen. The same test passes on a real Mac.
    func testElementFullscreenIsReportedBothWaysAndThePageReturnsToItsPane() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.hostedPage(html: "<html><body style=\"margin:0\"><div id=\"stage\" style=\"width:100%;height:100%\">stage</div></body></html>")
            defer {
                page.server.stop()
                page.window.orderOut(nil)
                page.contents.close()
            }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            page.window.setContentSize(NSSize(width: 640, height: 480))
            page.window.contentView = container
            page.contents.embedForInspectorDocking(in: container)
            container.layoutSubtreeIfNeeded()
            page.contents.setVisible(true)

            _ = try await page.contents.evaluateJavaScript("document.getElementById('stage').requestFullscreen(); 1")
            try await self.waitUntil("the page never entered element fullscreen", timeout: .seconds(15)) {
                page.recorder.fullscreenChanges.last == true
            }
            XCTAssertTrue(page.contents.mediaState.isFullscreen, "media state must say a fullscreen element is showing")

            _ = try await page.contents.evaluateJavaScript("document.exitFullscreen(); 1")
            try await self.waitUntil("the page never left element fullscreen", timeout: .seconds(15)) {
                page.recorder.fullscreenChanges.last == false
            }
            XCTAssertFalse(page.contents.mediaState.isFullscreen)
            try await self.waitUntil("the page did not return to its pane after fullscreen") {
                page.contents.view.isDescendant(of: container)
            }
            container.layoutSubtreeIfNeeded()
            XCTAssertEqual(page.contents.view.frame.size.width, 640, accuracy: 1)
            container.setFrameSize(NSSize(width: 500, height: 400))
            container.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                page.contents.view.frame.size.width, 500, accuracy: 1,
                "the page stopped following its pane after fullscreen"
            )
        }
    }

    // MARK: - Mute

    func testMutingSilencesPlaybackWithoutPausingItAndUnmutingRestoresIt() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.hostedPage(
                html: "<html><body><audio id=\"a\" src=\"/clip.webm\" loop></audio></body></html>",
                routes: ["/clip.webm": LiveHTTPTestServer.Route(contentType: "audio/webm", data: LiveMediaFixtures.audioWebM, supportsRangeRequests: true)]
            )
            defer {
                page.server.stop()
                page.window.orderOut(nil)
                page.contents.close()
            }
            _ = try await page.contents.evaluateJavaScript("document.getElementById('a').play().catch(function(){}); 1")
            try await self.waitUntil("the audio never started playing", timeout: .seconds(20)) {
                (try await page.contents.evaluateJavaScript("!document.getElementById('a').paused && document.getElementById('a').currentTime > 0") as? Bool) == true
            }

            page.contents.setMuted(true)
            try await self.waitUntil("muting never reached the page's media element") {
                (try await page.contents.evaluateJavaScript("document.getElementById('a').muted") as? Bool) == true
            }
            try await Task.sleep(for: .milliseconds(400))
            let stillPlaying = try await page.contents.evaluateJavaScript("!document.getElementById('a').paused") as? Bool
            XCTAssertEqual(stillPlaying, true, "muting paused the media instead of silencing it")
            XCTAssertTrue(page.contents.mediaState.isMuted)
            XCTAssertFalse(page.contents.mediaState.isAudible, "a muted tab must not report itself audible")

            page.contents.setMuted(false)
            try await self.waitUntil("unmuting never reached the page's media element") {
                (try await page.contents.evaluateJavaScript("document.getElementById('a').muted") as? Bool) == false
            }
            XCTAssertFalse(page.contents.mediaState.isMuted)
            let resumed = try await page.contents.evaluateJavaScript("!document.getElementById('a').paused") as? Bool
            XCTAssertEqual(resumed, true)
        }
    }
}
