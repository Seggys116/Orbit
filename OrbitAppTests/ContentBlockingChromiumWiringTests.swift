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
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        XCTAssertTrue(engine.capabilities.contains(.contentBlocking))
        XCTAssertTrue(engine.capabilities.contains(.blockedRequestCounts))
    }

    func testApplyContentBlockerInstallsAHandlerThatBlocksAMatchingRequest() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertTrue(webKit.blockerDecision(url: "https://ads.example.com/tracker.js", documentURL: "https://example.com/", resourceType: .script))
        XCTAssertFalse(webKit.blockerDecision(url: "https://example.com/app.js", documentURL: "https://example.com/", resourceType: .script))
    }

    func testApplyContentBlockerNilBlockerAllowsEveryRequest() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        await engine.applyContentBlocker(nil, session: engine.defaultSession)

        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertFalse(webKit.blockerDecision(url: "https://ads.example.com/tracker.js", documentURL: "https://example.com/", resourceType: .script))
    }

    func testApplyContentBlockerDisabledBlockerAllowsEveryRequest() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")
        blocker.isEnabled = false

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertFalse(webKit.blockerDecision(url: "https://ads.example.com/tracker.js", documentURL: "https://example.com/", resourceType: .script))
    }

    func testApplyContentBlockerRespectsAllowlist() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")
        blocker.setAllowlist(["example.com"])

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertFalse(
            webKit.blockerDecision(url: "https://ads.example.com/tracker.js", documentURL: "https://example.com/", resourceType: .script),
            "the document's own host is allowlisted, so nothing on its page should be blocked"
        )
    }

    func testApplyContentBlockerServesAnEmptyRedirectSubstitutionRatherThanBlocking() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/ga.js$redirect=empty\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        guard case .redirect(_, _, let substitution) = blocker.decision(
            forURL: "https://ads.example.com/ga.js",
            documentURL: "https://example.com/",
            resourceType: .script
        ) else {
            return XCTFail("an empty redirect must substitute, not block")
        }
        let payload = blocker.stubPayload(for: substitution, resourceType: .script)
        XCTAssertEqual(payload.mimeType, "text/javascript")
        XCTAssertTrue(payload.content.isEmpty)
    }

    func testApplyContentBlockerServesANamedRedirectResourceWithItsOwnBytes() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/ga.js$redirect=noopjs\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let expected = try XCTUnwrap(RedirectResourceLibrary.resource(named: "noopjs"))
        guard case .redirect(_, _, let substitution) = blocker.decision(
            forURL: "https://ads.example.com/ga.js",
            documentURL: "https://example.com/",
            resourceType: .script
        ) else {
            return XCTFail("a named redirect must substitute")
        }
        let payload = blocker.stubPayload(for: substitution, resourceType: .script)
        XCTAssertEqual(payload.mimeType, expected.mimeType)
        XCTAssertEqual(payload.content, expected.content)
    }

    func testApplyContentBlockerSubstitutionMimeTypeFollowsTheRequestedResourceType() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/pixel$redirect=empty\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        guard case .redirect(_, _, let substitution) = blocker.decision(
            forURL: "https://ads.example.com/pixel",
            documentURL: "https://example.com/",
            resourceType: .image
        ) else {
            return XCTFail("an empty image redirect must substitute")
        }
        let payload = blocker.stubPayload(for: substitution, resourceType: .image)
        XCTAssertEqual(payload.mimeType, "image/gif")
        XCTAssertTrue(payload.content.isEmpty)
    }
}
