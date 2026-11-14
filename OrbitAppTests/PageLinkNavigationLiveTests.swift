//  A real AppKit mouse event through Orbit's own view layering into a real page; assertions are on what the engine did, never a hit test, because a click dropped by -shouldIgnoreMouseEvent: resolves identically.

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class PageLinkNavigationLiveTests: XCTestCase {

    // Evidence can't live on the clicked document's `window`: a capture-phase mousedown rewrites the anchor's href, so the URL Orbit lands on is the evidence.
    private enum ClickDestination {
        static let notSeen = "/click-not-seen"
        static let onLink = "/click-on-link"
        static let offLink = "/click-off-link"
    }

    private static let trustedClickProbeScript = """
    var link = document.getElementById('target');
    document.addEventListener('mousedown', function (event) {
      if (!event.isTrusted) { return; }
      var onLink = event.target && link.contains(event.target);
      link.setAttribute('href', onLink ? '\(ClickDestination.onLink)' : '\(ClickDestination.offLink)');
    }, true);
    """

    // The anchor fills the viewport so the engine view's centre is over it, avoiding coordinate arithmetic between three layers.
    private static func fullViewportLinkPage(href: String, attributes: String = "", script: String = "") -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>start</title><style>
        html, body { margin: 0; padding: 0; height: 100%; }
        a { position: fixed; inset: 0; display: block; background: #eeeeee; }
        </style></head><body>
        <a id="target" href="\(href)"\(attributes.isEmpty ? "" : " " + attributes)>open</a>
        \(script.isEmpty ? "" : "<script>\(script)</script>")
        </body></html>
        """
    }

    private static func destinationPage(title: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body><h1>\(title)</h1></body></html>
        """
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/link": .init(
                contentType: "text/html; charset=utf-8",
                body: Self.fullViewportLinkPage(href: ClickDestination.notSeen, script: Self.trustedClickProbeScript)
            ),
            // No probe script: activated by scripted .click(), whose event.isTrusted is false.
            "/blank": .init(
                contentType: "text/html; charset=utf-8",
                body: Self.fullViewportLinkPage(href: "/opened", attributes: #"target="_blank" rel="noopener noreferrer""#)
            ),
            ClickDestination.notSeen: .init(contentType: "text/html; charset=utf-8", body: Self.destinationPage(title: "not seen")),
            ClickDestination.onLink: .init(contentType: "text/html; charset=utf-8", body: Self.destinationPage(title: "on link")),
            ClickDestination.offLink: .init(contentType: "text/html; charset=utf-8", body: Self.destinationPage(title: "off link")),
            "/opened": .init(contentType: "text/html; charset=utf-8", body: Self.destinationPage(title: "opened")),
        ])
    }

    // `adopted` is AddNewContents (engine built the WebContents); `requested` is OpenURLFromTab (it did not), and conflating them would let a fix for one pass a test for the other.
    @MainActor
    private final class NewContentRecorder: WebContentsDelegate {
        private(set) var adopted: [(request: NewContentRequest, contents: any WebContents)] = []
        private(set) var requested: [NewContentRequest] = []

        func webContents(_ contents: WebContents, requestsNewContent request: NewContentRequest) -> Bool {
            requested.append(request)
            return true
        }

        func webContents(_ contents: WebContents, requestsAdoptionOf pending: PendingWebContents) -> Bool {
            guard let opened = pending.adopt() else { return false }
            adopted.append((pending.request, opened))
            return true
        }

        func closeAll() {
            for entry in adopted { entry.contents.close() }
            adopted.removeAll()
        }
    }

    private static let windowSize = CGSize(width: 900, height: 700)

    // Mirrors OrbitWindowController.installContentView(window:) exactly: -shouldIgnoreMouseEvent: re-runs the hit test from window.contentView, so a plainer container would test a different tree.
    private func hostRealContentCard(
        _ contents: WebKitWebContents,
        url: URL
    ) throws -> (window: NSWindow, environment: AppEnvironment, tabID: TabID) {
        let environment = AppEnvironment.demo
        let tabID = try XCTUnwrap(environment.activeTabID, "The demo environment has no active tab to host a page in.")
        var tab = try XCTUnwrap(environment.tab(tabID))
        tab.url = url
        environment.state.tabs[tabID] = tab
        environment._test_attachWebContents(contents, for: tabID)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: ContentCardView().environment(environment))
        host.safeAreaRegions = []
        host.sizingOptions = []
        let container = OrbitWindowContentView(frame: NSRect(origin: .zero, size: Self.windowSize))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return (window, environment, tabID)
    }

    private func waitUntilEngineViewIsMounted(
        _ contents: WebKitWebContents,
        in window: NSWindow,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            window.contentView?.layoutSubtreeIfNeeded()
            let view = contents.view
            let frame = view.convert(view.bounds, to: nil)
            if view.window === window, frame.width > 1, frame.height > 1 { return }
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: """
                    The engine view never reached the window (window=\(String(describing: view.window)) \
                    frame=\(frame)); a blank pane, not a click problem -- see \
                    WebContentsHostView.
                    """
                )
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private struct ClickOutcome {
        let resolvedView: NSView?
        let pointInWindow: NSPoint
        var resolvedDescription: String { resolvedView.map { "\(type(of: $0))" } ?? "nil" }
    }

    // Resolved via a manual hit test, not NSWindow.sendEvent:, because the XCTest host has no key window and real dispatch would swallow the first click.
    @discardableResult
    private func click(
        at pointInWindow: NSPoint,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = []
    ) -> ClickOutcome {
        guard let themeFrame = window.contentView?.superview else {
            return ClickOutcome(resolvedView: nil, pointInWindow: pointInWindow)
        }
        let resolved = themeFrame.hitTest(pointInWindow)
        guard let resolved else {
            return ClickOutcome(resolvedView: nil, pointInWindow: pointInWindow)
        }

        func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: pointInWindow,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: pressure
            )
        }

        if let down = event(.leftMouseDown, pressure: 1) { resolved.mouseDown(with: down) }
        if let up = event(.leftMouseUp, pressure: 0) { resolved.mouseUp(with: up) }
        return ClickOutcome(resolvedView: resolved, pointInWindow: pointInWindow)
    }

    private func engineCentre(of contents: WebKitWebContents) -> NSPoint {
        let frame = contents.view.convert(contents.view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func waitUntil(
        _ description: @autoclosure @escaping () -> String,
        timeout: Duration = .seconds(10),
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: description())
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func diagnosis(forLandedPath path: String?) -> String {
        switch path {
        case ClickDestination.onLink:
            return "a trusted mouse event reached the page, on the link"
        case ClickDestination.offLink:
            return """
            a trusted mouse event reached the page but landed off the anchor -- the \
            click coordinates are wrong, not the click path
            """
        case ClickDestination.notSeen:
            return """
            the anchor was followed WITHOUT any trusted mousedown ever reaching the \
            renderer, so whatever drove that navigation, it was not this click -- the \
            test would be vacuous if it accepted this
            """
        case "/link":
            return """
            the tab never left the start page, so the click produced no navigation at \
            all: an Orbit overlay won the hit test, or RenderWidgetHostViewCocoa's own \
            -shouldIgnoreMouseEvent: rejected it
            """
        case nil:
            return "the tab has no URL at all"
        default:
            return "the tab went somewhere this fixture never links to"
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testARealClickOnAPlainLinkReachesTheEngineAndFollowsIt

    func testARealClickOnAPlainLinkReachesTheEngineAndFollowsIt() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let server = try self.makeServer()
            defer { server.stop() }
            let start = server.baseURL.appendingPathComponent("link")

            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }

            let hosted = try self.hostRealContentCard(contents, url: start)
            defer {
                hosted.environment._test_detachWebContents(for: hosted.tabID)
                hosted.window.orderOut(nil)
            }

            contents.load(start)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntilEngineViewIsMounted(contents, in: hosted.window)
            // The compositor needs a frame before the renderer will hit-test the click against a laid-out document.
            try await Task.sleep(for: .milliseconds(400))

            let outcome = self.click(at: self.engineCentre(of: contents), in: hosted.window)

            // Waits for the tab to leave /link, not for the answer it wants, so a wrong answer fails loudly instead of timing out.
            try? await self.waitUntil("the tab never left /link") { contents.navigationState.url?.path != "/link" }

            let landed = contents.navigationState.url?.path
            XCTAssertEqual(
                landed, ClickDestination.onLink,
                """
                A real click at \(outcome.pointInWindow) resolved to \
                \(outcome.resolvedDescription) and the tab is now at \
                \(contents.navigationState.url?.absoluteString ?? "nil") -- \
                \(Self.diagnosis(forLandedPath: landed)). The destination is set by a \
                capture-phase mousedown listener in the page, so landing here proves \
                the click crossed Orbit's own view layering into the renderer AND that \
                following the link worked; nothing else in this fixture navigates.
                """
            )
        }
    }

    // Every gesture is checked against the link the page's own mousedown listener rewrote, so a navigation that was not this click cannot satisfy it.
    private func assertClickRequests(
        _ expected: NewContentDisposition,
        modifiers: NSEvent.ModifierFlags
    ) async throws {
        let server = try makeServer()
        defer { server.stop() }
        let start = server.baseURL.appendingPathComponent("link")

        let contents = try await WebKitLiveEngineHost.makeContents()
        defer { contents.close() }
        let recorder = NewContentRecorder()
        contents.delegate = recorder
        defer { recorder.closeAll() }

        let hosted = try hostRealContentCard(contents, url: start)
        defer {
            hosted.environment._test_detachWebContents(for: hosted.tabID)
            hosted.window.orderOut(nil)
        }

        contents.load(start)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        try await waitUntilEngineViewIsMounted(contents, in: hosted.window)
        try await Task.sleep(for: .milliseconds(400))

        click(at: engineCentre(of: contents), in: hosted.window, modifiers: modifiers)

        try await waitUntil("The click produced no new-content request at all.") { !recorder.requested.isEmpty }
        let request = try XCTUnwrap(recorder.requested.first)
        XCTAssertEqual(request.url.path, ClickDestination.onLink, Self.diagnosis(forLandedPath: request.url.path))
        XCTAssertEqual(request.disposition, expected)
        XCTAssertEqual(contents.navigationState.url?.path, "/link", "The click must not navigate the tab it was made in.")
        XCTAssertTrue(recorder.adopted.isEmpty, "Nothing is built for a click: the delegate opens the tab itself.")
    }

    func testAShiftClickAsksForANewWindow() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.assertClickRequests(.newWindow, modifiers: [.shift])
        }
    }

    func testWindowOpenWithFeaturesIsAdoptedAsAPopup() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let server = try self.makeServer()
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            let recorder = NewContentRecorder()
            contents.delegate = recorder
            defer { recorder.closeAll() }

            contents.load(server.baseURL.appendingPathComponent("link"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            _ = try await contents.evaluateJavaScript("window.open('/opened', '_blank', 'width=320,height=240')", userGesture: true)

            try await self.waitUntil("window.open with features produced no new WebContents.") { !recorder.adopted.isEmpty }
            XCTAssertEqual(recorder.adopted.first?.request.disposition, .popup)
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testATargetBlankLinkOpensARealSecondTabAtTheLinkedURL

    func testATargetBlankLinkOpensARealSecondTabAtTheLinkedURL() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.assertNewWindowLands(
                on: "/opened",
                startingAt: "blank",
                by: "document.getElementById('target').click()"
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testWindowOpenOpensARealSecondTabAtTheRequestedURL

    func testWindowOpenOpensARealSecondTabAtTheRequestedURL() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            try await self.assertNewWindowLands(
                on: "/opened",
                startingAt: "link",
                by: "window.open('/opened', '_blank')"
            )
        }
    }

    // Shared by the target="_blank" and window.open() tests: Orbit must own the already-built WebContents from AddNewContents, not a second one at the same URL, which would drop window.opener and restart the load.
    private func assertNewWindowLands(on path: String, startingAt route: String, by script: String) async throws {
        let server = try makeServer()
        defer { server.stop() }
        let start = server.baseURL.appendingPathComponent(route)

        let contents = try await WebKitLiveEngineHost.makeContents()
        defer { contents.close() }
        let recorder = NewContentRecorder()
        contents.delegate = recorder
        defer { recorder.closeAll() }

        contents.load(start)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

        _ = try await contents.evaluateJavaScript(script, userGesture: true)

        try await waitUntil(
            """
            \(script) produced no new WebContents at all. content:: builds one and \
            hands the only owning pointer to WebContentsDelegate::AddNewContents, \
            whose base implementation returns nullptr and lets it die -- no tab, no \
            window, no error.
            """
        ) { !recorder.adopted.isEmpty }

        XCTAssertEqual(recorder.adopted.count, 1)
        let entry = try XCTUnwrap(recorder.adopted.first)
        XCTAssertEqual(entry.request.url.path, path)
        XCTAssertEqual(entry.request.disposition, .newForegroundTab)

        let opened = try XCTUnwrap(entry.contents as? WebKitWebContents, "The adopted contents is not a live engine tab.")
        try await waitUntil(
            """
            The adopted WebContents never landed on \(path) (it is at \
            \(opened.navigationState.url?.absoluteString ?? "nil")). It was handed over \
            mid-navigation and must finish that navigation itself.
            """
        ) { opened.navigationState.url?.path == path && !opened.navigationState.isLoading }

        XCTAssertEqual(
            contents.navigationState.url?.path, "/\(route)",
            "Opening a second tab must leave the tab that opened it where it was."
        )
    }
}
