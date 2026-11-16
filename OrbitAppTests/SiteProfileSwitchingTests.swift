//  Site Profiles: switching replaces the tab's web view (it owns the data store) but keeps the tab's identity.

import XCTest
@testable import Orbit

@MainActor
final class SiteProfileSwitchingTests: XCTestCase {

    private var env: AppEnvironment!
    private var spaceID: SpaceID!
    private var profileID: ProfileID!
    private var created: [MockWebContents] = []

    private let githubURL = URL(string: "https://github.com/orbit/pulls")!

    override func setUp() {
        super.setUp()
        env = AppEnvironment.demo
        created = []
        env._test_webContentsFactory = { [unowned self] _, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            self.created.append(contents)
            return contents
        }
        profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Site Profiles Scratch", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID
        )
        env.selectSpace(spaceID)
    }

    override func tearDown() {
        env = nil
        spaceID = nil
        profileID = nil
        created = []
        super.tearDown()
    }

    // Creation times are pinned so "oldest first" never depends on two Date() calls differing.
    private func makeProfile(_ name: String = "Work") throws -> SiteProfile {
        let profile = try XCTUnwrap(env.createSiteProfile(name: name, for: githubURL))
        let index = try XCTUnwrap(env.state.siteProfiles.firstIndex { $0.id == profile.id })
        env.state.siteProfiles[index].createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        return try XCTUnwrap(env.store.siteProfile(profile.id))
    }

    private func menu(for tabID: TabID) -> ToolbarContextMenu {
        let settings = ToolbarSettings(defaults: UserDefaults(suiteName: "OrbitAppTests-SiteProfiles-\(UUID().uuidString)")!)
        return ToolbarContextMenu(tab: env.tab(tabID)!, settings: settings, developerModeSettings: DeveloperModeSettings.shared)
    }

    // MARK: - Switching

    func testSwitchingReleasesTheOldContentsAndMaterializesOnTheSiteProfile() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        let original = try XCTUnwrap(created.last)
        let work = try makeProfile()
        env._test_materializations = []

        env.switchSiteProfile(tabID: tabID, to: work.id)

        XCTAssertTrue(original.isClosed, "The old web view holds the old data store and must go.")
        let replacement = try XCTUnwrap(env.webContents[tabID] as? MockWebContents)
        XCTAssertFalse(replacement === original)
        XCTAssertEqual(env._test_materializations.count, 1)
        XCTAssertEqual(env._test_materializations.first?.tabID, tabID)
        XCTAssertEqual(env._test_materializations.first?.siteProfileID, work.id, "The new web view must be built on the site profile's session.")
        XCTAssertEqual(env.tab(tabID)?.siteProfileID, work.id)
        XCTAssertEqual(env.tab(tabID)?.isUnloaded, false)
    }

    func testSwitchingBackToDefaultUsesTheSpacesOwnSession() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        let work = try makeProfile()
        env.switchSiteProfile(tabID: tabID, to: work.id)
        env._test_materializations = []

        env.switchSiteProfile(tabID: tabID, to: nil)

        XCTAssertEqual(env._test_materializations.count, 1)
        XCTAssertNil(env._test_materializations.first?.siteProfileID)
        XCTAssertNil(env.tab(tabID)?.siteProfileID)
    }

    func testSwitchingToTheProfileAlreadyInUseDoesNothing() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        let work = try makeProfile()
        env.switchSiteProfile(tabID: tabID, to: work.id)
        let contents = try XCTUnwrap(env.webContents[tabID])
        env._test_materializations = []

        env.switchSiteProfile(tabID: tabID, to: work.id)

        XCTAssertTrue(env.webContents[tabID] === contents)
        XCTAssertTrue(env._test_materializations.isEmpty)
    }

    func testTheReloadedPageIsTheOneTheTabWasShowing() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        let work = try makeProfile()
        let navigated = URL(string: "https://github.com/orbit/issues/7")!
        (env.webContents[tabID] as? MockWebContents)?.navigationState.url = navigated
        var loadedURLs: [URL] = []
        env._test_webContentsFactory = { _, url in
            loadedURLs.append(url)
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }

        env.switchSiteProfile(tabID: tabID, to: work.id)

        XCTAssertEqual(loadedURLs, [navigated], "The profile switch must reopen the page the user was on, not the tab's first URL.")
    }

    func testATabWithNoLiveContentsIsOnlyRebound() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        env.releaseWebContents(for: tabID)
        let work = try makeProfile()
        env._test_materializations = []

        env.switchSiteProfile(tabID: tabID, to: work.id)

        XCTAssertEqual(env.tab(tabID)?.siteProfileID, work.id)
        XCTAssertNil(env.webContents[tabID], "A suspended tab stays suspended; it will open on the profile when it is next shown.")
        XCTAssertTrue(env._test_materializations.isEmpty)

        env.materializeWebContents(for: tabID, url: githubURL)
        XCTAssertEqual(env._test_materializations.last?.siteProfileID, work.id)
    }

    func testAPinnedTabKeepsItsBookmarkPositionAndSelection() throws {
        let todayID = env.openTab(url: URL(string: "https://today.example.com")!, in: spaceID)
        let pinnedID = env.openTab(url: githubURL, in: spaceID, section: .pinned)
        env.activateTab(pinnedID)
        let work = try makeProfile()
        let pinnedBefore = try XCTUnwrap(env.tab(pinnedID))
        let pinnedOrderBefore = env.store.pinnedNodes(in: spaceID).flatMap(\.allTabIDs)

        env.switchSiteProfile(tabID: pinnedID, to: work.id)

        let after = try XCTUnwrap(env.tab(pinnedID))
        XCTAssertEqual(after.section, .pinned)
        XCTAssertEqual(after.pinnedURL, pinnedBefore.pinnedURL)
        XCTAssertEqual(env.store.pinnedNodes(in: spaceID).flatMap(\.allTabIDs), pinnedOrderBefore)
        XCTAssertEqual(env.activeTabID, pinnedID, "The selection must not move.")
        XCTAssertNotNil(env.webContents[pinnedID])
        XCTAssertNil(env.tab(todayID)?.siteProfileID, "Other tabs of the same site stay on Default.")
    }

    func testAFavoriteBackedTabCanBeSwitched() throws {
        env.store.addFavorite(url: githubURL, title: "GitHub", in: spaceID)
        let favorite = try XCTUnwrap(env.store.favorite(matching: githubURL, in: spaceID))
        env.activateFavorite(favorite, in: spaceID)
        let tabID = try XCTUnwrap(env.store.favorite(favorite.id, in: spaceID)?.liveTabID)
        let contents = try XCTUnwrap(env.webContents[tabID])
        let work = try makeProfile()

        env.switchSiteProfile(tabID: tabID, to: work.id)

        XCTAssertEqual(env.tab(tabID)?.siteProfileID, work.id)
        XCTAssertEqual(env.store.favorite(favorite.id, in: spaceID)?.liveTabID, tabID, "The favourite keeps pointing at the same tab.")
        XCTAssertFalse(env.webContents[tabID] === contents)
        XCTAssertNotNil(env.webContents[tabID])
    }

    func testAnIncognitoTabCannotBeSwitchedOntoASiteProfile() throws {
        let incognitoProfile = env.store.createProfile(name: "Incognito", isPersistent: false)
        let incognitoSpace = env.createSpace(
            name: "Incognito Scratch", icon: "eyeglasses", iconIsEmoji: false, theme: SpaceTheme(), profileID: incognitoProfile
        )
        let tabID = env.openTab(url: githubURL, in: incognitoSpace)
        let contents = try XCTUnwrap(env.webContents[tabID])
        let work = try makeProfile()

        env.switchSiteProfile(tabID: tabID, to: work.id)

        XCTAssertNil(env.tab(tabID)?.siteProfileID)
        XCTAssertTrue(env.webContents[tabID] === contents, "A refused switch must leave the private tab's web view alone.")
    }

    // MARK: - Page-created tabs

    func testContentsBuiltOnASiteSessionBindTheirTab() throws {
        let work = try makeProfile()
        let tab = Tab(spaceID: spaceID, section: .today, url: githubURL)
        env.state.tabs[tab.id] = tab
        env._test_webContentsFactory = { _, url in
            let contents = MockWebContents(session: MockEngineSession(identifier: work.sessionIdentifier, isPersistent: true))
            contents.navigationState = NavigationState(url: url)
            return contents
        }

        env.materializeWebContents(for: tab.id, url: githubURL)

        XCTAssertEqual(env.tab(tab.id)?.siteProfileID, work.id, "A popup opened from a profiled tab is built on that tab's data store and must stay on it.")
    }

    func testANewTabForTheSameSiteInheritsTheOpenersProfileButOtherSitesDoNot() throws {
        let work = try makeProfile()
        let opener = env.openTab(url: githubURL, in: spaceID)
        env.switchSiteProfile(tabID: opener, to: work.id)
        let before = Set(env.state.tabs.keys)
        env._test_materializations = []

        let sameSite = NewContentRequest(url: URL(string: "https://gist.github.com/x")!, disposition: .newBackgroundTab, isUserGesture: true)
        let otherSite = NewContentRequest(url: URL(string: "https://example.org/")!, disposition: .newBackgroundTab, isUserGesture: true)
        let openerContents = try XCTUnwrap(env.webContents[opener])
        XCTAssertTrue(env.webContents(openerContents, requestsNewContent: sameSite))
        XCTAssertTrue(env.webContents(openerContents, requestsNewContent: otherSite))

        let opened = env.state.tabs.values.filter { !before.contains($0.id) }
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened.first { $0.url.host() == "gist.github.com" }?.siteProfileID, work.id)
        XCTAssertNil(opened.first { $0.url.host() == "example.org" }?.siteProfileID, "A link to another site must never carry the opener's login identity.")
    }

    // MARK: - Deleting

    func testDeletingAProfileMovesItsLiveTabsToDefaultAndRemovesIt() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        let otherTabID = env.openTab(url: githubURL, in: spaceID)
        let keep = try makeProfile("Personal")
        let work = try makeProfile()
        env.switchSiteProfile(tabID: tabID, to: work.id)
        env.switchSiteProfile(tabID: otherTabID, to: keep.id)
        let boundContents = try XCTUnwrap(env.webContents[tabID] as? MockWebContents)
        env._test_materializations = []

        env.deleteSiteProfile(work.id)

        XCTAssertTrue(boundContents.isClosed)
        XCTAssertNil(env.store.siteProfile(work.id))
        XCTAssertNil(env.tab(tabID)?.siteProfileID)
        XCTAssertNotNil(env.webContents[tabID])
        XCTAssertEqual(env._test_materializations.count, 1)
        XCTAssertNil(env._test_materializations.first?.siteProfileID)
        XCTAssertEqual(env.tab(otherTabID)?.siteProfileID, keep.id, "Another profile's tabs are untouched.")
        XCTAssertNotNil(env.store.siteProfile(keep.id))
    }

    func testConfirmedDeletionRemovesTheProfile() throws {
        let work = try makeProfile()

        env.confirmDeleteSiteProfile(work.id)

        XCTAssertNil(env.store.siteProfile(work.id))
    }

    // MARK: - Right-click menu

    func testRightClickOffersMakeProfiledPageUntilTheSiteHasAProfile() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)

        var entries = menu(for: tabID).entries(in: env)
        XCTAssertNotNil(entries.first(titled: ToolbarContextMenu.makeProfiledPageTitle))
        XCTAssertNil(entries.first(titled: ToolbarContextMenu.newProfileTitle(forSite: "github.com")))
        XCTAssertNil(entries.first(titled: ToolbarContextMenu.switchProfileTitle))

        _ = try makeProfile()

        entries = menu(for: tabID).entries(in: env)
        XCTAssertNil(entries.first(titled: ToolbarContextMenu.makeProfiledPageTitle))
        XCTAssertNotNil(entries.first(titled: ToolbarContextMenu.newProfileTitle(forSite: "github.com")))
        XCTAssertNotNil(entries.first(titled: ToolbarContextMenu.switchProfileTitle))
    }

    func testRightClickOffersNoProfileEntriesOnInternalPages() {
        let tabID = env.openTab(url: URL(string: "orbit://new-tab")!, in: spaceID)

        let entries = menu(for: tabID).entries(in: env)

        XCTAssertNil(entries.first(titled: ToolbarContextMenu.makeProfiledPageTitle))
        XCTAssertNil(entries.first(titled: ToolbarContextMenu.switchProfileTitle))
        XCTAssertFalse(entries.flattenedItems.contains { $0.title.hasPrefix("New Profile") })
    }

    func testRightClickOffersNoProfileEntriesInAnIncognitoSpace() throws {
        let incognitoProfile = env.store.createProfile(name: "Incognito", isPersistent: false)
        let incognitoSpace = env.createSpace(
            name: "Incognito Scratch", icon: "eyeglasses", iconIsEmoji: false, theme: SpaceTheme(), profileID: incognitoProfile
        )
        let tabID = env.openTab(url: githubURL, in: incognitoSpace)
        _ = try makeProfile()

        let entries = menu(for: tabID).entries(in: env)

        XCTAssertNil(entries.first(titled: ToolbarContextMenu.makeProfiledPageTitle))
        XCTAssertNil(entries.first(titled: ToolbarContextMenu.switchProfileTitle))
        XCTAssertFalse(entries.flattenedItems.contains { $0.title.hasPrefix("New Profile") })
        XCTAssertTrue(ToolbarContextMenu.siteProfileDropdownEntries(forTab: tabID, in: env).isEmpty)
    }

    func testTheOrdinaryRightClickEntriesAreStillThere() {
        let tabID = env.openTab(url: githubURL, in: spaceID)

        let entries = menu(for: tabID).entries(in: env)

        for title in ["Copy URL", "Share", "Capture...", "Capture Full Page"] {
            XCTAssertNotNil(entries.first(titled: title), "\(title) must survive the new group.")
        }
    }

    // MARK: - Address-field dropdown

    func testNoDropdownBeforeTheSiteHasAProfile() {
        let tabID = env.openTab(url: githubURL, in: spaceID)

        XCTAssertTrue(ToolbarContextMenu.siteProfileDropdownEntries(forTab: tabID, in: env).isEmpty)
    }

    func testDropdownOnDefaultListsProfilesWithoutRenameOrDelete() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        _ = try makeProfile("Work")
        _ = try makeProfile("Personal")

        let entries = ToolbarContextMenu.siteProfileDropdownEntries(forTab: tabID, in: env)
        let titles = entries.flattenedItems.map(\.title)

        XCTAssertEqual(titles, ["Default", "Work", "Personal", "New Profile..."])
        XCTAssertEqual(entries.first(titled: "Default")?.isChecked, true)
        XCTAssertEqual(entries.first(titled: "Work")?.isChecked, false)
        XCTAssertNil(entries.first(titled: "Rename Profile..."))
        XCTAssertNil(entries.first(titled: "Delete Profile"))
        XCTAssertTrue(entries.flattenedItems.allSatisfy { $0.systemImage == nil }, "Names only, no icons.")
    }

    func testDropdownOnAProfileChecksItAndOffersRenameAndDelete() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        let work = try makeProfile("Work")
        env.switchSiteProfile(tabID: tabID, to: work.id)

        let entries = ToolbarContextMenu.siteProfileDropdownEntries(forTab: tabID, in: env)

        XCTAssertEqual(entries.first(titled: "Work")?.isChecked, true)
        XCTAssertEqual(entries.first(titled: "Default")?.isChecked, false)
        XCTAssertNotNil(entries.first(titled: "Rename Profile..."))
        XCTAssertEqual(entries.first(titled: "Delete Profile")?.isDestructive, true)
    }

    func testPickingFromTheDropdownSwitchesTheTab() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        let work = try makeProfile("Work")

        ToolbarContextMenu.siteProfileDropdownEntries(forTab: tabID, in: env).first(titled: "Work")?.action?()
        XCTAssertEqual(env.tab(tabID)?.siteProfileID, work.id)

        ToolbarContextMenu.siteProfileDropdownEntries(forTab: tabID, in: env).first(titled: "Default")?.action?()
        XCTAssertNil(env.tab(tabID)?.siteProfileID)
    }

    func testDropdownFollowsABoundTabToAnotherSiteForASignInRedirect() throws {
        let tabID = env.openTab(url: githubURL, in: spaceID)
        let work = try makeProfile("Work")
        env.switchSiteProfile(tabID: tabID, to: work.id)

        env.state.tabs[tabID]?.url = URL(string: "https://accounts.example.org/login")!

        let titles = ToolbarContextMenu.siteProfileDropdownEntries(forTab: tabID, in: env).flattenedItems.map(\.title)
        XCTAssertEqual(titles.prefix(2), ["Default", "Work"])
    }

    // MARK: - Layout

    func testTheDropdownYieldsToTheURLInANarrowPane() {
        XCTAssertTrue(OrbitToolbarMetrics.fitsSiteProfileDropdown(regionWidth: 600, sideReserve: 70))
        XCTAssertFalse(OrbitToolbarMetrics.fitsSiteProfileDropdown(regionWidth: 300, sideReserve: 70))
    }
}
