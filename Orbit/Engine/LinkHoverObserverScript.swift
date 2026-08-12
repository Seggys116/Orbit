import Foundation

public enum LinkHoverObserverScript {

    /// Must equal the channel name the Chromium bridge routes on.
    public static let channelName = "orbitLinkHover"

    public static let scriptID = UUID(uuidString: "F2A91C46-7D30-4B58-8E1A-3C6D9B04E7F5")!

    // MARK: - Source

    public static let chromiumPostExpression =
        "__orbitPost('\(channelName)', JSON.stringify(payload))"

    public static func source(postExpression: String) -> String {
        """
        (function () {
          'use strict';
          var __orbitLinkHoverKey = Symbol.for('__orbitLinkHoverInstalled');
          if (window[__orbitLinkHoverKey]) { return; }
          window[__orbitLinkHoverKey] = true;

          // __orbitPostMessage is deleted after document-start scripts run; must capture it now, not re-read the global later.
          var __orbitPost = window.__orbitPostMessage;

          var lastPosted = null;

          function post(url) {
            if (url === lastPosted) { return; }
            lastPosted = url;
            var payload = { url: url };
            \(postExpression);
          }

          // SVG <a>.href is an SVGAnimatedString, not a string; .baseVal is the authored value.
          function hrefOf(element) {
            var raw = element.href;
            if (raw && typeof raw === 'object' && 'baseVal' in raw) {
              raw = raw.baseVal;
            }
            if (typeof raw !== 'string' || raw.length === 0) { return null; }
            try {
              return new URL(raw, element.baseURI || document.baseURI).href;
            } catch (e) {
              return null;
            }
          }

          function linkFor(node) {
            if (!node) { return null; }
            var element = node.nodeType === 1 ? node : node.parentElement;
            if (!element || typeof element.closest !== 'function') { return null; }
            var anchor = element.closest('a[href], area[href]');
            return anchor ? hrefOf(anchor) : null;
          }

          document.addEventListener('mouseover', function (event) {
            post(linkFor(event.target));
          }, { capture: true, passive: true });

          document.addEventListener('mouseout', function (event) {
            post(linkFor(event.relatedTarget));
          }, { capture: true, passive: true });

          // mouseout's relatedTarget isn't reliable on every exit path; blur/visibilitychange catch the rest.
          window.addEventListener('blur', function () { post(null); }, { passive: true });
          document.addEventListener('visibilitychange', function () {
            if (document.hidden) { post(null); }
          }, { passive: true });
        })();
        """
    }

    /// `allFrames: true`: a hovered link can be inside an iframe.
    public static var chromiumUserScript: UserScript {
        UserScript(
            id: scriptID,
            kind: .javaScript,
            source: source(postExpression: chromiumPostExpression),
            injectionTime: .documentStart,
            matchPatterns: ["<all_urls>"],
            allFrames: true
        )
    }

    // MARK: - Decoding

    /// Scheme-filtered: `javascript:` must never become a "hovered link".
    public static func decode(payloadJSON: String) -> URL? {
        guard let data = payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return decode(object["url"])
    }

    public static func decode(_ raw: Any?) -> URL? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        guard let url = URL(string: string) else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
