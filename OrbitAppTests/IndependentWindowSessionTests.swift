import AppKit
import XCTest

@testable import Orbit

// Two ordinary windows share the document's tabs and Spaces but not their selection.
@MainActor
final class IndependentWindowSessionTests: XCTestCase {

    private lazy var first: AppEnvironment = AppEnvironment.demo

    private var spaceID: SpaceID!
    private var pageA: TabID!
    private var pageB: TabID!
    private var pageC: TabID!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        let space = Space(name: "Personal", profileID: profile.id, order: 0)
        state.profiles = [profile]
        state.spaces = [space]
        state.activeSpaceID = space.id
        first.state = state
        spaceID = space.id
        pageA = first.openTab(url: URL(string: "https://a.example.com")!, in: space.id)
        pageB = first.openTab(url: URL(string: "https://b.example.com")!, in: space.id, activate: false)
        pageC = first.openTab(url: URL(string: "https://c.example.com")!, in: space.id, activate: false)
        first.activateTab(pageA)
    }

    override func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func register(_ session: WindowSession) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = OrbitWindowController(window: window)
        controller.adopt(session)
        window.delegate = controller
        OrbitWindowController._test_register(controller)
        windows.append(window)
        return window
    }

    private func openSecondWindow() -> AppEnvironment {
        register(WindowSession.standard(on: first))
        let session = WindowSession.independentStandard(on: first)
        register(session)
        return session.environment
    }

    func test_aNewWindow_startsOnANewTabNotOnTheFirstWindowsPage() {
        let second = openSecondWindow()

        XCTAssertNotNil(second.activeTabID, "A new window opens with a tab of its own.")
        XCTAssertNotEqual(second.activeTabID, pageA, "A new window must not be stuck on the page the first window is showing.")
        XCTAssertEqual(first.activeTabID, pageA, "Opening a window must leave the first one where it was.")
        XCTAssertNotNil(second.activeTab.map(NewTabPageModel.isUnlisted), "The new window starts on the new tab page.")
    }

    func test_choosingATabInTheSecondWindow_doesNotMoveTheFirst() {
        let second = openSecondWindow()

        second.activateTab(pageB)

        XCTAssertEqual(second.activeTabID, pageB)
        XCTAssertEqual(first.activeTabID, pageA, "Choosing a tab in one window moved the other window's page.")
        XCTAssertEqual(first.state.activeTabBySpace[spaceID], pageA, "The document's own selection belongs to the first window and must not follow the second.")
    }

    func test_choosingATabInTheFirstWindow_doesNotMoveTheSecond() {
        let second = openSecondWindow()
        second.activateTab(pageB)

        first.activateTab(pageC)

        XCTAssertEqual(first.activeTabID, pageC)
        XCTAssertEqual(second.activeTabID, pageB, "Choosing a tab in the first window moved the second window's page.")
    }

    func test_aTabShownInAnotherWindow_isNotTakenOrShownTwice() {
        let second = openSecondWindow()
        let before = second.activeTabID

        second.activateTab(pageA)

        XCTAssertEqual(second.activeTabID, before, "A page already on screen in another window must not also be shown here.")
        XCTAssertEqual(first.activeTabID, pageA)
    }

    func test_closingTheSecondWindowsTab_movesItBesideTheOneItClosedAndLeavesTheFirstAlone() {
        let second = openSecondWindow()
        second.activateTab(pageB)

        second.closeTab(pageB)

        XCTAssertEqual(first.activeTabID, pageA, "Closing a tab in the second window moved the first.")
        XCTAssertNotEqual(second.activeTabID, pageA, "The second window moved onto the page the first window is showing.")
        XCTAssertNotEqual(second.activeTabID, pageB)
    }

    func test_eachWindowKeepsItsOwnSpace() {
        let second = openSecondWindow()
        let other = first.store.createSpace(name: "Work", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: first.state.profiles[0].id, activate: false)

        second.selectSpace(other, animated: false)

        XCTAssertEqual(second.activeSpace?.id, other)
        XCTAssertEqual(first.activeSpace?.id, spaceID, "Switching Space in one window moved the other.")
        XCTAssertEqual(second.pagerSpaces.count, first.pagerSpaces.count, "A further ordinary window pages through the same Spaces as the first.")
    }
}
