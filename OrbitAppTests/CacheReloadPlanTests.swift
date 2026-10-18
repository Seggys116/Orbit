import XCTest
@testable import Orbit

final class CacheReloadPlanTests: XCTestCase {

    func testASingleTabReloadsOnlyItself() {
        let tab = UUID()
        let background = UUID()
        let ids = CacheReloadPlan.visibleTabIDs(around: tab, splitTabIDs: [])
        XCTAssertEqual(ids, [tab])
        XCTAssertFalse(ids.contains(background))
    }

    func testASplitReloadsEveryVisiblePane() {
        let left = UUID()
        let right = UUID()
        let background = UUID()
        let ids = CacheReloadPlan.visibleTabIDs(around: right, splitTabIDs: [left, right])
        XCTAssertEqual(ids, [left, right])
        XCTAssertFalse(ids.contains(background))
    }

    func testASplitTheTabIsNotInDoesNotReloadThosePanes() {
        let tab = UUID()
        let left = UUID()
        let right = UUID()
        XCTAssertEqual(CacheReloadPlan.visibleTabIDs(around: tab, splitTabIDs: [left, right]), [tab])
    }

    func testACommittedDocumentReloadsFromOrigin() {
        XCTAssertEqual(CacheReloadPlan.navigationAfterCacheWipe(hasCommittedDocument: true), .fromOrigin)
        XCTAssertEqual(CacheReloadPlan.navigationAfterCacheWipe(hasCommittedDocument: false), .unconditionalLoad)
    }
}
