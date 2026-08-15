// Never synthesize .leftMouseDragged here: it starts an uncompletable AppKit drag and hangs.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SidebarMiniPlayerClickTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?

    private let cardWidth: CGFloat = 220

    override func setUp() {
        super.setUp()
        env._test_webContentsFactory = { _, url in
            let contents = MockWebContents()
            contents.navigationState = NavigationState(url: url)
            return contents
        }
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Hosts a real `SidebarMiniPlayerView` for `tab`, always expanded (matches a hovered card,
    /// which is when the title row this defect is about is even on screen).
    private func hostMiniPlayer(tab: Orbit.Tab, theme: SpaceTheme) -> NSView {
        let content = SidebarMiniPlayerView(tab: tab, theme: theme, alwaysExpanded: true)
            .environment(env)
            .frame(width: cardWidth, alignment: .topLeading)

        let hostView = NSHostingView(rootView: content)
        let fitting = hostView.fittingSize
        let size = CGSize(width: cardWidth, height: max(fitting.height, 1))
        hostView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        self.window = window
        return hostView
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        window.sendEvent(mouseEvent(.leftMouseDown, at: point, in: window))
        window.sendEvent(mouseEvent(.leftMouseUp, at: point, in: window))
    }

    private func toolTipBackingViews(in root: NSView) -> [OrbitTooltipBackingView] {
        var result: [OrbitTooltipBackingView] = []
        if let backing = root as? OrbitTooltipBackingView {
            result.append(backing)
        }
        for subview in root.subviews {
            result.append(contentsOf: toolTipBackingViews(in: subview))
        }
        return result
    }

    /// The real on-screen (window-coordinate) rect of the control whose `.orbitTooltip(text)` this
    /// is — exactly the rect AppKit itself would hit-test, not a hand-computed guess at it.
    private func windowFrame(forTooltip text: String, in hostView: NSView) -> NSRect {
        guard let backing = toolTipBackingViews(in: hostView).first(where: { $0.tooltipText == text }) else {
            XCTFail("No control tagged with tooltip '\(text)' was found in the hosted mini-player.")
            return .zero
        }
        return backing.convert(backing.bounds, to: nil)
    }

    // MARK: - Fixture

    /// A tab playing media in a Space that is NOT the currently active one — the exact case the
    /// defect report calls out: the playing tab may be in a different Space than the active one.
    private func fixture_playingTabInAnotherSpace() -> (activeSpace: SpaceID, playingSpace: SpaceID, playingTab: TabID) {
        let profileID = env.createDefaultProfileIfNeeded()
        let activeSpace = env.createSpace(
            name: "Active Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID
        )
        let playingSpace = env.createSpace(
            name: "Playing Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID
        )
        env.selectSpace(activeSpace)

        let playingTab = env.openTab(url: URL(string: "https://open.spotify.com/mini-player-click")!, in: playingSpace, activate: false)
        let contents = MockWebContents()
        contents.mediaState = MediaState(
            isAudible: true,
            hasVideo: true,
            hasActiveMediaSession: true,
            isPictureInPictureAvailable: false,
            nowPlayingTitle: "Saturdays (feat. HAIM)",
            nowPlayingArtist: "Twin Shadow",
            isPlaying: true
        )
        env._test_attachWebContents(contents, for: playingTab)

        XCTAssertEqual(env.activeSpace?.id, activeSpace, "test precondition: a DIFFERENT Space is active")
        XCTAssertTrue(
            env.nowPlayingTabs.map(\.id).contains(playingTab),
            "test precondition: the tab must actually be in the tray"
        )
        return (activeSpace, playingSpace, playingTab)
    }

    // MARK: - 1. A real click on the title switches to that tab, carrying the Space with it

    func test_realClick_onTitle_switchesToThatTabAndItsSpace() {
        let fixture = fixture_playingTabInAnotherSpace()
        guard let tab = env.tab(fixture.playingTab) else { return XCTFail("test precondition: tab missing") }

        let hostView = hostMiniPlayer(tab: tab, theme: SpaceTheme())
        guard let window else { return XCTFail("test precondition: no window") }

        let rowFrame = windowFrame(forTooltip: "Go to Tab", in: hostView)
        XCTAssertGreaterThan(rowFrame.width, 0, "test precondition: the title row must have real bounds")

        // +60 clears the favicon and its spacing, landing in the title text.
        let titlePoint = NSPoint(x: rowFrame.minX + 60, y: rowFrame.midY)

        click(at: titlePoint, in: window)
        pump(seconds: 0.3)

        XCTAssertEqual(env.activeTabID, fixture.playingTab, "clicking the title must switch to the playing tab")
        XCTAssertEqual(
            env.activeSpace?.id, fixture.playingSpace,
            "the playing tab lives in a different Space than the one that was active — activating it must carry the Space switch with it"
        )
    }

    // MARK: - 2. A real click on the favicon switches to that tab

    func test_realClick_onFavicon_switchesToThatTab() {
        let fixture = fixture_playingTabInAnotherSpace()
        guard let tab = env.tab(fixture.playingTab) else { return XCTFail("test precondition: tab missing") }

        let hostView = hostMiniPlayer(tab: tab, theme: SpaceTheme())
        guard let window else { return XCTFail("test precondition: no window") }

        let rowFrame = windowFrame(forTooltip: "Go to Tab", in: hostView)
        let faviconPoint = NSPoint(x: rowFrame.minX + OrbitMetrics.iconFavicon / 2, y: rowFrame.midY)

        click(at: faviconPoint, in: window)
        pump(seconds: 0.3)

        XCTAssertEqual(env.activeTabID, fixture.playingTab, "clicking the favicon must switch to the playing tab")
    }

    // MARK: - 3. A real click on play/pause must NOT also switch tabs

    // Proves a real control's click never also reaches the catcher underneath it.
    func test_realClick_onPlayPause_doesNotSwitchTabs() throws {
        let fixture = fixture_playingTabInAnotherSpace()
        guard let tab = env.tab(fixture.playingTab) else { return XCTFail("test precondition: tab missing") }
        XCTAssertNil(env.activeTabID, "test precondition: nothing is active yet")

        let hostView = hostMiniPlayer(tab: tab, theme: SpaceTheme())
        guard let window else { return XCTFail("test precondition: no window") }

        // Fixture sets isPlaying: true, so the transport control's own tooltip reads "Pause".
        let playPausePoint = try XCTUnwrap(
            centreOrNil(forTooltip: "Pause", in: hostView),
            "test precondition: the play/pause control must be on screen"
        )

        click(at: playPausePoint, in: window)
        pump(seconds: 0.3)

        XCTAssertNil(
            env.activeTabID,
            "a click on play/pause must never also activate the tab underneath it via the title row's own click catcher"
        )
    }

    // MARK: - 4. A real click on the close ("Hide Player") button still only dismisses the card

    // The close button overlaps the catcher; AppKit's hit test must give its region to the button.
    func test_realClick_onClose_dismissesWithoutActivatingTheTab() {
        let fixture = fixture_playingTabInAnotherSpace()
        guard let tab = env.tab(fixture.playingTab) else { return XCTFail("test precondition: tab missing") }
        XCTAssertNil(env.activeTabID, "test precondition: nothing is active yet")

        let hostView = hostMiniPlayer(tab: tab, theme: SpaceTheme())
        guard let window else { return XCTFail("test precondition: no window") }

        let closeFrame = windowFrame(forTooltip: "Hide Player", in: hostView)
        let closePoint = NSPoint(x: closeFrame.midX, y: closeFrame.midY)

        click(at: closePoint, in: window)
        pump(seconds: 0.3)

        XCTAssertNil(env.activeTabID, "the close control's own region must not also reach the row's activation catcher underneath it")
        XCTAssertFalse(
            env.nowPlayingTabs.map(\.id).contains(fixture.playingTab),
            "the click must still dismiss the mini-player card, exactly as before this fix"
        )
    }

    // MARK: - 5. A real click on the speaker control mutes/unmutes, and does not switch tabs

    func test_realClick_onSpeaker_togglesMutedAndDoesNotSwitchTabs() throws {
        let fixture = fixture_playingTabInAnotherSpace()
        guard let tab = env.tab(fixture.playingTab) else { return XCTFail("test precondition: tab missing") }
        XCTAssertNil(env.activeTabID, "test precondition: nothing is active yet")
        XCTAssertFalse(tab.isMuted, "test precondition: the tab starts unmuted")

        let hostView = hostMiniPlayer(tab: tab, theme: SpaceTheme())
        guard let window else { return XCTFail("test precondition: no window") }

        let mutePoint = try XCTUnwrap(
            centreOrNil(forTooltip: "Mute", in: hostView),
            "test precondition: the speaker control must be on screen"
        )

        click(at: mutePoint, in: window)
        pump(seconds: 0.3)

        XCTAssertEqual(env.tab(fixture.playingTab)?.isMuted, true, "a real click on the speaker control must mute the tab")
        XCTAssertNil(
            env.activeTabID,
            "a click on the speaker control must never also activate the tab underneath it via the title row's own click catcher"
        )

        // `tab` is a snapshot, not re-read from env, so re-host to get the Unmute control.
        guard let mutedTab = env.tab(fixture.playingTab) else { return XCTFail("test precondition: tab missing") }
        self.window?.orderOut(nil)
        let hostView2 = hostMiniPlayer(tab: mutedTab, theme: SpaceTheme())
        guard let window2 = self.window else { return XCTFail("test precondition: no window") }

        let unmutePoint = try XCTUnwrap(
            centreOrNil(forTooltip: "Unmute", in: hostView2),
            "the speaker control's tooltip must read 'Unmute' once the tab is muted"
        )
        click(at: unmutePoint, in: window2)
        pump(seconds: 0.3)

        XCTAssertEqual(env.tab(fixture.playingTab)?.isMuted, false, "a second real click on the speaker control must unmute the tab")
    }

    private func centreOrNil(forTooltip text: String, in hostView: NSView) -> NSPoint? {
        guard let backing = toolTipBackingViews(in: hostView).first(where: { $0.tooltipText == text }) else {
            return nil
        }
        let frame = backing.convert(backing.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }
}
