import XCTest

final class SpaceTitleRowCaretTests: XCTestCase {

    func test_isPinnedSectionCollapsed_defaultsToExpandedWhenTheStoredOptionalIsNil() {
        var space = Space(name: "Test", profileID: UUID())
        XCTAssertNil(space.pinnedSectionCollapsed, "A freshly constructed Space must not synthesize a stored value on its own.")
        XCTAssertFalse(space.isPinnedSectionCollapsed, "Absent storage must read as expanded (false), not collapsed.")

        space.isPinnedSectionCollapsed = true
        XCTAssertEqual(space.pinnedSectionCollapsed, true, "Setting through the non-optional accessor must write the backing optional.")
        XCTAssertTrue(space.isPinnedSectionCollapsed)

        space.isPinnedSectionCollapsed = false
        XCTAssertEqual(space.pinnedSectionCollapsed, false, "Toggling back to expanded must be distinguishable from 'never set' (nil) — both read false, but only one round-trips as an explicit `false` on disk.")
    }

    func test_showPinnedSectionDecision_truthTable() {
        func decision(hasPinnedNodes: Bool, isCollapsed: Bool) -> Bool {
            hasPinnedNodes && !isCollapsed
        }

        XCTAssertFalse(decision(hasPinnedNodes: false, isCollapsed: false), "Genuinely empty (R17): never shown, regardless of the caret's own state.")
        XCTAssertFalse(decision(hasPinnedNodes: false, isCollapsed: true), "Genuinely empty and collapsed: still never shown.")
        XCTAssertTrue(decision(hasPinnedNodes: true, isCollapsed: false), "Has content, expanded: shown.")
        XCTAssertFalse(decision(hasPinnedNodes: true, isCollapsed: true), "Has content but the user collapsed it: hidden — the caret's whole purpose.")
    }
}
