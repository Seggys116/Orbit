//  Cover: a released tab's page is built when its row is pressed, so the click that follows finds it loading
//  instead of building it on the main thread after the click.

import AppKit
import XCTest
@testable import Orbit

@MainActor
final class TabRowPrefetchTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func releasedTab() throws -> TabID {
        let spaceID = try XCTUnwrap(env.spaces.first?.id)
        let id = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID, activate: false)
        env.releaseWebContents(for: id)
        XCTAssertNil(env.webContents[id], "Precondition: the tab has no page.")
        // openTab built a page through the factory before it was released; only what the prefetch builds is under test.
        env._test_materializations = []
        return id
    }

    private func installFactory() {
        env._test_webContentsFactory = { _, _ in MockWebContents() }
        env._test_materializations = []
    }

    func test_pressingARowBuildsAReleasedTabsPage() throws {
        installFactory()
        let id = try releasedTab()

        env.prefetchRenderer(for: id)

        XCTAssertNotNil(env.webContents[id], "The page must be ready before the click lands.")
        XCTAssertEqual(env._test_materializations.map(\.tabID), [id])
    }

    func test_prefetchLeavesALivePageAlone() throws {
        installFactory()
        let id = try releasedTab()
        let live = MockWebContents()
        env._test_attachWebContents(live, for: id)

        env.prefetchRenderer(for: id)

        XCTAssertTrue(env.webContents[id] === live, "A tab that already has a page must keep it.")
        XCTAssertTrue(env._test_materializations.isEmpty)
    }

    func test_prefetchIgnoresAnArchivedTab() throws {
        installFactory()
        let id = try releasedTab()
        env.store.closeTab(id)
        XCTAssertEqual(env.tab(id)?.section, .archived, "Precondition.")
        env._test_materializations = []

        env.prefetchRenderer(for: id)

        XCTAssertNil(env.webContents[id], "Selecting an archived tab restores it first; a prefetch must not build a page for a tab with no row.")
    }

    func test_prefetchIgnoresAnUnknownTab() {
        installFactory()

        env.prefetchRenderer(for: UUID())

        XCTAssertTrue(env._test_materializations.isEmpty)
    }

    func test_theRowCatcherReportsThePressBeforeTheRelease() {
        var order: [String] = []
        let view = OrbitActionButtonClickCatchingView()
        view.firesOnRelease = true
        view.pressAction = { order.append("press") }
        view.clickCountAction = { _ in order.append("click") }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        view.mouseDown(with: event(.leftMouseDown))
        XCTAssertEqual(order, ["press"], "The press runs at once; the click still waits for the release.")
        view.mouseUp(with: event(.leftMouseUp))

        XCTAssertEqual(order, ["press", "click"])
    }

    func test_aPressAloneStillDoesNotActivate() {
        var clicks = 0
        let view = OrbitActionButtonClickCatchingView()
        view.firesOnRelease = true
        view.pressAction = {}
        view.clickCountAction = { _ in clicks += 1 }

        view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)

        XCTAssertEqual(clicks, 0, "The prefetch must not turn a press that becomes a drag into a tab switch.")
    }
}
