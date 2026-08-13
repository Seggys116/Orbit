//  A real AppKit mouse event through Orbit's own view layering into a real page. Assertions
//  are on what the engine did, never a hit test: a click resolved but dropped by -shouldIgnoreMouseEvent: looks identical.
//  Exists because OrbitWebContentsHost implemented neither of WebContentsDelegate's new-window routes,
//  so target="_blank", window.open() and Cmd-click all did nothing.

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class PageLinkNavigationLiveTests: XCTestCase {

    // MARK: - Fixtures

    // Read-after-navigation only, so evidence can't live on the clicked document's `window`.
    // A capture-phase mousedown rewrites the anchor's href; the URL Orbit lands on IS the evidence.
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

    // The anchor fills the viewport so the engine view's own centre is over
    // it -- no coordinate arithmetic between three layers to get wrong.
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

    // MARK: - Delegate recorder

    // `adopted` is AddNewContents (engine built the WebContents); `requested` is OpenURLFromTab
    // (it did not). Conflating them would let a fix for one pass a test for the other.
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

    // MARK: - Hosting the real production tree

    private static let windowSize = CGSize(width: 900, height: 700)

    // Mirrors OrbitWindowController.installContentView(window:) exactly: -shouldIgnoreMouseEvent:
    // re-runs the hit test from window.contentView, so a plainer container would test a different tree.
    private func hostRealContentCard(
        _ contents: ChromiumWebContents,
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
        _ contents: ChromiumWebContents,
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

    // MARK: - Delivering a real click

    private struct ClickOutcome {
        let resolvedView: NSView?
        let pointInWindow: NSPoint
        var resolvedDescription: String { resolvedView.map { "\(type(of: $0))" } ?? "nil" }
    }

    // Resolved via a manual hit test, not NSWindow.sendEvent: -- the XCTest host has no key
    // window, so real event dispatch would swallow the first click for an unrelated reason.
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

    private func engineCentre(of contents: ChromiumWebContents) -> NSPoint {
        let frame = contents.view.convert(contents.view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: - Waiting

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

    // MARK: - 1. A plain same-tab link, clicked for real

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testARealClickOnAPlainLinkReachesTheEngineAndFollowsIt

    func testARealClickOnAPlainLinkReachesTheEngineAndFollowsIt() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE is not set")
        try LiveChromiumEngineHost.runLive(timeout: 90) {
            let server = try self.makeServer()
            defer { server.stop() }
            let start = server.baseURL.appendingPathComponent("link")

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }

            let hosted = try self.hostRealContentCard(contents, url: start)
            defer {
                hosted.environment._test_detachWebContents(for: hosted.tabID)
                hosted.window.orderOut(nil)
            }

            contents.load(start)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntilEngineViewIsMounted(contents, in: hosted.window)
            // The compositor needs a frame before the renderer will hit-test
            // the click against a laid-out document.
            try await Task.sleep(for: .milliseconds(400))

            let outcome = self.click(at: self.engineCentre(of: contents), in: hosted.window)

            // Waits for the tab to leave /link, not for the answer it wants -- a wrong
            // answer must fail loudly, not time out.
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

    // MARK: - 2. The route with nothing built yet: OpenURLFromTab

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testACmdClickAsksSwiftForANewBackgroundTabInsteadOfDoingNothing

    func testACmdClickAsksSwiftForANewBackgroundTabInsteadOfDoingNothing() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE is not set")
        try LiveChromiumEngineHost.runLive(timeout: 90) {
            let server = try self.makeServer()
            defer { server.stop() }
            let start = server.baseURL.appendingPathComponent("link")

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            let recorder = NewContentRecorder()
            contents.delegate = recorder
            defer { recorder.closeAll() }

            let hosted = try self.hostRealContentCard(contents, url: start)
            defer {
                hosted.environment._test_detachWebContents(for: hosted.tabID)
                hosted.window.orderOut(nil)
            }

            contents.load(start)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntilEngineViewIsMounted(contents, in: hosted.window)
            try await Task.sleep(for: .milliseconds(400))

            self.click(at: self.engineCentre(of: contents), in: hosted.window, modifiers: [.command])

            try await self.waitUntil(
                """
                A Cmd-click produced no new-content request at all. content:: routes it \
                through WebContentsDelegate::OpenURLFromTab, whose base implementation \
                returns nullptr and drops the navigation.
                """
            ) { !recorder.requested.isEmpty }

            let request = try XCTUnwrap(recorder.requested.first)
            // Same proof as test 1: only this URL if the page's mousedown listener saw a
            // trusted event on the anchor.
            XCTAssertEqual(
                request.url.path, ClickDestination.onLink,
                """
                The Cmd-click reached Swift but \
                \(Self.diagnosis(forLandedPath: request.url.path)).
                """
            )
            XCTAssertEqual(request.disposition, .newBackgroundTab)
            XCTAssertTrue(request.isUserGesture)
            XCTAssertEqual(
                contents.navigationState.url?.path, "/link",
                "A Cmd-click must not navigate the tab it was made in."
            )
        }
    }

    // MARK: - 3. The route the engine already built: target="_blank"

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testATargetBlankLinkOpensARealSecondTabAtTheLinkedURL

    func testATargetBlankLinkOpensARealSecondTabAtTheLinkedURL() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE is not set")
        try LiveChromiumEngineHost.runLive(timeout: 90) {
            try await self.assertNewWindowLands(
                on: "/opened",
                startingAt: "blank",
                by: "document.getElementById('target').click()"
            )
        }
    }

    // MARK: - 4. window.open()

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testWindowOpenOpensARealSecondTabAtTheRequestedURL

    func testWindowOpenOpensARealSecondTabAtTheRequestedURL() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE is not set")
        try LiveChromiumEngineHost.runLive(timeout: 90) {
            try await self.assertNewWindowLands(
                on: "/opened",
                startingAt: "link",
                by: "window.open('/opened', '_blank')"
            )
        }
    }

    // Shared by 3 and 4: Orbit must own the already-built WebContents from AddNewContents,
    // not a second one at the same URL, which would drop window.opener and restart the load.
    private func assertNewWindowLands(on path: String, startingAt route: String, by script: String) async throws {
        let server = try makeServer()
        defer { server.stop() }
        let start = server.baseURL.appendingPathComponent(route)

        let contents = try await LiveChromiumEngineHost.makeContents()
        defer { contents.close() }
        let recorder = NewContentRecorder()
        contents.delegate = recorder
        defer { recorder.closeAll() }

        contents.load(start)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

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

        let opened = try XCTUnwrap(entry.contents as? ChromiumWebContents, "The adopted contents is not a live engine tab.")
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

    // MARK: - 5. The C ABI both routes answer through

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTheLoadedFrameworkExportsTheNewContentCallback

    func testTheLoadedFrameworkExportsTheNewContentCallback() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE is not set")
        try LiveChromiumEngineHost.runLive {
            _ = await LiveChromiumEngineHost.sharedEngine()
            XCTAssertTrue(
                OrbitChromiumBridge.shared.hasNewContentRequestCallback,
                """
                The loaded Chromium framework has no OrbitSetNewContentRequestCallback, \
                so nothing a page opens in a second tab can reach Swift however \
                correct the Swift side is. Rebuild Chromium/Embedder.
                """
            )
        }
    }
}
