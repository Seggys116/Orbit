import XCTest

final class ContentBlockingDeferredLoadCompositionGuardTests: XCTestCase {

    private func appEnvironmentSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit/Core/AppEnvironment.swift")
    }

    private func pinnedTabsSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit/Core/AppEnvironment+PinnedTabs.swift")
    }

    private func commandBarDirectoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit/UI/CommandBar")
    }

    private func commandBarSources() throws -> String {
        let directory = commandBarDirectoryURL()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThan(names.count, 1, "Found \(names.count) Swift file(s) in \(directory.path). The command bar is more than one file — the path resolution is wrong and every check below would pass vacuously.")
        return try names
            .map { try text(at: directory.appendingPathComponent($0)) }
            .joined(separator: "\n")
    }

    private func text(at url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 500, "Walked \(text.count) characters of \(url.path). That is far too few — the path resolution is wrong and every check below would pass vacuously.")
        return text
    }

    // MARK: - The gate itself: a session content blocking is not ready for
    // must be created with no initial URL.

    func test_makeWebContentsIsCalledWithTheContentBlockingReadinessTernary() throws {
        let text = try text(at: appEnvironmentSourceURL())
        XCTAssertTrue(
            text.contains("contents = try engine.makeWebContents(session: session, initialURL: nil)"),
            "materializeWebContents must create every session with initialURL: nil, even one content blocking has already gated as ready — passing the real url here starts navigation inside engine.makeWebContents itself, before adoptWebContents has registered the tab, so WillCreateURLLoaderFactory fires first and every webRequest event for that navigation reports tabId -1. Reintroducing a readiness ternary here reopens exactly that leak."
        )
    }

    // MARK: - The first navigation must not wait for content blocking.

    func test_navigationIsNotHeldForContentBlocking() throws {
        let text = try text(at: appEnvironmentSourceURL())
        XCTAssertFalse(
            text.contains("await contentBlockingReadiness.value"),
            "materializeWebContents must not await content-blocking readiness before contents.load. A cold compile holds the main actor, so a timeout raced on that actor never fires and the first pages stay blank."
        )
        XCTAssertFalse(
            text.contains("if let contentBlockingReadiness"),
            "There must not be a deferred-load branch that withholds the URL until the rule compile finishes."
        )
        let loadRange = try XCTUnwrap(text.range(of: "contents.load(url)"))
        let adoptRange = try XCTUnwrap(text.range(of: "adoptWebContents(contents, for: tabID, url: url)"))
        XCTAssertTrue(
            adoptRange.upperBound < loadRange.lowerBound,
            "The tab has to be registered before load(), and load() has to be the call that actually fetches the page."
        )
    }

    // MARK: - The funnel: `loadInTab` must be what actually invalidates a
    // pending deferred load, and it must be what every direct-navigation call
    // site uses.

    func test_loadInTabBumpsNavigationGenerationBeforeLoading() throws {
        let text = try text(at: appEnvironmentSourceURL())
        XCTAssertTrue(
            text.contains("func loadInTab(_ tabID: TabID, url: URL) {"),
            "AppEnvironment must expose a single funnel for navigating an already-materialised tab, or nothing can invalidate a pending deferred content-blocking load."
        )
        let bumpRange = try XCTUnwrap(text.range(of: "navigationGeneration[tabID, default: 0] += 1"))
        let loadRange = try XCTUnwrap(
            text.range(of: "webContents[tabID]?.load(url)", range: bumpRange.upperBound..<text.endIndex),
            "loadInTab must call webContents[tabID]?.load(url) AFTER bumping navigationGeneration, in that order, and within the same function"
        )
        XCTAssertTrue(bumpRange.upperBound <= loadRange.lowerBound)
    }

    func test_commandBarEditURLNavigatesThroughLoadInTabNotDirectly() throws {
        let text = try commandBarSources()
        XCTAssertTrue(
            text.contains("env.loadInTab(tabID, url: url)"),
            "the Cmd+L / edit-URL path must navigate through env.loadInTab(_:url:), not env.webContents[tabID]?.load(url) directly, or a navigation made through this path can be silently undone by a content-blocking deferred load that was already queued. This reads every Swift file under Orbit/UI/CommandBar, so moving the path between files is fine — removing it is not."
        )
        XCTAssertFalse(
            text.contains("env.webContents[tabID]?.load(url)"),
            "the direct WebContents.load(_:) call this fix replaced must actually be gone from the edit-URL path, not merely supplemented."
        )
    }

    func test_pinnedTabResetNavigatesThroughLoadInTabNotDirectly() throws {
        let text = try text(at: pinnedTabsSourceURL())
        XCTAssertTrue(
            text.contains("loadInTab(id, url: origin)"),
            "resetPinnedTab must navigate through loadInTab(_:url:), not webContents[id]?.load(origin) directly, for the same reason CommandBarView's edit-URL path must."
        )
        XCTAssertFalse(
            text.contains("webContents[id]?.load(origin)"),
            "the direct WebContents.load(_:) call this fix replaced must actually be gone from resetPinnedTab, not merely supplemented."
        )
    }
}
