//  A real WebKit navigation to a real server that answers 401 until the right Basic credentials arrive.
//  Asserts on what the server received and what the page shows, not on the delegate being called.

import AppKit
import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class WebKitHTTPAuthenticationLiveTests: XCTestCase {

    private static let username = "orbit-user"
    private static let password = "correct horse"
    private static let marker = "orbit-protected-content"

    @MainActor
    private final class CredentialRecorder: WebContentsDelegate {
        var requests: [HTTPCredentialRequest] = []
        var answers: [HTTPCredentialResponse?] = []

        func webContents(_ contents: WebContents, requestsHTTPCredentials request: HTTPCredentialRequest) async -> HTTPCredentialResponse? {
            requests.append(request)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(
            routes: [:],
            authenticatedRoutes: [
                "/protected": LiveHTTPTestServer.AuthenticatedRoute(
                    realm: "Staff",
                    username: Self.username,
                    password: Self.password,
                    route: LiveHTTPTestServer.Route(
                        contentType: "text/html",
                        body: "<html><body>\(Self.marker)</body></html>"
                    )
                )
            ]
        )
    }

    private func pageText(_ contents: WebKitWebContents) async throws -> String {
        let text = try await contents.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
        return text ?? ""
    }

    private func open(
        answers: [HTTPCredentialResponse?]
    ) async throws -> (contents: WebKitWebContents, recorder: CredentialRecorder, server: LiveHTTPTestServer, window: NSWindow) {
        let server = try makeServer()
        let contents = try await WebKitLiveEngineHost.makeContents()
        let recorder = CredentialRecorder()
        recorder.answers = answers
        contents.delegate = recorder
        let window = LiveContextMenuGesture.host(contents)
        contents.load(server.baseURL.appendingPathComponent("protected"))
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        return (contents, recorder, server, window)
    }

    private func close(_ page: (contents: WebKitWebContents, recorder: CredentialRecorder, server: LiveHTTPTestServer, window: NSWindow)) {
        page.server.stop()
        page.window.orderOut(nil)
        page.contents.close()
    }

    func testCorrectCredentialsOpenThePageAndTheServerSeesThem() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let page = try await self.open(answers: [HTTPCredentialResponse(username: Self.username, password: Self.password)])
            defer { self.close(page) }

            XCTAssertEqual(page.recorder.requests.count, 1)
            let request = try XCTUnwrap(page.recorder.requests.first)
            XCTAssertEqual(request.host, "127.0.0.1")
            XCTAssertEqual(request.realm, "Staff")
            XCTAssertFalse(request.previousAttemptFailed)
            XCTAssertFalse(request.isProxy)
            let text = try await self.pageText(page.contents)
            XCTAssertEqual(text, Self.marker)

            let expected = "Basic " + Data("\(Self.username):\(Self.password)".utf8).base64EncodedString()
            XCTAssertTrue(
                page.server.requestLog.all.contains { $0.path == "/protected" && $0.headers["authorization"] == expected },
                "the server must have received the credentials the user typed"
            )
        }
    }

    func testRefusedCredentialsPromptAgainAndSaySo() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let page = try await self.open(answers: [
                HTTPCredentialResponse(username: Self.username, password: "wrong"),
                HTTPCredentialResponse(username: Self.username, password: Self.password),
            ])
            defer { self.close(page) }

            XCTAssertEqual(page.recorder.requests.map(\.previousAttemptFailed), [false, true])
            let text = try await self.pageText(page.contents)
            XCTAssertEqual(text, Self.marker)
        }
    }

    func testCancellingLeavesTheProtectedPageClosedAndDoesNotAskAgain() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let page = try await self.open(answers: [nil])
            defer { self.close(page) }

            XCTAssertEqual(page.recorder.requests.count, 1, "declining must end the challenge, not repeat the prompt")
            let text = try await self.pageText(page.contents)
            XCTAssertFalse(text.contains(Self.marker))
            XCTAssertFalse(page.server.requestLog.all.contains { $0.headers["authorization"] != nil })
        }
    }

    func testPromptAsksNotToRememberInAnEphemeralSession() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let page = try await self.open(answers: [nil])
            defer { self.close(page) }

            let request = try XCTUnwrap(page.recorder.requests.first)
            XCTAssertEqual(
                request.canRemember,
                page.contents.webView.configuration.websiteDataStore.isPersistent,
                "nothing may be offered for saving when the session writes nothing to disk"
            )
        }
    }
}
