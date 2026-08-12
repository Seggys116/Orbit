//  corpus: dbepggeogbaibhgnhhndojpepiihcmeb
//  Drives real Vimium: forTrusted() ignores synthetic events, so the keystroke
//  must travel a real NSEvent through the real AppKit view tree.

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class CorpusVimiumLiveTests: CorpusLiveTestCase {

    private static let corpusName = "Vimium"
    private static let windowSize = CGSize(width: 900, height: 700)
    /// ANSI `j`.
    private static let jKeyCode: UInt16 = 38

    private var hostedWindow: NSWindow?

    override func tearDown() {
        hostedWindow?.orderOut(nil)
        hostedWindow = nil
        super.tearDown()
    }

    private static let tallPageHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Orbit Vimium subject</title>
    <style>html, body { margin: 0; } #tall { height: 8000px; background: linear-gradient(#fff, #ccc); }</style>
    </head><body><div id="tall">orbit-vimium-subject</div></body></html>
    """

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.tallPageHTML),
        ])
    }

    @discardableResult
    private static func poll(
        timeout: Duration = .seconds(30), _ condition: () async throws -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    // MARK: - Hosting the real production view tree

    /// Mirrors OrbitWindowController.installContentView(window:): a plainer
    /// container would be a tree the engine's own hit test never sees in production.
    private func hostContentCard() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: ContentCardView().environment(env))
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
        hostedWindow = window
        return window
    }

    private func waitUntilEngineViewIsMounted(
        _ contents: ChromiumWebContents, in window: NSWindow, timeout: Duration = .seconds(15)
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
                    the engine view never reached the window (window=\(String(describing: view.window)) \
                    frame=\(frame)); a blank pane, not a Vimium problem -- see WebContentsHostView
                    """
                )
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func engineCentre(of contents: ChromiumWebContents) -> NSPoint {
        let frame = contents.view.convert(contents.view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// Resolved through AppKit's own hit test, not NSWindow.sendEvent: -- the
    /// XCTest host has no key window, so AppKit would swallow the event for an unrelated reason.
    private func resolvedPageView(in window: NSWindow, at point: NSPoint) -> NSView? {
        window.contentView?.superview?.hitTest(point)
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        guard let resolved = resolvedPageView(in: window, at: point) else { return }
        func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
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
    }

    @discardableResult
    private func press(
        _ characters: String, keyCode: UInt16, at point: NSPoint, in window: NSWindow
    ) -> NSView? {
        guard let resolved = resolvedPageView(in: window, at: point) else { return nil }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        }
        if let down = event(.keyDown) { resolved.keyDown(with: down) }
        if let up = event(.keyUp) { resolved.keyUp(with: up) }
        return resolved
    }

    // MARK: - Vimium's own footprint in the page

    /// Non-empty only when Vimium's content-script CSS landed; independent of
    /// its JavaScript, so it distinguishes the two failure modes.
    private static let cssMarkerProbe = """
    String(window.getComputedStyle(document.documentElement)
      .getPropertyValue('--vimium-background-color') || '').trim()
    """

    // MARK: - Tests

    // Skips only when the corpus has not been vendored (`Scripts/extension-corpus fetch`).
    // ORBIT-LIVE-ENGINE: MAY-SKIP testVimiumOffersAToolbarActionThroughTheProductionEntryPath
    func testVimiumOffersAToolbarActionThroughTheProductionEntryPath() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName)

        try LiveChromiumEngineHost.runLive(timeout: 180) {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine

            let bridge = OrbitChromiumTabsBridge.shared
            if !bridge.isWindowRegistered(env) {
                bridge.windowCreated(owner: env, focused: false)
            }
            bridge.windowFocusChanged(owner: env)
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(
                loaded.id, entry.id,
                "the vendored corpus directory produced a different extension than the pin"
            )
            XCTAssertTrue(
                loaded.hasToolbarAction,
                "Vimium's manifest declares an action; without one Orbit draws no toolbar icon for it at all"
            )

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let registryID = try XCTUnwrap(bridge.existingTabID(for: tabID))
            env.activateTab(tabID)

            let session = env.webContents[tabID]?.session ?? engine.defaultSession
            let entries = SiteControlPopoverView.extensionActionEntries(
                engine: engine, session: session, tabID: registryID
            )
            let action = try XCTUnwrap(
                entries.first { $0.extensionInfo.id == loaded.id },
                """
                Vimium has no entry in the production toolbar path, so the user has no icon to click. \
                Entries offered for this tab: \(entries.map(\.extensionInfo.id))
                """
            )
            XCTAssertEqual(action.popupURL.scheme, "chrome-extension")
            XCTAssertEqual(
                action.popupURL.host, loaded.id,
                "the toolbar entry addresses an origin the running engine does not answer to: \(action.popupURL)"
            )
        }
    }

    // Skips only when the corpus has not been vendored on this machine.
    // ORBIT-LIVE-ENGINE: MAY-SKIP testPressingJScrollsTheRealPage
    func testPressingJScrollsTheRealPage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let directory = try ExtensionCorpus.directory(for: Self.corpusName)
        let entry = try ExtensionCorpus.entry(for: Self.corpusName)
        try ExtensionCorpus.verifyManifestVersionMatchesPin(for: Self.corpusName)

        try LiveChromiumEngineHost.runLive(timeout: 240) {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine

            let bridge = OrbitChromiumTabsBridge.shared
            if !bridge.isWindowRegistered(env) {
                bridge.windowCreated(owner: env, focused: false)
            }
            bridge.windowFocusChanged(owner: env)
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(
                loaded.id, entry.id,
                "the vendored corpus directory produced a different extension than the pin"
            )

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            env.activateTab(tabID)

            let window = self.hostContentCard()
            try await self.waitUntilEngineViewIsMounted(contents, in: window)
            // The compositor needs a frame before the renderer hit-tests input
            // against a laid-out document.
            try await Task.sleep(for: .milliseconds(500))

            let scrollHeight = try await contents.evaluateJavaScript(
                "document.documentElement.scrollHeight"
            ) as? NSNumber
            XCTAssertGreaterThan(
                (scrollHeight?.doubleValue ?? 0), 2000,
                "the subject page is not scrollable, so nothing below could measure a scroll"
            )

            let cssMarker = await Self.poll(timeout: .seconds(30)) {
                let value = try await contents.evaluateJavaScript(Self.cssMarkerProbe) as? String
                return !(value ?? "").isEmpty
            }
            XCTAssertTrue(
                cssMarker,
                """
                Vimium's own content-script CSS never reached the document (its vimium.css declares \
                :root { --vimium-background-color: white }), so its content scripts did not run at all \
                and the keystroke below has nothing to reach
                """
            )

            let centre = self.engineCentre(of: contents)
            // A real click first: gives the document focus and sets
            // vimium_frontend.js's windowHasFocus, which several paths gate on.
            self.click(at: centre, in: window)
            contents.focus()
            try await Task.sleep(for: .milliseconds(500))

            let before = (try await contents.evaluateJavaScript("window.scrollY") as? NSNumber)?.doubleValue ?? -1
            XCTAssertEqual(before, 0, accuracy: 0.5, "the page is expected to start at the top")

            let resolved = self.press("j", keyCode: Self.jKeyCode, at: centre, in: window)
            XCTAssertNotNil(
                resolved,
                "AppKit's hit test resolved no view at the engine view's own centre, so no event was delivered anywhere"
            )

            // Vimium scrolls smoothly by default, so movement lands over
            // several animation frames rather than in one.
            var after = before
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                after = (try await contents.evaluateJavaScript("window.scrollY") as? NSNumber)?.doubleValue ?? after
                if after > before { break }
                try await Task.sleep(for: .milliseconds(150))
            }
            print("ORBIT-VIMIUM scrollY before=\(before) after=\(after), resolved view = \(String(describing: resolved.map { type(of: $0) }))")

            XCTAssertGreaterThan(
                after, before,
                """
                A real, trusted `j` keydown reached \(String(describing: resolved.map { type(of: $0) })) and the page \
                did not move (scrollY \(before) -> \(after)). Vimium's CSS did land, so its content \
                scripts ran; what it installs only after \
                chrome.runtime.sendMessage({handler:"initializeFrame"}) answers and chrome.storage \
                yields its settings is normal mode, which is what maps `j` to scrollDown. Either that \
                round trip never completed, or the key never reached the renderer as a trusted event.
                """
            )
        }
    }
}
