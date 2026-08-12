import AppKit
import XCTest

@testable import Orbit

@MainActor
final class IncognitoWindowSessionTests: XCTestCase {

    private lazy var host: AppEnvironment = AppEnvironment.demo

    private var personalSpaceID: SpaceID!
    private var workSpaceID: SpaceID!

    private var window: NSWindow?
    private var controller: OrbitWindowController?

    override func setUp() {
        super.setUp()
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        let personal = Space(name: "Personal", profileID: profile.id, order: 0)
        let work = Space(name: "Work", profileID: profile.id, order: 1)
        state.profiles = [profile]
        state.spaces = [personal, work]
        state.activeSpaceID = personal.id
        host.state = state
        personalSpaceID = personal.id
        workSpaceID = work.id
    }

    override func tearDown() {
        tearDownWindow()
        super.tearDown()
    }

    // MARK: - Real-window plumbing

    private func makeRealWindow(for session: WindowSession) -> NSWindow {
        let window = OrbitWindowController.makeWindow()
        window.isReleasedWhenClosed = false
        let controller = OrbitWindowController(window: window)
        controller.adopt(session)
        window.delegate = controller
        controller.installContentView(window: window)
        self.window = window
        self.controller = controller
        return window
    }

    private func tearDownWindow() {
        guard let window else {
            controller = nil
            return
        }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        window.delegate = nil
        controller?.window = nil
        self.controller = nil
        self.window = nil
    }

    // MARK: - Per-window active Space

    func test_openingAnIncognitoSession_leavesTheDocumentsActiveSpaceAlone() {
        let session = WindowSession.incognito(on: host)

        XCTAssertEqual(
            host.state.activeSpaceID, personalSpaceID,
            """
            Opening an Incognito window moved the document's global \
            activeSpaceID, which is what every other open window reads — so \
            Cmd+Shift+N dragged the user's ordinary windows into the \
            Incognito Space with it. refs/ARC_SPEC.md defines Incognito as a \
            window mode; the Space belongs to one window, not to the document.
            """
        )
        XCTAssertEqual(host.activeSpace?.id, personalSpaceID)
        XCTAssertTrue(session.isIncognito)
        XCTAssertNotNil(session.environment.activeSpace)
    }

    func test_theIncognitoWindowAndTheMainWindowShowDifferentSpacesSimultaneously() throws {
        let session = WindowSession.incognito(on: host)
        let incognitoSpace = try XCTUnwrap(session.environment.activeSpace)

        XCTAssertNotEqual(incognitoSpace.id, personalSpaceID)
        XCTAssertEqual(host.activeSpace?.id, personalSpaceID)
        XCTAssertTrue(
            host.isIncognito(incognitoSpace),
            "the Space the Incognito window shows must be recognised as Incognito, or every privacy-gated feature (history writes, Tidy Tabs, the ChatGPT Command Bar, Link Previews) runs in it"
        )
        XCTAssertTrue(session.environment.isWindowScoped)
        XCTAssertFalse(host.isWindowScoped, "the shared environment must keep following the document")
    }

    func test_switchingSpaceInEitherWindow_doesNotMoveTheOther() throws {
        let session = WindowSession.incognito(on: host)
        let incognitoSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        host.selectSpace(workSpaceID)
        XCTAssertEqual(host.activeSpace?.id, workSpaceID)
        XCTAssertEqual(
            session.environment.activeSpace?.id, incognitoSpaceID,
            "the Incognito window followed the main window's Space change"
        )

        session.environment.selectSpace(personalSpaceID)
        XCTAssertEqual(session.environment.activeSpace?.id, personalSpaceID)
        XCTAssertEqual(
            host.activeSpace?.id, workSpaceID,
            "the main window followed the Incognito window's Space change"
        )
        XCTAssertEqual(
            host.state.activeSpaceID, workSpaceID,
            "a window-scoped environment must never write the document's activeSpaceID"
        )
    }

    func test_steppingSpacesInTheIncognitoWindow_doesNotMoveTheMainWindow() {
        let session = WindowSession.incognito(on: host)

        session.environment.nextSpace()
        session.environment.nextSpace()

        XCTAssertEqual(
            host.state.activeSpaceID, personalSpaceID,
            "nextSpace() from a window-scoped environment wrote the document's activeSpaceID"
        )
    }

    func test_aTabOpenedInTheIncognitoWindow_isNotTheMainWindowsActiveTab() throws {
        let session = WindowSession.incognito(on: host)
        let incognitoSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        let tabID = session.environment.openTab(
            url: URL(string: "https://private.example.com/secret")!,
            in: incognitoSpaceID
        )

        XCTAssertEqual(session.environment.activeTabID, tabID)
        XCTAssertNotEqual(host.activeTabID, tabID)
        XCTAssertNil(host.activeTab, "the main window's Space has no tabs in this fixture and must still have none")
        XCTAssertEqual(
            host.state.activeSpaceID, personalSpaceID,
            """
            `BrowserStore.openTab(activate:)` sets `state.activeSpaceID = \
            spaceID` as a side effect — correct for a one-window app, and a \
            second route by which an Incognito window drags every other \
            window onto its Space, entirely separately from selectSpace.
            """
        )
    }

    func test_activatingATabInsideTheIncognitoWindow_doesNotMoveTheMainWindow() throws {
        let session = WindowSession.incognito(on: host)
        let incognitoSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)
        let tabID = session.environment.openTab(
            url: URL(string: "https://private.example.com/one")!,
            in: incognitoSpaceID,
            activate: false
        )
        host.selectSpace(workSpaceID)

        session.environment.activateTab(tabID)

        XCTAssertEqual(session.environment.activeTabID, tabID)
        XCTAssertEqual(session.environment.activeSpace?.id, incognitoSpaceID)
        XCTAssertEqual(
            host.state.activeSpaceID, workSpaceID,
            "activating a tab in the Incognito window moved the main window's Space"
        )
        XCTAssertEqual(host.activeSpace?.id, workSpaceID)
    }

    func test_activatingATabInAnotherSpace_movesTheScopedWindowToThatSpace() throws {
        let session = WindowSession.incognito(on: host)
        let incognitoSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)
        let workTabID = host.openTab(url: URL(string: "https://public.example.com/work")!, in: workSpaceID, activate: false)

        session.environment.activateTab(workTabID)

        XCTAssertEqual(
            session.environment.activeSpace?.id, workSpaceID,
            "the scoped window refused to follow a tab into its own Space, so Switch to Tab does nothing visible"
        )
        XCTAssertNotEqual(session.environment.activeSpace?.id, incognitoSpaceID)
        XCTAssertEqual(
            host.state.activeSpaceID, personalSpaceID,
            "the document still must not have moved"
        )
    }

    // MARK: - History

    func test_visitsInAnIncognitoSpace_areNeverRecordedInHistory() async throws {
        let session = WindowSession.incognito(on: host)
        let incognitoSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        session.environment.openTab(
            url: URL(string: "https://private.example.com/incognito-secret")!,
            in: incognitoSpaceID
        )

        let recorded = await historyContains("incognito-secret", within: 2.0)
        XCTAssertFalse(
            recorded,
            """
            A URL visited in an Incognito window was written to the history \
            database. The ephemeral Profile only makes the *cookie jar* \
            memory-only; nothing stopped the visit itself being recorded.
            """
        )
    }

    func test_visitsInAnOrdinarySpace_areStillRecorded() async {
        host.openTab(url: URL(string: "https://public.example.com/ordinary-page")!, in: personalSpaceID)

        let recorded = await historyContains("ordinary-page", within: 5.0)
        XCTAssertTrue(
            recorded,
            """
            An ordinary visit was not recorded either, so this fixture never \
            records anything and the Incognito assertion above proves nothing.
            """
        )
    }

    /// Reloads from the shared database each poll: `localHistoryCache` is
    /// per-environment, so `host`'s cache never sees the window-scoped visit.
    private func historyContains(_ needle: String, within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            await host.reloadHistoryCacheAfterBulkImport()
            if host.historyResults(matching: needle).isEmpty == false { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: - The load-bearing test: closing the window ends the session

    func test_closingTheIncognitoWindow_leavesNothingOfTheSessionInMemory() throws {
        let session = WindowSession.incognito(on: host)
        let environment = session.environment
        let incognitoSpaceID = try XCTUnwrap(environment.activeSpace?.id)
        let incognitoProfileID = try XCTUnwrap(host.state.spaces.first { $0.id == incognitoSpaceID }?.profileID)

        let tabID = environment.openTab(
            url: URL(string: "https://private.example.com/secret")!,
            in: incognitoSpaceID
        )
        let contents = MockWebContents()
        environment._test_attachWebContents(contents, for: tabID)
        environment.crashedTabs.insert(tabID)

        _ = makeRealWindow(for: session)

        XCTAssertFalse(session.isDisposed)
        XCTAssertEqual(environment.webContents.count, 1, "test precondition: the session owns a live renderer")
        XCTAssertNotNil(host.state.tabs[tabID], "test precondition: the Incognito tab is in the document")
        XCTAssertNotNil(host.store.space(incognitoSpaceID), "test precondition: the Incognito Space is in the document")

        tearDownWindow()

        XCTAssertTrue(session.isDisposed, "windowWillClose did not dispose the session")
        XCTAssertTrue(
            contents.isClosed,
            """
            The Incognito window's renderer was never closed. Dropping the \
            reference is not enough: the engine-side browser stays alive, \
            which is a live private session with a window nothing owns.
            """
        )
        XCTAssertTrue(
            environment.webContents.isEmpty,
            "the environment still holds the closed session's live WebContents map"
        )
        XCTAssertTrue(environment.navigationStates.isEmpty, "a reactive mirror of the closed session survived")
        XCTAssertTrue(environment.mediaStates.isEmpty, "a reactive mirror of the closed session survived")
        XCTAssertTrue(environment.crashedTabs.isEmpty, "a reactive mirror of the closed session survived")
        XCTAssertNil(environment.windowActiveSpaceID, "the disposed environment still points at its Space")

        XCTAssertNil(
            host.state.tabs[tabID],
            """
            The tab opened in the Incognito window is still in the in-memory \
            document after its window closed — its URL included. \
            StateStore's ephemeral stripping keeps it off disk; nothing was \
            removing it from memory.
            """
        )
        XCTAssertNil(host.store.space(incognitoSpaceID), "the Incognito Space outlived its window")
        XCTAssertFalse(
            host.state.profiles.contains { $0.id == incognitoProfileID },
            "the ephemeral Profile outlived its window"
        )
        XCTAssertFalse(
            host.state.profiles.contains { !$0.isPersistent },
            "no non-persistent Profile may remain once every Incognito window is closed"
        )
        XCTAssertEqual(
            host.state.activeSpaceID, personalSpaceID,
            "closing the Incognito window disturbed the main window's Space"
        )
    }

    func test_closingAnOrdinaryWindow_disposesNothing() {
        let session = WindowSession.standard(on: host)
        host.openTab(url: URL(string: "https://public.example.com/keep-me")!, in: personalSpaceID)
        let tabCountBefore = host.state.tabs.count
        let spaceCountBefore = host.state.spaces.count

        _ = makeRealWindow(for: session)
        tearDownWindow()

        XCTAssertEqual(host.state.tabs.count, tabCountBefore, "closing an ordinary window destroyed tabs")
        XCTAssertEqual(host.state.spaces.count, spaceCountBefore, "closing an ordinary window destroyed Spaces")
        XCTAssertEqual(host.activeSpace?.id, personalSpaceID)
        XCTAssertFalse(host.isWindowScoped, "a standard session must never scope the shared environment")
    }

    // MARK: - Two Incognito windows at once

    func test_asecondIncognitoSessionOpenedFromInsideTheFirst_isIndependentOfIt() throws {
        let first = WindowSession.incognito(on: host)
        let second = WindowSession.incognito(on: first.environment)

        let firstSpaceID = try XCTUnwrap(first.environment.activeSpace?.id)
        let secondSpaceID = try XCTUnwrap(second.environment.activeSpace?.id)
        XCTAssertNotEqual(firstSpaceID, secondSpaceID)
        XCTAssertTrue(
            second.environment.rootEnvironment === host,
            "the second session rooted at the first window's environment, so its engine dies with that window"
        )

        first.dispose()

        XCTAssertFalse(second.isDisposed)
        XCTAssertNil(host.store.space(firstSpaceID), "the first session's Space survived its own disposal")
        XCTAssertNotNil(
            host.store.space(secondSpaceID),
            """
            Disposing one Incognito session took the other one's Space with \
            it. Two Incognito windows can be open at once and each owns only \
            what it created.
            """
        )
    }

    func test_disposingTwice_isANoOp() throws {
        let session = WindowSession.incognito(on: host)
        let spaceCountAfterOpening = host.state.spaces.count

        session.dispose()
        let spaceCountAfterFirstDispose = host.state.spaces.count
        session.dispose()

        XCTAssertEqual(spaceCountAfterOpening, 3, "test precondition: two ordinary Spaces plus the Incognito one")
        XCTAssertEqual(spaceCountAfterFirstDispose, 2)
        XCTAssertEqual(host.state.spaces.count, 2, "a second dispose() removed something else")
    }
}
