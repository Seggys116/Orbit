import AppKit
import XCTest
@testable import Orbit

@MainActor
final class PageFocusAfterTabSwitchTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var scratchSpaceID: SpaceID!
    private var originalActiveSpaceID: SpaceID?
    private var attachedTabIDs: [TabID] = []

    override func setUp() {
        super.setUp()
        originalActiveSpaceID = env.activeSpace?.id
        let profileID = env.createDefaultProfileIfNeeded()
        scratchSpaceID = env.createSpace(
            name: "Page Focus Scratch",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: profileID
        )
        env.selectSpace(scratchSpaceID)
    }

    override func tearDown() {
        for tabID in attachedTabIDs { env._test_detachWebContents(for: tabID) }
        attachedTabIDs.removeAll()
        if let scratchSpaceID { env.deleteSpace(scratchSpaceID) }
        if let originalActiveSpaceID, env.space(originalActiveSpaceID) != nil {
            env.selectSpace(originalActiveSpaceID)
        }
        scratchSpaceID = nil
        originalActiveSpaceID = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTabWithPage(_ path: String) -> (tabID: TabID, page: MockWebContents) {
        let tabID = env.openTab(
            url: URL(string: "https://example.com/\(path)")!,
            in: scratchSpaceID,
            section: .today,
            activate: false
        )
        let page = MockWebContents()
        env._test_attachWebContents(page, for: tabID)
        attachedTabIDs.append(tabID)
        return (tabID, page)
    }

    // MARK: - Tab activation

    func testActivatingATabFocusesItsPage() {
        let (tabID, page) = makeTabWithPage("activated")
        XCTAssertEqual(page.focusCallCount, 0, "Fixture check: opening a tab with activate: false must not have focused it yet.")
        XCTAssertFalse(env.isCommandBarPresented, "Fixture check: no overlay is presented.")
        XCTAssertFalse(env.isFindBarPresented, "Fixture check: no overlay is presented.")

        env.activateTab(tabID)

        XCTAssertEqual(env.activeTabID, tabID, "Fixture check: the tab really did become active.")
        XCTAssertEqual(
            page.focusCallCount, 1,
            "Activating a tab never asked its page to take focus, so the user's next keystroke goes nowhere until they click the page."
        )
    }

    func testSwitchingBetweenTabsFocusesOnlyTheTabBeingActivated() {
        let first = makeTabWithPage("first")
        let second = makeTabWithPage("second")

        env.activateTab(first.tabID)
        XCTAssertEqual(first.page.focusCallCount, 1)
        XCTAssertEqual(second.page.focusCallCount, 0, "Activating one tab focused a different tab's page.")

        env.activateTab(second.tabID)
        XCTAssertEqual(
            second.page.focusCallCount, 1,
            "Switching to the second tab did not focus it."
        )
        XCTAssertEqual(
            first.page.focusCallCount, 1,
            "Switching away from the first tab focused it again; focus must follow the tab being activated."
        )
    }

    // MARK: - The Command Bar path

    func testActivatingATabWhileTheCommandBarIsPresentedDoesNotFocusAndDismissingItThenDoes() {
        let (tabID, page) = makeTabWithPage("from-command-bar")
        env.isCommandBarPresented = true

        env.activateTab(tabID)

        XCTAssertEqual(
            page.focusCallCount, 0,
            """
            Activating a tab stole first responder while the Command Bar was presented. The bar is a \
            real editable text field with its own @FocusState; taking focus from it mid-word is the \
            reason activateTab's guard exists.
            """
        )

        env.dismissCommandBar()

        XCTAssertFalse(env.isCommandBarPresented, "dismissCommandBar() left the bar marked as presented.")
        XCTAssertEqual(
            page.focusCallCount, 1,
            """
            Dismissing the Command Bar left the page unfocused. Nothing else offers it focus after a \
            Command Bar navigation — activateTab already declined while the flag was true — so this \
            is every ⌘T-and-Enter ending with a page the keyboard cannot reach.
            """
        )
    }

    func testDismissingTheFindBarFocusesThePageAndStillClearsTheQuery() {
        let (tabID, page) = makeTabWithPage("found")
        env.activateTab(tabID)
        let focusCountBeforeFindBar = page.focusCallCount

        env.isFindBarPresented = true
        env.findQuery = "needle"
        env.activateTab(tabID)
        XCTAssertEqual(
            page.focusCallCount, focusCountBeforeFindBar,
            "A tab activation stole first responder from the Find bar's text field."
        )

        env.dismissFindBar()

        XCTAssertFalse(env.isFindBarPresented, "dismissFindBar() left the bar marked as presented.")
        XCTAssertEqual(env.findQuery, "", "Dismissing the Find bar must still clear the query — the previous teardown was not preserved.")
        XCTAssertEqual(
            page.focusCallCount, focusCountBeforeFindBar + 1,
            "Closing the Find bar left first responder on a text field that no longer exists, so the page stayed unreachable from the keyboard."
        )
    }

    func testDismissingOneOverlayDoesNotFocusThePageWhileTheOtherIsStillPresented() {
        let (tabID, page) = makeTabWithPage("two-overlays")
        env.activateTab(tabID)
        let focusCountBefore = page.focusCallCount

        env.isFindBarPresented = true
        env.isCommandBarPresented = true

        env.dismissCommandBar()

        XCTAssertFalse(env.isCommandBarPresented, "The Command Bar must still be dismissed.")
        XCTAssertEqual(
            page.focusCallCount, focusCountBefore,
            "Dismissing the Command Bar focused the page while the Find bar was still presented, taking the keyboard away from the Find field."
        )

        env.dismissFindBar()

        XCTAssertEqual(
            page.focusCallCount, focusCountBefore + 1,
            "With the last overlay gone, the page must finally get focus back."
        )
    }

    // MARK: - The presented flag must never get stuck

    func testEveryDismissalPathLeavesThePresentedFlagsFalse() throws {
        env.isCommandBarPresented = true
        env.dismissCommandBar()
        XCTAssertFalse(env.isCommandBarPresented)
        env.dismissCommandBar()
        XCTAssertFalse(env.isCommandBarPresented, "dismissCommandBar() must be idempotent; a second dismissal is reachable from the scrim.")

        env.isFindBarPresented = true
        env.dismissFindBar()
        XCTAssertFalse(env.isFindBarPresented)
        env.dismissFindBar()
        XCTAssertFalse(env.isFindBarPresented, "dismissFindBar() must be idempotent.")

        let allowedFiles: Set<String> = ["AppEnvironment+Commands.swift", "AppEnvironment.swift"]
        for flag in ["isCommandBarPresented", "isFindBarPresented"] {
            let offenders = try Self.filesAssigningFalse(to: flag).subtracting(allowedFiles)
            XCTAssertTrue(
                offenders.isEmpty,
                """
                \(flag) is cleared by hand in \(offenders.sorted().joined(separator: ", ")). Every dismissal \
                must go through AppEnvironment.dismissCommandBar()/dismissFindBar(), because clearing the \
                flag is only half of a dismissal — the page also has to be given keyboard focus back, and a \
                path that skips that leaves the user typing into nothing.
                """
            )
        }
    }

    /// Every file under `Orbit/**` with a line of *code* (comments excluded)
    /// assigning `false` to `flag`, by file name.
    private static func filesAssigningFalse(to flag: String) throws -> Set<String> {
        let productionRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: productionRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not walk \(productionRoot.path) — this guard's own directory walk is broken.")
            return []
        }

        var files: Set<String> = []
        var scannedFileCount = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFileCount += 1
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { continue }
                if trimmed.contains("\(flag) = false") {
                    files.insert(url.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scannedFileCount, 0, "Found no Swift files under \(productionRoot.path).")
        XCTAssertFalse(
            files.isEmpty,
            "Found no assignment of false to \(flag) anywhere in Orbit/**, which means this guard's own matcher has stopped working."
        )
        return files
    }

    // MARK: - Split View (the path that already worked)

    func testFocusingASplitPaneFocusesThatPanesPageAndNotTheOther() throws {
        let left = makeTabWithPage("split-left")
        let right = makeTabWithPage("split-right")

        // `.right` puts the new pane after the existing one, so index 0 is
        // `left` and index 1 is `right`.
        guard let groupID = env.createSplit(existingTabID: left.tabID, newTabID: right.tabID, edge: .right) else {
            return XCTFail("The split was not created, so nothing below is testing pane focus.")
        }
        XCTAssertEqual(
            env.state.splitGroups[groupID]?.tabIDs, [left.tabID, right.tabID],
            "Fixture check: pane order decides what index 0 and index 1 mean below."
        )

        let leftFocusesAfterSetup = left.page.focusCallCount
        let rightFocusesAfterSetup = right.page.focusCallCount

        env.focusSplitPane(index: 1)

        XCTAssertEqual(env.focusedSplitPaneIndex, 1, "The focused pane index did not move.")
        XCTAssertGreaterThan(
            right.page.focusCallCount, rightFocusesAfterSetup,
            "Focusing the right pane never asked its page to take first responder, so the accent border moved but the keyboard did not."
        )
        XCTAssertEqual(
            left.page.focusCallCount, leftFocusesAfterSetup,
            "Focusing the right pane also focused the left one — keystrokes would land in whichever pane won the race."
        )

        let rightFocusesBeforeSwitchingBack = right.page.focusCallCount
        env.focusSplitPane(index: 0)

        XCTAssertEqual(env.focusedSplitPaneIndex, 0)
        XCTAssertGreaterThan(
            left.page.focusCallCount, leftFocusesAfterSetup,
            "Focusing the left pane back never reached its page."
        )
        XCTAssertEqual(
            right.page.focusCallCount, rightFocusesBeforeSwitchingBack,
            "Focusing the left pane also re-focused the right one."
        )
    }
}
