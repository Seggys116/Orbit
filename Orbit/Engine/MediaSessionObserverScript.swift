import Foundation

public enum MediaSessionObserverScript {

    public static let channelName = "orbitMediaSession"

    public static let scriptID = UUID(uuidString: "6E2C1A54-9E1B-4E86-9D2F-3A8B7C4D5E11")!

    // MARK: - Payload kinds

    public enum PayloadKind: String, Sendable, CaseIterable {
        case metadata
        case playbackState
    }

    // MARK: - Source

    public static let chromiumPostExpression =
        "__orbitPost('\(channelName)', JSON.stringify(payload))"

    public static func source(postExpression: String) -> String {
        """
        (function() {
          // Captured now, before the engine deletes the global binding.
          var __orbitPost = window.__orbitPostMessage;

          var __orbitDesiredMuted = false;

          function post(payload) {
            try { \(postExpression); } catch (e) {}
          }

          function reportMetadata() {
            try {
              if (!('mediaSession' in navigator)) { return; }
              var md = navigator.mediaSession.metadata;
              var artwork = null;
              if (md && md.artwork && md.artwork.length > 0) {
                artwork = md.artwork[md.artwork.length - 1].src || null;
              }
              post({
                kind: '\(PayloadKind.metadata.rawValue)',
                title: md ? (md.title || null) : null,
                artist: md ? (md.artist || null) : null,
                artwork: artwork,
                playbackState: navigator.mediaSession.playbackState || 'none'
              });
            } catch (e) {}
          }

          function enforceMute(el) {
            if (__orbitDesiredMuted) { el.muted = true; }
          }

          function sessionPlaybackState() {
            try {
              if (!('mediaSession' in navigator)) { return 'none'; }
              return navigator.mediaSession.playbackState || 'none';
            } catch (e) { return 'none'; }
          }

          function isInPictureInPicture(el) {
            try {
              if (document.pictureInPictureElement === el) { return true; }
              return el.webkitPresentationMode === 'picture-in-picture';
            } catch (e) { return false; }
          }

          function reportPlaybackState() {
            try {
              var elements = Array.prototype.slice.call(document.querySelectorAll('video, audio'));
              var hasVideo = elements.some(function(el) { return el.tagName === 'VIDEO'; });
              var playing = elements.filter(function(el) { return !el.paused && !el.ended && el.readyState > 2; });
              var isAudible = playing.some(function(el) { return !el.muted && el.volume > 0; });
              var sessionState = sessionPlaybackState();
              // With no elements to scan, trust mediaSession.playbackState instead
              // of defaulting to "not playing".
              var isPlaying = playing.length > 0
                || (elements.length === 0 && sessionState === 'playing');
              var hasActiveMediaSession =
                elements.some(function(el) { return el.__orbitPlaybackBegun === true; })
                || sessionState === 'playing'
                || sessionState === 'paused';
              var inPictureInPicture =
                !!document.pictureInPictureElement || elements.some(isInPictureInPicture);
              post({
                kind: '\(PayloadKind.playbackState.rawValue)',
                hasVideo: hasVideo,
                isPlaying: isPlaying,
                isAudible: isAudible,
                hasActiveMediaSession: hasActiveMediaSession,
                isPictureInPictureActive: inPictureInPicture
              });
            } catch (e) {}
          }

          var __orbitLastTitle, __orbitLastArtist, __orbitLastArtwork, __orbitLastSessionState;

          function checkMediaSession() {
            try {
              if (!('mediaSession' in navigator)) { return; }
              var md = navigator.mediaSession.metadata;
              var title = md ? (md.title || null) : null;
              var artist = md ? (md.artist || null) : null;
              var artwork = null;
              if (md && md.artwork && md.artwork.length > 0) {
                artwork = md.artwork[md.artwork.length - 1].src || null;
              }
              var state = navigator.mediaSession.playbackState || 'none';
              if (title === __orbitLastTitle && artist === __orbitLastArtist &&
                  artwork === __orbitLastArtwork && state === __orbitLastSessionState) {
                return;
              }
              __orbitLastTitle = title;
              __orbitLastArtist = artist;
              __orbitLastArtwork = artwork;
              __orbitLastSessionState = state;
              reportMetadata();
              if (state === 'playing' || state === 'paused') { reportPlaybackState(); }
            } catch (e) {}
          }

          [
            'play', 'playing', 'pause', 'volumechange', 'loadedmetadata', 'emptied', 'ended',
            'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged'
          ].forEach(function(eventName) {
            document.addEventListener(eventName, function(event) {
              var el = event.target;
              if (el && (el.tagName === 'VIDEO' || el.tagName === 'AUDIO')) {
                enforceMute(el);
                if (eventName === 'play' || eventName === 'playing') {
                  el.__orbitPlaybackBegun = true;
                } else if (eventName === 'ended' || eventName === 'emptied') {
                  el.__orbitPlaybackBegun = false;
                }
              }
              reportPlaybackState();
              checkMediaSession();
            }, true);
          });

          document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('video, audio').forEach(enforceMute);
            reportPlaybackState();
            checkMediaSession();
          });
          window.addEventListener('load', function() { reportPlaybackState(); checkMediaSession(); });

          // Polled, not watched: patching MediaSession's setters fails anti-bot scripts' native-code check.
          setInterval(function() {
            document.querySelectorAll('video, audio').forEach(enforceMute);
            reportPlaybackState();
            checkMediaSession();
          }, 2000);
        })();
        """
    }

    /// Installed once per session, not per-tab: must keep working across navigations.
    public static var chromiumUserScript: UserScript {
        UserScript(
            id: scriptID,
            kind: .javaScript,
            source: source(postExpression: chromiumPostExpression),
            injectionTime: .documentStart,
            matchPatterns: ["<all_urls>"],
            allFrames: false
        )
    }

    // MARK: - Decoding

    /// `metadata` can only raise `hasActiveMediaSession`, never lower it.
    public static func apply(payload: [String: Any], to state: MediaState) -> MediaState {
        guard let rawKind = payload["kind"] as? String,
              let kind = PayloadKind(rawValue: rawKind) else { return state }

        var updated = state
        switch kind {
        case .metadata:
            updated.nowPlayingTitle = payload["title"] as? String
            updated.nowPlayingArtist = payload["artist"] as? String
            updated.nowPlayingArtworkURL = (payload["artwork"] as? String).flatMap(URL.init(string:))
            if let playbackState = payload["playbackState"] as? String {
                updated.isPlaying = playbackState == "playing"
                if playbackState == "playing" || playbackState == "paused" {
                    updated.hasActiveMediaSession = true
                }
            }
        case .playbackState:
            updated.hasVideo = payload["hasVideo"] as? Bool ?? updated.hasVideo
            updated.isPlaying = payload["isPlaying"] as? Bool ?? updated.isPlaying
            updated.isAudible = payload["isAudible"] as? Bool ?? updated.isAudible
            updated.hasActiveMediaSession =
                payload["hasActiveMediaSession"] as? Bool ?? updated.hasActiveMediaSession
            updated.isPictureInPictureActive =
                payload["isPictureInPictureActive"] as? Bool ?? updated.isPictureInPictureActive
        }
        return updated
    }

    public static func apply(payloadJSON json: String, to state: MediaState) -> MediaState {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else { return state }
        return apply(payload: payload, to: state)
    }
}
