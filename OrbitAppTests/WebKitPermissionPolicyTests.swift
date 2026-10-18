//  Stored per-site decisions answer WebKit permission requests; only unresolved kinds prompt.

import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class WebKitPermissionPolicyTests: XCTestCase {

    private let origin = URL(string: "https://camera.example")!

    private func makeSession() -> WebKitSession {
        WebKitSession(identifier: "permission-policy-\(UUID().uuidString)", persistent: false, storageURL: nil)
    }

    private final class Prompter {
        var requests: [PermissionRequest] = []
        var answer: PermissionDecision
        init(_ answer: PermissionDecision) { self.answer = answer }
        func ask(_ request: PermissionRequest) async -> PermissionDecision {
            requests.append(request)
            return answer
        }
    }

    func test_aStoredAllowGrantsWithoutPrompting() async {
        let session = makeSession()
        session.setContentSetting(.allow, for: .camera, url: origin)
        let prompter = Prompter(.deny)
        let granted = await WebKitPermissionPolicy.resolve(kinds: [.camera], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertTrue(granted)
        XCTAssertTrue(prompter.requests.isEmpty)
    }

    func test_aStoredBlockDeniesWithoutPrompting() async {
        let session = makeSession()
        session.setContentSetting(.block, for: .microphone, url: origin)
        let prompter = Prompter(.allow)
        let granted = await WebKitPermissionPolicy.resolve(kinds: [.microphone], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertFalse(granted)
        XCTAssertTrue(prompter.requests.isEmpty)
    }

    func test_askPromptsAndAOneOffAnswerIsNotRemembered() async {
        let session = makeSession()
        let prompter = Prompter(.allow)
        let granted = await WebKitPermissionPolicy.resolve(kinds: [.camera], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertTrue(granted)
        XCTAssertEqual(prompter.requests.count, 1)
        XCTAssertEqual(prompter.requests.first?.origin, origin)
        XCTAssertEqual(session.contentSetting(.camera, for: origin), .ask)
    }

    func test_aRememberedAnswerPersistsAndShortCircuitsTheNextRequest() async {
        let session = makeSession()
        let prompter = Prompter(.allowAlways)
        let first = await WebKitPermissionPolicy.resolve(kinds: [.camera], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertTrue(first)
        XCTAssertEqual(session.contentSetting(.camera, for: origin), .allow)
        let second = await WebKitPermissionPolicy.resolve(kinds: [.camera], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertTrue(second)
        XCTAssertEqual(prompter.requests.count, 1)

        prompter.answer = .denyAlways
        let other = URL(string: "https://other.example")!
        let denied = await WebKitPermissionPolicy.resolve(kinds: [.camera], origin: other, session: session, prompt: prompter.ask)
        XCTAssertFalse(denied)
        XCTAssertEqual(session.contentSetting(.camera, for: other), .block)
        XCTAssertEqual(session.contentSetting(.camera, for: origin), .allow, "decisions are per origin")
    }

    func test_cameraAndMicrophoneNeedBothAllowedAndOnlyPromptForTheMissingOne() async {
        let session = makeSession()
        session.setContentSetting(.allow, for: .camera, url: origin)
        XCTAssertEqual(
            WebKitPermissionPolicy.verdict(kinds: WebKitPermissionPolicy.kinds(for: .cameraAndMicrophone), origin: origin, session: session),
            .prompt([.microphone]))

        session.setContentSetting(.allow, for: .microphone, url: origin)
        XCTAssertEqual(
            WebKitPermissionPolicy.verdict(kinds: [.camera, .microphone], origin: origin, session: session), .grant)

        session.setContentSetting(.block, for: .camera, url: origin)
        XCTAssertEqual(
            WebKitPermissionPolicy.verdict(kinds: [.camera, .microphone], origin: origin, session: session), .deny,
            "one blocked kind blocks the whole request")
    }

    func test_mediaCaptureTypesMapToTheirKinds() {
        XCTAssertEqual(WebKitPermissionPolicy.kinds(for: .camera), [.camera])
        XCTAssertEqual(WebKitPermissionPolicy.kinds(for: .microphone), [.microphone])
        XCTAssertEqual(WebKitPermissionPolicy.kinds(for: .cameraAndMicrophone), [.camera, .microphone])
    }

    func test_anOriginWithNoStoredSettingSupportFallsThroughToThePrompt() async {
        let session = makeSession()
        let local = URL(string: "file:///tmp/page.html")!
        let prompter = Prompter(.allowAlways)
        let granted = await WebKitPermissionPolicy.resolve(kinds: [.camera], origin: local, session: session, prompt: prompter.ask)
        XCTAssertTrue(granted)
        XCTAssertEqual(prompter.requests.count, 1)
    }

    func test_aStoredLocationAllowGrantsWithoutPrompting() async {
        let session = makeSession()
        session.setContentSetting(.allow, for: .geolocation, url: origin)
        let prompter = Prompter(.deny)
        let granted = await WebKitPermissionPolicy.resolve(kinds: [.geolocation], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertTrue(granted)
        XCTAssertTrue(prompter.requests.isEmpty)
    }

    func test_aStoredLocationBlockDeniesWithoutPrompting() async {
        let session = makeSession()
        session.setContentSetting(.block, for: .geolocation, url: origin)
        let prompter = Prompter(.allowAlways)
        let granted = await WebKitPermissionPolicy.resolve(kinds: [.geolocation], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertFalse(granted)
        XCTAssertTrue(prompter.requests.isEmpty)
    }

    func test_anUndecidedNotificationRequestPromptsOnceAndTheAnswerIsRemembered() async {
        let session = makeSession()
        let prompter = Prompter(.allowAlways)
        let first = await WebKitPermissionPolicy.resolve(kinds: [.notifications], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertTrue(first)
        XCTAssertEqual(prompter.requests.map(\.kinds), [[.notifications]])
        XCTAssertEqual(session.contentSetting(.notifications, for: origin), .allow)
        let second = await WebKitPermissionPolicy.resolve(kinds: [.notifications], origin: origin, session: session, prompt: prompter.ask)
        XCTAssertTrue(second)
        XCTAssertEqual(prompter.requests.count, 1)
    }

    func test_locationAndNotificationDecisionsAreIndependent() async {
        let session = makeSession()
        session.setContentSetting(.allow, for: .geolocation, url: origin)
        XCTAssertEqual(
            WebKitPermissionPolicy.verdict(kinds: [.notifications], origin: origin, session: session),
            .prompt([.notifications])
        )
        session.setContentSetting(.block, for: .notifications, url: origin)
        XCTAssertEqual(WebKitPermissionPolicy.verdict(kinds: [.geolocation], origin: origin, session: session), .grant)
        XCTAssertEqual(WebKitPermissionPolicy.verdict(kinds: [.notifications], origin: origin, session: session), .deny)
    }
}
