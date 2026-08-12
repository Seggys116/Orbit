import Foundation
import XCTest
@testable import Orbit

@MainActor
final class AppEnvironmentWebContentsDelegateTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func makeAttachedTab(url: String = "https://www.google.com") -> (TabID, MockWebContents) {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab

        let mock = MockWebContents()
        XCTAssertNotEqual(mock.id, tab.id)
        env._test_attachWebContents(mock, for: tab.id)
        return (tab.id, mock)
    }

    private func detach(_ tabID: TabID) {
        env._test_detachWebContents(for: tabID)
        env.state.tabs.removeValue(forKey: tabID)
    }

    // MARK: - tabID(for:) itself

    func testTabIDForResolvesTheAttachedTabsRealID() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }
        XCTAssertEqual(env.tabID(for: mock), tabID)
    }

    func testTabIDForIsNilForUnattachedContents() {
        let stray = MockWebContents()
        XCTAssertNil(env.tabID(for: stray), "A WebContents that was never attached to any tab must not resolve to one.")
    }

    // MARK: - D5: title

    func testDidChangeTitlePersistsToTheStore() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }

        XCTAssertEqual(env.store.tab(tabID)?.title, "", "test precondition")

        env.webContents(mock, didChangeTitle: "Google")

        XCTAssertEqual(env.store.tab(tabID)?.title, "Google", "didChangeTitle did not persist to BrowserStore (D5).")
        XCTAssertEqual(env.tab(tabID)?.displayTitle, "Google", "displayTitle should show the real title, not fall back to the host, once it's set.")
    }

    func testDisplayTitleFallsBackToHostWhenTitleNeverArrives() {
        let (tabID, _) = makeAttachedTab(url: "https://www.google.com")
        defer { detach(tabID) }
        XCTAssertEqual(env.tab(tabID)?.displayTitle, "www.google.com")
    }

    // MARK: - Favicon / URL (D5's "also confirm the favicon and URL updates")

    func testDidChangeFaviconPersistsURLToTheStore() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }
        let faviconURL = URL(string: "https://www.google.com/favicon.ico")!

        env.webContents(mock, didChangeFavicon: nil, url: faviconURL)

        XCTAssertEqual(env.store.tab(tabID)?.faviconURL, faviconURL, "didChangeFavicon did not persist faviconURL to BrowserStore.")
    }

    func testNavigationStateChangeUpdatesURLInTheStore() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }
        let newURL = URL(string: "https://www.google.com/search?q=orbit")!
        mock.navigationState = NavigationState(url: newURL, title: "", isLoading: true)

        env.webContentsDidChangeNavigationState(mock)

        XCTAssertEqual(env.store.tab(tabID)?.url, newURL, "webContentsDidChangeNavigationState did not persist the new URL to BrowserStore.")
    }

    // MARK: - D4 (enabled by the same fix): reactive navigationState mirror

    func testNavigationStateChangeUpdatesTheReactiveMirrorUnderTheRealTabID() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }

        mock.navigationState = NavigationState(url: mock.navigationState.url, title: "", isLoading: true)
        env.webContentsDidChangeNavigationState(mock)
        XCTAssertEqual(env.navigationStates[tabID]?.isLoading, true, "Loading state never reached env.navigationStates[tabID] — this is D4's stuck stop/reload icon.")

        mock.navigationState.isLoading = false
        env.webContentsDidChangeNavigationState(mock)
        XCTAssertEqual(env.navigationStates[tabID]?.isLoading, false, "Loading state did not clear in env.navigationStates[tabID] once the load finished.")
    }

    // MARK: - Crash / responsiveness (same identity bug, different symptom)

    func testCrashIsRecordedAgainstTheRealTabID() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }
        env.webContentsDidCrash(mock)
        XCTAssertTrue(env.crashedTabs.contains(tabID))
    }

    func testRequestCloseArchivesTheRealTabAndReleasesItsWebContents() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }

        env.webContentsDidRequestClose(mock)

        XCTAssertEqual(env.store.tab(tabID)?.section, .archived, "webContentsDidRequestClose did not archive the real tab.")
        XCTAssertNil(env.webContents[tabID], "webContentsDidRequestClose did not release the tab's WebContents.")
    }

    // MARK: - The page's live colour, and the opacity gate on it

    func testDidChangeThemeColorTracksThePagesLatestColour() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }

        env.webContents(mock, didChangeThemeColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(env.themeColors[tabID]?.red ?? -1, 1.0, accuracy: 0.01)

        env.webContents(mock, didChangeThemeColor: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1))
        XCTAssertEqual(
            env.themeColors[tabID]?.red ?? -1, 0.05, accuracy: 0.01,
            "A second report must replace the first: the colour is a live signal, not a first answer that sticks."
        )

        env.webContents(mock, didChangeThemeColor: nil)
        XCTAssertNil(
            env.themeColors[tabID],
            "nil is a real answer — the pane must fall back to its neutral rather than keeping a colour the page no longer has."
        )
    }

    func testDidChangeThemeColorRejectsAColourTooTransparentToBeOne() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }

        env.webContents(mock, didChangeThemeColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertNotNil(env.themeColors[tabID], "Test precondition: an opaque colour is accepted.")

        env.webContents(mock, didChangeThemeColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.02))
        XCTAssertNil(
            env.themeColors[tabID],
            "A 2%-opaque white is not a colour: painted it is whatever is behind it, but ThemeColor.luminance would read it as near-white and pick dark glyphs for a dark bar."
        )
    }

    func testDidChangeThemeColorKeepsAMeaningfullyTranslucentColour() {
        let (tabID, mock) = makeAttachedTab()
        defer { detach(tabID) }

        env.webContents(mock, didChangeThemeColor: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.5))

        XCTAssertEqual(env.themeColors[tabID]?.alpha ?? -1, 0.5, accuracy: 0.01, "Only barely-there colours are rejected; the rest keep their alpha for the consumer to composite.")
        XCTAssertEqual(env.themeColors[tabID]?.blue ?? -1, 0.8, accuracy: 0.01)
    }
}
