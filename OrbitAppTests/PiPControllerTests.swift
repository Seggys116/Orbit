import XCTest
@testable import Orbit

@MainActor
final class PiPControllerTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PiPController.shared._test_reset()
        env._test_engineCapabilitiesOverride = [.pictureInPicture]
    }

    override func tearDown() {
        PiPController.shared._test_reset()
        super.tearDown()
    }

    private var controller: PiPController { PiPController.shared }

    private func videoTabAndAnother() throws -> (video: TabID, other: TabID, contents: MockWebContents) {
        let spaceID = try XCTUnwrap(env.spaces.first?.id)
        let video = env.openTab(url: URL(string: "https://video.example.com/watch")!, in: spaceID, activate: true)
        let other = env.openTab(url: URL(string: "https://example.com/")!, in: spaceID, activate: false)
        let contents = MockWebContents()
        contents.mediaState = MediaState(hasVideo: true, hasActiveMediaSession: true, isPictureInPictureAvailable: true, isPlaying: true)
        env._test_attachWebContents(contents, for: video)
        // Seeds the controller's last-active tab so the first tick is not itself a spurious focus change.
        PiPController.shared._test_seedLastActiveTab(env.activeTabID)
        return (video, other, contents)
    }

    private func reportPictureInPicture(_ active: Bool, for tabID: TabID, contents: MockWebContents) {
        contents.mediaState.isPictureInPictureActive = active
        env.mediaStates[tabID]?.isPictureInPictureActive = active
    }

    // MARK: - Requesting

    func test_aVideoTabLosingFocus_isAskedToEnterPictureInPicture() throws {
        let tabs = try videoTabAndAnother()

        env.activateTab(tabs.other)
        controller.tick(env: env)

        XCTAssertEqual(
            tabs.contents.togglePictureInPictureCallCount, 1,
            "Leaving a tab with playing video must ask it to float."
        )
    }

    func test_anAudioOnlyTabLosingFocus_isNotAskedToEnterPictureInPicture() throws {
        let tabs = try videoTabAndAnother()
        tabs.contents.mediaState = MediaState(isAudible: true, hasActiveMediaSession: true, isPlaying: true)
        env.mediaStates[tabs.video] = tabs.contents.mediaState

        env.activateTab(tabs.other)
        controller.tick(env: env)

        XCTAssertEqual(tabs.contents.togglePictureInPictureCallCount, 0)
    }

    func test_withoutTheEngineCapability_nothingIsRequested() throws {
        let tabs = try videoTabAndAnother()
        env._test_engineCapabilitiesOverride = [.audioMuting]

        XCTAssertFalse(controller.requestPiP(for: tabs.video, env: env))
        XCTAssertEqual(tabs.contents.togglePictureInPictureCallCount, 0)
    }

    // MARK: - `pipTabID` tells the truth

    func test_whenTheRequestIsRefused_pipTabIDIsNeverSet() throws {
        let tabs = try videoTabAndAnother()

        XCTAssertTrue(controller.requestPiP(for: tabs.video, env: env), "The request was dispatched.")
        XCTAssertNil(controller.pipTabID, "Asking is not succeeding; nothing has confirmed yet.")

        for _ in 0...PiPController.confirmationTicks {
            controller.tick(env: env)
        }

        XCTAssertNil(
            controller.pipTabID,
            "Orbit recorded a tab as floating in picture-in-picture that the browser refused to float."
        )
        XCTAssertFalse(
            controller._test_hasPendingRequest(for: tabs.video),
            "A request that was never confirmed must be written off, not left outstanding forever."
        )
    }

    func test_whenThePageConfirms_pipTabIDIsSet() throws {
        let tabs = try videoTabAndAnother()
        XCTAssertTrue(controller.requestPiP(for: tabs.video, env: env))

        reportPictureInPicture(true, for: tabs.video, contents: tabs.contents)
        controller.tick(env: env)

        XCTAssertEqual(controller.pipTabID, tabs.video)
        XCTAssertFalse(controller._test_hasPendingRequest(for: tabs.video))
    }

    func test_afterARefusedRequest_theTabCanBeAskedAgain() throws {
        let tabs = try videoTabAndAnother()
        env.activateTab(tabs.other)
        controller.tick(env: env)
        XCTAssertEqual(tabs.contents.togglePictureInPictureCallCount, 1, "Precondition.")

        for _ in 0...PiPController.confirmationTicks {
            controller.tick(env: env)
        }

        env.activateTab(tabs.video)
        controller.tick(env: env)
        env.activateTab(tabs.other)
        controller.tick(env: env)

        XCTAssertEqual(
            tabs.contents.togglePictureInPictureCallCount, 2,
            "The second attempt was suppressed by bookkeeping left over from the first."
        )
    }

    // MARK: - Dismissing

    func test_refocusingThePictureInPictureTab_dismissesIt() throws {
        let tabs = try videoTabAndAnother()
        XCTAssertTrue(controller.requestPiP(for: tabs.video, env: env))
        reportPictureInPicture(true, for: tabs.video, contents: tabs.contents)
        controller.tick(env: env)
        XCTAssertEqual(controller.pipTabID, tabs.video, "Precondition: it is floating.")

        env.activateTab(tabs.other)
        controller.tick(env: env)
        env.activateTab(tabs.video)
        controller.tick(env: env)

        XCTAssertNil(controller.pipTabID, "Coming back to the tab must end its floating window.")
        XCTAssertEqual(
            tabs.contents.togglePictureInPictureCallCount, 2,
            "The exit has to reach the engine, not just clear Orbit's bookkeeping."
        )
    }

    func test_dismissingATabThatIsNotFloating_doesNothing() throws {
        let tabs = try videoTabAndAnother()

        controller.dismissPiP(for: tabs.video, env: env)

        XCTAssertNil(controller.pipTabID)
        XCTAssertEqual(tabs.contents.togglePictureInPictureCallCount, 0)
    }

    func test_returningBeforeTheRequestIsConfirmed_cancelsIt() throws {
        let tabs = try videoTabAndAnother()
        XCTAssertTrue(controller.requestPiP(for: tabs.video, env: env))
        XCTAssertTrue(controller._test_hasPendingRequest(for: tabs.video), "Precondition.")

        controller.dismissPiP(for: tabs.video, env: env)
        reportPictureInPicture(true, for: tabs.video, contents: tabs.contents)
        controller.tick(env: env)

        XCTAssertNil(
            controller.pipTabID,
            "A cancelled request was still promoted when the page reported late."
        )
    }

    func test_aPause_doesNotDismissPictureInPicture() throws {
        let tabs = try videoTabAndAnother()
        XCTAssertTrue(controller.requestPiP(for: tabs.video, env: env))
        reportPictureInPicture(true, for: tabs.video, contents: tabs.contents)
        controller.tick(env: env)
        XCTAssertEqual(controller.pipTabID, tabs.video, "Precondition: it is floating.")

        env.extensionPoints.dismissPictureInPicture = { [weak env] tabID in
            guard let env else { return }
            PiPController.shared.dismissPiP(for: tabID, env: env)
        }
        defer { env.extensionPoints.dismissPictureInPicture = nil }

        env.webContents(tabs.contents, didChangeMediaState: MediaState(
            hasVideo: true,
            hasActiveMediaSession: true,
            isPictureInPictureActive: true,
            isPictureInPictureAvailable: true,
            isPlaying: false
        ))

        XCTAssertEqual(
            controller.pipTabID, tabs.video,
            "Pausing a video closed its picture-in-picture window."
        )

        env.webContents(tabs.contents, didChangeMediaState: MediaState())
        XCTAssertNil(controller.pipTabID)
    }

    // MARK: - The "back to tab" restore control

    // orbit_video_overlay_window_mac.mm's kControlBackToTab calls content::
    // VideoPictureInPictureWindowController::CloseAndFocusInitiator(), which
    // reaches WebContentsDelegate::ActivateContents, which OrbitWebContentsHost
    // now forwards through OrbitWebContentsCallbacks.activation_requested to
    // ChromiumWebContents.handleActivationRequested to
    // AppEnvironment.webContentsDidRequestActivation(_:).
    func test_backToTabActivationRoutesToTheOriginatingTab() throws {
        let (tabID, spaceID, contents) = try makeAttachedTabForActivation()
        env.activateTab(env.openTab(url: URL(string: "https://elsewhere.example.com")!, in: spaceID, activate: false))
        XCTAssertNotEqual(env.activeTabID, tabID, "Precondition: some other tab is active.")

        env.webContentsDidRequestActivation(contents)

        XCTAssertEqual(env.activeTabID, tabID, "The 'back to tab' control did not switch to the tab that floated it.")
    }

    // The originating tab can be in a Space that is not the currently active
    // one -- e.g. PiP kept floating after the user switched Spaces.
    func test_backToTabActivationSwitchesSpacesWhenTheOriginatingTabIsElsewhere() throws {
        let profileID = env.createDefaultProfileIfNeeded()
        let originSpaceID = try XCTUnwrap(env.spaces.first?.id)
        let otherSpaceID = env.createSpace(
            name: "Elsewhere", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID
        )
        let tabID = env.openTab(url: URL(string: "https://video.example.com/watch")!, in: originSpaceID, activate: false)
        let contents = MockWebContents()
        env._test_attachWebContents(contents, for: tabID)
        env.selectSpace(otherSpaceID)
        XCTAssertEqual(env.activeSpace?.id, otherSpaceID, "Precondition.")

        env.webContentsDidRequestActivation(contents)

        XCTAssertEqual(
            env.activeSpace?.id, originSpaceID,
            "The 'back to tab' control did not switch to the Space the floating tab actually lives in."
        )
        XCTAssertEqual(env.activeTabID, tabID)
    }

    private func makeAttachedTabForActivation() throws -> (TabID, SpaceID, MockWebContents) {
        let spaceID = try XCTUnwrap(env.spaces.first?.id)
        let tabID = env.openTab(url: URL(string: "https://video.example.com/watch")!, in: spaceID, activate: true)
        let contents = MockWebContents()
        env._test_attachWebContents(contents, for: tabID)
        return (tabID, spaceID, contents)
    }

    // activateTab must switch to the tab's own Space, not just materialise
    // the tab in whichever Space happens to be active -- the property the
    // "back to tab" control above relies on.
    func test_activateTab_switchesToTheTabsOwnSpaceEvenWhenAnotherSpaceIsActive() throws {
        let profileID = env.createDefaultProfileIfNeeded()
        let originSpaceID = try XCTUnwrap(env.spaces.first?.id)
        let otherSpaceID = env.createSpace(
            name: "Elsewhere", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID
        )
        let tabID = env.openTab(url: URL(string: "https://video.example.com/watch")!, in: originSpaceID, activate: false)
        env.selectSpace(otherSpaceID)
        XCTAssertEqual(env.activeSpace?.id, otherSpaceID, "Precondition.")

        env.activateTab(tabID)

        XCTAssertEqual(
            env.activeSpace?.id, originSpaceID,
            "activateTab did not switch back to the Space the floating tab actually lives in."
        )
        XCTAssertEqual(env.activeTabID, tabID, "activateTab did not make the floating tab the active one.")
    }
}

final class PictureInPictureScriptTests: XCTestCase {

    private var source: String { PictureInPictureScript.source }

    func test_theScriptDrivesBothTheStandardAndTheWebKitPictureInPictureAPIs() {
        XCTAssertTrue(source.contains("requestPictureInPicture()"), "The standard entry path is missing.")
        XCTAssertTrue(source.contains("exitPictureInPicture()"), "The standard exit path is missing.")
        XCTAssertTrue(
            source.contains("webkitSetPresentationMode"),
            "WebKit reports and drives picture-in-picture through presentation mode, not the standard API."
        )
    }

    func test_everyFailurePathIsReported() {
        XCTAssertTrue(
            source.contains("console.error"),
            "Nothing in the script reports a failure, so a rejected request is invisible again."
        )
        XCTAssertTrue(
            source.contains(PictureInPictureScript.logPrefix),
            "A diagnostic with no prefix cannot be attributed to Orbit in a page's console."
        )
        for swallow in ["catch(function(){})", "catch (function(){})", "catch(function() {})"] {
            XCTAssertFalse(
                source.contains(swallow),
                "An empty catch is exactly how this failure went unnoticed for a whole release."
            )
        }
    }

    func test_theScriptPrefersTheVideoThatIsActuallyPlaying() {
        XCTAssertTrue(
            source.contains("!v.paused"),
            """
            The script no longer prefers a playing video, so it will float a muted background \
            decoration in preference to the thing the user is watching.
            """
        )
    }
}
