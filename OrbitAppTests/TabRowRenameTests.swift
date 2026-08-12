import XCTest
@testable import Orbit

@MainActor
final class TabRowRenameTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var scratchSpaceID: SpaceID!
    private var originalActiveSpaceID: SpaceID?
    private var pinnedTabID: TabID!

    override func setUp() {
        super.setUp()
        originalActiveSpaceID = env.activeSpace?.id
        let profileID = env.createDefaultProfileIfNeeded()
        scratchSpaceID = env.createSpace(
            name: "Rename Scratch",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: profileID
        )
        env.selectSpace(scratchSpaceID)
        pinnedTabID = env.openTab(
            url: URL(string: "https://getyourguide.com/monte-alban")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )
        env.state.tabs[pinnedTabID]?.title = "Monte Alban Tour | GetYourGuide"
    }

    override func tearDown() {
        if let scratchSpaceID { env.deleteSpace(scratchSpaceID) }
        if let originalActiveSpaceID, env.space(originalActiveSpaceID) != nil {
            env.selectSpace(originalActiveSpaceID)
        }
        scratchSpaceID = nil
        originalActiveSpaceID = nil
        pinnedTabID = nil
        super.tearDown()
    }

    private func makeRename() -> TabTitleRename { TabTitleRename() }

    // MARK: - Beginning

    func testBeginningARenameOpensTheFieldSeededWithTheCurrentTitle() {
        let rename = makeRename()
        XCTAssertFalse(rename.isEditing, "A row starts showing its label, not a text field.")

        guard let tab = env.tab(pinnedTabID) else { return XCTFail("Scratch tab missing.") }
        rename.begin(from: tab.displayTitle)

        XCTAssertTrue(rename.isEditing, "Double-clicking the title did not put the row into edit mode.")
        XCTAssertEqual(rename.draft, "Monte Alban Tour | GetYourGuide", "The field was not seeded with the title on screen.")
    }

    // MARK: - Committing

    func testCommittingWritesTheCustomTitleAndClosesTheField() {
        let rename = makeRename()
        rename.begin(from: env.tab(pinnedTabID)?.displayTitle ?? "")
        rename.draft = "Monte Alban Tour"

        let holdsCustomTitle = rename.commit(tabID: pinnedTabID, in: env)

        XCTAssertTrue(holdsCustomTitle)
        XCTAssertFalse(rename.isEditing, "Committing must close the field.")
        XCTAssertEqual(
            env.tab(pinnedTabID)?.customTitle, "Monte Alban Tour",
            "Return did not write the custom title — renameTab still has no reachable call site."
        )
        XCTAssertEqual(env.tab(pinnedTabID)?.displayTitle, "Monte Alban Tour", "The row would still show the old title.")
        XCTAssertEqual(
            env.state.tabs[pinnedTabID]?.customTitle, "Monte Alban Tour",
            "The rename never reached the persisted OrbitState."
        )
    }

    func testCommittingTrimsSurroundingWhitespace() {
        let rename = makeRename()
        rename.begin(from: "")
        rename.draft = "   Oaxaca Trip \n"

        rename.commit(tabID: pinnedTabID, in: env)

        XCTAssertEqual(env.tab(pinnedTabID)?.customTitle, "Oaxaca Trip")
    }

    func testACustomTitleSurvivesThePageChangingItsOwnTitle() {
        let rename = makeRename()
        rename.begin(from: "")
        rename.draft = "Monte Alban Tour"
        rename.commit(tabID: pinnedTabID, in: env)

        env.state.tabs[pinnedTabID]?.title = "Tours in Oaxaca — 120 results"

        XCTAssertEqual(
            env.tab(pinnedTabID)?.displayTitle, "Monte Alban Tour",
            "The page's own title overrode the user's rename."
        )
    }

    // MARK: - Cancelling

    func testCancellingLeavesTheTitleUntouched() {
        let rename = makeRename()
        rename.begin(from: env.tab(pinnedTabID)?.displayTitle ?? "")
        rename.draft = "Typed then abandoned"

        rename.cancel()

        XCTAssertFalse(rename.isEditing, "Escape must close the field.")
        XCTAssertNil(env.tab(pinnedTabID)?.customTitle, "Escape wrote a custom title anyway.")
        XCTAssertEqual(
            env.tab(pinnedTabID)?.displayTitle, "Monte Alban Tour | GetYourGuide",
            "The row's title changed on a cancelled rename."
        )
    }

    func testCancellingDoesNotUndoAnEarlierRename() {
        let first = makeRename()
        first.begin(from: "")
        first.draft = "Monte Alban Tour"
        first.commit(tabID: pinnedTabID, in: env)

        let second = makeRename()
        second.begin(from: env.tab(pinnedTabID)?.displayTitle ?? "")
        second.draft = "Something else"
        second.cancel()

        XCTAssertEqual(env.tab(pinnedTabID)?.customTitle, "Monte Alban Tour")
    }

    // MARK: - Clearing

    func testCommittingAnEmptyDraftRestoresThePageTitle() {
        let rename = makeRename()
        rename.begin(from: "")
        rename.draft = "Monte Alban Tour"
        rename.commit(tabID: pinnedTabID, in: env)
        XCTAssertEqual(env.tab(pinnedTabID)?.displayTitle, "Monte Alban Tour", "test precondition")

        let clearing = makeRename()
        clearing.begin(from: env.tab(pinnedTabID)?.displayTitle ?? "")
        clearing.draft = "    "

        let holdsCustomTitle = clearing.commit(tabID: pinnedTabID, in: env)

        XCTAssertFalse(holdsCustomTitle)
        XCTAssertNil(env.tab(pinnedTabID)?.customTitle, "An emptied field must clear the custom title, not store blank.")
        XCTAssertEqual(
            env.tab(pinnedTabID)?.displayTitle, "Monte Alban Tour | GetYourGuide",
            "Clearing the rename did not bring the page's own title back."
        )
    }
}
