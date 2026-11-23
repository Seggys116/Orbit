//  Back must keep working around a split: the page a pane was on before the split is still behind it, the pane's own
//  navigation after the split goes back one step, and separating the split changes none of it. Real pages in a real engine.

import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class SplitNavigationLiveTests: LiveEnvironmentTestCase {

    private var server: LiveHTTPTestServer!
    private var spaceID: SpaceID!

    override func setUpWithError() throws {
        try super.setUpWithError()
        func page(_ name: String) -> LiveHTTPTestServer.Route {
            .init(contentType: "text/html; charset=utf-8", body: "<!doctype html><title>\(name)</title><h1>\(name)</h1>")
        }
        server = try LiveHTTPTestServer(routes: ["/a": page("a"), "/b": page("b"), "/c": page("c"), "/d": page("d")])
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(name: "Split Back", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        env.selectSpace(spaceID)
    }

    override func tearDownWithError() throws {
        server.stop()
        server = nil
        try super.tearDownWithError()
    }

    private func url(_ path: String) -> URL { URL(string: path, relativeTo: server.baseURL)!.absoluteURL }

    private func pageURL(_ tab: TabID) -> URL? { (env.webContents[tab] as? WebKitWebContents)?.webView.url }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out: \(what)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func load(_ tab: TabID, _ path: String) async throws {
        env.loadInTab(tab, url: url(path))
        try await waitUntil("\(path) loaded in the tab") { self.pageURL(tab) == self.url(path) && self.env.navigationState(for: tab)?.isLoading == false }
    }

    private func back(from tab: TabID, expecting path: String) async throws {
        env.activateTab(tab)
        let list = (env.webContents[tab] as? WebKitWebContents)?.webView.backForwardList
        let history = "engine history: back \(list?.backList.map { $0.url.path } ?? []) current \(list?.currentItem?.url.path ?? "-"); app state url \(env.navigationState(for: tab)?.url?.path ?? "-")"
        XCTAssertEqual(env.navigationState(for: tab)?.canGoBack, true, "Back is not offered for the pane even though it has a page behind it. \(history)")
        XCTAssertTrue(env.perform(.goBack))
        try await waitUntil("back reached \(path)") { self.pageURL(tab) == self.url(path) && self.env.navigationState(for: tab)?.isLoading == false }
        XCTAssertEqual(env.navigationState(for: tab)?.url, url(path), "The address shown does not follow the page after Back.")
    }

    func test_backStillWorksForAPaneThatHadHistoryBeforeTheSplit() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let left = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntil("a loaded") { self.pageURL(left) == self.url("/a") && self.env.navigationState(for: left)?.isLoading == false }
            try await self.load(left, "/b")
            let right = self.env.openTab(url: self.url("/c"), in: self.spaceID, section: .today, activate: false)
            self.env.createSplit(existingTabID: left, newTabID: right, edge: .right)
            try await self.waitUntil("both panes loaded") { self.pageURL(left) == self.url("/b") && self.pageURL(right) == self.url("/c") && self.env.navigationState(for: left)?.isLoading == false && self.env.navigationState(for: right)?.isLoading == false }

            try await self.back(from: left, expecting: "/a")
            // the other pane still has its own page
            XCTAssertEqual(self.pageURL(right), self.url("/c"))
        }
    }

    func test_backWorksInAPaneAfterItNavigatesInsideTheSplit_andInTheOtherPaneToo() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let left = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntil("a loaded") { self.pageURL(left) == self.url("/a") && self.env.navigationState(for: left)?.isLoading == false }
            let right = self.env.openTab(url: self.url("/c"), in: self.spaceID, section: .today, activate: false)
            self.env.createSplit(existingTabID: left, newTabID: right, edge: .right)
            try await self.waitUntil("both panes loaded") { self.pageURL(left) == self.url("/a") && self.pageURL(right) == self.url("/c") && self.env.navigationState(for: left)?.isLoading == false && self.env.navigationState(for: right)?.isLoading == false }

            try await self.load(right, "/d")
            try await self.load(left, "/b")
            try await self.back(from: right, expecting: "/c")
            try await self.back(from: left, expecting: "/a")
            XCTAssertEqual(self.pageURL(right), self.url("/c"), "Going back in one pane moved the other")
            XCTAssertNotNil(self.env.splitGroup(for: left), "Going back dissolved the split")
        }
    }

    func test_backStillWorksAfterTheSplitIsSeparated() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let left = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntil("a loaded") { self.pageURL(left) == self.url("/a") && self.env.navigationState(for: left)?.isLoading == false }
            try await self.load(left, "/b")
            let right = self.env.openTab(url: self.url("/c"), in: self.spaceID, section: .today, activate: false)
            self.env.createSplit(existingTabID: left, newTabID: right, edge: .right)
            try await self.waitUntil("both panes loaded") { self.pageURL(left) == self.url("/b") && self.pageURL(right) == self.url("/c") && self.env.navigationState(for: left)?.isLoading == false && self.env.navigationState(for: right)?.isLoading == false }
            let group = try XCTUnwrap(self.env.splitGroup(for: left))

            self.env.separateAllTabs(group.id)
            try await Task.sleep(for: .milliseconds(300))

            try await self.back(from: left, expecting: "/a")
        }
    }

    // A pane whose page was released (a sleeping tab) is rebuilt when the split shows it: its history must come back with it.
    func test_aSleepingTabKeepsItsBackHistoryWhenItJoinsASplit() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let sleeper = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntil("a loaded") { self.pageURL(sleeper) == self.url("/a") && self.env.navigationState(for: sleeper)?.isLoading == false }
            try await self.load(sleeper, "/b")
            let other = self.env.openTab(url: self.url("/c"), in: self.spaceID)
            try await self.waitUntil("c loaded") { self.pageURL(other) == self.url("/c") && self.env.navigationState(for: other)?.isLoading == false }
            self.env.releaseWebContents(for: sleeper)
            XCTAssertNil(self.env.webContents[sleeper], "the tab is asleep")

            self.env.createSplit(existingTabID: other, newTabID: sleeper, edge: .right)
            try await self.waitUntil("the sleeping pane woke on /b") { self.pageURL(sleeper) == self.url("/b") && self.env.navigationState(for: sleeper)?.isLoading == false }

            try await self.back(from: sleeper, expecting: "/a")
        }
    }
}
