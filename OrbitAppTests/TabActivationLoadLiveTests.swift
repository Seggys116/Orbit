import AppKit
import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class TabActivationLoadLiveTests: LiveEnvironmentTestCase {

    private var server: LiveHTTPTestServer!
    private var spaceID: SpaceID!
    private var window: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let routes = ["/a", "/b", "/c"].reduce(into: [String: LiveHTTPTestServer.Route]()) { routes, path in
            routes[path] = .init(
                contentType: "text/html; charset=utf-8",
                body: "<!doctype html><html><head><title>\(path)</title></head><body><h1>\(path)</h1></body></html>"
            )
        }
        server = try LiveHTTPTestServer(routes: routes)
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(name: "Activation", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        env.selectSpace(spaceID)
    }

    override func tearDownWithError() throws {
        window?.close()
        window = nil
        server.stop()
        server = nil
        try super.tearDownWithError()
    }

    private func url(_ path: String) -> URL { server.baseURL.appendingPathComponent(String(path.dropFirst())) }

    private func requestCount(_ path: String) -> Int { server.requestLog.all.filter { $0.path == path }.count }

    private func waitUntilLoaded(_ tabID: TabID, at url: URL, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let state = env.webContents[tabID]?.navigationState, state.url == url, !state.isLoading { return }
            guard ContinuousClock.now < deadline else {
                let state = env.webContents[tabID]?.navigationState
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "tab never loaded \(url): renderer \(env.webContents[tabID] == nil ? "missing" : "present"), url \(String(describing: state?.url)), loading \(String(describing: state?.isLoading))"
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForRequest(_ path: String, count: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while requestCount(path) < count {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "\(path) was requested \(requestCount(path)) times, expected \(count)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testReopenLastClosedTabLoadsTheReopenedPage() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let first = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntilLoaded(first, at: self.url("/a"))
            let second = self.env.openTab(url: self.url("/b"), in: self.spaceID)
            try await self.waitUntilLoaded(second, at: self.url("/b"))

            XCTAssertTrue(self.env.perform(.closeTabOrWindow))
            XCTAssertEqual(self.env.activeTabID, first)
            XCTAssertNil(self.env.webContents[second])

            XCTAssertTrue(self.env.perform(.reopenLastClosedTab))

            XCTAssertEqual(self.env.activeTabID, second)
            XCTAssertNotNil(self.env.webContents[second], "The reopened tab is on screen with no renderer: a blank pane that never loads.")
            try await self.waitUntilLoaded(second, at: self.url("/b"))
            XCTAssertEqual(self.requestCount("/b"), 2)
        }
    }

    func testSwitchingToASpaceWhoseActiveTabHasNoRendererLoadsIt() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let home = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntilLoaded(home, at: self.url("/a"))
            let profileID = self.env.createDefaultProfileIfNeeded()
            let other = self.env.createSpace(name: "Other", icon: "square", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
            self.env.selectSpace(other)
            let away = self.env.openTab(url: self.url("/c"), in: other)
            try await self.waitUntilLoaded(away, at: self.url("/c"))
            self.env.selectSpace(self.spaceID)
            self.env.releaseWebContents(for: away)

            self.env.selectSpace(other)

            XCTAssertEqual(self.env.activeTabID, away)
            XCTAssertNotNil(self.env.webContents[away], "The Space's active tab is on screen with no renderer.")
            try await self.waitUntilLoaded(away, at: self.url("/c"))
            XCTAssertEqual(self.requestCount("/c"), 2)
        }
    }

    func testThePaneLoadsAnActiveTabThatReachedTheScreenWithoutARenderer() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let first = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntilLoaded(first, at: self.url("/a"))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentCardView().environment(self.env))
            window.makeKeyAndOrderFront(nil)
            self.window = window

            let background = self.env.openTab(url: self.url("/b"), in: self.spaceID, activate: false)
            try await self.waitUntilLoaded(background, at: self.url("/b"))
            self.env.releaseWebContents(for: background)
            self.env.store.selectTab(background)

            let deadline = ContinuousClock.now + .seconds(10)
            while self.env.webContents[background] == nil, ContinuousClock.now < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let contents = try XCTUnwrap(self.env.webContents[background], "The pane shows the tab with no renderer and never asks for one.")
            try await self.waitUntilLoaded(background, at: self.url("/b"))
            let mountDeadline = ContinuousClock.now + .seconds(10)
            while contents.view.window !== window, ContinuousClock.now < mountDeadline {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(contents.view.window === window, "The engine view is not in the pane.")
        }
    }

    func testReloadLoadsTheActiveTabWhenItHasNoRenderer() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            let tab = self.env.openTab(url: self.url("/a"), in: self.spaceID)
            try await self.waitUntilLoaded(tab, at: self.url("/a"))
            self.env.releaseWebContents(for: tab)

            XCTAssertTrue(self.env.perform(.refresh))

            XCTAssertNotNil(self.env.webContents[tab], "Reload did nothing for a tab with no renderer.")
            try await self.waitUntilLoaded(tab, at: self.url("/a"))
            XCTAssertEqual(self.requestCount("/a"), 2)
        }
    }

    func testReloadWithNoCommittedDocumentLoadsTheRequestedURL() throws {
        try assertReloadWithNoCommittedDocumentLoads(ignoringCache: false)
    }

    func testHardReloadWithNoCommittedDocumentLoadsTheRequestedURL() throws {
        try assertReloadWithNoCommittedDocumentLoads(ignoringCache: true)
    }

    private func assertReloadWithNoCommittedDocumentLoads(ignoringCache: Bool) throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let contents = try XCTUnwrap(try engine.makeWebContents(session: engine.defaultSession, initialURL: nil) as? WebKitWebContents)
            defer { contents.close() }
            let target = self.url("/a")
            contents.load(target)
            contents.stopLoading()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(contents.webView.backForwardList.currentItem, "Precondition: nothing committed.")
            let requestsBefore = self.requestCount("/a")

            contents.reload(ignoringCache: ignoringCache)

            try await self.waitForRequest("/a", count: requestsBefore + 1)
            let deadline = ContinuousClock.now + .seconds(10)
            while contents.webView.backForwardList.currentItem?.url != target, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(contents.webView.backForwardList.currentItem?.url, target)
        }
    }
}
