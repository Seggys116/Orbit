import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// MARK: - 1. The pure glyph state machine

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class ToolbarAddressCopyGlyphTests: XCTestCase {

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_atRest_secureShowsTheChainLink

    func test_atRest_secureShowsTheChainLink() {
        XCTAssertEqual(
            ToolbarAddressCopyGlyph.current(security: .secure, isHovering: false, isCopied: false),
            .resting(symbol: "link", isWarning: false)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_atRest_insecureShowsTheWarningLockSlash

    func test_atRest_insecureShowsTheWarningLockSlash() {
        XCTAssertEqual(
            ToolbarAddressCopyGlyph.current(security: .insecure, isHovering: false, isCopied: false),
            .resting(symbol: "lock.slash", isWarning: true)
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_atRest_localAndUnknownDrawNothing

    func test_atRest_localAndUnknownDrawNothing() {
        for security: SecurityLevel in [.local, .unknown] {
            XCTAssertEqual(
                ToolbarAddressCopyGlyph.current(security: security, isHovering: false, isCopied: false), .none,
                "\(security) must keep drawing nothing at rest, exactly as ToolbarSecurityGlyph.symbol(for:) already does — see ToolbarAddressCopyControl.swift's header, \"THE .local/.unknown EDGE CASE\"."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_hovering_alwaysShowsTheCopyGlyphRegardlessOfSecurityState

    func test_hovering_alwaysShowsTheCopyGlyphRegardlessOfSecurityState() {
        for security: SecurityLevel in [.secure, .insecure, .mixedContent, .certificateError, .local, .unknown] {
            XCTAssertEqual(
                ToolbarAddressCopyGlyph.current(security: security, isHovering: true, isCopied: false), .hoverCopy,
                "Hovering over \(security)'s address indicator must show the copy affordance, even where the resting glyph draws nothing at all."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_copied_outranksHovering

    func test_copied_outranksHovering() {
        XCTAssertEqual(
            ToolbarAddressCopyGlyph.current(security: .secure, isHovering: true, isCopied: true),
            .copied
        )
        XCTAssertEqual(
            ToolbarAddressCopyGlyph.current(security: .secure, isHovering: false, isCopied: true),
            .copied
        )
    }
}

// MARK: - 2. The raw AppKit click + hover surface

@MainActor
final class ToolbarAddressCopyClickCatchingNSViewTests: XCTestCase {

    private func mouseDownEvent(at point: NSPoint = NSPoint(x: 5, y: 5)) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // MARK: The click genuinely fires (the user's exact complaint, applied here)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_mouseDown_invokesOnClick

    func test_mouseDown_invokesOnClick() {
        let view = ToolbarAddressCopyClickCatchingNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        var clickCount = 0
        view.onClick = { clickCount += 1 }

        view.mouseDown(with: mouseDownEvent())

        XCTAssertEqual(clickCount, 1, "A click must invoke onClick exactly once.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_mouseDown_withNoOnClickWired_doesNothingAndDoesNotCrash

    func test_mouseDown_withNoOnClickWired_doesNothingAndDoesNotCrash() {
        let view = ToolbarAddressCopyClickCatchingNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.mouseDown(with: mouseDownEvent())
    }

    // MARK: Hit testing — always the frontmost responder for its own bounds

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_hitTest_claimsPointsInsideBounds

    func test_hitTest_claimsPointsInsideBounds() {
        let view = ToolbarAddressCopyClickCatchingNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertTrue(view.hitTest(NSPoint(x: 8, y: 8)) === view)
        XCTAssertTrue(view.hitTest(NSPoint(x: 0, y: 0)) === view)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_hitTest_returnsNilOutsideBounds

    func test_hitTest_returnsNilOutsideBounds() {
        let view = ToolbarAddressCopyClickCatchingNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertNil(view.hitTest(NSPoint(x: -1, y: -1)))
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 20)))
    }

    // MARK: First click after window activation must not be wasted

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_acceptsFirstMouse_isTrue

    func test_acceptsFirstMouse_isTrue() {
        let view = ToolbarAddressCopyClickCatchingNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    // MARK: Never a window-drag handle — this control's own, independent fix

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickCatcher_isNeverAWindowDragHandle

    func test_clickCatcher_isNeverAWindowDragHandle() {
        let view = ToolbarAddressCopyClickCatchingNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "This header sits inside the window's 32pt title-bar band; a click-catching NSView that answers true here never even reaches mouseDown(with:) under .fullSizeContentView — AppKit consumes the event to move/zoom the window instead."
        )
    }

    // MARK: Hover — reports genuine transitions only, never a duplicate

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_updateHover_reportsEnterAndExit

    func test_updateHover_reportsEnterAndExit() {
        let view = ToolbarAddressCopyClickCatchingNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.updateHover(atLocationInView: NSPoint(x: 8, y: 8))
        view.updateHover(atLocationInView: NSPoint(x: 30, y: 30))

        XCTAssertEqual(reported, [true, false])
        XCTAssertFalse(view.isHovering)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_updateHover_neverReportsTheSameStateTwice

    func test_updateHover_neverReportsTheSameStateTwice() {
        let view = ToolbarAddressCopyClickCatchingNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        var reportCount = 0
        view.onHoverChanged = { _ in reportCount += 1 }

        view.updateHover(atLocationInView: NSPoint(x: 8, y: 8))
        view.updateHover(atLocationInView: NSPoint(x: 9, y: 9))
        view.updateHover(atLocationInView: NSPoint(x: 8, y: 8))

        XCTAssertEqual(reportCount, 1, "Moving within the same hover state must not report a duplicate transition.")
        XCTAssertTrue(view.isHovering)
    }
}

// MARK: - 3. The real, hosted, end-to-end control

@MainActor
final class ToolbarAddressCopyControlHostedTests: XCTestCase {

    private static func firstDescendant<T: NSView>(ofType: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let found = firstDescendant(ofType: T.self, in: subview) { return found }
        }
        return nil
    }

    private func mouseDownEvent(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func hostControl(security: SecurityLevel, url: URL, pasteboard: NSPasteboard) -> (window: NSWindow, catcher: ToolbarAddressCopyClickCatchingNSView)? {
        let host = NSHostingView(
            rootView: ToolbarAddressCopyControl(security: security, url: url, foreground: .white, pasteboard: pasteboard)
        )
        host.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        // NSHostingView builds its AppKit representable subviews lazily during layout.
        host.layoutSubtreeIfNeeded()

        guard let catcher = Self.firstDescendant(ofType: ToolbarAddressCopyClickCatchingNSView.self, in: host) else {
            return nil
        }
        return (window, catcher)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realClick_putsTheRawURLOnThePasteboard

    func test_realClick_putsTheRawURLOnThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OrbitAppTests-ToolbarAddressCopy-\(UUID().uuidString)"))
        let url = URL(string: "https://example.com/deep/path?q=1#frag")!

        guard let (window, catcher) = hostControl(security: .secure, url: url, pasteboard: pasteboard) else {
            XCTFail("Could not find ToolbarAddressCopyClickCatchingNSView inside the hosted control's real view hierarchy.")
            return
        }
        defer { window.orderOut(nil) }

        catcher.mouseDown(with: mouseDownEvent(at: NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY)))

        XCTAssertEqual(
            pasteboard.string(forType: .string), url.absoluteString,
            "Clicking the real, mounted hover-to-copy control must put the whole raw absolute URL on the pasteboard — the same thing ToolbarContextMenuAction.copyURL(_:to:) puts there for the header's own right-click 'Copy URL' row, so the two Toolbar surfaces never disagree about what they copy."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realHover_changesTheRenderedGlyph

    func test_realHover_changesTheRenderedGlyph() {
        let url = URL(string: "https://example.com")!
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OrbitAppTests-ToolbarAddressCopy-\(UUID().uuidString)"))
        guard let (window, catcher) = hostControl(security: .secure, url: url, pasteboard: pasteboard) else {
            XCTFail("Could not find ToolbarAddressCopyClickCatchingNSView inside the hosted control's real view hierarchy.")
            return
        }
        defer { window.orderOut(nil) }
        guard let host = window.contentView as? NSHostingView<ToolbarAddressCopyControl> else {
            XCTFail("Expected the window's content view to be the hosting view this test created.")
            return
        }

        func snapshot() -> NSBitmapImageRep? {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

        guard let restingRep = snapshot() else {
            XCTFail("Could not capture the control's resting-state render.")
            return
        }

        catcher.updateHover(atLocationInView: NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY))
        let settled = expectation(description: "hover glyph animation settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        guard let hoveredRep = snapshot() else {
            XCTFail("Could not capture the control's hovered-state render.")
            return
        }

        func averageAlpha(_ rep: NSBitmapImageRep) -> Double {
            var total = 0.0
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    total += Double(color.alphaComponent)
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : 0
        }

        XCTAssertNotEqual(
            averageAlpha(restingRep), averageAlpha(hoveredRep), accuracy: 0.0001,
            "Hovering the real, mounted control must repaint it — the resting chain link and the hovered copy icon must not render identically."
        )
    }
}

// MARK: - 4. `ToolbarView` itself: the control is a real sibling, correctly gated

@MainActor
final class ToolbarViewAddressCopyControlIntegrationTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
    }

    private func makeTab(url: String) -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func cleanup(_ tabIDs: [TabID]) {
        for id in tabIDs {
            env.state.tabs.removeValue(forKey: id)
            env.navigationStates.removeValue(forKey: id)
        }
    }

    private static func firstDescendant<T: NSView>(ofType: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let found = firstDescendant(ofType: T.self, in: subview) { return found }
        }
        return nil
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_control_isMountedForALoadedPage_andAbsentOnAnEmptyTab

    func test_control_isMountedForALoadedPage_andAbsentOnAnEmptyTab() {
        let loadedTab = makeTab(url: "https://example.com")
        defer { cleanup([loadedTab.id]) }
        env.navigationStates[loadedTab.id] = NavigationState(url: loadedTab.url, security: .secure)

        let loadedHost = NSHostingView(rootView: ToolbarView(tab: loadedTab).environment(env))
        loadedHost.frame = CGRect(x: 0, y: 0, width: 400, height: OrbitToolbarMetrics.totalHeight)
        let loadedWindow = NSWindow(contentRect: loadedHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        loadedWindow.contentView = loadedHost
        loadedWindow.orderFront(nil)
        defer { loadedWindow.orderOut(nil) }
        loadedHost.layoutSubtreeIfNeeded()

        XCTAssertNotNil(
            Self.firstDescendant(ofType: ToolbarAddressCopyClickCatchingNSView.self, in: loadedHost),
            "A loaded, secure tab must mount the hover-to-copy control's real click-catching NSView."
        )

        let emptyTab = makeTab(url: "orbit://new-tab")
        defer { cleanup([emptyTab.id]) }

        let emptyHost = NSHostingView(rootView: ToolbarView(tab: emptyTab).environment(env))
        emptyHost.frame = CGRect(x: 0, y: 0, width: 400, height: OrbitToolbarMetrics.totalHeight)
        let emptyWindow = NSWindow(contentRect: emptyHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        emptyWindow.contentView = emptyHost
        emptyWindow.orderFront(nil)
        defer { emptyWindow.orderOut(nil) }
        emptyHost.layoutSubtreeIfNeeded()

        XCTAssertNil(
            Self.firstDescendant(ofType: ToolbarAddressCopyClickCatchingNSView.self, in: emptyHost),
            "An empty tab with nothing worth copying must not mount the hover-to-copy control at all — matching the old inline icon's own `if hasLoadedPage` gate."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickingTheControlInsideARealToolbarView_copiesThatPanesOwnURL

    func test_clickingTheControlInsideARealToolbarView_copiesThatPanesOwnURL() {
        let tab = makeTab(url: "https://example.com/this-panes-own-page")
        defer { cleanup([tab.id]) }
        env.navigationStates[tab.id] = NavigationState(url: tab.url, security: .secure)

        let host = NSHostingView(rootView: ToolbarView(tab: tab).environment(env))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: OrbitToolbarMetrics.totalHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        guard let catcher = Self.firstDescendant(ofType: ToolbarAddressCopyClickCatchingNSView.self, in: host) else {
            XCTFail("Could not find the control's click-catching NSView inside a real, hosted ToolbarView.")
            return
        }

        let previousContents = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let previousContents {
                NSPasteboard.general.setString(previousContents, forType: .string)
            }
        }

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        catcher.mouseDown(with: event)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), tab.url.absoluteString)
    }
}
