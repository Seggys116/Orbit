//  A pane shows its page, so the page must be declared visible. These pin the rule the check on a timer uses, and that the engine records what a pane declared.

import XCTest
@testable import Orbit

@MainActor
final class PageVisibilityWatchdogTests: XCTestCase {

    func test_aShownPageDeclaredHiddenOrNeverDeclaredNeedsRepair() {
        XCTAssertTrue(PageVisibilityWatchdog.needsRepair(declaredVisible: false, viewIsHidden: false, paneIsShowingIt: true))
        XCTAssertTrue(PageVisibilityWatchdog.needsRepair(declaredVisible: nil, viewIsHidden: false, paneIsShowingIt: true))
        XCTAssertTrue(PageVisibilityWatchdog.needsRepair(declaredVisible: true, viewIsHidden: true, paneIsShowingIt: true), "a hidden view paints nothing whatever was declared")
    }

    func test_aPageThatIsShownAndDeclaredVisibleIsLeftAlone() {
        XCTAssertFalse(PageVisibilityWatchdog.needsRepair(declaredVisible: true, viewIsHidden: false, paneIsShowingIt: true))
    }

    func test_aPageNoPaneIsShowingIsNeverTouched() {
        XCTAssertFalse(PageVisibilityWatchdog.needsRepair(declaredVisible: false, viewIsHidden: true, paneIsShowingIt: false), "a warm page in the background stays hidden")
    }

    func test_theEngineRecordsWhatThePaneDeclared() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            XCTAssertNil(contents.declaredVisibility, "nothing declared yet")
            contents.setVisible(true)
            XCTAssertEqual(contents.declaredVisibility, true)
            contents.setVisible(false)
            XCTAssertEqual(contents.declaredVisibility, false)
        }
    }
}
