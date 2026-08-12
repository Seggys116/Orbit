//  The docked half of the inspector, asserted on the real view hierarchy,
//  frame and stored dock side -- a "docked" flag alone proves nothing.

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class DevToolsDockingLiveTests: XCTestCase {

    private static let pageHTML = "<html><body style=\"margin:0;background:#112233\">orbit-dock-test</body></html>"
    private static let paneSize = CGSize(width: 1000, height: 700)

    // MARK: - A real pane in a real window

    private struct Pane {
        var window: NSWindow
        var host: NSView
    }

    /// Mirrors OrbitWindowController.installContentView(window:): the real
    /// view ContentCardView puts a tab in, so the docked composition is the shipped one.
    private static func hostPane(for contents: ChromiumWebContents) -> Pane {
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

    private static func state(of inspected: ChromiumWebContents) -> [String: Any] {
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
        _ inspected: ChromiumWebContents,
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

    /// Waits for the CDP pipe to carry traffic and the frontend to have said
    /// where it belongs; nothing is presented before that, by design.
    private static func openInspector(
        on inspected: ChromiumWebContents,
        pane: Pane
    ) async throws -> ChromiumWebContents {
        inspected.showDeveloperTools(inspectAt: nil)
        let settled = await waitForState(inspected, pane: pane) { state in
            (state["attached"] as? Bool ?? false)
                && (state["responsesToFrontend"] as? Int ?? 0) > 0
                && (state["dockDecided"] as? Bool ?? false)
        }
        guard let frontend = inspected.developerToolsFrontend else {
            XCTFail("the inspector never opened; state \(settled)")
            throw XCTSkip("inspector never opened")
        }
        await settle(pane)
        return frontend
    }

    // MARK: - Driving the frontend's own dock control

    /// Goes through DockController itself, the same object the inspector's
    /// Dock side menu drives, rather than any Orbit-side shortcut.
    private static func requestDockSide(_ side: String, in frontend: ChromiumWebContents) async throws {
        let request = """
        (function () {
          window.__orbitDockRequest = 'pending';
          import('devtools://devtools/bundled/ui/legacy/legacy.js').then(function (ui) {
            ui.DockController.DockController.instance().setDockSide('\(side)');
            window.__orbitDockRequest = 'done';
          }, function (error) {
            window.__orbitDockRequest = 'error: ' + error;
          });
          return 'started';
        })()
        """
        _ = try await frontend.evaluateJavaScript(request)

        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let status = try await frontend.evaluateJavaScript("String(window.__orbitDockRequest)") as? String
            if status == "done" { return }
            if let status, status.hasPrefix("error") {
                XCTFail("DockController.setDockSide('\(side)') failed inside the frontend: \(status)")
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("the frontend never applied dock side \(side)")
    }

    // MARK: - Evidence helpers

    private static func isInside(_ view: NSView, _ pane: Pane) -> Bool {
        view.window === pane.window && view.isDescendant(of: pane.host)
    }

    private static func hasDetachedInspectorWindow() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.title.hasPrefix("Developer Tools") }
    }

    private static func makePage() async throws -> (ChromiumWebContents, LiveHTTPTestServer) {
        let server = try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: pageHTML),
        ])
        let engine = await LiveChromiumEngineHost.sharedEngine()
        let page = try await LiveChromiumEngineHost.makeContents(engine: engine)
        page.load(server.baseURL)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(page)
        return (page, server)
    }

    // MARK: - Docked mode really hosts the inspector inside the window

    func test_dockedInspectorLivesInsideTheBrowserWindowAndShrinksThePage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }

            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let frontend = try await Self.openInspector(on: page, pane: pane)

            // Chrome's default, and Orbit keeps it: the inspector opens docked
            // to the right of the page rather than in its own window.
            try await Self.requestDockSide("right", in: frontend)
            let docked = await Self.waitForState(page, pane: pane) { state in
                (state["docked"] as? Bool ?? false) && Self.reportedPageBounds(state) != nil
            }
            await Self.settle(pane)

            XCTAssertEqual(docked["docked"] as? Bool, true, "the inspector never docked; state \(docked)")
            XCTAssertEqual(docked["dockSide"] as? String, "right", "state \(docked)")
            XCTAssertFalse(
                Self.hasDetachedInspectorWindow(),
                "a docked inspector must not also have its own window open"
            )

            XCTAssertTrue(
                Self.isInside(frontend.view, pane),
                "the docked frontend's engine view is not in the browser window at all -- window=\(String(describing: frontend.view.window))"
            )
            XCTAssertTrue(
                Self.isInside(page.view, pane),
                "docking took the page's own engine view out of the window"
            )
            XCTAssertEqual(
                frontend.view.frame.size.width, Self.paneSize.width, accuracy: 1,
                "the docked frontend must fill the pane -- the page is drawn on top of it, not beside it"
            )

            guard let reported = Self.reportedPageBounds(docked) else {
                return XCTFail("the frontend never reported where the page goes; state \(docked)")
            }
            XCTAssertLessThan(
                reported.width, Self.paneSize.width - 40,
                "a right dock must leave the page narrower than the pane; reported \(reported)"
            )
            XCTAssertEqual(reported.minX, 0, accuracy: 1, "a right dock leaves the page at the pane's left edge; reported \(reported)")
            XCTAssertEqual(
                reported.height, Self.paneSize.height, accuracy: 2,
                "a right dock must leave the page full height; reported \(reported)"
            )
            XCTAssertEqual(
                page.view.frame.width, reported.width, accuracy: 2,
                "the page's real engine view was not resized to the rectangle the inspector asked for -- reported \(reported), view \(page.view.frame)"
            )
            XCTAssertEqual(
                page.view.frame.height, reported.height, accuracy: 2,
                "reported \(reported), view \(page.view.frame)"
            )

            // The page is still live behind the inspector, not an evicted
            // surface, re-asserted at the new, smaller size.
            let alive = try await page.evaluateJavaScript("document.body.textContent")
            XCTAssertEqual(alive as? String, "orbit-dock-test")

            page.closeDeveloperTools()
        }
    }

    func test_dockingToTheBottomAndLeftMovesThePageRatherThanRebuildingTheInspector() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }

            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let frontend = try await Self.openInspector(on: page, pane: pane)

            try await Self.requestDockSide("bottom", in: frontend)
            let bottom = await Self.waitForState(page, pane: pane) { state in
                guard state["docked"] as? Bool == true, let rect = Self.reportedPageBounds(state) else { return false }
                return rect.height < Self.paneSize.height - 40
            }
            await Self.settle(pane)

            guard let bottomRect = Self.reportedPageBounds(bottom) else {
                return XCTFail("no page rectangle after docking to the bottom; state \(bottom)")
            }
            XCTAssertEqual(bottom["dockSide"] as? String, "bottom", "state \(bottom)")
            XCTAssertEqual(
                bottomRect.width, Self.paneSize.width, accuracy: 2,
                "a bottom dock leaves the page full width; reported \(bottomRect)"
            )
            XCTAssertLessThan(
                bottomRect.height, Self.paneSize.height - 40,
                "a bottom dock must take height away from the page; reported \(bottomRect)"
            )
            XCTAssertEqual(
                page.view.frame.height, bottomRect.height, accuracy: 2,
                "the page's engine view did not follow the bottom dock; reported \(bottomRect), view \(page.view.frame)"
            )
            XCTAssertTrue(Self.isInside(frontend.view, pane), "the bottom-docked frontend left the browser window")

            try await Self.requestDockSide("left", in: frontend)
            let left = await Self.waitForState(page, pane: pane) { state in
                guard state["docked"] as? Bool == true, let rect = Self.reportedPageBounds(state) else { return false }
                return rect.minX > 40
            }
            await Self.settle(pane)

            guard let leftRect = Self.reportedPageBounds(left) else {
                return XCTFail("no page rectangle after docking to the left; state \(left)")
            }
            XCTAssertEqual(left["dockSide"] as? String, "left", "state \(left)")
            XCTAssertGreaterThan(
                leftRect.minX, 40,
                "a left dock must inset the page from the pane's left edge; reported \(leftRect)"
            )
            XCTAssertEqual(
                page.view.frame.width, leftRect.width, accuracy: 2,
                "the page's engine view did not follow the left dock; reported \(leftRect), view \(page.view.frame)"
            )

            // The same frontend object throughout: a dock-side change re-parents
            // one WebContents, it does not open a second inspector.
            XCTAssertTrue(
                page.developerToolsFrontend === frontend,
                "changing the dock side replaced the inspector instead of moving it"
            )
            XCTAssertTrue(Self.isInside(frontend.view, pane), "the left-docked frontend left the browser window")

            page.closeDeveloperTools()
        }
    }

    // MARK: - Both modes, both ways

    func test_undockingMovesTheInspectorToItsOwnWindowAndRedockingBringsItBack() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }

            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let frontend = try await Self.openInspector(on: page, pane: pane)
            try await Self.requestDockSide("right", in: frontend)
            await Self.waitForState(page, pane: pane) { $0["docked"] as? Bool == true }
            await Self.settle(pane)
            XCTAssertTrue(Self.isInside(frontend.view, pane), "precondition: the inspector should have started docked")

            try await Self.requestDockSide("undocked", in: frontend)
            let undocked = await Self.waitForState(page, pane: pane) { $0["docked"] as? Bool == false }
            await Self.settle(pane)

            XCTAssertEqual(undocked["docked"] as? Bool, false, "state \(undocked)")
            XCTAssertEqual(undocked["dockSide"] as? String, "undocked", "state \(undocked)")
            XCTAssertFalse(
                Self.isInside(frontend.view, pane),
                "the undocked inspector is still inside the browser window"
            )
            // Not merely "not in the pane": guards against the outgoing
            // container stealing the view back and being discarded, leaving it parented to nothing.
            XCTAssertNotNil(
                frontend.view.superview,
                "the undocked inspector was left parented to nothing -- it was taken out of the detached window and stranded"
            )
            XCTAssertNotNil(frontend.view.window, "the undocked inspector ended up in no window at all")
            XCTAssertNotEqual(frontend.view.window, pane.window)
            XCTAssertTrue(
                frontend.view.window?.title.hasPrefix("Developer Tools") ?? false,
                "the undocked inspector is not in a DevTools window; title \(frontend.view.window?.title ?? "<none>")"
            )
            XCTAssertTrue(
                frontend.view.window?.contentView.map { frontend.view.isDescendant(of: $0) } ?? false,
                "the undocked inspector is not in its window's own content hierarchy"
            )
            XCTAssertEqual(
                page.view.frame.size.width, Self.paneSize.width, accuracy: 2,
                "undocking must give the page the whole pane back; view \(page.view.frame)"
            )
            XCTAssertTrue(Self.isInside(page.view, pane), "undocking took the page out of its own pane")

            try await Self.requestDockSide("right", in: frontend)
            let redocked = await Self.waitForState(page, pane: pane) { state in
                (state["docked"] as? Bool ?? false) && Self.reportedPageBounds(state) != nil
            }
            await Self.settle(pane)

            XCTAssertEqual(redocked["docked"] as? Bool, true, "state \(redocked)")
            XCTAssertTrue(
                Self.isInside(frontend.view, pane),
                "re-docking never brought the inspector back into the browser window -- this is the state a swallowed setIsDocked ack leaves it in"
            )
            XCTAssertFalse(
                Self.hasDetachedInspectorWindow(),
                "the detached window survived re-docking"
            )
            guard let rect = Self.reportedPageBounds(redocked) else {
                return XCTFail("re-docking never produced a page rectangle; state \(redocked)")
            }
            XCTAssertLessThan(
                rect.width, Self.paneSize.width - 40,
                "re-docking reported no room for the inspector, so bounds updates stopped after the first change; reported \(rect)"
            )

            page.closeDeveloperTools()
        }
    }

    // MARK: - The choice is remembered

    func test_dockSideSurvivesClosingAndReopeningTheInspectorAndIsWrittenToTheProfile() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }

            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let first = try await Self.openInspector(on: page, pane: pane)
            try await Self.requestDockSide("bottom", in: first)
            let chosen = await Self.waitForState(page, pane: pane) { $0["dockSide"] as? String == "bottom" }
            XCTAssertEqual(chosen["dockSide"] as? String, "bottom", "state \(chosen)")

            page.closeDeveloperTools()
            await Self.settle(pane)
            XCTAssertNil(page.developerToolsFrontend, "closing the inspector left its frontend behind")

            let second = try await Self.openInspector(on: page, pane: pane)
            XCTAssertFalse(second === first, "precondition: reopening should build a new frontend")

            let reopened = await Self.waitForState(page, pane: pane) { state in
                (state["docked"] as? Bool ?? false) && Self.reportedPageBounds(state) != nil
            }
            await Self.settle(pane)

            XCTAssertEqual(
                reopened["dockSide"] as? String, "bottom",
                "the dock side was not remembered across reopening; state \(reopened)"
            )
            guard let rect = Self.reportedPageBounds(reopened) else {
                return XCTFail("the reopened inspector reported no page rectangle; state \(reopened)")
            }
            XCTAssertLessThan(
                rect.height, Self.paneSize.height - 40,
                "the reopened inspector did not come back docked to the bottom; reported \(rect)"
            )

            let stored = await Self.waitForStoredDockSide("bottom")
            XCTAssertTrue(
                stored,
                "currentDockState never reached the engine's own DevTools Preferences file, so the choice would not survive a relaunch"
            )

            page.closeDeveloperTools()
        }
    }

    /// Read-only, and only under the isolated per-process engine profile this
    /// suite's engine was started with -- never the real user's profile.
    private static func waitForStoredDockSide(_ side: String, timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if storedDockSideOnDisk() == side { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func storedDockSideOnDisk() -> String? {
        let root = EngineStorageDirectory.privateRoot
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: root.path) else { return nil }
        let mine = entries.filter { $0.contains("-\(getpid())-") }
        for entry in mine {
            let base = root.appendingPathComponent(entry, isDirectory: true)
            guard let walker = manager.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.lastPathComponent == "DevTools Preferences" {
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = object["currentDockState"] as? String,
                      let decoded = try? JSONSerialization.jsonObject(
                          with: Data(raw.utf8), options: [.fragmentsAllowed]
                      ) as? String
                else { continue }
                return decoded
            }
        }
        return nil
    }

    // MARK: - Teardown

    func test_closingADockedInspectorGivesThePaneBackAndLeavesNoFrontendBehind() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let (page, server) = try await Self.makePage()
            defer { server.stop() }
            defer { page.close() }

            let pane = Self.hostPane(for: page)
            defer { pane.window.orderOut(nil) }
            await Self.settle(pane)

            let frontend = try await Self.openInspector(on: page, pane: pane)
            try await Self.requestDockSide("right", in: frontend)
            await Self.waitForState(page, pane: pane) { state in
                (state["docked"] as? Bool ?? false) && Self.reportedPageBounds(state) != nil
            }
            await Self.settle(pane)
            let frontendView = frontend.view
            XCTAssertTrue(Self.isInside(frontendView, pane), "precondition: the inspector should be docked")

            page.closeDeveloperTools()
            await Self.settle(pane)

            XCTAssertNil(page.developerToolsFrontend, "the inspector's frontend outlived closing it")
            XCTAssertFalse(page.isDeveloperToolsDocked)
            XCTAssertNil(
                DevToolsDockState.shared.session(for: page),
                "the docked session was left registered after teardown"
            )
            XCTAssertNil(frontendView.window, "the frontend's engine view was left in the browser window")
            XCTAssertNil(frontendView.superview, "the frontend's engine view was left parented in the pane")
            XCTAssertTrue(
                page.devToolsStateJSON().contains("\"open\":false"),
                "the engine still reports an open inspector; state \(page.devToolsStateJSON())"
            )

            XCTAssertTrue(Self.isInside(page.view, pane), "closing the inspector took the page out of its pane")
            XCTAssertEqual(
                page.view.frame.size.width, Self.paneSize.width, accuracy: 2,
                "the page never got the whole pane back; view \(page.view.frame)"
            )
            XCTAssertEqual(
                page.view.frame.size.height, Self.paneSize.height, accuracy: 2,
                "view \(page.view.frame)"
            )

            let alive = try await page.evaluateJavaScript("document.body.textContent")
            XCTAssertEqual(alive as? String, "orbit-dock-test", "the page did not survive the inspector's teardown")
        }
    }

    // MARK: - Geometry the docked pane derives, without an engine

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
