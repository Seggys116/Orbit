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
                    MediaSurfaceWatch.sleepers[key] = nil
                    MediaSurfaceWatch.waitingInterval[key] = nil
                    return
                }
                if let interval = self.mediaProbeInterval {
                    await self.refreshObservedMedia()
                    await self.pauseBeforeNextMediaProbe(interval)
                } else {
                    await self.pauseBeforeNextMediaProbe(Self.idleRecheckInterval)
                }
            }
        }
    }

    /// Without live media the page script's own play, pause and picture-in-picture events are the whole story, so
    /// no script round trip is made at all. An audible tab that is not playing is not probed either: the probe
    /// only reads media elements, so it could not report anything the page events have not.
    private static let idleRecheckInterval = Duration.seconds(10)

    /// How often to probe, or nil for not at all. 200 ms only where frame accuracy matters: the floating window,
    /// and the visible tab in the window the user is working in. A hidden tab relies on page events plus a slow safety probe.
    private var mediaProbeInterval: Duration? {
        let state = mediaState
        if state.isPictureInPictureActive { return .milliseconds(200) }
        if state.isPlaying {
            if isBackgrounded { return .seconds(5) }
            return isInKeyWindow ? .milliseconds(200) : .seconds(1)
        }
        if state.isFullscreen { return .seconds(2) }
        return nil
    }

    /// Ends the current probe wait early when playing, floating, fullscreen or visibility changed, so the cadence
    /// follows the tab at once. Called from those state changes; a missed call only delays the new cadence by `idleRecheckInterval`.
    func mediaProbeCadenceMayHaveChanged() {
        let key = ObjectIdentifier(self)
        guard MediaSurfaceWatch.waitingInterval[key] != mediaProbeInterval else { return }
        MediaSurfaceWatch.sleepers[key]?.cancel()
    }

    private func pauseBeforeNextMediaProbe(_ interval: Duration) async {
        let key = ObjectIdentifier(self)
        let sleeper = Task { _ = try? await Task.sleep(for: interval) }
        MediaSurfaceWatch.sleepers[key] = sleeper
        MediaSurfaceWatch.waitingInterval[key] = mediaProbeInterval
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
    }

    private func refreshObservedMedia() async {
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
    static var sleepers: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The cadence the loop is currently waiting out, so an unchanged cadence does not cut the wait short.
    static var waitingInterval: [ObjectIdentifier: Duration?] = [:]
    private static var generations: [ObjectIdentifier: Int] = [:]

    static func bump(_ key: ObjectIdentifier) -> Int {
        let next = (generations[key] ?? 0) + 1
        generations[key] = next
        return next
    }

    static func generation(of key: ObjectIdentifier) -> Int { generations[key] ?? 0 }
}
