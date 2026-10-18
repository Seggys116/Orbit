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

    public static let bridgePostExpression =
        "__orbitPost('\(channelName)', JSON.stringify(payload))"

    public static func source(postExpression: String) -> String {
        """
        (function() {
          // Captured now, before the engine deletes the global binding.
          var __orbitPost = window.__orbitPostMessage;

          // null: Orbit has never asked; true/false: Orbit's own mute button asked and
          // must keep winning against the page's own controls and newly added elements.
          window.__orbitDesiredMuted = typeof window.__orbitDesiredMuted === 'boolean' ? window.__orbitDesiredMuted : null;

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
            if (window.__orbitDesiredMuted === null) { return; }
            el.muted = window.__orbitDesiredMuted;
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
              var started = elements.filter(function(el) { return !el.paused && !el.ended; });
              var audible = started.filter(function(el) { return el.readyState >= 2 && !el.muted && el.volume > 0; });
              var sessionState = sessionPlaybackState();
              // paused is the playback flag. readyState lags play(), including on a
              // background tab that has not decoded a frame yet.
              var isPlaying = started.length > 0 || sessionState === 'playing';
              var isAudible = audible.length > 0;
              var hasActiveMediaSession =
                elements.some(function(el) { return el.__orbitPlaybackBegun === true; })
                || sessionState === 'playing'
                || sessionState === 'paused';
              var inPictureInPicture =
                !!document.pictureInPictureElement || elements.some(isInPictureInPicture);
              var canPictureInPicture = elements.some(function(el) {
                if (el.tagName !== 'VIDEO' || el.disablePictureInPicture) { return false; }
                try {
                  if (el.webkitSupportsPresentationMode && el.webkitSupportsPresentationMode('picture-in-picture')) {
                    return true;
                  }
                } catch (e) {}
                return typeof el.requestPictureInPicture === 'function';
              });
              post({
                kind: '\(PayloadKind.playbackState.rawValue)',
                hasVideo: hasVideo,
                isPlaying: isPlaying,
                isAudible: isAudible,
                hasActiveMediaSession: hasActiveMediaSession,
                isPictureInPictureActive: inPictureInPicture,
                isPictureInPictureAvailable: canPictureInPicture
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

          function anyLiveMedia() {
            try {
              if (document.pictureInPictureElement) { return true; }
              if (sessionPlaybackState() === 'playing') { return true; }
              var elements = document.querySelectorAll('video, audio');
              for (var i = 0; i < elements.length; i++) {
                var el = elements[i];
                if (!el.paused && !el.ended) { return true; }
                if (isInPictureInPicture(el)) { return true; }
              }
              return false;
            } catch (e) { return true; }
          }

          document.addEventListener('visibilitychange', function() {
            if (document.hidden) { return; }
            document.querySelectorAll('video, audio').forEach(enforceMute);
            reportPlaybackState();
            checkMediaSession();
          });

          // Polled, not watched: patching MediaSession's setters fails anti-bot scripts' native-code check.
          // A hidden page with nothing playing skips the scan so the web process can nap. Play events
          // and visibilitychange still report, including background audio for the mini player.
          setInterval(function() {
            if (document.hidden && !anyLiveMedia()) { return; }
            document.querySelectorAll('video, audio').forEach(enforceMute);
            reportPlaybackState();
            checkMediaSession();
          }, 2000);
        })();
        """
    }

    /// Installed once per session, not per-tab: must keep working across navigations.
    public static var userScript: UserScript {
        UserScript(
            id: scriptID,
            kind: .javaScript,
            source: source(postExpression: bridgePostExpression),
            injectionTime: .documentStart,
            matchPatterns: ["<all_urls>"],
            allFrames: false
        )
    }

    // MARK: - Mute

    /// Sets the observer's persistent desired-mute flag and mutes/unmutes every
    /// element on the page right now, rather than waiting for the next poll tick.
    public static func setDesiredMuted(_ muted: Bool) -> String {
        """
        (function() {
          window.__orbitDesiredMuted = \(muted);
          document.querySelectorAll('video, audio').forEach(function(el) { el.muted = \(muted); });
          return true;
        })();
        """
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
                // "none" is the unset default, not a pause. Applying it used to
                // clear a playback report that had already arrived.
                if playbackState == "playing" {
                    updated.isPlaying = true
                    updated.hasActiveMediaSession = true
                } else if playbackState == "paused" {
                    updated.isPlaying = false
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
            if let available = payload["isPictureInPictureAvailable"] as? Bool {
                updated.isPictureInPictureAvailable = available
            }
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
