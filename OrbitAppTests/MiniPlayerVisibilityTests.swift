import XCTest
@testable import Orbit

/// Pure value tests for the rule that decides which media tabs get a sidebar mini player row. No windows, no app activation.
@MainActor
final class MiniPlayerVisibilityTests: XCTestCase {

    private static let playing = MediaState(
        isAudible: true, hasVideo: true, hasActiveMediaSession: true,
        isPictureInPictureAvailable: true, isPlaying: true
    )

    private static let paused = MediaState(
        isAudible: false, hasVideo: true, hasActiveMediaSession: true,
        isPictureInPictureAvailable: true, isPlaying: false
    )

    private static var playingInPictureInPicture: MediaState {
        var state = playing
        state.isPictureInPictureActive = true
        return state
    }

    private static var pausedInPictureInPicture: MediaState {
        var state = paused
        state.isPictureInPictureActive = true
        return state
    }

    // MARK: - qualifiesForRow

    func test_playingMedia_qualifies() {
        XCTAssertTrue(MiniPlayerVisibility.qualifiesForRow(Self.playing, pausedByOrbit: false))
    }

    func test_playingMedia_qualifiesEvenWithTheOrbitFlagSet() {
        XCTAssertTrue(MiniPlayerVisibility.qualifiesForRow(Self.playing, pausedByOrbit: true))
    }

    func test_pausedOnThePage_doesNotQualify() {
        XCTAssertFalse(
            MiniPlayerVisibility.qualifiesForRow(Self.paused, pausedByOrbit: false),
            "Media the user paused on the tab itself must not keep a row."
        )
    }

    func test_pausedByOrbit_qualifies() {
        XCTAssertTrue(
            MiniPlayerVisibility.qualifiesForRow(Self.paused, pausedByOrbit: true),
            "A pause from the mini player or picture-in-picture keeps the row so its play button can resume."
        )
    }

    func test_idleMedia_neverQualifies() {
        XCTAssertFalse(MiniPlayerVisibility.qualifiesForRow(.idle, pausedByOrbit: false))
        XCTAssertFalse(
            MiniPlayerVisibility.qualifiesForRow(.idle, pausedByOrbit: true),
            "A stale Orbit flag must not keep a row for media that has ended."
        )
    }

    func test_aVideoNobodyPlayed_doesNotQualify() {
        XCTAssertFalse(MiniPlayerVisibility.qualifiesForRow(MediaState(hasVideo: true), pausedByOrbit: false))
    }

    // MARK: - pausedByOrbit

    func test_aPlayingReport_withNoFlag_staysUnflagged() {
        XCTAssertFalse(
            MiniPlayerVisibility.pausedByOrbit(previous: Self.playing, current: Self.playing, wasPausedByOrbit: false)
        )
    }

    func test_aPauseWithTheFlagAlreadySet_staysFlagged() {
        XCTAssertTrue(
            MiniPlayerVisibility.pausedByOrbit(previous: Self.playing, current: Self.paused, wasPausedByOrbit: true),
            "The mini player sets the flag before sending pause, so the resulting report must keep it."
        )
    }

    func test_aPauseWithNoFlag_isThePagesOwn() {
        XCTAssertFalse(
            MiniPlayerVisibility.pausedByOrbit(previous: Self.playing, current: Self.paused, wasPausedByOrbit: false)
        )
    }

    func test_aPauseWhileFloating_isAttributedToOrbit() {
        XCTAssertTrue(
            MiniPlayerVisibility.pausedByOrbit(
                previous: Self.playingInPictureInPicture, current: Self.pausedInPictureInPicture, wasPausedByOrbit: false
            )
        )
    }

    func test_aPauseReportedAfterThePictureInPictureWindowClosed_isStillAttributedToOrbit() {
        XCTAssertTrue(
            MiniPlayerVisibility.pausedByOrbit(
                previous: Self.playingInPictureInPicture, current: Self.paused, wasPausedByOrbit: false
            ),
            "Closing the floating window pauses the video a moment after the window goes."
        )
    }

    func test_aLateReportOfTheMediaStillPlaying_doesNotCancelAPendingOrbitPause() {
        XCTAssertTrue(
            MiniPlayerVisibility.pausedByOrbit(previous: Self.playing, current: Self.playing, wasPausedByOrbit: true),
            "A report that was in flight before the pause landed is not a resume."
        )
    }

    func test_resuming_clearsTheFlag() {
        XCTAssertFalse(
            MiniPlayerVisibility.pausedByOrbit(previous: Self.paused, current: Self.playing, wasPausedByOrbit: true)
        )
    }

    func test_theFirstReportBeingPlaying_clearsAStaleFlag() {
        XCTAssertFalse(
            MiniPlayerVisibility.pausedByOrbit(previous: nil, current: Self.playing, wasPausedByOrbit: true)
        )
    }

    func test_aPausedReportAfterAPausedReport_keepsTheFlag() {
        XCTAssertTrue(
            MiniPlayerVisibility.pausedByOrbit(previous: Self.paused, current: Self.paused, wasPausedByOrbit: true)
        )
        XCTAssertFalse(
            MiniPlayerVisibility.pausedByOrbit(previous: Self.paused, current: Self.paused, wasPausedByOrbit: false),
            "A page-side pause stays page-side across later paused reports."
        )
    }

    func test_whenTheMediaEnds_theFlagIsCleared() {
        XCTAssertFalse(
            MiniPlayerVisibility.pausedByOrbit(previous: Self.paused, current: .idle, wasPausedByOrbit: true)
        )
    }

    func test_aFirstPausedReportWithNoHistory_isThePagesOwn() {
        XCTAssertFalse(
            MiniPlayerVisibility.pausedByOrbit(previous: nil, current: Self.paused, wasPausedByOrbit: false)
        )
    }

    // MARK: - The two together

    func test_pageSidePause_thenPlayOnPage_thenOrbitPause_endsWithARow() {
        var flagged = false
        var previous: MediaState? = Self.playing

        flagged = MiniPlayerVisibility.pausedByOrbit(previous: previous, current: Self.paused, wasPausedByOrbit: flagged)
        previous = Self.paused
        XCTAssertFalse(MiniPlayerVisibility.qualifiesForRow(Self.paused, pausedByOrbit: flagged), "Page-side pause.")

        flagged = MiniPlayerVisibility.pausedByOrbit(previous: previous, current: Self.playing, wasPausedByOrbit: flagged)
        previous = Self.playing
        XCTAssertTrue(MiniPlayerVisibility.qualifiesForRow(Self.playing, pausedByOrbit: flagged), "Playing again.")

        flagged = true
        flagged = MiniPlayerVisibility.pausedByOrbit(previous: previous, current: Self.paused, wasPausedByOrbit: flagged)
        XCTAssertTrue(MiniPlayerVisibility.qualifiesForRow(Self.paused, pausedByOrbit: flagged), "Orbit pause.")
    }
}
