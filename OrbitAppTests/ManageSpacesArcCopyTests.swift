import XCTest
@testable import Orbit

@MainActor
final class ManageSpacesArcCopyTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var scratchSpaceIDs: [SpaceID] = []
    private var originalActiveSpaceID: SpaceID?

    override func setUp() {
        super.setUp()
        originalActiveSpaceID = env.activeSpace?.id
    }

    override func tearDown() {
        for id in scratchSpaceIDs where env.space(id) != nil {
            env.deleteSpace(id)
        }
        scratchSpaceIDs = []
        if let originalActiveSpaceID, env.space(originalActiveSpaceID) != nil {
            env.selectSpace(originalActiveSpaceID)
        }
        originalActiveSpaceID = nil
        super.tearDown()
    }

    // MARK: - 1. The invented copy is gone

    func testNoInventedInstructionLineOrSectionLabels() throws {
        let lines = try executableLines(of: "UI/Spaces/ManageSpacesView.swift")

        let banned = [
            "Drag tabs between Spaces",
            "\"PINNED\"",
            "\"TODAY\"",
        ]

        for needle in banned {
            let offending = lines.enumerated().filter { $0.element.contains(needle) }
            XCTAssertTrue(
                offending.isEmpty,
                """
                ManageSpacesView carries `\(needle)` again on line(s) \
                \(offending.map { "\($0.offset + 1)" }.joined(separator: ", ")). Arc has no instruction copy \
                and no PINNED/TODAY labels in this surface — refs/reference/web/arc-manage-spaces-panel-allthingshow.png. \
                Do not put Orbit-invented text into a surface presented as Arc's.
                """
            )
        }
    }

    func testTheSectionsAreSeparatedByArcsTodayDividerWithClear() throws {
        let source = try source(of: "UI/Spaces/ManageSpacesView.swift")
        XCTAssertTrue(source.contains("todayDivider(for:"), "The Pinned/Today separator is gone entirely; Arc separates them with its Today divider.")
        XCTAssertTrue(
            source.contains("TodayDividerRow(spaceID: spaceID"),
            "ManageSpacesView must mount the shared TodayDividerRow. A private second copy here is exactly how this surface and the sidebar came to disagree about Arc."
        )

        let dividerSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Orbit/UI/Sidebar/TodayDividerRow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            dividerSource.contains("Text(\"Clear\")"),
            "The Today divider lost its `Clear` control (refs/reference/arc-sidebar-today-list-clear.png and arc-hover-preview-pinned-tab.png, both viewed; Arc 1.152.0's UnpinnedSectionDividerCellView names a `clearButton` on this cell)."
        )
        XCTAssertTrue(
            dividerSource.contains("arrow.down"),
            "The Today divider lost its down-arrow glyph. Arc's own cell carries a `downArrowImage` whose accessibility description is literally \"arrow pointing down\", and web/arc-manage-spaces-panel-allthingshow.png renders the control as `↓ Clear`."
        )
    }

    // MARK: - 2. Everything that copy described still works

    func testDraggingATabIntoAnotherSpacesColumnStillMovesIt() {
        let source = makeSpace(named: "Copy Guard Source")
        let destination = makeSpace(named: "Copy Guard Destination")

        env.selectSpace(source)
        let tabID = env.openTab(url: URL(string: "https://example.com/manage-spaces-drag")!, in: source, activate: false)

        XCTAssertTrue(env.todayTabs(in: source).map(\.id).contains(tabID), "test precondition: the tab starts in the source Space")

        let order = ManageSpacesDropAction.perform(
            ManageSpacesDragPayload(id: tabID, kind: .tab, originSpaceID: source),
            ontoSpace: destination,
            currentOrder: env.spaces.map(\.id),
            in: env
        )

        XCTAssertFalse(env.todayTabs(in: source).map(\.id).contains(tabID), "The tab did not leave the source Space's column.")
        XCTAssertTrue(env.todayTabs(in: destination).map(\.id).contains(tabID), "The tab never arrived in the destination Space's column.")
        XCTAssertEqual(order, env.spaces.map(\.id), "A tab drop must not reorder the columns.")
    }

    func testDroppingATabOnItsOwnColumnChangesNothing() {
        let space = makeSpace(named: "Copy Guard Self Drop")
        let tabID = env.openTab(url: URL(string: "https://example.com/self-drop")!, in: space, activate: false)
        let before = env.todayTabs(in: space).map(\.id)

        _ = ManageSpacesDropAction.perform(
            ManageSpacesDragPayload(id: tabID, kind: .tab, originSpaceID: space),
            ontoSpace: space,
            currentOrder: env.spaces.map(\.id),
            in: env
        )

        XCTAssertEqual(env.todayTabs(in: space).map(\.id), before, "Dropping a tab on its own column changed that column.")
    }

    func testDraggingAColumnHeaderStillReordersTheSpaces() {
        let first = makeSpace(named: "Copy Guard Order A")
        let second = makeSpace(named: "Copy Guard Order B")

        let before = env.spaces.map(\.id)
        guard let fromIndex = before.firstIndex(of: second), let toIndex = before.firstIndex(of: first) else {
            return XCTFail("test precondition: both scratch Spaces must be in the store's order")
        }
        XCTAssertNotEqual(fromIndex, toIndex)

        let after = ManageSpacesDropAction.perform(
            ManageSpacesDragPayload(id: second, kind: .space, originSpaceID: second),
            ontoSpace: first,
            currentOrder: before,
            in: env
        )

        XCTAssertNotEqual(after, before, "Dragging a column header returned an unchanged order.")
        XCTAssertEqual(after.firstIndex(of: second), toIndex, "The dragged column did not land where it was dropped.")
        XCTAssertEqual(env.spaces.map(\.id), after, "The store's Space order does not match the reordered columns.")
    }

    func testClearOnTheTodayDividerEmptiesTodayAndLeavesPinnedAlone() {
        let space = makeSpace(named: "Copy Guard Clear")
        let pinnedTab = env.openTab(url: URL(string: "https://example.com/pinned")!, in: space, activate: false)
        env.pinTab(pinnedTab)
        _ = env.openTab(url: URL(string: "https://example.com/today-1")!, in: space, activate: false)
        _ = env.openTab(url: URL(string: "https://example.com/today-2")!, in: space, activate: false)

        let pinnedBefore = env.pinnedNodes(in: space).flatMap(\.allTabIDs)
        XCTAssertFalse(pinnedBefore.isEmpty, "test precondition: the column must have pinned tabs")
        XCTAssertFalse(env.todayTabs(in: space).isEmpty, "test precondition: the column must have Today tabs")

        env.clearTodayTabs(in: space)

        XCTAssertTrue(env.todayTabs(in: space).isEmpty, "Clear did not empty the column's Today section.")
        XCTAssertEqual(env.pinnedNodes(in: space).flatMap(\.allTabIDs), pinnedBefore, "Clear removed pinned tabs; it must only clear Today.")
    }

    /// Arc no longer clears tabs playing media (2022 release notes v0.74/0.75).
    func testClearSkipsATabPlayingMediaAndClearsEverythingElse() {
        let space = makeSpace(named: "Copy Guard Clear Media")
        let playing = env.openTab(url: URL(string: "https://example.com/video")!, in: space, activate: false)
        let silent = env.openTab(url: URL(string: "https://example.com/article")!, in: space, activate: false)

        env.store.setMediaState(MediaState(hasVideo: true, isPlaying: true), forTab: playing)

        env.clearTodayTabs(in: space)

        XCTAssertEqual(env.todayTabs(in: space).map(\.id), [playing],
                       "Clear must leave a tab that is playing media in Today, and take everything else.")
        XCTAssertEqual(env.tab(silent)?.section, .archived)

        env.store.setMediaState(MediaState(hasVideo: true, isPlaying: false), forTab: playing)
        env.clearTodayTabs(in: space)

        XCTAssertTrue(env.todayTabs(in: space).isEmpty, "Once the page stops playing, Clear must take the tab like any other.")
    }

    // MARK: - Helpers

    private func makeSpace(named name: String) -> SpaceID {
        let id = env.createSpace(
            name: name,
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: NewSpaceProfileDefault.resolve(in: env)
        )
        scratchSpaceIDs.append(id)
        return id
    }

    private static var productionSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit", isDirectory: true)
    }

    private func source(of relativePath: String) throws -> String {
        try String(contentsOf: Self.productionSourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func executableLines(of relativePath: String) throws -> [String] {
        try source(of: relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}
