import Foundation
import XCTest
@testable import Orbit

// PiP "back to tab": exercises the delegate call exactly as the trampoline invokes it.
@MainActor
final class WebContentsActivationRequestTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func makeAttachedTab(spaceID: SpaceID, url: String = "https://www.example.com") -> (TabID, MockWebContents) {
        let tab = Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab

        let mock = MockWebContents()
        env._test_attachWebContents(mock, for: tab.id)
        return (tab.id, mock)
    }

    private func detach(_ tabID: TabID) {
        env._test_detachWebContents(for: tabID)
        env.state.tabs.removeValue(forKey: tabID)
    }

    // MARK: - Same Space

    func testActivationRequestActivatesTheOriginatingTabNotTheCurrentOne() {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())

        let (currentTabID, currentMock) = makeAttachedTab(spaceID: spaceID, url: "https://current.example.com")
        defer { detach(currentTabID) }
        let (pipTabID, pipMock) = makeAttachedTab(spaceID: spaceID, url: "https://pip.example.com")
        defer { detach(pipTabID) }

        env.activateTab(currentTabID)
        XCTAssertEqual(env.activeTabID, currentTabID, "Test precondition: a different tab is active before the activation request fires.")

        env.webContentsDidRequestActivation(pipMock)

        XCTAssertEqual(
            env.activeTabID, pipTabID,
            "PiP's back-to-tab control must activate the ORIGINATING tab (the one that entered picture-in-picture), not leave whatever was already active in place."
        )
        _ = currentMock
    }

    // MARK: - Cross-Space

    func testActivationRequestSwitchesToTheOriginatingTabsSpaceWhenItLivesElsewhere() {
        let profileID = env.createDefaultProfileIfNeeded()
        let firstSpaceID = env.createSpace(name: "First Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        let secondSpaceID = env.createSpace(name: "Second Space", icon: "square", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)

        let (currentTabID, _) = makeAttachedTab(spaceID: firstSpaceID, url: "https://current.example.com")
        defer { detach(currentTabID) }
        let (pipTabID, pipMock) = makeAttachedTab(spaceID: secondSpaceID, url: "https://pip.example.com")
        defer { detach(pipTabID) }

        env.activateTab(currentTabID)
        XCTAssertEqual(env.state.activeSpaceID, firstSpaceID, "Test precondition.")
        XCTAssertEqual(env.activeTabID, currentTabID, "Test precondition: a different tab, in a different Space, is active before the activation request fires.")

        env.webContentsDidRequestActivation(pipMock)

        XCTAssertEqual(
            env.state.activeSpaceID, secondSpaceID,
            "Activating a tab that lives in another Space must switch the active Space to it — otherwise the tab activates invisibly behind the Space still on screen."
        )
        XCTAssertEqual(
            env.activeTabID, pipTabID,
            "The originating tab must be the active tab once its Space is switched to."
        )
    }

    func testActivationRequestForAnUnattachedContentsIsANoOp() {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let (currentTabID, _) = makeAttachedTab(spaceID: spaceID)
        defer { detach(currentTabID) }
        env.activateTab(currentTabID)

        let stray = MockWebContents()
        env.webContentsDidRequestActivation(stray)

        XCTAssertEqual(env.activeTabID, currentTabID, "A stray WebContents that never resolves to a tab must not disturb the currently active tab.")
    }
}
