import Foundation
import WebKit

extension WebKitWebContents {

    func find(_ text: String, options: FindOptions) {
        guard !isClosed else { return }
        extras.findGeneration += 1
        let generation = extras.findGeneration
        guard !text.isEmpty else {
            resetFindState()
            clearFindCache()
            clearFindSelection()
            delegate?.webContents(self, didUpdateFindResult: .none)
            return
        }
        let queryChanged = text != extras.findQuery || options.matchCase != extras.findMatchCase
        // Typing refines the search from the match already showing, as Chrome does, instead of jumping past it.
        if !options.findNext, extras.findOrdinal > 0 {
            webView.evaluateJavaScript(Self.collapseSelectionToStartSource, in: nil, in: Self.findWorld, completionHandler: nil)
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !options.forward
        configuration.caseSensitive = options.matchCase
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            guard let self, generation == self.extras.findGeneration, !self.isClosed else { return }
            guard result.matchFound else {
                self.resetFindState()
                self.extras.findQuery = text
                self.extras.findMatchCase = options.matchCase
                self.delegate?.webContents(self, didUpdateFindResult: .none)
                return
            }
            Task { @MainActor in
                let counted = await self.countMatches(of: text, matchCase: options.matchCase, generation: generation)
                guard generation == self.extras.findGeneration, !self.isClosed else { return }
                // An inexact selection reports the first match forever. Walk from the stored position instead.
                var walked = counted
                if options.findNext, let counted, counted.ordinal > 0, counted.ordinal == self.extras.findOrdinal, counted.count > 1 {
                    walked = (count: counted.count, ordinal: 0)
                }
                let resolved = Self.resolveFindResult(
                    counted: walked,
                    previousOrdinal: queryChanged ? 0 : self.extras.findOrdinal,
                    previousCount: queryChanged ? 0 : self.extras.findCount,
                    forward: options.forward
                )
                self.extras.findQuery = text
                self.extras.findMatchCase = options.matchCase
                self.extras.findOrdinal = resolved.ordinal
                self.extras.findCount = resolved.count
                self.delegate?.webContents(self, didUpdateFindResult: FindResult(
                    activeMatchOrdinal: resolved.ordinal, matchCount: resolved.count, isFinalUpdate: true
                ))
            }
        }
    }

    func stopFinding(clearSelection: Bool) {
        extras.findGeneration += 1
        resetFindState()
        clearFindCache()
        if clearSelection { clearFindSelection() }
    }

    private func resetFindState() {
        extras.findQuery = ""
        extras.findOrdinal = 0
        extras.findCount = 0
    }

    private func clearFindSelection() {
        webView.evaluateJavaScript(Self.clearSelectionSource, in: nil, in: Self.findWorld, completionHandler: nil)
    }

    /// Drops the page-side match list. The next search walks again; stepping through an unchanged query does not.
    private func clearFindCache() {
        let script = Self.clearFindCacheSource(epoch: extras.findGeneration)
        webView.evaluateJavaScript(script, in: nil, in: WKContentWorld.page, completionHandler: nil)
    }

    private static var findWorld: WKContentWorld { WKContentWorld.world(name: "orbit-find") }

    /// WebKit confirmed a match. The walker's count and the selection's position are the truth when it
    /// can see them; otherwise the ordinal advances from where it was, wrapping at either end.
    static func resolveFindResult(
        counted: (count: Int, ordinal: Int)?,
        previousOrdinal: Int,
        previousCount: Int,
        forward: Bool
    ) -> (count: Int, ordinal: Int) {
        let count = max(counted?.count ?? 0, previousCount, 1)
        var ordinal = counted?.ordinal ?? 0
        if ordinal == 0 {
            if previousOrdinal == 0 {
                ordinal = 1
            } else if forward {
                ordinal = previousOrdinal % count + 1
            } else {
                ordinal = previousOrdinal <= 1 ? count : previousOrdinal - 1
            }
        }
        return (count, min(max(ordinal, 1), count))
    }

    private func countMatches(of text: String, matchCase: Bool, generation: Int) async -> (count: Int, ordinal: Int)? {
        let script = Self.countSource(query: JavaScriptLiteral.string(text), matchCase: matchCase, generation: generation)
        // The page world, not the find world: the selection WebKit's find paints lives there, and a named
        // world evaluation is what fails closed on these pages.
        let raw = try? await webView.evaluateJavaScript(script)
        let text = raw as? String ?? (raw as? NSString).map(String.init)
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = Self.jsonInt(object["count"]),
              let ordinal = Self.jsonInt(object["ordinal"])
        else { return nil }
        return (count, ordinal)
    }

    // JSONSerialization boxes numbers as NSNumber. Casting the dictionary to [String: Int] drops the payload.
    private static func jsonInt(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        return (value as? NSNumber)?.intValue
    }

    // Same-origin frames in WebKit's own search order: the main document, then each frame depth first.
    private static let documentsHelper = """
    function orbitDocuments() {
      var out = [];
      (function visit(win) {
        var doc;
        try { doc = win.document; void doc.body; } catch (e) { return; }
        out.push(doc);
        var frames = doc.querySelectorAll('iframe, frame');
        for (var i = 0; i < frames.length; i++) {
          try { if (frames[i].contentWindow) { visit(frames[i].contentWindow); } } catch (e) {}
        }
      })(window);
      return out;
    }
    """

    private static let clearSelectionSource = """
    (function () {
      \(documentsHelper)
      orbitDocuments().forEach(function (doc) {
        try { doc.defaultView.getSelection().removeAllRanges(); } catch (e) {}
      });
    })()
    """

    private static func clearFindCacheSource(epoch: Int) -> String {
        """
        (function () {
          \(documentsHelper)
          window.__orbitFindEpoch = \(epoch);
          function disarm(doc) {
            try {
              if (doc && doc.__orbitFindObserver) {
                doc.__orbitFindObserver.disconnect();
                doc.__orbitFindObserver = null;
              }
              if (doc) doc.__orbitFindDirty = false;
            } catch (e) {}
          }
          try {
            var cache = window.__orbitFindCache;
            if (cache && cache.docs) {
              for (var i = 0; i < cache.docs.length; i++) disarm(cache.docs[i]);
            }
          } catch (e) {}
          try { orbitDocuments().forEach(disarm); } catch (e) {}
          try { delete window.__orbitFindCache; } catch (e) { window.__orbitFindCache = null; }
        })()
        """
    }

    private static let collapseSelectionToStartSource = """
    (function () {
      \(documentsHelper)
      orbitDocuments().forEach(function (doc) {
        try {
          var selection = doc.defaultView.getSelection();
          if (selection.rangeCount > 0 && !selection.isCollapsed) { selection.collapseToStart(); }
        } catch (e) {}
      });
    })()
    """

    // Matches are found in the rendered text, whitespace collapsed and blocks kept apart, the way WebKit's own search reads the page.
    private static func countSource(query: String, matchCase: Bool, generation: Int) -> String {
        """
        (function (rawNeedle, matchCase) {
          // A stop or a newer find publishes a higher epoch before this script runs. Do not walk
          // or replace the match list for a search that has already been superseded.
          if ((window.__orbitFindEpoch || 0) > \(generation)) {
            return JSON.stringify({ count: 0, ordinal: 0 });
          }
          window.__orbitFindEpoch = \(generation);
          \(documentsHelper)
          function fold(ch) {
            if (matchCase) { return ch; }
            var lower = ch.toLowerCase();
            return lower.length === 1 ? lower : ch;
          }
          var needle = '';
          var previousSpace = false;
          for (var n = 0; n < rawNeedle.length; n++) {
            var c = rawNeedle[n];
            if (/\\s/.test(c)) { if (!previousSpace) { needle += ' '; } previousSpace = true; }
            else { needle += fold(c); previousSpace = false; }
          }
          if (needle.length === 0) { return JSON.stringify({ count: 0, ordinal: 0 }); }

          function matchesIn(doc, out) {
            var root = doc.body || doc.documentElement;
            if (!root) { return; }
            var walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            var chars = [], map = [];
            var hidden = new Map(), blocks = new Map();
            var lastBlock = null, lastSpace = true;
            // checkVisibility() is false for every element until the view has renderers. A web view that
            // is sized but not in a window has none, so it would drop the visible text along with the hidden.
            function isHidden(el) {
              if (hidden.has(el)) { return hidden.get(el); }
              var node = el, hide = false;
              while (node && node.nodeType === 1) {
                var tag = node.tagName;
                if (node.hidden || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE' || tag === 'HEAD') {
                  hide = true;
                  break;
                }
                try {
                  var style = doc.defaultView.getComputedStyle(node);
                  if (style && (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.contentVisibility === 'hidden')) {
                    hide = true;
                    break;
                  }
                } catch (e) {}
                node = node.parentElement;
              }
              hidden.set(el, hide);
              return hide;
            }
            function blockOf(el) {
              if (blocks.has(el)) { return blocks.get(el); }
              var node = el, block = doc.documentElement;
              try {
                while (node) {
                  var display = doc.defaultView.getComputedStyle(node).display;
                  if (display.indexOf('inline') !== 0 && display !== 'contents') { block = node; break; }
                  node = node.parentElement;
                }
              } catch (e) {}
              blocks.set(el, block);
              return block;
            }
            var node;
            while ((node = walker.nextNode())) {
              var parent = node.parentElement;
              if (!parent || isHidden(parent)) { continue; }
              var block = blockOf(parent);
              if (lastBlock !== null && block !== lastBlock) { chars.push('\\n'); map.push(null); lastSpace = true; }
              lastBlock = block;
              var data = node.data;
              for (var i = 0; i < data.length; i++) {
                var ch = data[i];
                if (/\\s/.test(ch)) {
                  if (lastSpace) { continue; }
                  chars.push(' '); map.push({ node: node, offset: i }); lastSpace = true;
                } else {
                  chars.push(fold(ch)); map.push({ node: node, offset: i }); lastSpace = false;
                }
              }
            }
            var haystack = chars.join('');
            var from = 0, at;
            while ((at = haystack.indexOf(needle, from)) !== -1) {
              var start = map[at], end = map[at + needle.length - 1];
              if (start && end) {
                var range = doc.createRange();
                range.setStart(start.node, start.offset);
                range.setEnd(end.node, end.offset + 1);
                out.push({ doc: doc, range: range });
              }
              from = at + needle.length;
            }
          }

          // Stepping to the next match used to walk every text node and resolve computed style again.
          // The match list only changes when the text or the visibility does, so keep it and rebuild
          // when a mutation lands. The active ordinal still comes from the selection, which is what wraps.
          function disarm(doc) {
            try {
              if (doc && doc.__orbitFindObserver) {
                doc.__orbitFindObserver.disconnect();
                doc.__orbitFindObserver = null;
              }
              if (doc) doc.__orbitFindDirty = false;
            } catch (e) {}
          }
          function arm(doc) {
            if (!doc || !doc.documentElement) return false;
            if (doc.__orbitFindObserver) return true;
            try {
              var observer = new MutationObserver(function () { doc.__orbitFindDirty = true; });
              observer.observe(doc.documentElement, {
                subtree: true, childList: true, characterData: true, attributes: true
              });
              doc.__orbitFindObserver = observer;
              return true;
            } catch (e) { return false; }
          }
          function sameDocs(cachedDocs, liveDocs) {
            if (!cachedDocs || cachedDocs.length !== liveDocs.length) return false;
            for (var i = 0; i < liveDocs.length; i++) {
              if (cachedDocs[i] !== liveDocs[i]) return false;
            }
            return true;
          }
          // Pending records are drained here: the observer callback is a microtask, and the next
          // find can run before that callback sets the dirty flag.
          function docsAreClean(cachedDocs) {
            if (!cachedDocs) return false;
            for (var i = 0; i < cachedDocs.length; i++) {
              var doc = cachedDocs[i];
              if (!doc || !doc.documentElement || !doc.__orbitFindObserver || doc.__orbitFindDirty) return false;
              try {
                if (doc.__orbitFindObserver.takeRecords().length > 0) {
                  doc.__orbitFindDirty = true;
                  return false;
                }
              } catch (e) { return false; }
            }
            return true;
          }

          var docs = orbitDocuments();
          var all = [];
          var reused = null;
          try {
            var cached = window.__orbitFindCache;
            if (cached && cached.needle === needle && cached.matchCase === matchCase && Array.isArray(cached.matches)
                && sameDocs(cached.docs, docs) && docsAreClean(cached.docs)) {
              reused = cached.matches;
            }
          } catch (e) {}
          if (reused) {
            all = reused;
          } else {
            var previous = null;
            try { previous = window.__orbitFindCache; } catch (e) {}
            if (previous && previous.docs) {
              for (var p = 0; p < previous.docs.length; p++) {
                var stale = previous.docs[p];
                var stillLive = false;
                for (var q = 0; q < docs.length; q++) { if (docs[q] === stale) { stillLive = true; break; } }
                if (!stillLive) disarm(stale);
              }
            }
            var canCache = true;
            for (var d = 0; d < docs.length; d++) { if (!arm(docs[d])) canCache = false; }
            for (var s = 0; s < docs.length; s++) { try { matchesIn(docs[s], all); } catch (e) {} }
            var stable = canCache;
            for (var c = 0; c < docs.length; c++) {
              var observer = docs[c].__orbitFindObserver;
              var changedDuringScan = true;
              try { changedDuringScan = !observer || observer.takeRecords().length > 0; }
              catch (e) { changedDuringScan = true; }
              if (changedDuringScan) stable = false;
              docs[c].__orbitFindDirty = false;
            }
            if (stable && window.__orbitFindEpoch === \(generation)) {
              window.__orbitFindCache = { needle: needle, matchCase: matchCase, docs: docs, matches: all };
            } else {
              try { delete window.__orbitFindCache; } catch (e) { window.__orbitFindCache = null; }
            }
          }

          var ordinal = 0;
          for (var k = 0; k < all.length && ordinal === 0; k++) {
            var selection;
            try { selection = all[k].doc.defaultView.getSelection(); } catch (e) { continue; }
            if (!selection || selection.rangeCount === 0 || selection.isCollapsed) { continue; }
            try {
              if (selection.getRangeAt(0).compareBoundaryPoints(Range.START_TO_START, all[k].range) === 0) { ordinal = k + 1; }
            } catch (e) {}
          }
          return JSON.stringify({ count: all.length, ordinal: ordinal });
        })(\(query), \(matchCase))
        """
    }
}
