//  Regression cover: a failure or crash card stayed up after a new navigation started, and Try Again reloaded
//  whatever the web view had last committed instead of the page that failed.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class NavigationFailureRecoveryTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func tabWithPage() throws -> (id: TabID, contents: MockWebContents) {
        let spaceID = try XCTUnwrap(env.spaces.first?.id)
        let id = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID, activate: false)
        let contents = MockWebContents()
        env._test_attachWebContents(contents, for: id)
        return (id, contents)
    }

    private func fail(_ id: TabID, url: URL?) {
        env.tabErrors[id] = EngineError(code: .connectionTimedOut, url: url, underlyingDescription: "timed out")
    }

    func test_aNewNavigationClearsTheFailureCard() throws {
        let tab = try tabWithPage()
        fail(tab.id, url: URL(string: "https://down.example.com/")!)
        env.crashedTabs.insert(tab.id)

        env.loadInTab(tab.id, url: URL(string: "https://up.example.com/")!)

        XCTAssertNil(env.tabErrors[tab.id], "A load that ends without committing left the old error over the tab.")
        XCTAssertFalse(env.crashedTabs.contains(tab.id))
        XCTAssertEqual(tab.contents.navigationState.url, URL(string: "https://up.example.com/"))
    }

    func test_tryAgainLoadsThePageThatFailed_notAReloadOfWhatWasCommitted() throws {
        let tab = try tabWithPage()
        let failed = URL(string: "https://down.example.com/page")!
        fail(tab.id, url: failed)

        env.reloadTab(tab.id, ignoringCache: false)

        XCTAssertEqual(tab.contents.navigationState.url, failed, "Try Again must fetch the failed page.")
        XCTAssertEqual(tab.contents.reloadCallCount, 0, "A reload would have reloaded the previously committed document.")
        XCTAssertNil(env.tabErrors[tab.id])
    }

    func test_reloadingAHealthyTab_stillReloads() throws {
        let tab = try tabWithPage()

        env.reloadTab(tab.id, ignoringCache: false)

        XCTAssertEqual(tab.contents.reloadCallCount, 1)
    }

    func test_aFailureWithNoURL_fallsBackToReload() throws {
        let tab = try tabWithPage()
        fail(tab.id, url: nil)

        env.reloadTab(tab.id, ignoringCache: false)

        XCTAssertEqual(tab.contents.reloadCallCount, 1, "A crash card has no failed URL to load, so Try Again reloads the page.")
    }
}
