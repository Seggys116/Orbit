//  The address the toolbar shows must be the address of the page on screen after every kind of navigation, so Back
//  always goes one step. Each step compares what the app reports with what WebKit is actually showing.

import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class NavigationURLTrackingLiveTests: LiveEnvironmentTestCase {

    private var server: LiveHTTPTestServer!
    private var spaceID: SpaceID!

    override func setUpWithError() throws {
        try super.setUpWithError()
        func page(_ name: String, extra: String = "") -> LiveHTTPTestServer.Route {
            .init(contentType: "text/html; charset=utf-8", body: "<!doctype html><title>\(name)</title><h1>\(name)</h1>\(extra)")
        }
        server = try LiveHTTPTestServer(
            routes: [
                "/a": page("a"), "/b": page("b"), "/c": page("c"),
                "/spa": page("spa", extra: "<script>function go(p){history.pushState({}, '', p)}</script>"),
                // Commits, then never finishes: its image never answers, as a hanging tracker does on a real site.
                "/spa-hang": page("spa-hang", extra: "<img src=\"/slow\"><script>function go(p){history.pushState({}, '', p)}</script>"),
                "/redirect": .init(contentType: "text/html", body: "<!doctype html><script>location.replace('/b')</script>"),
            ],
            stallingRoutes: ["/slow"]
        )
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(name: "Nav", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        env.selectSpace(spaceID)
    }

    override func tearDownWithError() throws {
        server.stop()
        server = nil
        try super.tearDownWithError()
    }

    private func url(_ path: String) -> URL { URL(string: path, relativeTo: server.baseURL)!.absoluteURL }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                let lists = env.webContents.values.compactMap { ($0 as? WebKitWebContents)?.webView.backForwardList }
                let history = lists.map { list in
                    "back \(list.backList.map { $0.url.path }) current \(list.currentItem?.url.path ?? "-") forward \(list.forwardList.map { $0.url.path })"
                }
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out: \(what); \(history)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func historySummary(_ contents: WebKitWebContents) -> String {
        let list = contents.webView.backForwardList
        return "back \(list.backList.map { $0.url.path }) current \(list.currentItem?.url.path ?? "-") forward \(list.forwardList.map { $0.url.path })"
    }

    /// A Back that is still committing swallows the next one, as it would for a user clicking faster than the page can answer.
    private func waitForQuiet(_ tab: TabID) async throws {
        try await waitUntil("navigation finished") { self.env.navigationState(for: tab)?.isLoading == false }
        try await Task.sleep(for: .milliseconds(150))
    }

    /// What the toolbar reads for the tab, and what the page is really at.
    private func shown(_ tabID: TabID) -> (app: URL?, page: URL?) {
        (env.navigationState(for: tabID)?.url, (env.webContents[tabID] as? WebKitWebContents)?.webView.url)
    }

    private func assertAgree(_ tabID: TabID, _ step: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("\(step): toolbar address follows the page") { shown(tabID).app == shown(tabID).page }
        let now = shown(tabID)
        XCTAssertEqual(now.app, now.page, "\(step): the toolbar shows a different address than the page", file: file, line: line)
    }

    func testAddressFollowsEveryKindOfNavigationAndBackGoesOneStep() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let tab = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntil("first load") { self.shown(tab).page == self.url("/a") && self.env.navigationState(for: tab)?.isLoading == false }
            let contents = try XCTUnwrap(self.env.webContents[tab] as? WebKitWebContents)

            // Typed navigations.
            self.env.loadInTab(tab, url: self.url("/b"))
            try await self.waitUntil("b loaded") { self.shown(tab).page == self.url("/b") && self.env.navigationState(for: tab)?.isLoading == false }
            try await self.assertAgree(tab, "after typing /b")
            self.env.loadInTab(tab, url: self.url("/c"))
            try await self.waitUntil("c loaded") { self.shown(tab).page == self.url("/c") && self.env.navigationState(for: tab)?.isLoading == false }
            try await self.assertAgree(tab, "after typing /c")
            XCTAssertEqual(contents.webView.backForwardList.backList.count, 2, "three pages, so two entries behind; no entry was added twice")

            // Back goes exactly one step and the toolbar follows.
            contents.goBack()
            try await self.waitUntil("back to b") { self.shown(tab).page == self.url("/b") }
            try await self.waitForQuiet(tab)
            try await self.assertAgree(tab, "after Back from /c")
            XCTAssertEqual(self.shown(tab).app, self.url("/b"))
            contents.goBack()
            try await self.waitUntil("back to a") { self.shown(tab).page == self.url("/a") }
            print("NAVTRACE after second back: \(self.historySummary(contents)) app=\(String(describing: self.shown(tab).app))")
            try await self.waitForQuiet(tab)
            try await self.assertAgree(tab, "after Back from /b")
            contents.goForward()
            try await self.waitUntil("forward to b") { self.shown(tab).page == self.url("/b") }
            try await self.waitForQuiet(tab)
            try await self.assertAgree(tab, "after Forward")

            // A page that changes its own address without loading a document (single-page apps).
            self.env.loadInTab(tab, url: self.url("/spa"))
            try await self.waitUntil("spa loaded") { self.shown(tab).page == self.url("/spa") && self.env.navigationState(for: tab)?.isLoading == false }
            _ = try await contents.evaluateJavaScript("go('/spa/one')")
            try await self.assertAgree(tab, "after pushState to /spa/one")
            _ = try await contents.evaluateJavaScript("go('/spa/two')")
            try await self.assertAgree(tab, "after pushState to /spa/two")
            XCTAssertEqual(self.shown(tab).app, self.url("/spa/two"))
            contents.goBack()
            try await self.waitUntil("back to /spa/one") { self.shown(tab).page == self.url("/spa/one") }
            try await self.waitForQuiet(tab)
            try await self.assertAgree(tab, "after Back inside the single-page app")
            XCTAssertEqual(self.shown(tab).app, self.url("/spa/one"), "one Back is one step, not two")

            // A redirect lands on its destination and adds one entry, not two.
            let behind = contents.webView.backForwardList.backList.count
            self.env.loadInTab(tab, url: self.url("/redirect"))
            try await self.waitUntil("redirect landed") { self.shown(tab).page == self.url("/b") && self.env.navigationState(for: tab)?.isLoading == false }
            try await self.assertAgree(tab, "after a redirect")
            XCTAssertEqual(contents.webView.backForwardList.backList.count, behind + 1, "a redirect must add one history entry")
        }
    }

    func testNavigatingWhileAnotherLoadIsStillPendingKeepsTheAddressRight() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let tab = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntil("first load") { self.shown(tab).page == self.url("/a") && self.env.navigationState(for: tab)?.isLoading == false }
            let contents = try XCTUnwrap(self.env.webContents[tab] as? WebKitWebContents)

            // A load that never answers, then the user types somewhere else.
            self.env.loadInTab(tab, url: self.url("/slow"))
            try await Task.sleep(for: .milliseconds(300))
            self.env.loadInTab(tab, url: self.url("/b"))
            try await self.waitUntil("b loaded") { self.shown(tab).page == self.url("/b") && self.env.navigationState(for: tab)?.isLoading == false }
            try await self.assertAgree(tab, "after abandoning a stalled load")

            // The stalled attempt must not leave the app thinking a load is still owed: a later page-initiated change shows.
            self.env.loadInTab(tab, url: self.url("/spa"))
            try await self.waitUntil("spa loaded") { self.shown(tab).page == self.url("/spa") && self.env.navigationState(for: tab)?.isLoading == false }
            _ = try await contents.evaluateJavaScript("go('/spa/after-stall')")
            try await self.assertAgree(tab, "after pushState following a stalled load")
            print("NAVTRACE before back: \(self.historySummary(contents))")
            contents.goBack()
            try await self.waitUntil("back to /spa") { self.shown(tab).page == self.url("/spa") }
            try await self.waitForQuiet(tab)
            print("NAVTRACE after back: \(self.historySummary(contents))")
            try await self.assertAgree(tab, "after Back")
            XCTAssertEqual(contents.webView.backForwardList.backList.last?.url, self.url("/b"))
        }
    }

    func testAddressFollowsASinglePageAppThatNeverFinishesLoading() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let tab = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntil("first load") { self.shown(tab).page == self.url("/a") && self.env.navigationState(for: tab)?.isLoading == false }
            let contents = try XCTUnwrap(self.env.webContents[tab] as? WebKitWebContents)

            self.env.loadInTab(tab, url: self.url("/spa-hang"))
            try await self.waitUntil("document committed") { self.shown(tab).page == self.url("/spa-hang") }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(self.env.navigationState(for: tab)?.isLoading, true, "the premise: the page is still loading its image")

            _ = try await contents.evaluateJavaScript("go('/spa-hang/one')")
            try await self.assertAgree(tab, "after pushState while the page is still loading")
            _ = try await contents.evaluateJavaScript("go('/spa-hang/two')")
            try await self.assertAgree(tab, "after a second pushState")
            XCTAssertEqual(self.shown(tab).app, self.url("/spa-hang/two"))
            contents.goBack()
            try await self.waitUntil("back one step") { self.shown(tab).page == self.url("/spa-hang/one") }
            try await self.assertAgree(tab, "after Back")
            XCTAssertEqual(self.shown(tab).app, self.url("/spa-hang/one"), "one Back is one step")
        }
    }
}
