import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class PageZoomPersistenceTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var defaultsSuiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "OrbitAppTests-SiteZoom-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: defaultsSuiteName)
        SiteZoomStore.defaults = scratchDefaults
    }

    override func tearDown() {
        scratchDefaults.removePersistentDomain(forName: defaultsSuiteName)
        SiteZoomStore.defaults = .standard
        super.tearDown()
    }

    @discardableResult
    private func makeAttachedTab(url: String, spaceID: SpaceID? = nil) -> (TabID, MockWebContents) {
        let resolvedSpaceID = spaceID
            ?? env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Tab(spaceID: resolvedSpaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        let mock = MockWebContents()
        mock.navigationState = NavigationState(url: URL(string: url)!)
        env._test_attachWebContents(mock, for: tab.id)
        return (tab.id, mock)
    }

    private func detach(_ tabID: TabID) {
        env._test_detachWebContents(for: tabID)
        env.state.tabs.removeValue(forKey: tabID)
    }

    // MARK: - The write half

    func testZoomingAPagePersistsItAgainstTheHost() {
        let (tabID, mock) = makeAttachedTab(url: "https://example.com/article")
        defer { detach(tabID) }

        XCTAssertNil(SiteZoomStore.zoomFactor(forHost: "example.com"), "test precondition")

        env.webContents(mock, didChangeZoomFactor: 1.5)

        XCTAssertEqual(
            SiteZoomStore.zoomFactor(forHost: "example.com"),
            1.5,
            "A zoom change reported by the engine was not written to the per-host store, so it is lost on relaunch."
        )
    }

    func testZoomingAPageAlsoRecordsItOnTheTab() {
        let (tabID, mock) = makeAttachedTab(url: "https://example.com/article")
        defer { detach(tabID) }

        XCTAssertNil(env.store.tab(tabID)?.zoomFactor, "test precondition")

        env.webContents(mock, didChangeZoomFactor: 1.25)

        XCTAssertEqual(
            env.store.tab(tabID)?.zoomFactor,
            1.25,
            "Tab.zoomFactor is encoded into state.json, copied by duplicateTab and mapped by the sync layer — it must carry the tab's real zoom, not nil forever."
        )
    }

    func testThePerHostLevelSurvivesAReadBackFromTheDefaultsDomain() {
        let (tabID, mock) = makeAttachedTab(url: "https://news.ycombinator.com/")
        defer { detach(tabID) }

        env.webContents(mock, didChangeZoomFactor: 2.0)

        let reread = UserDefaults(suiteName: defaultsSuiteName)!
            .dictionary(forKey: SiteZoomStore.defaultsKey)?["news.ycombinator.com"] as? Double
        XCTAssertEqual(reread, 2.0, "The level never reached the preferences domain, so a relaunch would not find it.")
    }

    // MARK: - The restore half

    func testAFreshTabOnAZoomedHostComesUpAtThatHostsZoom() {
        let (firstTabID, firstMock) = makeAttachedTab(url: "https://example.com/one")
        defer { detach(firstTabID) }
        env.webContents(firstMock, didChangeZoomFactor: 1.75)

        let (secondTabID, secondMock) = makeAttachedTab(url: "https://example.com/two")
        defer { detach(secondTabID) }
        XCTAssertEqual(secondMock.zoomFactor, 1.0, "test precondition: a fresh WebContents starts unzoomed")

        env.applyStoredZoomFactor(to: secondMock, tabID: secondTabID, url: URL(string: "https://example.com/two")!)

        XCTAssertEqual(secondMock.zoomFactor, 1.75, "A new tab on an already-zoomed host did not pick the host's level up.")
    }

    func testATabOnAnUnzoomedHostIsRestoredToTheBaselineRatherThanLeftAlone() {
        let (zoomedTabID, zoomedMock) = makeAttachedTab(url: "https://example.com/one")
        defer { detach(zoomedTabID) }
        env.webContents(zoomedMock, didChangeZoomFactor: 1.5)

        env.applyStoredZoomFactor(to: zoomedMock, tabID: zoomedTabID, url: URL(string: "https://other.example.org/")!)

        XCTAssertEqual(zoomedMock.zoomFactor, 1.0, "A page on an unzoomed host inherited the previous site's zoom.")
    }

    func testResettingToOneHundredPercentRemovesTheHostEntryEntirely() {
        let (tabID, mock) = makeAttachedTab(url: "https://example.com/")
        defer { detach(tabID) }

        env.webContents(mock, didChangeZoomFactor: 1.5)
        XCTAssertNotNil(SiteZoomStore.zoomFactor(forHost: "example.com"), "test precondition")

        env.webContents(mock, didChangeZoomFactor: 1.0)

        XCTAssertNil(
            SiteZoomStore.zoomFactor(forHost: "example.com"),
            "A host reset to 100% must carry no entry, so \"reset\" and \"never zoomed\" are the same stored state."
        )
        XCTAssertNil(env.store.tab(tabID)?.zoomFactor, "The tab's own record must clear too, not keep a stale 1.5.")
    }

    // MARK: - Hosts, and URLs that have none

    func testHostsAreKeptDistinctFromEachOther() {
        let (firstID, firstMock) = makeAttachedTab(url: "https://example.com/")
        defer { detach(firstID) }
        let (secondID, secondMock) = makeAttachedTab(url: "https://www.example.com/")
        defer { detach(secondID) }

        env.webContents(firstMock, didChangeZoomFactor: 1.5)
        env.webContents(secondMock, didChangeZoomFactor: 2.0)

        XCTAssertEqual(SiteZoomStore.zoomFactor(forHost: "example.com"), 1.5)
        XCTAssertEqual(
            SiteZoomStore.zoomFactor(forHost: "www.example.com"),
            2.0,
            "`www.` must not be folded away — Chromium's own map, which Arc's profile carries, keys www.kongregate.com in full."
        )
    }

    func testAnOrbitSchemeURLFallsBackToTheTabsOwnRecord() {
        let noteURL = "orbit://note/\(UUID().uuidString)"
        let (tabID, mock) = makeAttachedTab(url: noteURL)
        defer { detach(tabID) }

        env.webContents(mock, didChangeZoomFactor: 1.25)

        XCTAssertTrue(
            SiteZoomStore.allZoomFactors().isEmpty,
            "A URL with no host must not invent a key in the per-host store."
        )
        XCTAssertEqual(env.store.tab(tabID)?.zoomFactor, 1.25, "The tab's own record is the only place a hostless URL can be remembered.")

        let restored = MockWebContents()
        env.applyStoredZoomFactor(to: restored, tabID: tabID, url: URL(string: noteURL)!)
        XCTAssertEqual(restored.zoomFactor, 1.25)
    }

    // MARK: - Incognito

    func testAnIncognitoSpaceLeavesNothingBehindOnDisk() {
        let profileID = env.createDefaultProfileIfNeeded()
        let incognito = Space(name: "Incognito", profileID: profileID, isEphemeral: true)
        env.state.spaces.append(incognito)
        XCTAssertTrue(env.isIncognito(incognito), "test precondition")

        let (tabID, mock) = makeAttachedTab(url: "https://private.example.com/", spaceID: incognito.id)
        defer { detach(tabID) }

        env.webContents(mock, didChangeZoomFactor: 1.5)

        XCTAssertTrue(
            SiteZoomStore.allZoomFactors().isEmpty,
            "A per-host zoom level written from a private session is a record that the site was visited."
        )
        XCTAssertNil(env.store.tab(tabID)?.zoomFactor, "An Incognito tab must not carry a zoom into the persisted document either.")
    }

    // MARK: - What already read Tab.zoomFactor

    func testDuplicatingATabCarriesItsZoomAcross() {
        let (tabID, mock) = makeAttachedTab(url: "https://example.com/")
        defer { detach(tabID) }
        env.webContents(mock, didChangeZoomFactor: 1.5)

        let copyID = try! XCTUnwrap(env.store.duplicateTab(tabID))
        XCTAssertEqual(env.store.tab(copyID)?.zoomFactor, 1.5, "duplicateTab copies zoomFactor; it must now have something to copy.")
    }

    // MARK: - The store on its own

    func testTheStoreClampsAnOutOfRangeLevelToTheZoomLadder() {
        SiteZoomStore.setZoomFactor(99, forHost: "example.com")
        XCTAssertEqual(SiteZoomStore.zoomFactor(forHost: "example.com"), ZoomStep.p500.rawValue)

        SiteZoomStore.setZoomFactor(0.001, forHost: "example.com")
        XCTAssertEqual(SiteZoomStore.zoomFactor(forHost: "example.com"), ZoomStep.p25.rawValue)
    }

    func testTheStoreIsCaseInsensitiveAboutHosts() {
        SiteZoomStore.setZoomFactor(1.5, forHost: "Example.COM")
        XCTAssertEqual(SiteZoomStore.zoomFactor(forHost: "example.com"), 1.5)
        XCTAssertEqual(SiteZoomStore.hostKey(for: URL(string: "https://EXAMPLE.com/x")!), "example.com")
    }

    func testOnlyWebSchemesGetAHostKey() {
        XCTAssertEqual(SiteZoomStore.hostKey(for: URL(string: "https://example.com/a")!), "example.com")
        XCTAssertEqual(SiteZoomStore.hostKey(for: URL(string: "http://example.com/a")!), "example.com")

        XCTAssertNil(SiteZoomStore.hostKey(for: URL(string: "about:blank")!))
        XCTAssertNil(SiteZoomStore.hostKey(for: URL(string: "file:///tmp/x.html")!))
        XCTAssertNil(
            SiteZoomStore.hostKey(for: URL(string: "orbit://note/\(UUID().uuidString)")!),
            "URL.host() returns \"note\" here — filing on it would give every note in the app one shared zoom level."
        )
        XCTAssertNil(SiteZoomStore.hostKey(for: URL(string: "orbit://easel/\(UUID().uuidString)")!))
    }
}
