import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ZenImportCoordinatorTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var fallbackSpaceID: SpaceID!
    private var existingSpaceIDs: Set<SpaceID> = []
    private var token = ""

    override func setUp() async throws {
        try await super.setUp()
        token = UUID().uuidString.prefix(8).lowercased()
        existingSpaceIDs = Set(env.store.spaces.map(\.id))
        fallbackSpaceID = env.store.createSpace(name: "Zen Fallback \(token)", activate: false)
    }

    override func tearDown() async throws {
        let created = env.store.spaces.map(\.id).filter { !existingSpaceIDs.contains($0) }
        for id in created { env.store.deleteSpace(id) }
        fallbackSpaceID = nil
        try await super.tearDown()
    }

    private func tab(
        _ url: String,
        _ title: String,
        _ kind: ZenTab.Kind,
        workspace: String?,
        folder: String? = nil
    ) -> ZenTab {
        ZenTab(
            url: URL(string: url)!,
            title: title,
            kind: kind,
            workspaceUUID: workspace,
            folderID: folder,
            lastAccessedAt: nil
        )
    }

    private func space(named name: String) -> Space? {
        env.store.spaces.first { $0.name == name }
    }

    func testWorkspacesBecomeSpacesWithTheirNameIconThemeAndProfile() throws {
        let zen = ZenStructure(
            workspaces: [
                ZenWorkspace(
                    uuid: "ws-1",
                    name: "Work \(token)",
                    emoji: "\u{1F4BC}",
                    theme: ZenWorkspaceTheme(
                        colors: [ZenColor(red: 1, green: 0, blue: 0), ZenColor(red: 0, green: 0, blue: 1)],
                        rotation: 45,
                        texture: 0.25
                    )
                ),
                ZenWorkspace(uuid: "ws-2", name: "Plain \(token)", emoji: nil, theme: nil),
            ],
            folders: [],
            tabs: []
        )

        let result = ZenImportCoordinator.apply(zen, fallbackSpaceID: fallbackSpaceID, env: env)
        XCTAssertEqual(result.spacesCreated, 2)

        let work = try XCTUnwrap(space(named: "Work \(token)"))
        XCTAssertEqual(work.icon, "\u{1F4BC}")
        XCTAssertTrue(work.iconIsEmoji)
        XCTAssertEqual(work.theme.style, .linear)
        XCTAssertEqual(work.theme.colors.count, 2)
        XCTAssertEqual(work.theme.colors[0].red, 1, accuracy: 0.001)
        XCTAssertEqual(work.theme.angle, 45, accuracy: 0.001)
        XCTAssertEqual(work.theme.grain, 0.25, accuracy: 0.001)
        XCTAssertEqual(work.profileID, env.store.space(fallbackSpaceID)?.profileID)

        let plain = try XCTUnwrap(space(named: "Plain \(token)"))
        XCTAssertFalse(plain.iconIsEmoji)
        XCTAssertEqual(plain.icon, "circle.grid.2x2")
    }

    func testPinnedEssentialAndOpenTabsLandInPinnedFavoritesAndToday() throws {
        let zen = ZenStructure(
            workspaces: [
                ZenWorkspace(uuid: "ws-1", name: "One \(token)", emoji: nil, theme: nil),
                ZenWorkspace(uuid: "ws-2", name: "Two \(token)", emoji: nil, theme: nil),
            ],
            folders: [
                ZenFolder(id: "outer", name: "Outer", parentID: nil, workspaceUUID: "ws-1", isCollapsed: false),
                ZenFolder(id: "inner", name: "Inner", parentID: "outer", workspaceUUID: "ws-1", isCollapsed: true),
            ],
            tabs: [
                tab("https://root.example.com/", "Root", .pinned, workspace: "ws-1"),
                tab("https://deep.example.com/", "Deep", .pinned, workspace: "ws-1", folder: "inner"),
                tab("https://other.example.com/", "Other", .pinned, workspace: "ws-2"),
                tab("https://mail.example.com/", "Mail", .essential, workspace: "ws-2"),
                tab("https://open-one.example.com/", "Open One", .open, workspace: "ws-1"),
                tab("https://open-two.example.com/", "Open Two", .open, workspace: "ws-2"),
            ]
        )

        let result = ZenImportCoordinator.apply(zen, fallbackSpaceID: fallbackSpaceID, env: env)
        XCTAssertEqual(result.pinnedTabsImported, 3)
        XCTAssertEqual(result.todayTabsImported, 2)
        XCTAssertEqual(result.favoritesImported, 1)
        XCTAssertEqual(result.foldersCreated, 2)

        let one = try XCTUnwrap(space(named: "One \(token)"))
        let two = try XCTUnwrap(space(named: "Two \(token)"))

        guard case .folder(let outer) = try XCTUnwrap(one.pinned.first) else {
            return XCTFail("Folders must come first in the pinned forest.")
        }
        XCTAssertEqual(outer.name, "Outer")
        XCTAssertTrue(outer.isExpanded)
        guard case .folder(let inner) = try XCTUnwrap(outer.children.first) else {
            return XCTFail("A nested Zen folder must nest in Orbit.")
        }
        XCTAssertEqual(inner.name, "Inner")
        XCTAssertFalse(inner.isExpanded)
        XCTAssertEqual(inner.allTabIDs.compactMap { env.state.tabs[$0]?.url.absoluteString }, ["https://deep.example.com/"])

        guard case .tab(let rootID) = try XCTUnwrap(one.pinned.last) else {
            return XCTFail("A loose pinned tab must stay at the top level.")
        }
        let rootTab = try XCTUnwrap(env.state.tabs[rootID])
        XCTAssertEqual(rootTab.section, .pinned)
        XCTAssertEqual(rootTab.pinnedURL, URL(string: "https://root.example.com/"))
        XCTAssertEqual(rootTab.spaceID, one.id)

        XCTAssertEqual(
            two.pinned.flatMap(\.allTabIDs).compactMap { env.state.tabs[$0]?.url.absoluteString },
            ["https://other.example.com/"]
        )
        XCTAssertEqual(one.today.compactMap { env.state.tabs[$0]?.url.absoluteString }, ["https://open-one.example.com/"])
        XCTAssertEqual(two.today.compactMap { env.state.tabs[$0]?.url.absoluteString }, ["https://open-two.example.com/"])
        XCTAssertEqual(env.state.tabs[try XCTUnwrap(one.today.first)]?.section, .today)

        let favoriteURLs = one.favorites.map(\.url.absoluteString)
        XCTAssertEqual(favoriteURLs.last, "https://mail.example.com/", "Essentials append after the favourites already there.")
        XCTAssertEqual(favoriteURLs.filter { $0 == "https://mail.example.com/" }.count, 1)

        let again = ZenImportCoordinator.apply(
            ZenStructure(workspaces: [], folders: [], tabs: [tab("https://mail.example.com/", "Mail", .essential, workspace: nil)]),
            fallbackSpaceID: one.id,
            env: env
        )
        XCTAssertEqual(again.favoritesImported, 0, "An essential already present as a favourite must not be added twice.")
    }

    func testTabsOfAnUnknownWorkspaceGoToTheFirstImportedSpace() throws {
        let zen = ZenStructure(
            workspaces: [ZenWorkspace(uuid: "ws-1", name: "Only \(token)", emoji: nil, theme: nil)],
            folders: [],
            tabs: [tab("https://stray.example.com/", "Stray", .open, workspace: "gone")]
        )

        _ = ZenImportCoordinator.apply(zen, fallbackSpaceID: fallbackSpaceID, env: env)
        let only = try XCTUnwrap(space(named: "Only \(token)"))
        XCTAssertEqual(only.today.compactMap { env.state.tabs[$0]?.url.absoluteString }, ["https://stray.example.com/"])
    }

    func testWithoutWorkspacesTheTabsGoToTheSpaceTheImportWasStartedFrom() throws {
        let before = env.store.spaces.count
        let zen = ZenStructure(
            workspaces: [],
            folders: [],
            tabs: [
                tab("https://pin.example.com/", "Pin", .pinned, workspace: nil),
                tab("https://open.example.com/", "Open", .open, workspace: nil),
            ]
        )

        let result = ZenImportCoordinator.apply(zen, fallbackSpaceID: fallbackSpaceID, env: env)
        XCTAssertEqual(result.spacesCreated, 0)
        XCTAssertEqual(env.store.spaces.count, before, "No workspace means no new Space.")

        let target = try XCTUnwrap(env.store.space(fallbackSpaceID))
        XCTAssertEqual(target.pinned.flatMap(\.allTabIDs).count, 1)
        XCTAssertEqual(target.today.count, 1)
    }

    func testAFolderParentCycleDoesNotLoseTheTabsInsideIt() throws {
        let zen = ZenStructure(
            workspaces: [ZenWorkspace(uuid: "ws-1", name: "Loop \(token)", emoji: nil, theme: nil)],
            folders: [
                ZenFolder(id: "a", name: "A", parentID: "b", workspaceUUID: nil, isCollapsed: true),
                ZenFolder(id: "b", name: "B", parentID: "a", workspaceUUID: nil, isCollapsed: true),
            ],
            tabs: [tab("https://loop.example.com/", "Loop", .pinned, workspace: "ws-1", folder: "a")]
        )

        let result = ZenImportCoordinator.apply(zen, fallbackSpaceID: fallbackSpaceID, env: env)
        XCTAssertEqual(result.pinnedTabsImported, 1)
        let loop = try XCTUnwrap(space(named: "Loop \(token)"))
        XCTAssertEqual(loop.pinned.flatMap(\.allTabIDs).count, 1)
    }

    func testTheSummaryLineReportsEveryZenCountAndZenImportsItsOwnStructure() {
        let summary = BrowserImportSummary(
            browser: .zen,
            foldersCreated: 1,
            bookmarksImported: 2,
            historyEntriesImported: 3,
            spacesCreated: 4,
            pinnedTabsImported: 5,
            todayTabsImported: 6,
            favoritesImported: 7
        )
        let line = OnboardingImportStep.zenSummaryLine(summary)
        XCTAssertTrue(line.contains("4 Spaces"), line)
        XCTAssertTrue(line.contains("5 pinned tabs"), line)
        XCTAssertTrue(line.contains("6 open tabs"), line)
        XCTAssertTrue(line.contains("7 favourites"), line)
        XCTAssertTrue(line.hasSuffix("from Zen Browser."), line)
        XCTAssertTrue(ImportableBrowser.zen.importsWorkspaces)
        XCTAssertFalse(ImportableBrowser.zen.importsNativeStructure)
    }
}
