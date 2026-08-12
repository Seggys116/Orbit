import XCTest
@testable import Orbit

final class MediaSessionBridgeTests: XCTestCase {

    // MARK: - The shared decoder

    func test_metadataPayload_populatesAllThreeNowPlayingFields() {
        let updated = MediaSessionObserverScript.apply(
            payload: [
                "kind": "metadata",
                "title": "Saturdays (feat. HAIM)",
                "artist": "Twin Shadow",
                "artwork": "https://example.com/cover.jpg",
                "playbackState": "playing",
            ],
            to: .idle
        )

        XCTAssertEqual(updated.nowPlayingTitle, "Saturdays (feat. HAIM)")
        XCTAssertEqual(updated.nowPlayingArtist, "Twin Shadow")
        XCTAssertEqual(updated.nowPlayingArtworkURL, URL(string: "https://example.com/cover.jpg"))
        XCTAssertTrue(updated.isPlaying, "playbackState 'playing' must move isPlaying, which is what the card's play/pause glyph reads.")
    }

    func test_metadataPayloadWithNullFields_clearsThePreviousTrack() {
        let playing = MediaSessionObserverScript.apply(
            payload: ["kind": "metadata", "title": "Summer Girl", "artist": "HAIM"],
            to: .idle
        )
        XCTAssertEqual(playing.nowPlayingTitle, "Summer Girl", "Precondition.")

        let cleared = MediaSessionObserverScript.apply(payload: ["kind": "metadata"], to: playing)

        XCTAssertNil(cleared.nowPlayingTitle, "A stale title is worse than none: the card would name a track that stopped.")
        XCTAssertNil(cleared.nowPlayingArtist)
        XCTAssertNil(cleared.nowPlayingArtworkURL)
    }

    func test_playbackStatePayload_movesFlagsAndLeavesTheTrackAlone() {
        let withTrack = MediaSessionObserverScript.apply(
            payload: ["kind": "metadata", "title": "Summer Girl", "artist": "HAIM"],
            to: .idle
        )

        let updated = MediaSessionObserverScript.apply(
            payload: ["kind": "playbackState", "hasVideo": true, "isPlaying": true, "isAudible": true],
            to: withTrack
        )

        XCTAssertTrue(updated.hasVideo)
        XCTAssertTrue(updated.isPlaying)
        XCTAssertTrue(updated.isAudible)
        XCTAssertEqual(updated.nowPlayingTitle, "Summer Girl", "A playback-state payload overwrote the track metadata.")
        XCTAssertEqual(updated.nowPlayingArtist, "HAIM")
    }

    func test_playbackStatePayloadWithMissingKeys_preservesTheExistingFlags() {
        var seeded = MediaState.idle
        seeded.hasVideo = true
        seeded.isPlaying = true
        seeded.isAudible = true

        let updated = MediaSessionObserverScript.apply(
            payload: ["kind": "playbackState", "isPlaying": false],
            to: seeded
        )

        XCTAssertFalse(updated.isPlaying, "The one key that was present must be honoured.")
        XCTAssertTrue(updated.hasVideo, "An absent key was read as false.")
        XCTAssertTrue(updated.isAudible, "An absent key was read as false.")
    }

    // MARK: - Paused is not stopped

    func test_aPausePayload_leavesTheTabStillCountingAsMedia() {
        let playing = MediaSessionObserverScript.apply(
            payload: [
                "kind": "playbackState",
                "hasVideo": true,
                "isPlaying": true,
                "isAudible": true,
                "hasActiveMediaSession": true,
            ],
            to: .idle
        )
        XCTAssertTrue(playing.isMediaActive, "Precondition.")

        let paused = MediaSessionObserverScript.apply(
            payload: [
                "kind": "playbackState",
                "hasVideo": true,
                "isPlaying": false,
                "isAudible": false,
                "hasActiveMediaSession": true,
            ],
            to: playing
        )

        XCTAssertFalse(paused.isPlaying)
        XCTAssertFalse(paused.isAudible)
        XCTAssertTrue(
            paused.hasActiveMediaSession,
            "The element is still loaded; only `hasActiveMediaSession` can say so."
        )
        XCTAssertTrue(
            paused.isMediaActive,
            "A paused tab stopped counting as a media tab, which is what unmounted the now-playing card."
        )
    }

    func test_anEndedPayload_stopsTheTabCountingAsMedia() {
        let paused = MediaSessionObserverScript.apply(
            payload: ["kind": "playbackState", "isPlaying": false, "isAudible": false, "hasActiveMediaSession": true],
            to: .idle
        )
        XCTAssertTrue(paused.isMediaActive, "Precondition.")

        let ended = MediaSessionObserverScript.apply(
            payload: ["kind": "playbackState", "isPlaying": false, "isAudible": false, "hasActiveMediaSession": false],
            to: paused
        )

        XCTAssertFalse(ended.isMediaActive, "The media ended; nothing should keep a card up for this tab.")
    }

    func test_aVideoElementNobodyPlayed_isNotAMediaTab() {
        let updated = MediaSessionObserverScript.apply(
            payload: [
                "kind": "playbackState",
                "hasVideo": true,
                "isPlaying": false,
                "isAudible": false,
                "hasActiveMediaSession": false,
            ],
            to: .idle
        )

        XCTAssertTrue(updated.hasVideo)
        XCTAssertFalse(updated.isMediaActive)
    }

    func test_metadataPayloads_canRaiseTheSessionFlagButNeverLowerIt() {
        let paused = MediaSessionObserverScript.apply(
            payload: ["kind": "metadata", "title": "Summer Girl", "playbackState": "paused"],
            to: .idle
        )
        XCTAssertTrue(
            paused.hasActiveMediaSession,
            "A page that drives Media Session with no DOM element to sweep still has a live session."
        )
        XCTAssertFalse(paused.isPlaying, "'paused' is not 'playing'.")

        let afterNone = MediaSessionObserverScript.apply(
            payload: ["kind": "metadata", "title": "Summer Girl", "playbackState": "none"],
            to: paused
        )
        XCTAssertTrue(
            afterNone.hasActiveMediaSession,
            "A metadata payload cleared the session flag the DOM sweep had set."
        )
    }

    // MARK: - Picture-in-picture is reported at all

    func test_thePlaybackPayloadCarriesPictureInPictureBothWays() {
        let entered = MediaSessionObserverScript.apply(
            payload: ["kind": "playbackState", "isPictureInPictureActive": true],
            to: .idle
        )
        XCTAssertTrue(entered.isPictureInPictureActive)

        let left = MediaSessionObserverScript.apply(
            payload: ["kind": "playbackState", "isPictureInPictureActive": false],
            to: entered
        )
        XCTAssertFalse(left.isPictureInPictureActive)
    }

    func test_theObserverEmitsTheKeysTheDecoderReads() {
        let source = MediaSessionObserverScript.source(postExpression: "noop()")
        for key in ["hasVideo", "isPlaying", "isAudible", "hasActiveMediaSession", "isPictureInPictureActive"] {
            XCTAssertTrue(
                source.contains("\(key):"),
                "The observer never emits '\(key)', so the decoder's read of it is dead."
            )
        }
    }

    func test_theObserverListensForTheEventsThatMoveTheNewFlags() {
        let source = MediaSessionObserverScript.source(postExpression: "noop()")
        for event in ["enterpictureinpicture", "leavepictureinpicture", "webkitpresentationmodechanged", "ended", "emptied"] {
            XCTAssertTrue(
                source.contains("'\(event)'"),
                "The observer does not listen for '\(event)', so the flags it moves would go stale."
            )
        }
        XCTAssertTrue(
            source.contains("__orbitPlaybackBegun"),
            """
            The observer no longer marks elements that have begun playback, so \
            `hasActiveMediaSession` cannot tell a paused track from a video nobody played.
            """
        )
    }

    func test_unusablePayloads_leaveTheStateExactlyAsItWas() {
        var seeded = MediaState.idle
        seeded.nowPlayingTitle = "Summer Girl"
        seeded.isPlaying = true

        for payload: [String: Any] in [
            [:],
            ["kind": "somethingElse", "title": "Injected"],
            ["kind": 7],
            ["title": "No kind at all"],
        ] {
            XCTAssertEqual(
                MediaSessionObserverScript.apply(payload: payload, to: seeded),
                seeded,
                "Payload \(payload) changed the media state."
            )
        }
    }

    // MARK: - The Chromium transport carries the same meaning

    func test_jsonPayload_decodesToTheSameStateAsTheEquivalentObject() {
        let object: [String: Any] = [
            "kind": "metadata",
            "title": "Saturdays (feat. HAIM)",
            "artist": "Twin Shadow",
            "artwork": "https://example.com/cover.jpg",
            "playbackState": "playing",
        ]
        let json = """
        {"kind":"metadata","title":"Saturdays (feat. HAIM)","artist":"Twin Shadow",\
        "artwork":"https://example.com/cover.jpg","playbackState":"playing"}
        """

        XCTAssertEqual(
            MediaSessionObserverScript.apply(payloadJSON: json, to: .idle),
            MediaSessionObserverScript.apply(payload: object, to: .idle)
        )
    }

    func test_malformedJSON_leavesTheStateAlone() {
        var seeded = MediaState.idle
        seeded.nowPlayingTitle = "Summer Girl"

        for json in ["", "{", "null", "[1,2,3]", "\"a string\""] {
            XCTAssertEqual(
                MediaSessionObserverScript.apply(payloadJSON: json, to: seeded),
                seeded,
                "Payload \(json.debugDescription) changed the media state."
            )
        }
    }

    // MARK: - One script, one transport

    func test_chromiumInstallsTheSharedObserverWithOnlyTheChromiumTransport() {
        let script = MediaSessionObserverScript.chromiumUserScript

        XCTAssertEqual(
            script.source,
            MediaSessionObserverScript.source(postExpression: MediaSessionObserverScript.chromiumPostExpression),
            """
            The installed observer is no longer the shared generator's output. That is how this defect \
            happened the first time: a second, hand-maintained copy of the script drifted from the \
            decoder that reads its payloads.
            """
        )
        XCTAssertTrue(
            script.source.contains(MediaSessionObserverScript.chromiumPostExpression),
            "The generated source does not carry the transport, so nothing it observes can reach the host."
        )
        XCTAssertEqual(script.injectionTime, .documentStart, "Injected after the page's scripts, the prototype overrides would miss every metadata assignment the page already made.")
        XCTAssertEqual(script.matchPatterns, ["<all_urls>"])
        XCTAssertEqual(script.kind, .javaScript)
        XCTAssertEqual(
            script.id, MediaSessionObserverScript.scriptID,
            "A fresh id per access would let a session accumulate one observer per registration."
        )
        XCTAssertNotEqual(
            script.id, MediaTransportScript.scriptID,
            "The two session-level scripts must be separately removable."
        )
    }

    func test_thePostExpressionIsTheOnlyThingThatVariesInTheGeneratedSource() {
        let placeholder = "noop()"
        let lhs = MediaSessionObserverScript
            .source(postExpression: placeholder)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let rhs = MediaSessionObserverScript
            .source(postExpression: MediaSessionObserverScript.chromiumPostExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lhs.count, rhs.count, "Changing the post expression changed the shape of the script.")

        let differing = zip(lhs, rhs).filter { $0 != $1 }
        XCTAssertEqual(differing.count, 1, "Expected exactly one differing line (the post expression); got \(differing.count).")
        XCTAssertTrue(
            differing.first?.0.contains(placeholder) == true,
            "The differing line is not the substituted expression."
        )
        XCTAssertTrue(
            differing.first?.1.contains(MediaSessionObserverScript.chromiumPostExpression) == true,
            "The differing line is not the Chromium post expression."
        )
    }

    func test_theObserverEmitsEveryPayloadKindTheDecoderUnderstands() {
        let source = MediaSessionObserverScript.source(postExpression: "noop()")
        for kind in MediaSessionObserverScript.PayloadKind.allCases {
            XCTAssertTrue(
                source.contains("kind: '\(kind.rawValue)'"),
                "The observer never emits a '\(kind.rawValue)' payload, so the decoder's branch for it is dead."
            )
        }
    }
}
