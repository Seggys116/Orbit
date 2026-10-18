//  The docked half of the inspector, asserted on the real view hierarchy,
//  frame and stored dock side -- a "docked" flag alone proves nothing.

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class DevToolsDockingLiveTests: XCTestCase {

    private var savedDockSide: DevToolsDockSide = .right

    override func setUp() {
        super.setUp()
        savedDockSide = DevToolsDockPreference.current
        DevToolsDockPreference.current = .right
    }

    override func tearDown() {
        DevToolsDockPreference.current = savedDockSide
        for window in NSApp.windows where window.title.hasPrefix("Web Inspector") {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        super.tearDown()
    }

    private static let pageHTML = "<html><body style=\"margin:0;background:#112233\">orbit-dock-test</body></html>"
    private static let paneSize = CGSize(width: 1000, height: 700)

    // MARK: - A real pane in a real window

    private struct Pane {
        var window: NSWindow
        var host: NSView
    }

    /// Mirrors OrbitWindowController.installContentView(window:): the real
    /// view ContentCardView puts a tab in, so the docked composition is the shipped one.
    private static func hostPane(for contents: WebKitWebContents) -> Pane {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: paneSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: WebContentsHostView(contents: contents, environment: nil))
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(origin: .zero, size: paneSize)
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: paneSize))
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        return Pane(window: window, host: host)
    }

    private static func settle(_ pane: Pane, turns: Int = 6) async {
        for _ in 0..<turns {
            pane.window.layoutIfNeeded()
            pane.host.layoutSubtreeIfNeeded()
            pane.window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    // MARK: - Engine-reported state

    private static func decodeState(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func state(of inspected: WebKitWebContents) -> [String: Any] {
        decodeState(inspected.devToolsStateJSON())
    }

    private static func reportedPageBounds(_ state: [String: Any]) -> CGRect? {
        guard let bounds = state["inspectedPageBounds"] as? [String: Any],
              let x = bounds["x"] as? Int, let y = bounds["y"] as? Int,
              let width = bounds["width"] as? Int, let height = bounds["height"] as? Int,
              width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    @discardableResult
    private static func waitForState(
        _ inspected: WebKitWebContents,
        pane: Pane?,
        timeout: Duration = .seconds(25),
        until predicate: ([String: Any]) -> Bool
    ) async -> [String: Any] {
        var last: [String: Any] = [:]
        let deadline = ContinuousClock.now + timeout
        while true {
            last = state(of: inspected)
            if predicate(last) { return last }
            guard ContinuousClock.now < deadline else { return last }
            if let pane {
                pane.window.layoutIfNeeded()
                pane.window.displayIfNeeded()
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private struct InspectorDidNotOpen: Error {}

    /// Waits for the inspector to be connected with its frontend loaded and WebKit to have settled where it lives.
    private static func openInspector(
        on inspected: WebKitWebContents,
        pane: Pane
    ) async throws -> WebKitInspectorFrontend {
        inspected.showDeveloperTools(inspectAt: nil)
        let settled = await waitForState(inspected, pane: pane) { state in
            (state["open"] as? Bool ?? false)
                && (state["attached"] as? Bool ?? false)
                && (state["responsesToFrontend"] as? Int ?? 0) > 0
                && (state["dockDecided"] as? Bool ?? false)
        }
        guard let frontend = inspected.developerToolsFrontend else {
            XCTFail("the inspector never opened; state \(settled)")
            throw InspectorDidNotOpen()
        }
        await settle(pane)
        return frontend
    }

    // MARK: - Driving the frontend's own dock control

    /// The host call the inspector's own dock buttons make, rather than any Orbit-side shortcut.
    private static func requestDockSide(_ side: String, in frontend: WebKitInspectorFrontend) async throws {
        let started = try await frontend.evaluateJavaScript(
            "(function(){ if (typeof InspectorFrontendHost === 'undefined') { return 'missing'; } InspectorFrontendHost.requestSetDockSide('\(side)'); return 'sent'; })()"
        ) as? String
        XCTAssertEqual(started, "sent", "the Web Inspector frontend has no InspectorFrontendHost.requestSetDockSide")
    }

    // MARK: - Evidence helpers

    private static func isInside(_ view: NSView, _ pane: Pane) -> Bool {
        view.window === pane.window && view.isDescendant(of: pane.host)
    }

    private static func detachedInspectorWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("Web Inspector") }
    }

    private static func makePage() async throws -> (WebKitWebContents, LiveHTTPTestServer) {
        let server = try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: pageHTML),
        ])
        let engine = await WebKitLiveEngineHost.sharedEngine()
        let page = try await WebKitLiveEngineHost.makeContents(engine: engine)
        page.load(server.baseURL)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(page)
        return (page, server)
    }

    private static func assertPageAlive(_ page: WebKitWebContents, file: StaticString = #filePath, line: UInt = #line) async throws {
        let alive = try await page.evaluateJavaScript("document.body.textContent")
        XCTAssertEqual(alive as? String, "orbit-dock-test", "the inspected page is no longer live", file: file, line: line)
    }

    // MARK: - Docked mode really hosts the inspector inside the window

    func test_dockedInspectorLivesInsideTheBrowserWindowAndShrinksThePage() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)
            XCTAssertTrue(page.canDockInspector, "the shipped pane must hand the page to the inspector as a dockable host")

            let frontend = try await Self.openInspector(on: page, pane: pane)
            try await Self.requestDockSide("right", in: frontend)
            let docked = await Self.waitForState(page, pane: pane) { state in
                (state["dockSide"] as? String) == "right" && Self.reportedPageBounds(state) != nil
            }
            await Self.settle(pane)

            XCTAssertEqual(docked["docked"] as? Bool, true, "the inspector never docked; state \(docked)")
            XCTAssertEqual(docked["dockSide"] as? String, "right", "state \(docked)")
            XCTAssertTrue(page.isDeveloperToolsDocked)
            XCTAssertNil(Self.detachedInspectorWindow(), "a docked inspector must not also have its own window open")

            XCTAssertTrue(
                Self.isInside(frontend.view, pane),
                "the docked frontend is not in the browser window at all -- window=\(String(describing: frontend.view.window))"
            )
            XCTAssertTrue(Self.isInside(page.view, pane), "docking took the page's own engine view out of the window")
            XCTAssertFalse(frontend.view.isHidden)
            XCTAssertGreaterThan(frontend.view.frame.width, 100, "the docked frontend has no room: \(frontend.view.frame)")
            XCTAssertEqual(
                frontend.view.frame.height, Self.paneSize.height, accuracy: 2,
                "a right-docked frontend runs the full height of the pane: \(frontend.view.frame)"
            )

            guard let reported = Self.reportedPageBounds(docked) else {
                return XCTFail("the page's rectangle in the pane was never reported; state \(docked)")
            }
            XCTAssertLessThan(reported.width, Self.paneSize.width - 40, "a right dock must leave the page narrower than the pane; \(reported)")
            XCTAssertEqual(reported.minX, 0, accuracy: 1, "a right dock leaves the page at the pane's left edge; \(reported)")
            XCTAssertEqual(reported.height, Self.paneSize.height, accuracy: 2, "a right dock must leave the page full height; \(reported)")
            XCTAssertEqual(
                page.view.frame.width, reported.width, accuracy: 2,
                "the page's engine view is not the rectangle that was reported -- \(reported), view \(page.view.frame)"
            )
            XCTAssertEqual(
                page.view.frame.width + frontend.view.frame.width, Self.paneSize.width, accuracy: 4,
                "page and inspector must share the pane with nothing left over or overlapping: page \(page.view.frame), inspector \(frontend.view.frame)"
            )
            XCTAssertEqual(page.developerToolsDockSide, .right)

            try await Self.assertPageAlive(page)
            page.closeDeveloperTools()
        }
    }

    func test_dockingToTheBottomAndLeftMovesThePageRatherThanRebuildingTheInspector() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let frontend = try await Self.openInspector(on: page, pane: pane)

            try await Self.requestDockSide("bottom", in: frontend)
            let bottom = await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "bottom" }
            await Self.settle(pane)
            guard let bottomRect = Self.reportedPageBounds(bottom) else {
                return XCTFail("no page rectangle after docking to the bottom; state \(bottom)")
            }
            XCTAssertEqual(bottom["dockSide"] as? String, "bottom", "state \(bottom)")
            XCTAssertEqual(bottomRect.width, Self.paneSize.width, accuracy: 2, "a bottom dock leaves the page full width; \(bottomRect)")
            XCTAssertLessThan(bottomRect.height, Self.paneSize.height - 40, "a bottom dock must take height from the page; \(bottomRect)")
            XCTAssertEqual(bottomRect.minY, 0, accuracy: 1, "a bottom dock keeps the page at the top of the pane; \(bottomRect)")
            XCTAssertEqual(
                page.view.frame.height, bottomRect.height, accuracy: 2,
                "the page's engine view did not follow the bottom dock; \(bottomRect), view \(page.view.frame)"
            )
            XCTAssertEqual(
                frontend.view.frame.width, Self.paneSize.width, accuracy: 2,
                "a bottom-docked frontend spans the pane's width: \(frontend.view.frame)"
            )
            XCTAssertTrue(Self.isInside(frontend.view, pane), "the bottom-docked frontend left the browser window")
            XCTAssertTrue(Self.isInside(page.view, pane))

            try await Self.requestDockSide("left", in: frontend)
            let left = await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "left" }
            await Self.settle(pane)
            guard let leftRect = Self.reportedPageBounds(left) else {
                return XCTFail("no page rectangle after docking to the left; state \(left)")
            }
            XCTAssertEqual(left["dockSide"] as? String, "left", "state \(left)")
            XCTAssertGreaterThan(leftRect.minX, 40, "a left dock must inset the page from the pane's left edge; \(leftRect)")
            XCTAssertEqual(leftRect.height, Self.paneSize.height, accuracy: 2, "a left dock leaves the page full height; \(leftRect)")
            XCTAssertEqual(
                page.view.frame.width, leftRect.width, accuracy: 2,
                "the page's engine view did not follow the left dock; \(leftRect), view \(page.view.frame)"
            )
            XCTAssertTrue(Self.isInside(frontend.view, pane), "the left-docked frontend left the browser window")

            // The same frontend object throughout: a dock-side change moves one inspector, it does not open a second.
            XCTAssertTrue(
                page.developerToolsFrontend === frontend,
                "changing the dock side replaced the inspector instead of moving it"
            )
            XCTAssertNil(Self.detachedInspectorWindow(), "a docked inspector left a window behind")
            try await Self.assertPageAlive(page)
            page.closeDeveloperTools()
        }
    }

    // MARK: - Both modes, both ways

    func test_undockingMovesTheInspectorToItsOwnWindowAndRedockingBringsItBack() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let frontend = try await Self.openInspector(on: page, pane: pane)
            try await Self.requestDockSide("right", in: frontend)
            await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "right" }
            await Self.settle(pane)
            XCTAssertTrue(Self.isInside(frontend.view, pane), "precondition: the inspector should have started docked")

            try await Self.requestDockSide("undocked", in: frontend)
            let undocked = await Self.waitForState(page, pane: pane) { $0["docked"] as? Bool == false && $0["open"] as? Bool == true }
            await Self.settle(pane)

            XCTAssertEqual(undocked["docked"] as? Bool, false, "state \(undocked)")
            XCTAssertEqual(undocked["dockSide"] as? String, "undocked", "state \(undocked)")
            XCTAssertFalse(Self.isInside(frontend.view, pane), "the undocked inspector is still inside the browser window")
            XCTAssertNotNil(frontend.view.superview, "the undocked inspector was left parented to nothing")
            let window = try XCTUnwrap(frontend.view.window, "the undocked inspector ended up in no window at all")
            XCTAssertNotEqual(window, pane.window)
            XCTAssertTrue(window.title.hasPrefix("Web Inspector"), "title \(window.title)")
            XCTAssertTrue(
                window.contentView.map { frontend.view.isDescendant(of: $0) } ?? false,
                "the undocked inspector is not in its window's own content hierarchy"
            )
            XCTAssertNotNil(Self.detachedInspectorWindow())
            XCTAssertEqual(
                page.view.frame.size.width, Self.paneSize.width, accuracy: 2,
                "undocking must give the page the whole pane back; view \(page.view.frame)"
            )
            XCTAssertEqual(page.view.frame.size.height, Self.paneSize.height, accuracy: 2)
            XCTAssertTrue(Self.isInside(page.view, pane), "undocking took the page out of its own pane")
            XCTAssertEqual(page.developerToolsDockSide, .undocked)

            try await Self.requestDockSide("right", in: frontend)
            let redocked = await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "right" }
            await Self.settle(pane)

            XCTAssertEqual(redocked["docked"] as? Bool, true, "state \(redocked)")
            XCTAssertTrue(Self.isInside(frontend.view, pane), "re-docking never brought the inspector back into the browser window")
            XCTAssertNil(Self.detachedInspectorWindow(), "the detached window survived re-docking")
            guard let rect = Self.reportedPageBounds(redocked) else {
                return XCTFail("re-docking never produced a page rectangle; state \(redocked)")
            }
            XCTAssertLessThan(rect.width, Self.paneSize.width - 40, "re-docking left no room for the inspector; \(rect)")
            XCTAssertTrue(page.developerToolsFrontend === frontend, "re-docking replaced the inspector")
            try await Self.assertPageAlive(page)
            page.closeDeveloperTools()
        }
    }

    func test_theDockApiMovesAnOpenInspectorAndRemembersTheSide() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)
            _ = try await Self.openInspector(on: page, pane: pane)

            page.setDeveloperToolsDockSide(.bottom)
            let bottom = await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "bottom" }
            XCTAssertEqual(bottom["dockSide"] as? String, "bottom", "state \(bottom)")
            XCTAssertEqual(DevToolsDockPreference.current, .bottom)

            page.setDeveloperToolsDockSide(.undocked)
            let undocked = await Self.waitForState(page, pane: pane) { $0["docked"] as? Bool == false && $0["open"] as? Bool == true }
            XCTAssertEqual(undocked["dockSide"] as? String, "undocked", "state \(undocked)")
            XCTAssertEqual(DevToolsDockPreference.current, .undocked)
            XCTAssertNotNil(Self.detachedInspectorWindow())

            page.setDeveloperToolsDockSide(.left)
            let left = await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "left" }
            XCTAssertEqual(left["dockSide"] as? String, "left", "state \(left)")
            XCTAssertEqual(DevToolsDockPreference.current, .left)
            XCTAssertNil(Self.detachedInspectorWindow())
            page.closeDeveloperTools()
        }
    }

    // MARK: - The choice is remembered

    func test_dockSideSurvivesClosingAndReopeningTheInspector() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let first = try await Self.openInspector(on: page, pane: pane)
            // Chosen in the inspector itself, not through Orbit's API: Orbit has to notice.
            try await Self.requestDockSide("bottom", in: first)
            let chosen = await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "bottom" }
            XCTAssertEqual(chosen["dockSide"] as? String, "bottom", "state \(chosen)")
            await Self.settle(pane)
            XCTAssertEqual(DevToolsDockPreference.current, .bottom, "a side chosen in the inspector was not remembered")

            page.closeDeveloperTools()
            await Self.waitForState(page, pane: pane) { $0["open"] as? Bool == false }
            await Self.settle(pane)
            XCTAssertEqual(DevToolsDockPreference.current, .bottom, "closing the inspector forgot where it was docked")

            _ = try await Self.openInspector(on: page, pane: pane)
            let reopened = await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "bottom" && Self.reportedPageBounds($0) != nil }
            XCTAssertEqual(reopened["dockSide"] as? String, "bottom", "the inspector did not reopen where it was left; state \(reopened)")
            XCTAssertEqual(reopened["docked"] as? Bool, true)
            page.closeDeveloperTools()
        }
    }

    func test_anUndockedChoiceReopensInItsOwnWindow() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            DevToolsDockPreference.current = .undocked
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            _ = try await Self.openInspector(on: page, pane: pane)
            let state = await Self.waitForState(page, pane: pane) { $0["docked"] as? Bool == false && $0["open"] as? Bool == true }
            XCTAssertEqual(state["docked"] as? Bool, false, "state \(state)")
            XCTAssertNotNil(Self.detachedInspectorWindow(), "an undocked choice must open the inspector in its own window")
            XCTAssertEqual(page.view.frame.size.width, Self.paneSize.width, accuracy: 2, "the page lost room to a window it does not share")
            page.closeDeveloperTools()
        }
    }

    func test_aPageHostedWithoutAPaneStillGetsTheInspectorInItsOwnWindow() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.paneSize), styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.contentView = page.view
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }

            XCTAssertFalse(page.canDockInspector, "a view that is a window's own content has nowhere to share")
            page.showDeveloperTools(inspectAt: nil)
            let deadline = ContinuousClock.now + .seconds(10)
            while Self.detachedInspectorWindow() == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNotNil(Self.detachedInspectorWindow(), "an undockable page must fall back to WebKit's own inspector window")
            XCTAssertFalse(page.isDeveloperToolsDocked)
            page.closeDeveloperTools()
        }
    }

    func test_anInspectorFollowsThePageToANewPane() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)
            let frontend = try await Self.openInspector(on: page, pane: pane)
            try await Self.requestDockSide("right", in: frontend)
            await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "right" }

            let secondContainer = NSView(frame: NSRect(origin: .zero, size: Self.paneSize))
            let secondWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.paneSize), styleMask: [.titled], backing: .buffered, defer: false
            )
            secondWindow.contentView = secondContainer
            secondWindow.orderFront(nil)
            defer { secondWindow.orderOut(nil) }
            page.embedForInspectorDocking(in: secondContainer)
            secondContainer.layoutSubtreeIfNeeded()

            let deadline = ContinuousClock.now + .seconds(15)
            while !(page.inspectorFrontendWebView?.isDescendant(of: secondContainer) ?? false), ContinuousClock.now < deadline {
                secondContainer.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let moved = try XCTUnwrap(page.inspectorFrontendWebView)
            XCTAssertTrue(moved.isDescendant(of: secondContainer), "the inspector stayed behind in the pane the page left")
            XCTAssertTrue(page.view.isDescendant(of: secondContainer))
            XCTAssertTrue(page.isDeveloperToolsDocked)
            page.closeDeveloperTools()
        }
    }

    // MARK: - Closing

    func test_closingADockedInspectorGivesThePaneBackAndLeavesNoFrontendBehind() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let frontend = try await Self.openInspector(on: page, pane: pane)
            try await Self.requestDockSide("right", in: frontend)
            await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "right" }
            await Self.settle(pane)
            XCTAssertLessThan(page.view.frame.width, Self.paneSize.width - 40, "precondition: the inspector should have shared the pane")

            page.closeDeveloperTools()
            let closed = await Self.waitForState(page, pane: pane) { $0["open"] as? Bool == false }
            await Self.settle(pane)

            XCTAssertEqual(closed["open"] as? Bool, false, "state \(closed)")
            XCTAssertEqual(closed["docked"] as? Bool, false, "state \(closed)")
            XCTAssertFalse(page.developerToolsAreOpen())
            XCTAssertNil(Self.detachedInspectorWindow())
            XCTAssertNil(frontend.view.superview, "the closed inspector's view is still parented in the pane")
            XCTAssertEqual(page.view.frame.size.width, Self.paneSize.width, accuracy: 2, "the page did not get the whole pane back: \(page.view.frame)")
            XCTAssertEqual(page.view.frame.size.height, Self.paneSize.height, accuracy: 2)
            XCTAssertEqual(page.view.frame.minX, 0, accuracy: 1)
            XCTAssertTrue(Self.isInside(page.view, pane))
            try await Self.assertPageAlive(page)

            // The pane keeps following its window after the inspector is gone.
            pane.window.setContentSize(NSSize(width: 800, height: 600))
            await Self.settle(pane)
            XCTAssertEqual(page.view.frame.size.width, 800, accuracy: 2, "the page stopped following its pane after the inspector closed")
        }
    }

    func test_aDockedPageFollowsItsPaneWhenTheWindowResizes() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)
            let frontend = try await Self.openInspector(on: page, pane: pane)
            try await Self.requestDockSide("bottom", in: frontend)
            await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "bottom" }
            await Self.settle(pane)

            pane.window.setContentSize(NSSize(width: 800, height: 600))
            await Self.settle(pane, turns: 10)
            XCTAssertEqual(page.view.frame.width, 800, accuracy: 3, "page \(page.view.frame)")
            XCTAssertEqual(frontend.view.frame.width, 800, accuracy: 3, "inspector \(frontend.view.frame)")
            XCTAssertEqual(
                page.view.frame.height + frontend.view.frame.height, 600, accuracy: 4,
                "page \(page.view.frame) and inspector \(frontend.view.frame) must still fill the resized pane"
            )
            XCTAssertEqual(page.developerToolsDockSide, .bottom)
            page.closeDeveloperTools()
        }
    }

    // MARK: - State without an inspector

    func test_theStateReportsNothingOpenBeforeAnInspectorExists() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }
            let state = Self.state(of: page)
            XCTAssertEqual(state["open"] as? Bool, false)
            XCTAssertEqual(state["docked"] as? Bool, false)
            XCTAssertEqual(state["dockSide"] as? String, "undocked")
            XCTAssertNil(state["inspectedPageBounds"])
            XCTAssertNil(page.developerToolsFrontend)
            XCTAssertFalse(page.developerToolsAreOpen())
        }
    }

    func test_theDockPreferenceDefaultsToTheRightAndRoundTrips() {
        OrbitDefaults.standard.removeObject(forKey: "orbit.devTools.dockSide")
        XCTAssertEqual(DevToolsDockPreference.current, .right, "Chrome's default, which Orbit keeps")
        for side in [DevToolsDockSide.bottom, .left, .undocked, .right] {
            DevToolsDockPreference.current = side
            XCTAssertEqual(DevToolsDockPreference.current, side)
        }
        OrbitDefaults.standard.set("nonsense", forKey: "orbit.devTools.dockSide")
        XCTAssertEqual(DevToolsDockPreference.current, .right, "a corrupt stored side must not stop the inspector opening")
    }

    // MARK: - Geometry the docked pane derives, without an engine

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolvedPageRectMatchesChromesOwnResizingStrategy

    func test_resolvedPageRectMatchesChromesOwnResizingStrategy() {
        let container = CGSize(width: 1000, height: 700)

        XCTAssertEqual(
            DevToolsDockState.resolvedPageRect(nil, in: container),
            CGRect(x: 0, y: 0, width: 1000, height: 700),
            "with nothing reported yet the page fills the container, as ApplyDevToolsContentsResizingStrategy does"
        )
        XCTAssertEqual(
            DevToolsDockState.resolvedPageRect(CGRect(x: 0, y: 0, width: 0, height: 0), in: container),
            CGRect(x: 0, y: 0, width: 1000, height: 700)
        )
        XCTAssertEqual(
            DevToolsDockState.resolvedPageRect(CGRect(x: 0, y: 0, width: 4000, height: 4000), in: container),
            CGRect(x: 0, y: 0, width: 1000, height: 700),
            "an over-large rectangle is clamped rather than allowed to overhang the pane"
        )
        XCTAssertEqual(
            DevToolsDockState.resolvedPageRect(CGRect(x: 445, y: 0, width: 555, height: 700), in: container),
            CGRect(x: 445, y: 0, width: 555, height: 700)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_inferredSideReadsTheDockSideBackOutOfTheRectangle

    func test_inferredSideReadsTheDockSideBackOutOfTheRectangle() {
        let container = CGSize(width: 1000, height: 700)

        XCTAssertEqual(
            DevToolsDockState.inferredSide(pageBounds: CGRect(x: 0, y: 0, width: 600, height: 700), in: container),
            .right
        )
        XCTAssertEqual(
            DevToolsDockState.inferredSide(pageBounds: CGRect(x: 400, y: 0, width: 600, height: 700), in: container),
            .left
        )
        XCTAssertEqual(
            DevToolsDockState.inferredSide(pageBounds: CGRect(x: 0, y: 0, width: 1000, height: 400), in: container),
            .bottom
        )
        XCTAssertNil(
            DevToolsDockState.inferredSide(pageBounds: CGRect(x: 0, y: 0, width: 1000, height: 700), in: container),
            "a page filling the container describes no dock side at all"
        )
    }
}
