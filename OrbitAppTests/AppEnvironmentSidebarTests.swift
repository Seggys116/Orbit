import XCTest
@testable import Orbit

@MainActor
final class AppEnvironmentSidebarTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var suiteName: String!
    private var writingStore: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OrbitAppTests-AppEnvironmentSidebar-\(UUID().uuidString)"
        writingStore = UserDefaults(suiteName: suiteName)
        AppEnvironment.defaults = writingStore

        env.isSidebarVisible = true
        env.isSidebarHoverRevealed = false
    }

    override func tearDown() {
        writingStore?.removePersistentDomain(forName: suiteName)
        AppEnvironment.defaults = .standard
        writingStore = nil
        suiteName = nil
        super.tearDown()
    }

    private func reloadedStore() -> UserDefaults {
        writingStore.synchronize()
        guard let reloaded = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not construct a second UserDefaults over suite \(suiteName!).")
            return .standard
        }
        return reloaded
    }

    func testToggleSidebarCommandFlipsVisibility() {
        XCTAssertTrue(env.isSidebarVisible, "test precondition")

        env.perform(.toggleSidebar)
        XCTAssertFalse(env.isSidebarVisible, "Cmd+S (perform(.toggleSidebar)) did not hide the sidebar.")

        env.perform(.toggleSidebar)
        XCTAssertTrue(env.isSidebarVisible, "A second Cmd+S did not restore the sidebar.")
    }

    func testToggleSidebarIsIdempotentAcrossRepeatedToggles() {
        let initial = env.isSidebarVisible
        for i in 1...4 {
            env.perform(.toggleSidebar)
            let expected = (i % 2 == 0) ? initial : !initial
            XCTAssertEqual(env.isSidebarVisible, expected, "isSidebarVisible out of sync after \(i) toggle(s).")
        }
    }

    func testHoverRevealFlagTracksHoverState() {
        env.isSidebarVisible = false
        XCTAssertFalse(env.isSidebarHoverRevealed, "test precondition")

        env.isSidebarHoverRevealed = true
        XCTAssertTrue(env.isSidebarHoverRevealed, "Hover-in did not set isSidebarHoverRevealed.")

        env.isSidebarHoverRevealed = false
        XCTAssertFalse(env.isSidebarHoverRevealed, "Hover-out did not clear isSidebarHoverRevealed.")
    }

    func testSidebarVisibilityPersistsToUserDefaults() {
        env.isSidebarVisible = true

        env.perform(.toggleSidebar)
        XCTAssertFalse(
            reloadedStore().bool(forKey: AppEnvironment.Keys.sidebarVisible),
            "Hiding the sidebar did not reach storage, so the collapsed state would be lost on relaunch."
        )

        env.perform(.toggleSidebar)
        XCTAssertTrue(
            reloadedStore().bool(forKey: AppEnvironment.Keys.sidebarVisible),
            "Restoring the sidebar did not reach storage."
        )
    }
}
