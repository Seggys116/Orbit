//  Proves the Swift half of network-request content blocking end to end, down
//  to the exact closure OrbitContentBlockingURLLoaderFactory would call.
//  Never calls engine.start(), so this runs in every ordinary `xcodebuild
//  test`; it cannot prove the C++ interceptor is reached for a real request.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ContentBlockingChromiumWiringTests: XCTestCase {

    override func tearDown() {
        OrbitChromiumBridge.shared.contentBlockingDecisionHandler = nil
        super.tearDown()
    }

    private func makeBlocker(_ listText: String) -> ContentBlocker {
        var ruleSet = ContentBlockerRuleSet()
        ruleSet.add(listText: listText, listID: "TestList")
        let blocker = ContentBlocker()
        blocker.setRuleSet(ruleSet)
        blocker.isEnabled = true
        return blocker
    }

    func testApplyContentBlockerAdvertisesTheCapability() {
        let engine = ChromiumEngine(storage: .ephemeral)
        XCTAssertTrue(engine.capabilities.contains(.contentBlocking))
        XCTAssertTrue(engine.capabilities.contains(.blockedRequestCounts))
    }

    func testApplyContentBlockerInstallsAHandlerThatBlocksAMatchingRequest() async throws {
        let engine = ChromiumEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let handler = try XCTUnwrap(OrbitChromiumBridge.shared.contentBlockingDecisionHandler)
        // 3 == ContentBlockingResourceType.script.rawValue, mirrored in
        // orbit_content_blocking_url_loader_factory.cc's OrbitResourceType.
        XCTAssertEqual(handler("https://ads.example.com/tracker.js", "https://example.com/", 3), .block)
        XCTAssertEqual(handler("https://example.com/app.js", "https://example.com/", 3), .allow)
    }

    func testApplyContentBlockerNilBlockerAllowsEveryRequest() async throws {
        let engine = ChromiumEngine(storage: .ephemeral)
        await engine.applyContentBlocker(nil, session: engine.defaultSession)

        let handler = try XCTUnwrap(OrbitChromiumBridge.shared.contentBlockingDecisionHandler)
        XCTAssertEqual(handler("https://ads.example.com/tracker.js", "https://example.com/", 3), .allow)
    }

    func testApplyContentBlockerDisabledBlockerAllowsEveryRequest() async throws {
        let engine = ChromiumEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")
        blocker.isEnabled = false

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let handler = try XCTUnwrap(OrbitChromiumBridge.shared.contentBlockingDecisionHandler)
        XCTAssertEqual(handler("https://ads.example.com/tracker.js", "https://example.com/", 3), .allow)
    }

    func testApplyContentBlockerRespectsAllowlist() async throws {
        let engine = ChromiumEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")
        blocker.setAllowlist(["example.com"])

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let handler = try XCTUnwrap(OrbitChromiumBridge.shared.contentBlockingDecisionHandler)
        XCTAssertEqual(
            handler("https://ads.example.com/tracker.js", "https://example.com/", 3),
            .allow,
            "the document's own host is allowlisted, so nothing on its page should be blocked"
        )
    }

    func testApplyContentBlockerServesAnEmptyRedirectSubstitutionRatherThanBlocking() async throws {
        let engine = ChromiumEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/ga.js$redirect=empty\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let handler = try XCTUnwrap(OrbitChromiumBridge.shared.contentBlockingDecisionHandler)
        XCTAssertEqual(
            handler("https://ads.example.com/ga.js", "https://example.com/", 3),
            .substitute(mimeType: "text/javascript", body: []),
            "$redirect=empty on a script request must serve a zero-byte script, not ERR_BLOCKED_BY_CLIENT"
        )
    }

    func testApplyContentBlockerServesANamedRedirectResourceWithItsOwnBytes() async throws {
        let engine = ChromiumEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/ga.js$redirect=noopjs\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let expected = try XCTUnwrap(RedirectResourceLibrary.resource(named: "noopjs"))
        let handler = try XCTUnwrap(OrbitChromiumBridge.shared.contentBlockingDecisionHandler)
        XCTAssertEqual(
            handler("https://ads.example.com/ga.js", "https://example.com/", 3),
            .substitute(mimeType: expected.mimeType, body: expected.content)
        )
    }

    func testApplyContentBlockerSubstitutionMimeTypeFollowsTheRequestedResourceType() async throws {
        let engine = ChromiumEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/pixel$redirect=empty\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let handler = try XCTUnwrap(OrbitChromiumBridge.shared.contentBlockingDecisionHandler)
        // 4 == ContentBlockingResourceType.image.rawValue.
        XCTAssertEqual(
            handler("https://ads.example.com/pixel", "https://example.com/", 4),
            .substitute(mimeType: "image/gif", body: [])
        )
    }
}
