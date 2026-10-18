import Foundation
import XCTest
@testable import Orbit

@MainActor
class LiveEnvironmentTestCase: XCTestCase {

    lazy var env: AppEnvironment = Self.makeEnvironmentWithNoOpenTabs()

    private var contentBlockingWasEnabled: Bool?

    private static let closeBudget = 512

    override func setUp() {
        super.setUp()
        let blocker = ContentBlockingRuntime.shared.controller.blocker
        contentBlockingWasEnabled = blocker.isEnabled
        // Off: EasyList compiles moments after the first tab opens and would block the corpus subject's own ad script, faking the negative control.
        blocker.isEnabled = false
    }

    // No engine means no test in this process opened a tab, so `env` stays unbuilt.
    override func tearDown() {
        if WebKitLiveEngineHost.startedEngine != nil {
            closeEveryLiveTab()
            failIfAnyTabIsStillRegistered()
        }
        if let contentBlockingWasEnabled {
            ContentBlockingRuntime.shared.controller.blocker.isEnabled = contentBlockingWasEnabled
        }
        contentBlockingWasEnabled = nil
        super.tearDown()
    }

    /// The demo document with every open tab removed, so closing a tab can only ever activate — and
    /// materialise — a tab the test itself opened. Spaces, profiles and their sessions are untouched.
    static func makeEnvironmentWithNoOpenTabs() -> AppEnvironment {
        let environment = AppEnvironment.demo
        var state = environment.state
        for index in state.spaces.indices {
            state.spaces[index].today = []
            state.spaces[index].pinned = []
            for favorite in state.spaces[index].favorites.indices {
                state.spaces[index].favorites[favorite].liveTabID = nil
            }
        }
        state.tabs = [:]
        state.splitGroups = [:]
        state.activeTabBySpace = [:]
        environment.state = state
        environment.store.activationHistoryBySpace = [:]
        return environment
    }

    // A fixpoint, not one pass over a `state.tabs.keys` snapshot: closing a tab materialises the
    // successor BrowserStore picks, and a tab brought to life behind the cursor is never revisited.
    private func closeEveryLiveTab() {
        var closed = 0
        while let tabID = env.state.tabs.keys.first(where: { env.webContents[$0] != nil }) {
            env.closeTab(tabID)
            closed += 1
            guard closed <= Self.closeBudget else {
                XCTFail("\(Self.self) still had live tabs after closing \(closed) of them")
                return
            }
        }
    }

    private func failIfAnyTabIsStillRegistered() {
        let stranded = Array(env.webContents.keys)
        XCTAssertEqual(
            stranded, [],
            """
            \(Self.self) left live WebKit tabs \(stranded.map(\.uuidString).joined(separator: ", ")). \
            The engine is process-wide and chrome.tabs.query counts every tab still open. \
            Close or release every tab this environment materialised.
            """
        )
    }
}
