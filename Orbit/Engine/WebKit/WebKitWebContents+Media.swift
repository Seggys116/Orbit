import AppKit
import Foundation
import WebKit

extension WebKitWebContents {

    /// Mutes without pausing. The page script keeps every element muted, including ones added later, and WebKit's
    /// page-level audio mute covers media the script cannot reach, such as players in cross-origin frames.
    func applyMute(_ muted: Bool) {
        webView.evaluateJavaScript(MediaSessionObserverScript.setDesiredMuted(muted), completionHandler: nil)
        Self.setPageAudioMuted(webView, muted)
    }

    // _WKMediaMutedState: 0 is none muted, 1 is audio muted. Public API only offers suspending playback, which pauses it.
    private static func setPageAudioMuted(_ webView: WKWebView, _ muted: Bool) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return }
        let implementation = webView.method(for: selector)
        typealias Function = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(implementation, to: Function.self)(webView, selector, muted ? 1 : 0)
    }

    /// The media-session script misses a playing element whose readyState has not reached HAVE_CURRENT_DATA, and its picture-in-picture report can lag the real window opening or closing.
    func observeMediaSurfaces() {
        let key = ObjectIdentifier(self)
        let generation = MediaSurfaceWatch.bump(key)
        MediaSurfaceWatch.tasks[key]?.cancel()
        MediaSurfaceWatch.tasks[key] = Task { @MainActor [weak self] in
            while !Task.isCancelled, MediaSurfaceWatch.generation(of: key) == generation {
                guard let self else { return }
                if self.isClosed {
                    PaneFrameRestore.stop(self)
                    return
                }
                await self.refreshObservedMedia()
                await self.pauseBeforeNextMediaProbe()
            }
        }
    }

    /// A quiet page does not need a script round trip every fifth of a second.
    /// The page script still reports play and picture-in-picture as they happen,
    /// and this wait ends early when that report arrives.
    private func pauseBeforeNextMediaProbe() async {
        let playing = mediaState.isPlaying
        let floating = mediaState.isPictureInPictureActive
        // A hidden tab nobody is watching: the page script reports play and pause as they happen, and a
        // frame-accurate probe only matters for a floating window or the visible tab. Wake once a second instead of five times.
        let hidden = isBackgrounded
        if playing || floating {
            try? await Task.sleep(for: .milliseconds(hidden && !floating ? 1_000 : 200))
            return
        }
        var remaining = Duration.milliseconds(2_000)
        let slice = Duration.milliseconds(hidden ? 1_000 : 200)
        while remaining > .zero {
            if Task.isCancelled || isClosed { return }
            let step = min(slice, remaining)
            do {
                try await Task.sleep(for: step)
            } catch {
                return
            }
            remaining -= step
            // Also ends when the tab is shown or hidden, so the probe cadence follows the pane at once.
            if isClosed || mediaState.isPlaying || mediaState.isPictureInPictureActive || isBackgrounded != hidden {
                return
            }
        }
    }

    private func refreshObservedMedia() async {
        // Skipped for a hidden tab with nothing playing: each probe is a script round trip that wakes
        // an otherwise idle WebContent process, which is what lets WebKit throttle and nap it.
        if isBackgrounded, !hasLiveMediaToObserve { return }
        guard !isClosed, let probe = await Self.probeMediaSurface(in: webView), !isClosed else { return }
        var changed = false
        if mediaState.isPlaying != probe.playing {
            mediaState.isPlaying = probe.playing
            changed = true
        }
        if mediaState.isPictureInPictureActive != probe.inPictureInPicture {
            mediaState.isPictureInPictureActive = probe.inPictureInPicture
            changed = true
        }
        if changed {
            delegate?.webContents(self, didChangeMediaState: mediaState)
        }
    }

    private struct MediaSurfaceProbe {
        var playing: Bool
        var inPictureInPicture: Bool
    }

    private static func probeMediaSurface(in webView: WKWebView) async -> MediaSurfaceProbe? {
        guard let raw = try? await webView.evaluateJavaScript(surfaceProbeSource) else { return nil }
        let text = raw as? String ?? (raw as? NSString).map(String.init)
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return MediaSurfaceProbe(
            playing: jsonBool(object["playing"]),
            inPictureInPicture: jsonBool(object["pip"])
        )
    }

    private static let surfaceProbeSource = """
    (function() {
      var els = document.querySelectorAll('video, audio');
      var playing = false;
      var pip = false;
      try {
        if (navigator.mediaSession && navigator.mediaSession.playbackState === 'playing') playing = true;
      } catch (e) {}
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (!el.paused && !el.ended) playing = true;
        try {
          if (el.tagName === 'VIDEO' &&
              (document.pictureInPictureElement === el || el.webkitPresentationMode === 'picture-in-picture')) {
            pip = true;
          }
        } catch (e) {}
      }
      return JSON.stringify({ playing: playing, pip: pip });
    })()
    """

    private static func jsonBool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        return (value as? NSNumber)?.boolValue ?? false
    }
}

@MainActor
private enum MediaSurfaceWatch {
    static var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static var generations: [ObjectIdentifier: Int] = [:]

    static func bump(_ key: ObjectIdentifier) -> Int {
        let next = (generations[key] ?? 0) + 1
        generations[key] = next
        return next
    }

    static func generation(of key: ObjectIdentifier) -> Int { generations[key] ?? 0 }
}
