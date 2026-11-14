// Unit tests for OrbitInspectAttachPolicy, whose source is compiled directly into this bundle.

import XCTest

final class OrbitInspectAttachPolicyTests: XCTestCase {

    func testFreshPolicyNeverRequestsAttach() {
        var policy = OrbitInspectAttachPolicy()
        XCTAssertFalse(policy.takeAttachRequest())
    }

    func testReopeningAfterCloseRequestsAttachOnce() {
        var policy = OrbitInspectAttachPolicy()
        policy.didDetach()
        XCTAssertTrue(policy.takeAttachRequest())
        XCTAssertFalse(policy.takeAttachRequest(), "attach is sent once per close")
    }

    func testNewDocumentWithAttachedAgentNeedsNoAttach() {
        var policy = OrbitInspectAttachPolicy()
        policy.didDetach()
        policy.didHello(agentAttached: true)
        XCTAssertFalse(policy.takeAttachRequest())
    }

    func testRestoredPageThatWasFrozenDetachedStillNeedsAttach() {
        var policy = OrbitInspectAttachPolicy()
        policy.didHello(agentAttached: false)
        XCTAssertTrue(policy.takeAttachRequest())
    }

    func testRepeatedCloseAndReopenCycles() {
        var policy = OrbitInspectAttachPolicy()
        for _ in 0..<3 {
            policy.didDetach()
            XCTAssertTrue(policy.takeAttachRequest())
        }
        XCTAssertFalse(policy.takeAttachRequest())
    }
}
