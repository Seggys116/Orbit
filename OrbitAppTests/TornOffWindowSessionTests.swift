import AppKit
import XCTest

@testable import Orbit

@MainActor
final class TornOffWindowSessionTests: XCTestCase {

    private lazy var host: AppEnvironment = AppEnvironment.demo

    private var personalSpaceID: SpaceID!
    private var workSpaceID: SpaceID!
    private var originTabID: TabID!

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

        originTabID = host.openTab(url: URL(string: "https://origin.example.com/logged-in")!, in: personalSpaceID)
    }

    override func tearDown() {
        tearDownWindow()
        super.tearDown()
    }

    // MARK: - Real-window plumbing (identical shape to `IncognitoWindowSessionTests`)

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

    // MARK: - 1. The ephemeral Space reuses the origin tab's own persistent Profile

    func test_tornOffSession_reusesTheOriginTabsProfile_createsNoNewProfile() throws {
        let profileCountBefore = host.state.profiles.count
        let originProfileID = try XCTUnwrap(host.store.space(personalSpaceID)?.profileID)

        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)
        let tornOffSpace = try XCTUnwrap(host.store.space(tornOffSpaceID))

        XCTAssertEqual(
            tornOffSpace.profileID, originProfileID,
            "a torn-off Space must sit on the origin tab's own, real Profile — a tab logged into a site must not be silently signed out by tearing it off"
        )
        XCTAssertEqual(
            host.state.profiles.count, profileCountBefore,
            "tearing a tab off must never mint a new Profile, unlike Incognito"
        )
        XCTAssertTrue(host.state.profiles.first { $0.id == originProfileID }?.isPersistent == true, "test precondition: the reused Profile is genuinely persistent")
        XCTAssertTrue(tornOffSpace.isEphemeral, "only the Space itself is ephemeral — that is what keeps its tabs off disk without touching the Profile")
    }

    // MARK: - 2. Opening a torn-off session leaves the document's activeSpaceID alone

    func test_openingATornOffSession_leavesTheDocumentsActiveSpaceIDAlone() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))

        XCTAssertEqual(
            host.state.activeSpaceID, personalSpaceID,
            "tearing a tab off must never write the document's global activeSpaceID — every other open window would jump to the torn-off Space with it"
        )
        XCTAssertEqual(host.activeSpace?.id, personalSpaceID)
        XCTAssertTrue(session.isTornOff)
        XCTAssertNotNil(session.environment.activeSpace)
    }

    // MARK: - 3. The torn-off window and the main window show different Spaces simultaneously

    func test_theTornOffWindowAndTheMainWindowShowDifferentSpacesSimultaneously() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpace = try XCTUnwrap(session.environment.activeSpace)

        XCTAssertNotEqual(tornOffSpace.id, personalSpaceID)
        XCTAssertEqual(host.activeSpace?.id, personalSpaceID)
        XCTAssertTrue(session.environment.isWindowScoped)
        XCTAssertFalse(host.isWindowScoped, "the shared environment must keep following the document")
    }

    // MARK: - 4. Switching Space in one window never moves the other

    func test_switchingSpaceInEitherWindow_doesNotMoveTheOther() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        host.selectSpace(workSpaceID)
        XCTAssertEqual(host.activeSpace?.id, workSpaceID)
        XCTAssertEqual(
            session.environment.activeSpace?.id, tornOffSpaceID,
            "the torn-off window followed the main window's Space change"
        )

        session.environment.selectSpace(personalSpaceID)
        XCTAssertEqual(session.environment.activeSpace?.id, personalSpaceID)
        XCTAssertEqual(
            host.activeSpace?.id, workSpaceID,
            "the main window followed the torn-off window's Space change"
        )
        XCTAssertEqual(
            host.state.activeSpaceID, workSpaceID,
            "a window-scoped environment must never write the document's activeSpaceID"
        )
    }

    // MARK: - 5. `dispose()` removes the ephemeral Space and its tabs, leaves the Profile alive

    func test_dispose_removesTheEphemeralSpaceAndItsTabs_leavesTheProfileAlive() throws {
        let originProfileID = try XCTUnwrap(host.store.space(personalSpaceID)?.profileID)
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        let secondTabID = session.environment.openTab(url: URL(string: "https://second.example.com")!, in: tornOffSpaceID)

        XCTAssertNotNil(host.state.tabs[originTabID], "precondition: the origin tab is in the document")
        XCTAssertNotNil(host.state.tabs[secondTabID], "precondition: the second tab is in the document")
        XCTAssertNotNil(host.store.space(tornOffSpaceID), "precondition: the torn-off Space is in the document")

        session.dispose()

        XCTAssertTrue(session.isDisposed)
        XCTAssertNil(host.store.space(tornOffSpaceID), "the torn-off Space must be removed on disposal")
        XCTAssertNil(host.state.tabs[originTabID], "the origin tab, moved into the torn-off Space, must be removed with it")
        XCTAssertNil(host.state.tabs[secondTabID], "a tab opened directly inside the torn-off window must also be removed")
        XCTAssertTrue(
            host.state.profiles.contains { $0.id == originProfileID },
            "the origin tab's own persistent Profile must survive the torn-off window closing"
        )
        XCTAssertTrue(
            host.state.profiles.first { $0.id == originProfileID }?.isPersistent == true,
            "the surviving Profile must still be persistent — dispose() must never flip that"
        )
        XCTAssertEqual(
            host.state.activeSpaceID, personalSpaceID,
            "closing the torn-off window must not disturb the main window's Space"
        )
    }

    func test_disposingTwice_isANoOp() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let spaceCountAfterOpening = host.state.spaces.count

        session.dispose()
        let spaceCountAfterFirstDispose = host.state.spaces.count
        session.dispose()

        XCTAssertEqual(spaceCountAfterOpening, 3, "test precondition: Personal, Work, plus the torn-off Space")
        XCTAssertEqual(spaceCountAfterFirstDispose, 2)
        XCTAssertEqual(host.state.spaces.count, 2, "a second dispose() removed something else")
        XCTAssertTrue(session.isDisposed)
    }

    // MARK: - 6. The exact misclassification the integration pass fixed

    func test_tornOffEnvironment_reportsIsTornOffWindowTrue_andIsIncognitoFalse() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpace = try XCTUnwrap(session.environment.activeSpace)

        XCTAssertTrue(session.environment.isTornOffWindow, "a torn-off window's own environment must report isTornOffWindow == true")
        XCTAssertTrue(
            session.environment.isTornOffWindow(for: tornOffSpace),
            "the space:-parameterised overload SidebarView.content(for:) calls must agree"
        )
        XCTAssertFalse(
            session.environment.isIncognito(tornOffSpace),
            "a torn-off Space must never be classified as Incognito — its Profile is real and persistent, the exact distinction this task's own fix drew"
        )
        XCTAssertFalse(host.isTornOffWindow, "the main window's own (unscoped) environment must not itself report as a torn-off window")
    }

    func test_incognitoEnvironment_stillReportsIsIncognitoTrue_andIsTornOffWindowFalse() throws {
        let incognito = WindowSession.incognito(on: host)
        let incognitoSpace = try XCTUnwrap(incognito.environment.activeSpace)

        XCTAssertTrue(incognito.environment.isIncognito(incognitoSpace))
        XCTAssertFalse(
            incognito.environment.isTornOffWindow,
            "an Incognito session's own environment must not report isTornOffWindow == true"
        )
    }

    // MARK: - 7. `pagerSpaces` contains exactly the torn-off window's own Space

    func test_pagerSpaces_inATornOffWindow_containsExactlyItsOwnSpace() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        let pagerSpaceIDs = session.environment.pagerSpaces.map(\.id)

        XCTAssertEqual(
            pagerSpaceIDs, [tornOffSpaceID],
            "a torn-off window's pager must be restricted to the single Space it owns — Personal/Work must not be reachable from it"
        )
        XCTAssertFalse(pagerSpaceIDs.contains(personalSpaceID))
        XCTAssertFalse(pagerSpaceIDs.contains(workSpaceID))
        XCTAssertTrue(host.pagerSpaces.map(\.id).contains(personalSpaceID))
        XCTAssertTrue(host.pagerSpaces.map(\.id).contains(workSpaceID))
    }

    // MARK: - 8. A `.tornOff` session and an `.incognito` session opened together stay independent

    func test_aTornOffSessionAndAnIncognitoSession_openedTogether_stayIndependent() throws {
        let tornOff = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let incognito = WindowSession.incognito(on: host)

        let tornOffSpaceID = try XCTUnwrap(tornOff.environment.activeSpace?.id)
        let incognitoSpaceID = try XCTUnwrap(incognito.environment.activeSpace?.id)
        XCTAssertNotEqual(tornOffSpaceID, incognitoSpaceID)

        tornOff.dispose()

        XCTAssertTrue(tornOff.isDisposed)
        XCTAssertFalse(incognito.isDisposed)
        XCTAssertNil(host.store.space(tornOffSpaceID), "the torn-off session's own Space must be gone")
        XCTAssertNotNil(
            incognito.environment.activeSpace,
            "disposing the torn-off session took the independent Incognito session's Space with it"
        )
        XCTAssertNotNil(host.store.space(incognitoSpaceID))

        incognito.dispose()
        XCTAssertNil(host.store.space(incognitoSpaceID))
    }

    // MARK: - 9. `moveTabToMainWindow` moves the tab into a persistent Space so it survives the window closing

    func test_moveTabToMainWindow_movesTheTabIntoAPersistentSpace_survivingDisposal() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)
        XCTAssertEqual(host.store.tab(originTabID)?.spaceID, tornOffSpaceID, "precondition: the origin tab now lives in the torn-off Space")

        session.environment.moveTabToMainWindow(originTabID, destinationSpaceID: workSpaceID)

        XCTAssertEqual(
            host.store.tab(originTabID)?.spaceID, workSpaceID,
            "moveTabToMainWindow must relocate the tab into the named persistent Space"
        )

        session.dispose()

        XCTAssertNotNil(
            host.state.tabs[originTabID],
            "the tab was moved into a persistent Space before disposal and must survive the torn-off window closing"
        )
        XCTAssertEqual(host.store.tab(originTabID)?.spaceID, workSpaceID)
        XCTAssertNil(host.store.space(tornOffSpaceID), "the now-empty torn-off Space must still be removed")
    }

    func test_moveTabToMainWindow_carriesTheLiveRendererAcrossWithoutClosingIt() throws {
        let contents = MockWebContents()
        host._test_attachWebContents(contents, for: originTabID)

        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        XCTAssertNotNil(session.environment.webContents[originTabID], "adoptWebContents must have carried the live renderer into the torn-off environment")
        XCTAssertNil(host.webContents[originTabID], "the root environment must no longer hold the renderer once it has been adopted")

        session.environment.moveTabToMainWindow(originTabID, destinationSpaceID: workSpaceID)

        XCTAssertNotNil(host.webContents[originTabID], "the renderer must move back into the root environment")
        XCTAssertNil(session.environment.webContents[originTabID], "the torn-off environment must no longer hold it once handed back")
        XCTAssertFalse(contents.isClosed, "the renderer must never be closed by a tear-off/hand-back round trip — its scroll position and session history must survive")
    }

    // MARK: - 10. A stale tab id is a no-op, not a crash

    func test_tornOff_withATabIDThatDoesNotResolve_returnsNil() {
        let session = WindowSession.tornOff(on: host, adopting: UUID())
        XCTAssertNil(session, "a drag that raced a tab close, or a stale id, must produce no session at all")
    }

    // MARK: - 11. Closing the torn-off window through the real path leaves nothing in memory

    func test_closingTheTornOffWindowThroughTheRealPath_disposesTheSession() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        _ = makeRealWindow(for: session)
        XCTAssertFalse(session.isDisposed)

        tearDownWindow()

        XCTAssertTrue(session.isDisposed, "windowWillClose did not dispose the torn-off session")
        XCTAssertNil(host.store.space(tornOffSpaceID))
        XCTAssertNil(host.state.tabs[originTabID])
        XCTAssertEqual(host.state.activeSpaceID, personalSpaceID)
    }

    // MARK: - 12. Tearing a tab off an INCOGNITO window (Defect 1, P0)

    /// Regression: closing the origin Incognito window used to reassign the torn-off Space
    /// onto the user's real, persistent Profile, silently de-privatising the session.
    func test_tearingOffFromAnIncognitoOrigin_mintsAndOwnsItsOwnPrivateProfile() throws {
        let incognito = WindowSession.incognito(on: host)
        let incognitoSpaceID = try XCTUnwrap(incognito.environment.activeSpace?.id)
        let incognitoProfileID = try XCTUnwrap(host.store.space(incognitoSpaceID)?.profileID)
        let tabID = incognito.environment.openTab(
            url: URL(string: "https://private.example.com/secret")!,
            in: incognitoSpaceID
        )
        let profileCountBeforeTearOff = host.state.profiles.count

        let tornOff = try XCTUnwrap(WindowSession.tornOff(on: incognito.environment, adopting: tabID))
        let tornOffSpace = try XCTUnwrap(tornOff.environment.activeSpace)

        XCTAssertNotEqual(
            tornOffSpace.profileID, incognitoProfileID,
            "a tab torn off out of an Incognito window must not keep sharing the origin window's own Profile"
        )
        XCTAssertEqual(
            host.state.profiles.count, profileCountBeforeTearOff + 1,
            "the torn-off session must mint its own Profile, exactly as opening a fresh Incognito window would"
        )
        XCTAssertFalse(
            host.state.profiles.first { $0.id == tornOffSpace.profileID }?.isPersistent ?? true,
            "the minted Profile must itself be non-persistent"
        )
        XCTAssertTrue(
            tornOff.environment.isIncognito(tornOffSpace),
            "a torn-off window whose origin was private must itself still be recognised as Incognito — otherwise history and every isIncognito(_:)-gated feature switch back on"
        )
        XCTAssertTrue(tornOff.environment.isTornOffWindow, "the window is still mechanically a torn-off window")
        XCTAssertTrue(tornOff.environment.isTornOffWindow(for: tornOffSpace))
        XCTAssertTrue(
            tornOff.environment.isPrivateBrowsingContext(spaceID: tornOffSpace.id, profileID: tornOffSpace.profileID),
            "recordVisit's own suppression guard reads this — it must agree the session is private"
        )
    }

    func test_tearingOffFromAnIncognitoOrigin_disposesCleanly_closingOriginFirst() throws {
        let incognito = WindowSession.incognito(on: host)
        let incognitoSpaceID = try XCTUnwrap(incognito.environment.activeSpace?.id)
        let incognitoProfileID = try XCTUnwrap(host.store.space(incognitoSpaceID)?.profileID)
        let tabID = incognito.environment.openTab(
            url: URL(string: "https://private.example.com/secret")!,
            in: incognitoSpaceID
        )
        let tornOff = try XCTUnwrap(WindowSession.tornOff(on: incognito.environment, adopting: tabID))
        let tornOffSpaceID = try XCTUnwrap(tornOff.environment.activeSpace?.id)
        let tornOffProfileID = try XCTUnwrap(host.store.space(tornOffSpaceID)?.profileID)

        incognito.dispose()

        XCTAssertNil(host.store.space(incognitoSpaceID), "the origin Incognito Space must be gone")
        XCTAssertFalse(host.state.profiles.contains { $0.id == incognitoProfileID }, "the origin Incognito Profile must be gone")
        XCTAssertNotNil(
            host.store.space(tornOffSpaceID),
            "closing the Incognito origin must not disturb the torn-off session, which owns an independent Profile"
        )
        XCTAssertTrue(
            host.state.profiles.contains { $0.id == tornOffProfileID },
            "the torn-off session's own minted Profile must survive the origin closing"
        )
        let stillLiveSpace = try XCTUnwrap(tornOff.environment.activeSpace)
        XCTAssertTrue(
            tornOff.environment.isIncognito(stillLiveSpace),
            "the torn-off window must remain private after its Incognito origin has closed"
        )

        tornOff.dispose()

        XCTAssertNil(host.store.space(tornOffSpaceID))
        XCTAssertFalse(
            host.state.profiles.contains { $0.id == tornOffProfileID },
            "disposing the torn-off session must remove its own minted Profile"
        )
    }

    func test_tearingOffFromAnIncognitoOrigin_disposesCleanly_closingTornOffFirst() throws {
        let incognito = WindowSession.incognito(on: host)
        let incognitoSpaceID = try XCTUnwrap(incognito.environment.activeSpace?.id)
        let incognitoProfileID = try XCTUnwrap(host.store.space(incognitoSpaceID)?.profileID)
        let tabID = incognito.environment.openTab(
            url: URL(string: "https://private.example.com/secret")!,
            in: incognitoSpaceID
        )
        let tornOff = try XCTUnwrap(WindowSession.tornOff(on: incognito.environment, adopting: tabID))
        let tornOffSpaceID = try XCTUnwrap(tornOff.environment.activeSpace?.id)
        let tornOffProfileID = try XCTUnwrap(host.store.space(tornOffSpaceID)?.profileID)

        tornOff.dispose()

        XCTAssertNil(host.store.space(tornOffSpaceID), "the torn-off session's own Space must be gone")
        XCTAssertFalse(
            host.state.profiles.contains { $0.id == tornOffProfileID },
            "the torn-off session's own minted Profile must be gone"
        )
        XCTAssertNotNil(
            host.store.space(incognitoSpaceID),
            "closing the torn-off window first must not disturb the still-open Incognito origin"
        )
        XCTAssertTrue(
            host.state.profiles.contains { $0.id == incognitoProfileID },
            "the Incognito origin's own Profile must survive the torn-off window closing first"
        )
        XCTAssertFalse(incognito.isDisposed)

        incognito.dispose()

        XCTAssertNil(host.store.space(incognitoSpaceID))
        XCTAssertFalse(host.state.profiles.contains { $0.id == incognitoProfileID })
    }

    // MARK: - 13. `moveTabToMainWindow` brings the destination window forward and closes an emptied torn-off window (Defect 4, P2)

    /// Regression: the rescue control used to move the tab but never bring the destination
    /// window forward or close the now-tabless torn-off one.
    func test_moveTabToMainWindow_bringsDestinationForward_andClosesTheNowEmptyTornOffWindow() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        let mainWindow = OrbitWindowController.makeWindow()
        mainWindow.isReleasedWhenClosed = false
        let mainController = OrbitWindowController(window: mainWindow)
        mainController.adopt(WindowSession.standard(on: host))
        mainWindow.delegate = mainController
        mainController.installContentView(window: mainWindow)
        OrbitWindowController._test_register(mainController)

        let tornOffWindow = OrbitWindowController.makeWindow()
        tornOffWindow.isReleasedWhenClosed = false
        let tornOffController = OrbitWindowController(window: tornOffWindow)
        tornOffController.adopt(session)
        tornOffWindow.delegate = tornOffController
        tornOffController.installContentView(window: tornOffWindow)
        OrbitWindowController._test_register(tornOffController)

        defer {
            for window in [mainWindow, tornOffWindow] {
                window.orderOut(nil)
                window.contentView = nil
                window.delegate = nil
            }
        }

        session.environment.moveTabToMainWindow(originTabID, destinationSpaceID: workSpaceID)

        XCTAssertEqual(
            host.store.tab(originTabID)?.spaceID, workSpaceID,
            "the tab itself must have moved into the main window's Space"
        )
        // isKeyWindow is not asserted: a hosted CI runner does not always grant
        // real key status. isVisible is the reliable signal makeKeyAndOrderFront ran.
        XCTAssertTrue(
            mainWindow.isVisible,
            "the destination window must be brought to the front — the rescued tab must be what the user is actually looking at"
        )
        XCTAssertTrue(session.isDisposed, "the torn-off window, now with no tabs left, must be closed — which disposes its session")
        XCTAssertNil(host.store.space(tornOffSpaceID), "the disposed torn-off session's ephemeral Space must be gone")
        XCTAssertFalse(tornOffWindow.isVisible, "the torn-off window must actually have closed, not merely lost key status")
    }

    func test_moveTabToMainWindow_doesNotCloseTheTornOffWindow_whenOtherTabsRemain() throws {
        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)
        let secondTabID = session.environment.openTab(url: URL(string: "https://second.example.com")!, in: tornOffSpaceID)

        let tornOffWindow = OrbitWindowController.makeWindow()
        tornOffWindow.isReleasedWhenClosed = false
        let tornOffController = OrbitWindowController(window: tornOffWindow)
        tornOffController.adopt(session)
        tornOffWindow.delegate = tornOffController
        tornOffController.installContentView(window: tornOffWindow)
        OrbitWindowController._test_register(tornOffController)

        defer {
            tornOffWindow.orderOut(nil)
            tornOffWindow.contentView = nil
            tornOffWindow.delegate = nil
        }

        session.environment.moveTabToMainWindow(originTabID, destinationSpaceID: workSpaceID)

        XCTAssertFalse(session.isDisposed, "a torn-off window that still has another tab open must not be closed")
        XCTAssertNotNil(host.store.space(tornOffSpaceID), "the torn-off Space must survive while it still has a tab")
        XCTAssertNotNil(host.state.tabs[secondTabID])
    }

    // MARK: - 14. Tearing off a PINNED tab must not destroy the bookmark (Defect 5, P2)

    /// Regression: tearing off a pinned tab used to move it (not a copy) into the ephemeral
    /// Space, so closing the torn-off window destroyed the durable, user-created bookmark.
    func test_tearingOffAPinnedTab_keepsTheBookmarkInTheOriginSpace_survivingDisposal() throws {
        host.pinTab(originTabID)
        XCTAssertEqual(host.store.tab(originTabID)?.section, .pinned, "test precondition: the tab is pinned")
        let pinnedURL = try XCTUnwrap(host.store.tab(originTabID)?.pinnedURL)

        let session = try XCTUnwrap(WindowSession.tornOff(on: host, adopting: originTabID))
        let tornOffSpaceID = try XCTUnwrap(session.environment.activeSpace?.id)

        let originTabAfterTearOff = try XCTUnwrap(host.store.tab(originTabID))
        XCTAssertEqual(
            originTabAfterTearOff.spaceID, personalSpaceID,
            "tearing off a pinned tab must not move the bookmark out of its origin Space"
        )
        XCTAssertEqual(originTabAfterTearOff.section, .pinned, "the bookmark must remain pinned")
        XCTAssertTrue(originTabAfterTearOff.isUnloaded, "the origin tab's renderer must have been released, the same as the ordinary 'close, keep bookmark' control")
        XCTAssertTrue(
            host.pinnedNodes(in: personalSpaceID).flatMap(\.allTabIDs).contains(originTabID),
            "the bookmark must still be in the origin Space's Pinned tree"
        )

        let tornOffTabID = try XCTUnwrap(session.environment.activeTabID)
        XCTAssertNotEqual(tornOffTabID, originTabID, "the torn-off window must not have adopted the pinned tab's own id")
        XCTAssertEqual(host.store.tab(tornOffTabID)?.url, pinnedURL)
        XCTAssertEqual(host.store.tab(tornOffTabID)?.spaceID, tornOffSpaceID)
        XCTAssertEqual(
            host.store.tab(tornOffTabID)?.section, .today,
            "Arc has no Pinned-tab equivalent for a torn-off tab — the ephemeral copy is an ordinary Today tab"
        )

        session.dispose()

        XCTAssertTrue(session.isDisposed)
        XCTAssertNil(host.store.space(tornOffSpaceID), "the ephemeral torn-off Space must still be removed")
        XCTAssertNil(host.state.tabs[tornOffTabID], "the ephemeral tab created in the torn-off window must be removed with its Space")
        XCTAssertNotNil(
            host.state.tabs[originTabID],
            "the origin pinned tab must survive the torn-off window closing — this is the whole point of the fix"
        )
        XCTAssertEqual(host.store.tab(originTabID)?.section, .pinned, "the bookmark must still be pinned after disposal")
        XCTAssertTrue(
            host.pinnedNodes(in: personalSpaceID).flatMap(\.allTabIDs).contains(originTabID),
            "the bookmark must still be reachable from the origin Space's Pinned tree after disposal"
        )
    }
}
