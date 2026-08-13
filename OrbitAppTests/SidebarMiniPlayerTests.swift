import SwiftUI
import XCTest
@testable import Orbit

/// `MockWebContents` is shared infrastructure owned elsewhere and not to be extended here; it implements `togglePictureInPicture()` with no counter and always returns `nil` from `evaluateJavaScript`, so it can't exercise the success half of `AppEnvironment.mediaTransport`. This records both.
@MainActor
private final class RecordingMediaWebContents: NSObject, WebContents {
    // Deliberately not the owning TabID, exactly like the real backends.
    let id = UUID()
    let session: EngineSession
    weak var delegate: WebContentsDelegate?

    var navigationState: NavigationState = .empty
    var mediaState: MediaState = .idle
    var zoomFactor: Double = 1.0
    var isClosed = false

    private(set) var evaluatedScripts: [String] = []
    private(set) var pictureInPictureToggleCount = 0
    private(set) var muteCalls: [Bool] = []

    var scriptResult: Any?

    override convenience init() {
        self.init(session: MockEngineSession())
    }

    init(session: EngineSession) {
        self.session = session
    }

    func load(_ url: URL) { navigationState.url = url }
    func loadHTML(_ html: String, baseURL: URL?) {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func goBack() {}
    func goForward() {}
    func go(offset: Int) {}
    func sessionHistory() -> [SessionHistoryEntry] { [] }
    func currentCertificate() -> SiteCertificate? { nil }

    @discardableResult
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        evaluatedScripts.append(script)
        return scriptResult
    }

    func injectUserScript(_ script: UserScript) {}
    func find(_ text: String, options: FindOptions) {}
    func stopFinding(clearSelection: Bool) {}

    func cut() {}
    func copy() {}
    func paste() {}
    func selectAll() {}

    func setZoomFactor(_ factor: Double) { zoomFactor = factor }

    func setPreferredColorScheme(_ scheme: ContentColorScheme?) {}

    func setMuted(_ muted: Bool) {
        muteCalls.append(muted)
        mediaState.isMuted = muted
    }

    func togglePictureInPicture() { pictureInPictureToggleCount += 1 }

    func capturePreview(rect: CGRect?, size: CGSize) async -> NSImage? { nil }
    func print() {}
    func savePage() {}
    func cancelDownload(id: UUID) {}
    func showDeveloperTools(inspectAt point: CGPoint?) {}
    func closeDeveloperTools() {}
    func focus() {}
    func close() { isClosed = true }

    lazy var view: NSView = NSView(frame: .zero)
}

@MainActor
// Excluded renders below: a MeshGradient theme render stalls past five minutes on a hosted runner.
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class SidebarMiniPlayerTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func twoTabs() throws -> (spaceID: SpaceID, playing: TabID, other: TabID) {
        let spaceID = try XCTUnwrap(env.spaces.first?.id)
        let playing = env.openTab(url: URL(string: "https://open.spotify.com/")!, in: spaceID, activate: false)
        let other = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID, activate: true)
        return (spaceID, playing, other)
    }

    private func makePlaying(
        _ tabID: TabID,
        title: String? = "Saturdays (feat. HAIM)",
        artist: String? = "Twin Shadow"
    ) -> RecordingMediaWebContents {
        let contents = RecordingMediaWebContents()
        contents.mediaState = Self.playingState(title: title, artist: artist)
        env._test_attachWebContents(contents, for: tabID)
        return contents
    }

    private static func playingState(
        title: String? = "Saturdays (feat. HAIM)",
        artist: String? = "Twin Shadow"
    ) -> MediaState {
        MediaState(
            isAudible: true,
            hasVideo: true,
            hasActiveMediaSession: true,
            nowPlayingTitle: title,
            nowPlayingArtist: artist,
            isPlaying: true
        )
    }

    // What the observer reports one event after pause: both isPlaying and
    // isAudible go false together, while the element is still loaded.
    private static func pausedState(
        title: String? = "Saturdays (feat. HAIM)",
        artist: String? = "Twin Shadow"
    ) -> MediaState {
        MediaState(
            isAudible: false,
            hasVideo: true,
            hasActiveMediaSession: true,
            nowPlayingTitle: title,
            nowPlayingArtist: artist,
            isPlaying: false
        )
    }

    private static let stoppedState = MediaState()

    // MARK: - Which tabs are in the tray

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aTabPlayingInTheBackground_appearsInTheTray

    func test_aTabPlayingInTheBackground_appearsInTheTray() throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing)

        XCTAssertEqual(
            env.nowPlayingTabs.map(\.id), [tabs.playing],
            "Arc adds the Audio Player when you leave an audio tab; this is that tab."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theTabYouAreLookingAt_isNotInTheTray

    func test_theTabYouAreLookingAt_isNotInTheTray() throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing)
        env.activateTab(tabs.playing)

        XCTAssertTrue(
            env.nowPlayingTabs.isEmpty,
            "The active tab must not get a card — you are already looking at the player."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aSilentTab_isNotInTheTray

    func test_aSilentTab_isNotInTheTray() throws {
        let tabs = try twoTabs()
        let contents = RecordingMediaWebContents()
        contents.mediaState = .idle
        env._test_attachWebContents(contents, for: tabs.playing)

        XCTAssertTrue(env.nowPlayingTabs.isEmpty)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theTrayHoldsEveryBackgroundTabProducingMedia

    func test_theTrayHoldsEveryBackgroundTabProducingMedia() throws {
        let tabs = try twoTabs()
        let third = env.openTab(url: URL(string: "https://music.youtube.com/")!, in: tabs.spaceID, activate: false)
        _ = makePlaying(tabs.playing)
        _ = makePlaying(third)

        XCTAssertEqual(
            Set(env.nowPlayingTabs.map(\.id)), [tabs.playing, third],
            "Arc's is a 'multi media tray' (release notes, 2022-10-06), not a single slot."
        )
    }

    // MARK: - Dismissal

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_dismissing_removesTheCardWithoutStoppingPlayback

    func test_dismissing_removesTheCardWithoutStoppingPlayback() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)

        env.dismissMiniPlayer(for: tabs.playing)

        XCTAssertTrue(env.nowPlayingTabs.isEmpty, "The X removes the card.")
        XCTAssertTrue(
            env.mediaStates[tabs.playing]?.isPlaying ?? false,
            "Arc's wording is 'remove the Audio Player from your sidebar' — the music keeps playing."
        )
        XCTAssertTrue(contents.evaluatedScripts.isEmpty, "Dismissing must not send a transport action.")
        XCTAssertTrue(contents.muteCalls.isEmpty, "Dismissing must not mute the tab either.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_whenTheMediaStops_theDismissalIsLiftedAndTheCardCanReturn

    func test_whenTheMediaStops_theDismissalIsLiftedAndTheCardCanReturn() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        env.dismissMiniPlayer(for: tabs.playing)
        XCTAssertTrue(env.nowPlayingTabs.isEmpty)

        env.webContents(contents, didChangeMediaState: Self.stoppedState)
        XCTAssertTrue(env.nowPlayingTabs.isEmpty, "Nothing is loaded any more, so there is still no card.")

        env.webContents(contents, didChangeMediaState: Self.playingState())

        XCTAssertEqual(
            env.nowPlayingTabs.map(\.id), [tabs.playing],
            "The next listening session must get its card back rather than staying permanently dismissed."
        )
    }

    // MARK: - Pause

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pausing_keepsTheCardSoItsPlayButtonCanResume

    func test_pausing_keepsTheCardSoItsPlayButtonCanResume() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        XCTAssertEqual(env.nowPlayingTabs.map(\.id), [tabs.playing], "Precondition: the card is up.")

        env.webContents(contents, didChangeMediaState: Self.pausedState())

        XCTAssertEqual(
            env.nowPlayingTabs.map(\.id), [tabs.playing],
            "Pausing removed the card, so its play button could never be used to resume."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_whenTheMediaEnds_theCardGoes

    func test_whenTheMediaEnds_theCardGoes() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)

        env.webContents(contents, didChangeMediaState: Self.pausedState())
        XCTAssertFalse(env.nowPlayingTabs.isEmpty, "Precondition: paused keeps the card.")

        env.webContents(contents, didChangeMediaState: Self.stoppedState)

        XCTAssertTrue(
            env.nowPlayingTabs.isEmpty,
            "The media ended, the element was torn down or the page navigated away — the card must go."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aTabWithAVideoNobodyEverPlayed_isNotInTheTray

    func test_aTabWithAVideoNobodyEverPlayed_isNotInTheTray() throws {
        let tabs = try twoTabs()
        let contents = RecordingMediaWebContents()
        contents.mediaState = MediaState(hasVideo: true)
        env._test_attachWebContents(contents, for: tabs.playing)

        XCTAssertTrue(
            env.nowPlayingTabs.isEmpty,
            "hasVideo alone must not summon a card; nothing has ever played in this tab."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pausing_doesNotLiftADismissal

    func test_pausing_doesNotLiftADismissal() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        env.dismissMiniPlayer(for: tabs.playing)
        XCTAssertTrue(env.nowPlayingTabs.isEmpty, "Precondition: the user hid it.")

        env.webContents(contents, didChangeMediaState: Self.pausedState())

        XCTAssertTrue(
            env.nowPlayingTabs.isEmpty,
            "A pause resurrected a card the user had explicitly dismissed."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aPausedTabIsStillExemptFromAutoArchive

    func test_aPausedTabIsStillExemptFromAutoArchive() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        env.webContents(contents, didChangeMediaState: Self.playingState())
        XCTAssertTrue(env.store.tabsPlayingMedia.contains(tabs.playing), "Precondition.")

        env.webContents(contents, didChangeMediaState: Self.pausedState())
        XCTAssertTrue(
            env.store.tabsPlayingMedia.contains(tabs.playing),
            "Pausing made the tab auto-archivable again, against Arc's own rule."
        )

        env.webContents(contents, didChangeMediaState: Self.stoppedState)
        XCTAssertFalse(
            env.store.tabsPlayingMedia.contains(tabs.playing),
            "...but a tab whose media really has ended must stop being exempt."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aPausedTabIsStillProtectedFromRendererRelease

    func test_aPausedTabIsStillProtectedFromRendererRelease() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        XCTAssertTrue(env.rendererPolicyProtectedTabIDs.contains(tabs.playing), "Precondition.")

        env.webContents(contents, didChangeMediaState: Self.pausedState())
        XCTAssertTrue(
            env.rendererPolicyProtectedTabIDs.contains(tabs.playing),
            "A paused tab lost its renderer protection and could be unloaded mid-session."
        )

        env.webContents(contents, didChangeMediaState: Self.stoppedState)
        XCTAssertFalse(
            env.rendererPolicyProtectedTabIDs.contains(tabs.playing),
            "...and a tab with nothing loaded must not hold a renderer forever on the strength of it."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pausing_doesNotFireThePictureInPictureDismissal

    func test_pausing_doesNotFireThePictureInPictureDismissal() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        var dismissedTabs: [TabID] = []
        env.extensionPoints.dismissPictureInPicture = { dismissedTabs.append($0) }
        defer { env.extensionPoints.dismissPictureInPicture = nil }

        env.webContents(contents, didChangeMediaState: Self.pausedState())
        XCTAssertTrue(dismissedTabs.isEmpty, "Pausing a floating video closed its picture-in-picture window.")

        env.webContents(contents, didChangeMediaState: Self.stoppedState)
        XCTAssertEqual(
            dismissedTabs, [tabs.playing],
            "...but media that really has stopped must still bring the window down."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_thePlayGlyphIsReachable_aTabCanBeInTheTrayWhileNotPlaying

    func test_thePlayGlyphIsReachable_aTabCanBeInTheTrayWhileNotPlaying() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)

        env.webContents(contents, didChangeMediaState: Self.pausedState())

        let inTray = env.nowPlayingTabs.map(\.id)
        XCTAssertEqual(inTray, [tabs.playing])
        XCTAssertEqual(
            env.mediaStates[tabs.playing]?.isPlaying, false,
            "The card is drawn for a tab that is not playing, which is exactly when the play glyph shows."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_dismissingOneCard_leavesTheOtherAlone

    func test_dismissingOneCard_leavesTheOtherAlone() throws {
        let tabs = try twoTabs()
        let third = env.openTab(url: URL(string: "https://music.youtube.com/")!, in: tabs.spaceID, activate: false)
        _ = makePlaying(tabs.playing)
        _ = makePlaying(third)

        env.dismissMiniPlayer(for: tabs.playing)

        XCTAssertEqual(env.nowPlayingTabs.map(\.id), [third])
    }

    // MARK: - The label

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theLabelIsTitleThenArtist_asArcRendersIt

    func test_theLabelIsTitleThenArtist_asArcRendersIt() throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing)

        XCTAssertEqual(env.nowPlayingLabel(for: tabs.playing), "Saturdays (feat. HAIM) • Twin Shadow")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_withNoArtist_theLabelIsJustTheTitle

    func test_withNoArtist_theLabelIsJustTheTitle() throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing, artist: nil)

        XCTAssertEqual(env.nowPlayingLabel(for: tabs.playing), "Saturdays (feat. HAIM)")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_withNoMediaSessionMetadata_theLabelFallsBackToTheTabsOwnTitle

    func test_withNoMediaSessionMetadata_theLabelFallsBackToTheTabsOwnTitle() throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing, title: nil, artist: nil)
        env.renameTab(tabs.playing, to: "Spotify Web Player")

        XCTAssertEqual(env.nowPlayingLabel(for: tabs.playing), "Spotify Web Player")
    }

    // MARK: - Transport

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_nextTrack_sendsTheNextTrackInvocationToThatTabsPage

    func test_nextTrack_sendsTheNextTrackInvocationToThatTabsPage() async throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        contents.scriptResult = true

        let handled = await env.mediaTransport(.nextTrack, for: tabs.playing)

        XCTAssertTrue(handled)
        XCTAssertEqual(contents.evaluatedScripts.count, 1)
        XCTAssertEqual(
            contents.evaluatedScripts.first,
            MediaTransportScript.invocation(for: .nextTrack),
            "The card must send the real invocation, not a hand-rolled string."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_whenThePageHasNothingToDo_transportReportsFailure

    func test_whenThePageHasNothingToDo_transportReportsFailure() async throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        contents.scriptResult = false

        let handled = await env.mediaTransport(.nextTrack, for: tabs.playing)

        XCTAssertFalse(handled)
        XCTAssertEqual(contents.evaluatedScripts.count, 1, "It still asked the page — it just got told no.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_transportOnATabWithNoLiveContents_doesNothing

    func test_transportOnATabWithNoLiveContents_doesNothing() async throws {
        let tabs = try twoTabs()

        let handled = await env.mediaTransport(.nextTrack, for: tabs.playing)

        XCTAssertFalse(handled)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_playPause_sendsPauseWhilePlayingAndPlayWhilePaused

    func test_playPause_sendsPauseWhilePlayingAndPlayWhilePaused() async throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        contents.scriptResult = true

        await env.toggleMediaPlayback(for: tabs.playing)
        XCTAssertEqual(contents.evaluatedScripts.last, MediaTransportScript.invocation(for: .pause))

        env.webContents(contents, didChangeMediaState: Self.pausedState())
        XCTAssertEqual(
            env.nowPlayingTabs.map(\.id), [tabs.playing],
            "There has to still be a card for the user to press play on."
        )

        await env.toggleMediaPlayback(for: tabs.playing)
        XCTAssertEqual(contents.evaluatedScripts.last, MediaTransportScript.invocation(for: .play))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_transportGoesToTheTabItWasSentTo_notWhicheverTabIsActive

    func test_transportGoesToTheTabItWasSentTo_notWhicheverTabIsActive() async throws {
        let tabs = try twoTabs()
        let playing = makePlaying(tabs.playing)
        let otherContents = RecordingMediaWebContents()
        env._test_attachWebContents(otherContents, for: tabs.other)

        await env.mediaTransport(.nextTrack, for: tabs.playing)

        XCTAssertEqual(playing.evaluatedScripts.count, 1)
        XCTAssertTrue(
            otherContents.evaluatedScripts.isEmpty,
            "Transport must be routed by TabID, never to whatever contents happened to be handy."
        )
    }

    // MARK: - Mute

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theSpeakerControl_mutesTheTabForReal

    func test_theSpeakerControl_mutesTheTabForReal() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)

        env.muteTab(tabs.playing, muted: true)

        XCTAssertEqual(contents.muteCalls, [true], "Mute must reach the engine, not just the model.")
        XCTAssertTrue(env.tab(tabs.playing)?.isMuted ?? false, "...and must be recorded on the tab, which is what the glyph reads.")
    }

    // MARK: - Picture-in-picture

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_withoutTheEngineCapability_thePictureInPictureControlIsNotDrawn

    func test_withoutTheEngineCapability_thePictureInPictureControlIsNotDrawn() throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing)
        env._test_engineCapabilitiesOverride = [.audioMuting]

        XCTAssertFalse(env.canDrivePictureInPicture(for: tabs.playing))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_withTheCapabilityButNoLiveContents_thePictureInPictureControlIsNotDrawn

    func test_withTheCapabilityButNoLiveContents_thePictureInPictureControlIsNotDrawn() throws {
        let tabs = try twoTabs()
        env._test_engineCapabilitiesOverride = [.pictureInPicture]

        XCTAssertFalse(
            env.canDrivePictureInPicture(for: tabs.playing),
            "There is nothing to send the toggle to."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_withTheCapability_theControlIsDrawnAndReachesTheEngine

    func test_withTheCapability_theControlIsDrawnAndReachesTheEngine() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        env._test_engineCapabilitiesOverride = [.pictureInPicture]

        XCTAssertTrue(env.canDrivePictureInPicture(for: tabs.playing))
        XCTAssertTrue(env.toggleMiniPlayerPictureInPicture(for: tabs.playing))
        XCTAssertEqual(contents.pictureInPictureToggleCount, 1)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theToggleRefusesWithoutTheCapability_evenIfSomethingDrewTheButton

    func test_theToggleRefusesWithoutTheCapability_evenIfSomethingDrewTheButton() throws {
        let tabs = try twoTabs()
        let contents = makePlaying(tabs.playing)
        env._test_engineCapabilitiesOverride = []

        XCTAssertFalse(env.toggleMiniPlayerPictureInPicture(for: tabs.playing))
        XCTAssertEqual(contents.pictureInPictureToggleCount, 0)
    }

    // MARK: - Rendering

    private var theme: SpaceTheme {
        env.spaces.first?.theme ?? SpaceTheme()
    }

    // ImageRenderer in this process caches a rasterisation keyed by view type and size, so a second render of the same view at the same size returns a stale bitmap; renderSequence makes each render size unique to avoid it.
    private static var renderSequence = 0

    private func renderTray(alwaysExpanded: Bool) async -> RenderedImage {
        Self.renderSequence += 1
        return await renderForScreenshot(
            SidebarMiniPlayerTray(theme: theme, alwaysExpanded: alwaysExpanded).environment(env),
            size: CGSize(
                width: OrbitMetrics.sidebarDefaultWidth,
                height: Self.renderBaseHeight + CGFloat(Self.renderSequence)
            )
        )
    }

    private static let renderBaseHeight: CGFloat = 200

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_withNothingPlaying_theTrayDrawsNothing

    func test_withNothingPlaying_theTrayDrawsNothing() async {
        let box = await renderTray(alwaysExpanded: false).boundingBoxOfContent()
        XCTAssertNil(
            box,
            "Nothing is playing, so the sidebar must look exactly as it did before this feature existed."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_withATabPlaying_theTrayActuallyDraws

    func test_withATabPlaying_theTrayActuallyDraws() async throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing)

        let drawn = await renderTray(alwaysExpanded: false).boundingBoxOfContent()
        let box = try XCTUnwrap(drawn, "A tab is playing in the background and the tray drew nothing.")
        XCTAssertGreaterThan(box.width, 0)
        XCTAssertGreaterThan(box.height, 0)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theHoveredCardIsTallerThanTheIdleRow

    func test_theHoveredCardIsTallerThanTheIdleRow() async throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing)
        env._test_engineCapabilitiesOverride = [.pictureInPicture]

        let idleBox = await renderTray(alwaysExpanded: false).boundingBoxOfContent()
        let expandedBox = await renderTray(alwaysExpanded: true).boundingBoxOfContent()
        let idle = try XCTUnwrap(idleBox)
        let expanded = try XCTUnwrap(expandedBox)

        XCTAssertGreaterThan(
            expanded.height, idle.height,
            "The hovered card adds a whole row (favicon + title + close) above the controls."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_dismissing_stopsTheTrayDrawing

    func test_dismissing_stopsTheTrayDrawing() async throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing)
        let before = await renderTray(alwaysExpanded: true).boundingBoxOfContent()
        XCTAssertNotNil(before)

        env.dismissMiniPlayer(for: tabs.playing)

        let after = await renderTray(alwaysExpanded: true).boundingBoxOfContent()
        XCTAssertNil(after)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_thePictureInPictureControlIsDrawnOnlyWhenTheEngineCanDriveIt

    func test_thePictureInPictureControlIsDrawnOnlyWhenTheEngineCanDriveIt() async throws {
        let tabs = try twoTabs()
        _ = makePlaying(tabs.playing)

        env._test_engineCapabilitiesOverride = []
        let withoutImage = await renderTray(alwaysExpanded: true)
        let without = drawnPixelCount(withoutImage)

        env._test_engineCapabilitiesOverride = [.pictureInPicture]
        let withImage = await renderTray(alwaysExpanded: true)
        let with = drawnPixelCount(withImage)

        XCTAssertGreaterThan(
            with, without,
            "With the capability the control row gains a fifth glyph, so it must draw more ink."
        )
    }

    // Counts near-opaque glyph ink, not every non-transparent pixel: the card's own fill is semi-transparent, so a whole-card count would measure the card's area rather than what is actually drawn.
    private func drawnPixelCount(_ image: RenderedImage) -> Int {
        var count = 0
        for y in 0..<Int(image.pointSize.height) {
            for x in 0..<Int(image.pointSize.width) where image.color(atX: x, y: y).a > 0.5 {
                count += 1
            }
        }
        return count
    }

    // MARK: - Both engines install the transport script

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_bothBackendsInstallTheSameTransportSource

    func test_bothBackendsInstallTheSameTransportSource() {
        XCTAssertTrue(
            MediaTransportScript.source.contains("__orbitMediaTransport"),
            "The invocation calls window.__orbitMediaTransport; the installed source must define it."
        )
        XCTAssertTrue(
            MediaTransportScript.source.contains("setActionHandler"),
            "Previous/next depend entirely on capturing the page's own handlers."
        )
    }
}
