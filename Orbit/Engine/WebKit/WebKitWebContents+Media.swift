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

    /// The media-session script misses a playing element whose readyState has not reached HAVE_CURRENT_DATA, and WebKit's own picture-in-picture window is not an NSPanel this process can show the page in.
    func observeMediaSurfaces() {
        let key = ObjectIdentifier(self)
        let generation = MediaSurfaceWatch.bump(key)
        MediaSurfaceWatch.tasks[key]?.cancel()
        MediaSurfaceWatch.tasks[key] = Task { @MainActor [weak self] in
            while !Task.isCancelled, MediaSurfaceWatch.generation(of: key) == generation {
                guard let self else {
                    PictureInPicturePanels.dismiss(key)
                    return
                }
                if self.isClosed {
                    PictureInPicturePanels.dismiss(self)
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
    /// and this wait ends early when that report arrives so the panel can open.
    private func pauseBeforeNextMediaProbe() async {
        let playing = mediaState.isPlaying
        let showingPanel = PictureInPicturePanels.isShowing(self)
        let floating = mediaState.isPictureInPictureActive || showingPanel
        if showingPanel && playing {
            try? await Task.sleep(for: .milliseconds(80))
            return
        }
        // A hidden tab nobody is watching: the page script reports play and pause as they happen, and a
        // frame-accurate probe only matters for the panel or the visible tab. Wake once a second instead of five times.
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
        if isBackgrounded, !hasLiveMediaToObserve, !PictureInPicturePanels.isShowing(self) { return }
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
        guard probe.inPictureInPicture else {
            PictureInPicturePanels.dismiss(self)
            return
        }
        var frame = probe.frame
        if frame.map(Self.isNearlyBlack) != false {
            if let shot = await Self.snapshot(of: probe.elementRect, in: webView), !Self.isNearlyBlack(shot) {
                frame = shot
            }
        }
        PictureInPicturePanels.present(self, videoSize: probe.videoSize, frame: frame)
    }

    private struct MediaSurfaceProbe {
        var playing: Bool
        var inPictureInPicture: Bool
        var videoSize: CGSize
        var elementRect: CGRect
        var frame: NSImage?
    }

    private static func probeMediaSurface(in webView: WKWebView) async -> MediaSurfaceProbe? {
        guard let raw = try? await webView.evaluateJavaScript(surfaceProbeSource) else { return nil }
        let text = raw as? String ?? (raw as? NSString).map(String.init)
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let width = jsonDouble(object["w"])
        let height = jsonDouble(object["h"])
        return MediaSurfaceProbe(
            playing: jsonBool(object["playing"]),
            inPictureInPicture: jsonBool(object["pip"]),
            videoSize: CGSize(width: width, height: height),
            elementRect: CGRect(
                x: jsonDouble(object["x"]), y: jsonDouble(object["y"]),
                width: jsonDouble(object["rw"]), height: jsonDouble(object["rh"])
            ),
            frame: (object["frame"] as? String).flatMap(image(fromDataURL:))
        )
    }

    // Detached canvas: the picture-in-picture video element still decodes, and a bitmap paints into the panel where a video layer would capture as black.
    private static let surfaceProbeSource = """
    (function() {
      var els = document.querySelectorAll('video, audio');
      var playing = false;
      var pip = null;
      try {
        if (navigator.mediaSession && navigator.mediaSession.playbackState === 'playing') playing = true;
      } catch (e) {}
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (!el.paused && !el.ended) playing = true;
        var inPip = false;
        try {
          inPip = document.pictureInPictureElement === el || el.webkitPresentationMode === 'picture-in-picture';
        } catch (e) {}
        if (inPip && el.tagName === 'VIDEO' && !pip) pip = el;
      }
      var frame = '', w = 0, h = 0, x = 0, y = 0, rw = 0, rh = 0;
      if (pip) {
        w = pip.videoWidth || 0;
        h = pip.videoHeight || 0;
        try {
          var rect = pip.getBoundingClientRect();
          x = rect.x; y = rect.y; rw = rect.width; rh = rect.height;
        } catch (e) {}
        if (w > 0 && h > 0) {
          try {
            var canvas = document.createElement('canvas');
            canvas.width = w;
            canvas.height = h;
            canvas.getContext('2d').drawImage(pip, 0, 0, w, h);
            frame = canvas.toDataURL('image/png');
          } catch (e) {}
        }
      }
      return JSON.stringify({ playing: playing, pip: !!pip, w: w, h: h, x: x, y: y, rw: rw, rh: rh, frame: frame });
    })()
    """

    private static func snapshot(of rect: CGRect, in webView: WKWebView) async -> NSImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let height = webView.bounds.height
        let flipped = CGRect(x: rect.minX, y: max(0, height - rect.maxY), width: rect.width, height: rect.height)
        for candidate in [flipped, rect] {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = candidate
            if let image = try? await webView.takeSnapshot(configuration: configuration), !isNearlyBlack(image) {
                return image
            }
        }
        return nil
    }

    private static func image(fromDataURL dataURL: String) -> NSImage? {
        guard let range = dataURL.range(of: "base64,") else { return nil }
        let payload = String(dataURL[range.upperBound...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }

    fileprivate static func isNearlyBlack(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return true }
        var colorful = 0
        var sampled = 0
        let stepX = max(1, rep.pixelsWide / 8)
        let stepY = max(1, rep.pixelsHigh / 8)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.2 { colorful += 1 }
                sampled += 1
            }
        }
        return sampled == 0 || Double(colorful) / Double(sampled) < 0.1
    }

    private static func jsonBool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func jsonDouble(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        return (value as? NSNumber)?.doubleValue ?? 0
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

/// Chrome's picture-in-picture window is an NSPanel at floating level with this minimum content size.
/// WebKit's own window is not that panel, so the playing frame is painted here.
@MainActor
private enum PictureInPicturePanels {
    static let minimumContentSize = NSSize(width: 284, height: 160)
    private static var sessions: [ObjectIdentifier: Session] = [:]

    @MainActor
    final class Session {
        let panel: NSPanel
        let imageView: NSImageView

        init() {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleAxesIndependently
            imageView.imageAlignment = .alignCenter
            imageView.autoresizingMask = [.width, .height]
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .black
            panel.contentMinSize = PictureInPicturePanels.minimumContentSize
            panel.contentView = imageView
            if imageView.bounds.width < 2 || imageView.bounds.height < 2 {
                imageView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
            }
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.midX - 240, y: visible.midY - 160))
            }
            self.panel = panel
            self.imageView = imageView
        }
    }

    static func isShowing(_ contents: WebKitWebContents) -> Bool {
        sessions[ObjectIdentifier(contents)]?.panel.isVisible == true
    }

    static func present(_ contents: WebKitWebContents, videoSize: CGSize, frame: NSImage?) {
        let key = ObjectIdentifier(contents)
        let session = sessions[key] ?? Session()
        sessions[key] = session
        if videoSize.width > 0, videoSize.height > 0 {
            session.panel.contentAspectRatio = NSSize(width: videoSize.width, height: videoSize.height)
        }
        if let frame, session.imageView.image == nil || !WebKitWebContents.isNearlyBlack(frame) {
            session.imageView.image = frame
            session.imageView.needsDisplay = true
            session.panel.displayIfNeeded()
        }
        if !session.panel.isVisible {
            session.panel.orderFrontRegardless()
        }
        session.panel.displayIfNeeded()
    }

    static func dismiss(_ contents: WebKitWebContents) {
        dismiss(ObjectIdentifier(contents))
    }

    static func dismiss(_ key: ObjectIdentifier) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.panel.orderOut(nil)
    }
}
