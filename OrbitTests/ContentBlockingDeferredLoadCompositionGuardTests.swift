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

    private func commandBarSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit/UI/CommandBar/CommandBarView.swift")
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
            text.contains("initialURL: contentBlockingReadiness == nil ? url : nil"),
            "materializeWebContents must create a session content blocking has not gated as ready with `initialURL: nil`, and one it has not gated with the real url. Deleting or altering this ternary is exactly the leak the deferred load below exists to close."
        )
    }

    // MARK: - The deferred load must exist, must wait on readiness, and must
    // check it has not been superseded before firing.

    func test_theDeferredLoadTaskAwaitsReadinessThenLoadsTheOriginalURL() throws {
        let text = try text(at: appEnvironmentSourceURL())
        XCTAssertTrue(
            text.contains("if let contentBlockingReadiness {"),
            "materializeWebContents must branch on whether content blocking handed back a readiness Task at all — a session on a backend without .contentBlocking, or a session already bound, gets nil and must not be made to wait on anything."
        )
        XCTAssertTrue(
            text.contains("await contentBlockingReadiness.value"),
            "the deferred Task must actually await the readiness Task's value — not merely check whether it exists — or the navigation is never really held back."
        )
        XCTAssertTrue(
            text.contains("contents.load(url)"),
            "the deferred Task must eventually call load(url) with the ORIGINAL url materializeWebContents was asked to open — the whole point of withholding initialURL was to fetch this url once it is safe to."
        )
    }

    func test_theDeferredLoadChecksItHasNotBeenSupersededBeforeFiring() throws {
        let text = try text(at: appEnvironmentSourceURL())
        XCTAssertTrue(
            text.contains("let expectedGeneration = navigationGeneration[tabID, default: 0]"),
            "the deferred load must capture the tab's navigation generation BEFORE it starts waiting, so there is something to compare against once the wait is over."
        )
        XCTAssertTrue(
            text.contains("self.navigationGeneration[tabID, default: 0] == expectedGeneration else { return }"),
            "the deferred load must refuse to fire when the tab's navigation generation has moved on since it was queued — otherwise a real navigation the user made while content blocking was still compiling is silently overwritten the moment readiness resolves."
        )
        let generationCheckRange = try XCTUnwrap(
            text.range(of: "self.navigationGeneration[tabID, default: 0] == expectedGeneration else { return }")
        )
        let loadCallRange = try XCTUnwrap(text.range(of: "contents.load(url)"))
        XCTAssertTrue(
            generationCheckRange.lowerBound < loadCallRange.lowerBound,
            "the generation check must appear BEFORE the deferred contents.load(url) call, not after — a guard that runs after the clobbering load has already fired is decorative."
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
        let text = try text(at: commandBarSourceURL())
        XCTAssertTrue(
            text.contains("env.loadInTab(tabID, url: url)"),
            "the Cmd+L / edit-URL path must navigate through env.loadInTab(_:url:), not env.webContents[tabID]?.load(url) directly, or a navigation made through this path can be silently undone by a content-blocking deferred load that was already queued."
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
