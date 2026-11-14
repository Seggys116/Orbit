extension OrbitInspectAgent {
    static let sourcesSource = ##"""

      var src_overrides = {};    // url -> { styleEl, originalSheet, originalDisabled }
      var src_mutation_timer = null;

      ops["src.list"] = function (message) {
        var files = [];

        files.push({
          id: location.href,
          url: location.href,
          kind: "document",
          mime: "text/html",
          line: null,
          index: null,
          sourceURL: null
        });

        var scripts = document.querySelectorAll("script[src]");
        Array.prototype.forEach.call(scripts, function (el) {
          var src = el.src || "";
          if (!src) return;
          files.push({ id: src, url: src, kind: "script", mime: "text/javascript", line: null, index: null, sourceURL: null });
        });

        var inlineScripts = document.querySelectorAll("script:not([src])");
        Array.prototype.forEach.call(inlineScripts, function (el, idx) {
          var code = el.textContent || "";
          var sourceURL = null;
          var suMatch = code.match(/\/\/[#@]\s*sourceURL=([^\s]+)/);
          if (suMatch) sourceURL = suMatch[1];
          var line = src_elementLine(el);
          var id = sourceURL || ("(inline) " + location.href + ":" + line + ":" + idx);
          var url = sourceURL || ("(inline) " + location.href + ":" + line + ":" + idx);
          files.push({ id: id, url: url, kind: "inline-script", mime: "text/javascript", line: line, index: idx, sourceURL: sourceURL, content: code.length < 524288 ? code : null });
        });

        var links = document.querySelectorAll("link[rel~='stylesheet']");
        Array.prototype.forEach.call(links, function (el) {
          var href = el.href || "";
          if (!href) return;
          files.push({ id: href, url: href, kind: "stylesheet", mime: "text/css", line: null, index: null, sourceURL: null });
        });

        var styles = document.querySelectorAll("style");
        Array.prototype.forEach.call(styles, function (el, idx) {
          if (el.dataset && el.dataset.orbitOverride) return;
          var code = el.textContent || "";
          var line = src_elementLine(el);
          var id = "(inline-style) " + location.href + ":" + line + ":" + idx;
          files.push({ id: id, url: id, kind: "inline-style", mime: "text/css", line: line, index: idx, sourceURL: null, content: code.length < 524288 ? code : null });
        });

        if (document.adoptedStyleSheets && document.adoptedStyleSheets.length) {
          Array.prototype.forEach.call(document.adoptedStyleSheets, function (sheet, idx) {
            var id = "(adopted-style) " + location.href + ":" + idx;
            var text = "";
            try {
              var rules = sheet.cssRules;
              if (rules) {
                for (var ri = 0; ri < Math.min(rules.length, 2000); ri++) {
                  text += (rules[ri].cssText || "") + "\n";
                }
              }
            } catch (e) {}
            files.push({ id: id, url: id, kind: "adopted-stylesheet", mime: "text/css", line: null, index: idx, sourceURL: null, content: text || null });
          });
        }

        if (typeof performance !== "undefined" && performance.getEntriesByType) {
          try {
            var perfEntries = performance.getEntriesByType("resource");
            Array.prototype.forEach.call(perfEntries, function (entry) {
              var url = entry.name;
              if (!url || url === location.href) return;
              var type = entry.initiatorType || "";
              var kind = "other";
              var mime = "";
              if (type === "script") { kind = "script"; mime = "text/javascript"; }
              else if (type === "css" || type === "link") { kind = "stylesheet"; mime = "text/css"; }
              else return;
              var already = false;
              for (var fi = 0; fi < files.length; fi++) {
                if (files[fi].url === url) { already = true; break; }
              }
              if (!already) {
                files.push({ id: url, url: url, kind: kind, mime: mime, line: null, index: null, sourceURL: null });
              }
            });
          } catch (e) {}
        }

        // Running workers cannot be listed from the page, so completeness relies on the native network records.

        post({ t: "src.files", files: files, href: location.href });
      };

      ops["src.cssApply"] = function (message) {
        var url = message.url;
        var text = message.text || "";
        try {
          var original = null;
          var links = document.querySelectorAll("link[rel~='stylesheet']");
          Array.prototype.forEach.call(links, function (el) {
            if (el.href === url || el.href === decodeURIComponent(url)) original = el;
          });
          if (!original && url.indexOf("(inline-style)") === 0) {
            var idx = parseInt((url.split(":").pop() || "0"), 10);
            var styleEls = document.querySelectorAll("style");
            if (idx >= 0 && idx < styleEls.length) original = styleEls[idx];
          }

          src_revertOverride(url);

          var overrideEl = document.createElement("style");
          overrideEl.setAttribute("data-orbit-override", url);
          overrideEl.textContent = text;
          document.head.appendChild(overrideEl);

          var originalDisabled = false;
          if (original && original.sheet) {
            original.sheet.disabled = true;
            originalDisabled = true;
          }

          src_overrides[url] = { styleEl: overrideEl, original: original, originalDisabled: originalDisabled };
          post({ t: "src.cssResult", url: url, ok: true });
        } catch (e) {
          post({ t: "src.cssResult", url: url, ok: false, error: String(e && e.message || e) });
        }
      };

      ops["src.cssRevert"] = function (message) {
        src_revertOverride(message.url);
        post({ t: "src.cssResult", url: message.url, ok: true, reverted: true });
      };

      function src_revertOverride(url) {
        var entry = src_overrides[url];
        if (!entry) return;
        if (entry.styleEl && entry.styleEl.parentNode) entry.styleEl.parentNode.removeChild(entry.styleEl);
        if (entry.original && entry.original.sheet && entry.originalDisabled) {
          entry.original.sheet.disabled = false;
        }
        delete src_overrides[url];
      }

      ops["src.jsRun"] = function (message) {
        var code = message.code || "";
        var id = message.id || "";
        var resultText = "";
        var errorText = "";
        try {
          // CSP may block new Function, so fall back to indirect eval.
          var fn;
          try {
            fn = new Function(code); // eslint-disable-line no-new-func
          } catch (syntaxErr) {
            throw syntaxErr;
          }
          var raw = fn.call(window);
          resultText = preview(raw, 3, new WeakSet());
        } catch (e) {
          errorText = String(e && e.message ? e.name + ": " + e.message : e);
        }
        post({ t: "src.jsResult", id: id, result: resultText, error: errorText });
      };

      ops["src.outerHTML"] = function (message) {
        var html = "";
        try { html = document.documentElement.outerHTML || ""; } catch (e) {}
        if (html.length > 4194304) { html = html.slice(0, 4194304) + "\n<!-- [Orbit: truncated at 4 MB] -->"; }
        post({ t: "src.outerHTML", html: html });
      };

      ops["src.applyHTML"] = function (message) {
        try {
          document.open();
          document.write(message.html || "");
          document.close();
          post({ t: "src.htmlApplied", ok: true });
        } catch (e) {
          post({ t: "src.htmlApplied", ok: false, error: String(e && e.message || e) });
        }
      };

      ops["src.reApplyOverrides"] = function (message) {
        var overrides = message.overrides || {};
        Object.keys(overrides).forEach(function (url) {
          ops["src.cssApply"]({ url: url, text: overrides[url] });
        });
      };

      inits.push(function () {
        if (typeof MutationObserver === "undefined") return;
        var observer = new MutationObserver(function (mutations) {
          var changed = false;
          for (var i = 0; i < mutations.length; i++) {
            var m = mutations[i];
            var nodes = Array.prototype.slice.call(m.addedNodes).concat(Array.prototype.slice.call(m.removedNodes));
            for (var j = 0; j < nodes.length; j++) {
              var n = nodes[j];
              if (n && n.nodeType === 1) {
                var tag = (n.tagName || "").toLowerCase();
                if (tag === "script" || tag === "link" || tag === "style") { changed = true; break; }
              }
            }
            if (changed) break;
          }
          if (!changed) return;
          if (src_mutation_timer) clearTimeout(src_mutation_timer);
          src_mutation_timer = setTimeout(function () {
            src_mutation_timer = null;
            ops["src.list"]({});
          }, 300);
        });
        observer.observe(document.documentElement || document, { childList: true, subtree: true });
        disposers.push(function () { observer.disconnect(); });
      });

      function src_elementLine(el) {
        try {
          if (typeof el.sourceURL !== "undefined") return null;
          // Counting newlines through previous siblings and ancestors is expensive, so the traversal is capped.
          return null;
        } catch (e) { return null; }
      }

      navHooks.push(function () {
        setTimeout(function () { ops["src.list"]({}); }, 100);
      });

    """##
}
