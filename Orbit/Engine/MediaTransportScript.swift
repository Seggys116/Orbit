import Foundation

public enum MediaTransportScript {

    /// Verbatim Media Session action names — key into the page's captured handler table.
    public enum Action: String, Sendable, CaseIterable {
        case play
        case pause
        case previousTrack = "previoustrack"
        case nextTrack = "nexttrack"
    }

    public static let scriptID = UUID(uuidString: "6E2C1A54-9E1B-4E86-9D2F-3A8B7C4D5E10")!

    public static var userScript: UserScript {
        UserScript(
            id: scriptID,
            kind: .javaScript,
            source: source,
            injectionTime: .documentStart,
            matchPatterns: ["<all_urls>"],
            allFrames: false
        )
    }

    public static func invocation(for action: Action) -> String {
        """
        (typeof window.__orbitMediaTransport === 'function')
          ? window.__orbitMediaTransport('\(action.rawValue)')
          : false
        """
    }

    public static let source = """
    (function() {
      if (window.__orbitMediaTransportInstalled) { return; }
      window.__orbitMediaTransportInstalled = true;
      window.__orbitMediaActions = window.__orbitMediaActions || {};

      // Media Session has no way to read handlers back or dispatch one externally; wrap setActionHandler to capture them.
      try {
        if ('mediaSession' in navigator && typeof navigator.mediaSession.setActionHandler === 'function') {
          var passThrough = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
          navigator.mediaSession.setActionHandler = function(action, handler) {
            try {
              if (handler) { window.__orbitMediaActions[action] = handler; }
              else { delete window.__orbitMediaActions[action]; }
            } catch (e) {}
            return passThrough(action, handler);
          };
        }
      } catch (e) {}

      function mediaElements() {
        var all = Array.prototype.slice.call(document.querySelectorAll('video, audio'));
        var live = all.filter(function(el) { return el.readyState > 0 && (!el.paused || el.currentTime > 0); });
        return live.length ? live : all;
      }

      function invokeHandler(action) {
        var handler = window.__orbitMediaActions[action];
        if (typeof handler !== 'function') { return false; }
        try { handler({ action: action }); return true; } catch (e) { return false; }
      }

      window.__orbitMediaTransport = function(action) {
        if (invokeHandler(action)) { return true; }

        // Only play/pause have a DOM fallback; next/previous have none.
        var elements = mediaElements();
        if (action === 'pause') {
          var didPause = false;
          elements.forEach(function(el) { if (!el.paused) { el.pause(); didPause = true; } });
          return didPause;
        }
        if (action === 'play') {
          var didPlay = false;
          elements.forEach(function(el) {
            if (el.paused) {
              var promise = el.play();
              if (promise && typeof promise.catch === 'function') { promise.catch(function() {}); }
              didPlay = true;
            }
          });
          return didPlay;
        }
        return false;
      };
    })();
    """
}
