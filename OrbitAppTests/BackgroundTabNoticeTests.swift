import XCTest
@testable import Orbit

@MainActor
final class BackgroundTabNoticeTests: XCTestCase {

    private func makeEnvironmentWithOpener() throws -> (AppEnvironment, TabID, MockWebContents) {
        let env = AppEnvironment.demo
        let openerTabID = try XCTUnwrap(env.activeTabID, "The demo environment has no active tab to open from.")
        let opener = MockWebContents()
        env._test_attachWebContents(opener, for: openerTabID)
        return (env, openerTabID, opener)
    }

    private func openInBackground(_ env: AppEnvironment, from opener: MockWebContents) throws -> TabID {
        let tabsBefore = Set(env.state.tabs.keys)
        let handled = env.webContents(
            opener,
            requestsNewContent: NewContentRequest(
                url: URL(string: "https://example.com/middle-clicked")!, disposition: .newBackgroundTab, isUserGesture: true
            )
        )
        XCTAssertTrue(handled)
        return try XCTUnwrap(Set(env.state.tabs.keys).subtracting(tabsBefore).first)
    }

    func testAMiddleClickedLinkAnnouncesTheTabItOpened() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }

        let newTabID = try openInBackground(env, from: opener)

        XCTAssertEqual(env.visibleBackgroundTabNotice?.tabID, newTabID)
        env.closeTab(newTabID)
    }

    func testAForegroundTabIsNotAnnounced() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let tabsBefore = Set(env.state.tabs.keys)

        XCTAssertTrue(env.webContents(
            opener,
            requestsNewContent: NewContentRequest(
                url: URL(string: "https://example.com/foreground")!, disposition: .newForegroundTab, isUserGesture: true
            )
        ))

        XCTAssertNil(env.backgroundTabNotice)
        for id in Set(env.state.tabs.keys).subtracting(tabsBefore) { env.closeTab(id) }
    }

    func testPressingTheNoticeGoesToTheTabAndRemovesTheNotice() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let newTabID = try openInBackground(env, from: opener)
        XCTAssertEqual(env.activeTabID, openerTabID)

        env.openBackgroundTabFromNotice()

        XCTAssertEqual(env.activeTabID, newTabID, "Pressing the notice must take the user to the tab it names.")
        XCTAssertNil(env.backgroundTabNotice)
        env.closeTab(newTabID)
    }

    func testTheNoticeIsHiddenOnceItsTabIsOnScreen() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let newTabID = try openInBackground(env, from: opener)
        XCTAssertNotNil(env.visibleBackgroundTabNotice)

        env.activateTab(newTabID)

        XCTAssertNil(env.visibleBackgroundTabNotice, "The user is already looking at the tab, so there is nothing to offer.")
        env.closeTab(newTabID)
    }

    func testTheNoticeIsHiddenOnceItsTabIsClosed() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let newTabID = try openInBackground(env, from: opener)

        env.closeTab(newTabID)

        XCTAssertNil(env.visibleBackgroundTabNotice)
    }

    func testTheNoticeDismissesItself() async throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let newTabID = try openInBackground(env, from: opener)
        XCTAssertNotNil(env.backgroundTabNotice)

        try await Task.sleep(for: .seconds(AppEnvironment.backgroundTabNoticeDuration + 1))

        XCTAssertNil(env.backgroundTabNotice)
        env.closeTab(newTabID)
    }

    func testANewerNoticeIsNotClearedByTheOlderOnesTimer() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let first = try openInBackground(env, from: opener)
        let second = try openInBackground(env, from: opener)

        XCTAssertEqual(env.backgroundTabNotice?.tabID, second)
        XCTAssertEqual(env.backgroundTabNoticeGeneration, 2)
        env.closeTab(first)
        env.closeTab(second)
    }
}
