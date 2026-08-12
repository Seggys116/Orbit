import Foundation

public enum PageColorObserverScript {

    public static let channelName = "orbitPageColor"

    public static let scriptID = UUID(uuidString: "B7C4D2E1-5A83-4F16-9C0D-2E7A46B18F30")!

    public static let minimumPostInterval: Duration = .milliseconds(250)

    public static let idleReReadInterval: Duration = .seconds(2)

    public static let scrollQuietInterval: Duration = .milliseconds(150)

    // MARK: - Source

    public static let chromiumPostExpression =
        "__orbitPost('\(channelName)', JSON.stringify(payload))"

    public static func source(postExpression: String) -> String {
        let minimumPostIntervalMS = Int(minimumPostInterval.components.seconds * 1000
            + minimumPostInterval.components.attoseconds / 1_000_000_000_000_000)
        let idleReReadMS = Int(idleReReadInterval.components.seconds * 1000
            + idleReReadInterval.components.attoseconds / 1_000_000_000_000_000)
        let scrollQuietMS = Int(scrollQuietInterval.components.seconds * 1000
            + scrollQuietInterval.components.attoseconds / 1_000_000_000_000_000)

        return """
        (function() {
          var __orbitInstalledKey = Symbol.for('__orbitPageColorObserverInstalled');
          if (window[__orbitInstalledKey]) { return; }
          window[__orbitInstalledKey] = true;

          // Captured now, before the engine deletes the global binding.
          var __orbitPost = window.__orbitPostMessage;

        \(PageThemeColorScript.resolverSource)

          var MINIMUM_POST_INTERVAL_MS = \(minimumPostIntervalMS);
          var IDLE_RE_READ_MS = \(idleReReadMS);
          var SCROLL_QUIET_MS = \(scrollQuietMS);

          // undefined, not null: null is a real postable answer.
          var lastPostedColor;
          var lastPostedDocument;
          var lastPostTime = 0;
          var pendingTimer = null;
          var scrollTimer = null;
          var mediaQueryLists = [];

          function post(payload) {
            try { \(postExpression); } catch (e) {}
          }

          function evaluateAndPost() {
            pendingTimer = null;
            lastPostTime = Date.now();
            var reading;
            try { reading = __orbitReadPageColor(); } catch (e) { return; }
            if (!reading) { return; }
            // "No colour yet" while still parsing would flash the chrome to its fallback.
            if (reading.color === null && !reading.ready) { return; }
            if (reading.color === lastPostedColor && reading.document === lastPostedDocument) { return; }
            lastPostedColor = reading.color;
            lastPostedDocument = reading.document;
            post({ color: reading.color, document: reading.document, ready: reading.ready });
          }

          function schedule() {
            if (pendingTimer !== null) { return; }
            var elapsed = Date.now() - lastPostTime;
            var delay = elapsed >= MINIMUM_POST_INTERVAL_MS ? 0 : (MINIMUM_POST_INTERVAL_MS - elapsed);
            pendingTimer = setTimeout(evaluateAndPost, delay);
          }

          function scheduleAfterScrollSettles() {
            if (scrollTimer !== null) { clearTimeout(scrollTimer); }
            scrollTimer = setTimeout(function() {
              scrollTimer = null;
              schedule();
            }, SCROLL_QUIET_MS);
          }

          function refreshMediaQueryListeners() {
            for (var i = 0; i < mediaQueryLists.length; i++) {
              try { mediaQueryLists[i].removeEventListener('change', schedule); } catch (e) {}
            }
            mediaQueryLists = [];
            if (!window.matchMedia) { return; }
            var queries = ['(prefers-color-scheme: dark)'].concat(__orbitDeclaredMediaQueries());
            for (var j = 0; j < queries.length; j++) {
              try {
                var list = window.matchMedia(queries[j]);
                list.addEventListener('change', schedule);
                mediaQueryLists.push(list);
              } catch (e) {}
            }
          }

          // <html>/<body> watched for their own attributes only; a subtree observer there fires on every DOM write.
          var headObserver = new MutationObserver(function() {
            refreshMediaQueryListeners();
            schedule();
          });
          var rootObserver = new MutationObserver(schedule);

          function observeDocument() {
            try {
              if (document.head) {
                headObserver.observe(document.head, {
                  childList: true,
                  subtree: true,
                  attributes: true,
                  attributeFilter: ['content', 'media', 'name']
                });
              }
            } catch (e) {}
            // No attributeFilter: dark-mode toggles use class/style/data-theme/etc.; an enumerated list is always incomplete.
            try {
              if (document.documentElement) {
                rootObserver.observe(document.documentElement, { attributes: true });
              }
            } catch (e) {}
            try {
              if (document.body) {
                rootObserver.observe(document.body, { attributes: true });
              }
            } catch (e) {}
          }

          function resubscribe() {
            observeDocument();
            refreshMediaQueryListeners();
            schedule();
          }

          document.addEventListener('readystatechange', resubscribe, true);
          document.addEventListener('DOMContentLoaded', resubscribe, true);
          window.addEventListener('load', resubscribe);
          window.addEventListener('pageshow', schedule);

          window.addEventListener('resize', schedule);

          // capture: true because scroll doesn't bubble.
          document.addEventListener('scroll', scheduleAfterScrollSettles, { passive: true, capture: true });

          // pushState/replaceState are left unwrapped (a patched native fn fails anti-bot's toString() check); an unmatched route push is caught by the idle safety net instead.
          window.addEventListener('popstate', schedule);
          window.addEventListener('hashchange', schedule);

          document.addEventListener('visibilitychange', function() {
            if (!document.hidden) { schedule(); }
          });

          setInterval(function() {
            if (document.hidden) { return; }
            schedule();
          }, IDLE_RE_READ_MS);

          resubscribe();
        })();
        """
    }

    public static var chromiumUserScript: UserScript {
        UserScript(
            id: scriptID,
            kind: .javaScript,
            source: source(postExpression: chromiumPostExpression),
            injectionTime: .documentStart,
            matchPatterns: ["<all_urls>"],
            // An ad iframe reporting its own background as the page's colour would be actively wrong.
            allFrames: false
        )
    }

    // MARK: - Decoding

    public static func decode(_ raw: Any?) -> PageThemeColorScript.Reading? {
        PageThemeColorScript.decode(raw)
    }

    public static func decode(payloadJSON json: String) -> PageThemeColorScript.Reading? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return PageThemeColorScript.decode(object)
    }
}
