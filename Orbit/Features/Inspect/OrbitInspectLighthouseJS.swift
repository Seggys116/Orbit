extension OrbitInspectAgent {
    // swiftlint:disable:next line_length
    static let lighthouseSource = ##"""

      var lh_fcpMs = null;
      var lh_lcpMs = null;
      var lh_lcpElement = null;      // node id via refOf
      var lh_lcpSelector = "";
      var lh_lcpURL = "";
      var lh_lcpTag = "";
      var lh_lcpSnippet = "";
      var lh_lcpLoadMs = null;
      var lh_lcpRenderMs = null;
      var lh_clsScore = 0;
      var lh_clsShifts = [];
      var lh_clsShiftsTruncated = false;
      var lh_inpMax = null;
      var lh_longTasks = [];
      var lh_longTasksOk = false;
      var lh_docWriteDetected = false;
      var lh_syncXHRDetected = false;
      var lh_geoDetected = false;
      var lh_notifDetected = false;
      var lh_unloadDetected = false;
      var lh_timespanStartMs = null;
      var lh_clsAtTimespanStart = 0;
      var lh_longTasksAtTimespanStart = 0;
      var lh_loadedPosted = false;


      function lh_cssEscape(str) {
        if (typeof CSS !== "undefined" && CSS.escape) { return CSS.escape(str); }
        return String(str).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
      }

      function lh_cssSelector(el, depth) {
        if (!el || el.nodeType !== 1) { return ""; }
        if (depth === undefined) { depth = 0; }
        if (depth > 4) { return (el.tagName || "").toLowerCase(); }
        if (el.id && el.id.length < 40) { return "#" + lh_cssEscape(el.id); }
        var tag = (el.tagName || "").toLowerCase();
        var parent = el.parentElement;
        if (!parent) { return tag; }
        var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
        var idx = Array.prototype.indexOf.call(same, el) + 1;
        var parentSel = lh_cssSelector(parent, depth + 1);
        return (parentSel ? parentSel + " > " : "") + tag + (same.length > 1 ? ":nth-of-type(" + idx + ")" : "");
      }

      function lh_snippet(el) {
        try {
          // Only the first opening tag, capped at 150 characters.
          var outer = el.outerHTML || "";
          var end = outer.indexOf(">");
          return end > 0 ? outer.slice(0, Math.min(end + 1, 150)) : outer.slice(0, 150);
        } catch (e) { return ""; }
      }

      function lh_accessibleName(el) {
        try {
          var label = el.getAttribute("aria-label");
          if (label && label.trim()) { return label.trim().slice(0, 200); }
          var labelledBy = el.getAttribute("aria-labelledby");
          if (labelledBy) {
            var parts = labelledBy.split(/\s+/).map(function (id) {
              var ref = document.getElementById(id);
              return ref ? (ref.textContent || "").trim() : "";
            }).filter(Boolean);
            if (parts.length) { return parts.join(" ").slice(0, 200); }
          }
          var elId = el.id;
          if (elId) {
            var forLabel = document.querySelector("label[for=" + JSON.stringify(elId) + "]");
            if (forLabel) { return (forLabel.textContent || "").trim().slice(0, 200); }
          }
          var parentLabel = el.closest && el.closest("label");
          if (parentLabel) { return (parentLabel.textContent || "").trim().slice(0, 200); }
          if (el.tagName === "IMG") {
            var alt = el.getAttribute("alt");
            return alt !== null ? alt : null;
          }
          var text = (el.textContent || el.innerText || "").trim();
          if (text) { return text.slice(0, 200); }
          var titleAttr = el.getAttribute("title");
          if (titleAttr && titleAttr.trim()) { return titleAttr.trim().slice(0, 200); }
          return "";
        } catch (e) { return ""; }
      }

      function lh_parseRGBA(str) {
        if (!str || str === "transparent") { return [0, 0, 0, 0]; }
        var m = str.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+))?\s*\)/);
        if (!m) { return null; }
        return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10), m[4] !== undefined ? parseFloat(m[4]) : 1];
      }

      function lh_luminance(r, g, b) {
        function lin(c) { var v = c / 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
      }

      function lh_contrastRatio(fg, bg) {
        var l1 = lh_luminance(fg[0], fg[1], fg[2]);
        var l2 = lh_luminance(bg[0], bg[1], bg[2]);
        return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
      }

      // Walks ancestors until an opaque background is found, since contrast must be judged against what is actually painted behind the text.
      function lh_resolvedBg(el) {
        var stack = [];
        var cur = el;   // start from the element itself
        var needsReview = false;
        var guard = 0;
        while (cur && cur.nodeType === 1 && guard < 12) {
          guard++;
          try {
            var st = getComputedStyle(cur);
            var bgImg = st.backgroundImage;
            if (bgImg && bgImg !== "none") { needsReview = true; break; }
            var bg = lh_parseRGBA(st.backgroundColor);
            if (bg && bg[3] > 0) {
              stack.push(bg);
              if (bg[3] >= 1) { break; }
            }
          } catch (e) { break; }
          cur = cur.parentElement;
        }
        var base = [255, 255, 255, 1];
        for (var i = stack.length - 1; i >= 0; i--) {
          var layer = stack[i];
          var a = layer[3];
          base = [
            Math.round(layer[0] * a + base[0] * (1 - a)),
            Math.round(layer[1] * a + base[1] * (1 - a)),
            Math.round(layer[2] * a + base[2] * (1 - a)),
            1
          ];
        }
        return { color: base, needsReview: needsReview };
      }

      // A DOMRect as [left, top, width, height] in CSS pixels, rounded to a tenth.
      function lh_rect(r) {
        if (!r) { return null; }
        function t(n) { return Math.round(n * 10) / 10; }
        return [t(r.left !== undefined ? r.left : r.x), t(r.top !== undefined ? r.top : r.y), t(r.width), t(r.height)];
      }

      // Elements that failed a check and have no richer record: selector, node id and the opening tag.
      function lh_evidence(el) {
        return { sel: lh_cssSelector(el), id: idOf(el), snip: lh_snippet(el) };
      }

      function lh_domDepth(node) {
        var depth = 0;
        var cur = node;
        while (cur.parentElement) { depth++; cur = cur.parentElement; }
        return depth;
      }

      var lh_layoutProps = { width: 1, height: 1, top: 1, left: 1, right: 1, bottom: 1, margin: 1, padding: 1,
        "font-size": 1, "line-height": 1 };
      var lh_paintProps = { color: 1, background: 1, "background-color": 1, "box-shadow": 1,
        "border-color": 1, opacity: 1, visibility: 1 };

      function lh_animTriggers(props) {
        var layout = false, paint = false;
        props.forEach(function (p) {
          if (lh_layoutProps[p]) { layout = true; }
          if (lh_paintProps[p]) { paint = true; }
        });
        return { layout: layout, paint: paint };
      }


      function lh_setupObservers() {
        if (typeof PerformanceObserver === "undefined") { return; }

        try {
          new PerformanceObserver(function (list) {
            list.getEntries().forEach(function (e) {
              if (e.name === "first-contentful-paint") { lh_fcpMs = e.startTime; }
            });
          }).observe({ type: "paint", buffered: true });
        } catch (e) {}

        try {
          new PerformanceObserver(function (list) {
            var entries = list.getEntries();
            var last = entries[entries.length - 1];
            lh_lcpMs = last.startTime;
            lh_lcpLoadMs = last.loadTime || null;
            lh_lcpRenderMs = last.renderTime || null;
            if (last.element) {
              lh_lcpElement = refOf(last.element);
              lh_lcpSelector = lh_cssSelector(last.element);
              lh_lcpTag = (last.element.tagName || "").toLowerCase();
              lh_lcpSnippet = lh_snippet(last.element);
            }
            lh_lcpURL = last.url || "";
          }).observe({ type: "largest-contentful-paint", buffered: true });
        } catch (e) {}

        try {
          new PerformanceObserver(function (list) {
            list.getEntries().forEach(function (e) {
              if (!e.hadRecentInput) {
                lh_clsScore += e.value;
                var sources = [];
                var details = [];
                if (e.sources) {
                  e.sources.forEach(function (s) {
                    if (s.node) {
                      var name = lh_cssSelector(s.node);
                      sources.push(name);
                      details.push({ sel: name, ref: refOf(s.node), prev: lh_rect(s.previousRect), cur: lh_rect(s.currentRect) });
                    }
                  });
                }
                // The shift list is kept short; the running total above still counts every shift.
                if (lh_clsShifts.length < 150) {
                  lh_clsShifts.push({ v: e.value, t: e.startTime, srcs: sources.slice(0, 5), det: details.slice(0, 5) });
                } else {
                  lh_clsShiftsTruncated = true;
                }
              }
            });
          }).observe({ type: "layout-shift", buffered: true });
        } catch (e) {}

        // WebKit accepts observe({ type: "longtask" }) without error and then never reports a task, so support is read
        // from supportedEntryTypes; otherwise TBT would read a false 0 ms.
        try {
          var lh_types = (typeof PerformanceObserver !== "undefined" && PerformanceObserver.supportedEntryTypes) || [];
          if (lh_types.indexOf("longtask") >= 0) {
            new PerformanceObserver(function (list) {
              list.getEntries().forEach(function (e) {
                lh_longTasks.push({ s: e.startTime, d: e.duration });
              });
            }).observe({ type: "longtask", buffered: true });
            lh_longTasksOk = true;
          } else {
            lh_longTasksOk = false;
          }
        } catch (e) { lh_longTasksOk = false; }

        try {
          new PerformanceObserver(function (list) {
            list.getEntries().forEach(function (e) {
              var dur = (e.processingEnd || e.startTime) - e.startTime;
              if (lh_inpMax === null || dur > lh_inpMax) { lh_inpMax = dur; }
            });
          }).observe({ type: "event", buffered: true, durationThreshold: 16 });
        } catch (e) {}
      }

      // Observers, the geolocation and Notification wrappers and the load listener are never disposed, so a second init installs only the disposable hooks.
      var lh_permanentInstalled = false;

      function lh_hasUnloadListener() {
        try {
          if (window.onunload || window.onbeforeunload) return true;
          var list = typeof el_listeners !== "undefined" ? el_listeners.get(window) : null;
          return !!(list && list.some(function (entry) { return entry.type === "unload" || entry.type === "beforeunload"; }));
        } catch (e) { return false; }
      }

      inits.push(function () {
        var lh_first = !lh_permanentInstalled;
        lh_permanentInstalled = true;
        if (lh_first) { lh_setupObservers(); }

        // This install's switch: once disposed, a wrapper left inside a later patch only passes calls through.
        var live = { on: true };
        disposers.push(function () { live.on = false; });

        // The document.write wrapper is removed rather than reassigned so any later prototype patch stays in effect.
        try {
          var origWrite = document.write;
          var writeWrap = document.write = function () {
            if (live.on) lh_docWriteDetected = true;
            return origWrite.apply(this, arguments);
          };
          disposers.push(function () {
            try { if (Object.prototype.hasOwnProperty.call(document, "write") && document.write === writeWrap) delete document.write; } catch (e) {}
            restoreIfOurs(document, "write", writeWrap, origWrite);
          });
        } catch (e) {}

        try {
          var origOpen = XMLHttpRequest.prototype.open;
          var openWrap = XMLHttpRequest.prototype.open = function (method, url, async) {
            if (live.on && async === false) { lh_syncXHRDetected = true; }
            return origOpen.apply(this, arguments);
          };
          disposers.push(function () { restoreIfOurs(XMLHttpRequest.prototype, "open", openWrap, origOpen); });
        } catch (e) {}

        try {
          if (lh_first && navigator.geolocation) {
            var origGet  = navigator.geolocation.getCurrentPosition.bind(navigator.geolocation);
            var origWat  = navigator.geolocation.watchPosition.bind(navigator.geolocation);
            navigator.geolocation.getCurrentPosition = function () {
              lh_geoDetected = true;
              return origGet.apply(navigator.geolocation, arguments);
            };
            navigator.geolocation.watchPosition = function () {
              lh_geoDetected = true;
              return origWat.apply(navigator.geolocation, arguments);
            };
          }
        } catch (e) {}

        try {
          if (lh_first && typeof Notification !== "undefined" && Notification.requestPermission) {
            var origNotif = Notification.requestPermission.bind(Notification);
            Notification.requestPermission = function () {
              lh_notifDetected = true;
              return origNotif.apply(Notification, arguments);
            };
          }
        } catch (e) {}

        // Unload listeners are read from the Elements listener record, since wrapping window.addEventListener would shadow later prototype patches.

        if (lh_first) window.addEventListener("load", function () {
          var lastCount = performance.getEntriesByType ? performance.getEntriesByType("resource").length : 0;
          var idle = 0;
          var timer = setInterval(function () {
            var count = performance.getEntriesByType ? performance.getEntriesByType("resource").length : lastCount;
            if (count === lastCount) {
              idle++;
              if (idle >= 4 && !lh_loadedPosted) {  // 4 × 500 ms = 2 s idle
                clearInterval(timer);
                lh_loadedPosted = true;
                post({ t: "lh.loaded" });
              }
            } else {
              idle = 0;
              lastCount = count;
            }
          }, 500);
        });
      });


      // Main-thread observation. With no Long Tasks API, a Navigation run arms this through sessionStorage before its
      // reload so the new document starts it at document start, ahead of the page's own scripts.
      var lh_realSetTimeout = window.setTimeout;
      var lh_obs = null;

      // The first page script in the call stack, so work is charged to the file that scheduled it. Agent frames have no URL.
      function lh_callerURL() {
        try {
          var lines = String(new Error().stack || "").split("\n");
          for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            var at = line.lastIndexOf("@");
            // The agent's own frames. Injected into a document that is already loaded, they carry that document's address, so without this the work is charged to the page instead of the script that scheduled it.
            var fname = at >= 0 ? line.slice(0, at) : "";
            if (fname === "lh_callerURL" || fname === "wrap" || fname === "measured") continue;
            var loc = (at >= 0 ? line.slice(at + 1) : line).trim().replace(/^\(|\)$/g, "").replace(/:\d+:\d+$/, "");
            if (/^(https?|file):/.test(loc)) return loc.slice(0, 300);
          }
        } catch (e) {}
        return null;
      }

      function lh_record(o, category, src, t0, t1) {
        var key = category + "|" + src;
        var total = o.totals[key] || (o.totals[key] = { c: category, u: src, n: 0, t: 0 });
        total.n++; total.t += t1 - t0;
        if (t1 - t0 >= 5 && o.spans.length < 3000) o.spans.push({ c: category, u: src, s: t0, e: t1 });
      }

      function lh_wrapObserved(o) {
        function timed(category, fn, src) {
          return function () {
            if (!o.on) return fn.apply(this, arguments);
            var t0 = performance.now();
            try { return fn.apply(this, arguments); } finally { lh_record(o, category, src, t0, performance.now()); }
          };
        }
        function wrapScheduler(name, category) {
          var real = window[name];
          if (typeof real !== "function") return;
          var wrap = function (fn) {
            if (!o.on || typeof fn !== "function") return real.apply(window, arguments);
            var src = lh_callerURL();
            if (!src) return real.apply(window, arguments);
            var args = Array.prototype.slice.call(arguments);
            args[0] = timed(category, fn, src);
            return real.apply(window, args);
          };
          window[name] = wrap;
          // Put back only if nothing replaced it since; a reference the page kept still works, as it passes calls through once off.
          o.restore.push(function () { if (window[name] === wrap) window[name] = real; });
        }
        wrapScheduler("setTimeout", "Timer callbacks");
        wrapScheduler("setInterval", "Timer callbacks");
        wrapScheduler("requestAnimationFrame", "Animation frame callbacks");

        // A layout read is microseconds on a clean layout; one that takes a millisecond or more had to lay the page out first.
        function wrapRead(proto, name, isMethod) {
          try {
            var desc = Object.getOwnPropertyDescriptor(proto, name);
            if (!desc) return;
            var real = isMethod ? desc.value : desc.get;
            if (typeof real !== "function") return;
            var measured = function () {
              if (!o.on) return real.apply(this, arguments);
              var t0 = performance.now();
              var result = real.apply(this, arguments);
              var dt = performance.now() - t0;
              if (dt >= 1) {
                var src = lh_callerURL();
                if (src) { var r = o.layouts[src] || (o.layouts[src] = { u: src, n: 0, t: 0 }); r.n++; r.t += dt; }
              }
              return result;
            };
            var next = {};
            for (var k in desc) { next[k] = desc[k]; }
            if (isMethod) { next.value = measured; } else { next.get = measured; }
            Object.defineProperty(proto, name, next);
            o.restore.push(function () {
              var now = Object.getOwnPropertyDescriptor(proto, name);
              if (now && (isMethod ? now.value : now.get) === measured) Object.defineProperty(proto, name, desc);
            });
          } catch (e) {}
        }
        wrapRead(Element.prototype, "getBoundingClientRect", true);
        ["offsetWidth", "offsetHeight", "offsetTop", "offsetLeft"].forEach(function (n) { wrapRead(HTMLElement.prototype, n, false); });
        ["clientWidth", "clientHeight", "scrollWidth", "scrollHeight"].forEach(function (n) { wrapRead(Element.prototype, n, false); });
      }

      function lh_startObservation(budgetMs) {
        if (lh_obs || window !== window.top) return;
        var start = performance.now();
        var o = lh_obs = { period: 10, from: start, last: start, until: start + budgetMs, on: true,
                           blocks: [], spans: [], totals: {}, layouts: {}, scripts: [], restore: [] };
        function tick() {
          if (!o.on) return;
          var now = performance.now();
          var due = o.last + o.period;
          // The tick was due at `due` and ran at `now`, so the thread was busy at least that long: a lower bound within one period.
          if (now - due > 50 && o.blocks.length < 2000) o.blocks.push({ s: due, e: now });
          o.last = now;
          if (now > o.until) { lh_stopObservation(); return; }
          lh_realSetTimeout.call(window, tick, o.period);
        }
        lh_realSetTimeout.call(window, tick, o.period);
        lh_wrapObserved(o);
        // A classic script fires load straight after it has run, so download end to load is its evaluation window.
        document.addEventListener("load", function (ev) {
          var el = ev.target;
          if (!o.on || !el || el.tagName !== "SCRIPT" || !el.src) return;
          try {
            var entries = performance.getEntriesByName(el.src, "resource");
            if (entries.length && o.scripts.length < 300) {
              o.scripts.push({ u: String(el.src).slice(0, 300), re: entries[entries.length - 1].responseEnd, ld: performance.now() });
            }
          } catch (e) {}
        }, true);
      }

      function lh_stopObservation() {
        var o = lh_obs;
        if (!o || !o.on) return;
        o.on = false;
        o.to = performance.now();
        o.restore.forEach(function (f) { try { f(); } catch (e) {} });
        o.restore = [];
      }

      function lh_resourceSpans() {
        var out = [];
        try {
          (performance.getEntriesByType("resource") || []).slice(0, 500).forEach(function (r) {
            out.push({ s: r.startTime, e: r.responseEnd > 0 ? r.responseEnd : null, u: String(r.name).slice(0, 300) });
          });
        } catch (e) {}
        return out;
      }

      function lh_observationPayload(sinceMs) {
        var o = lh_obs;
        if (!o) return { ok: false };
        var since = sinceMs || 0;
        var spans = o.spans.filter(function (x) { return x.e > since; });
        var handlers = [];
        try {
          var nav = (performance.getEntriesByType("navigation") || [])[0];
          if (nav && since === 0) {
            if (nav.domContentLoadedEventEnd - nav.domContentLoadedEventStart > 0.5) {
              handlers.push({ c: "DOMContentLoaded handlers", u: null, s: nav.domContentLoadedEventStart, e: nav.domContentLoadedEventEnd });
            }
            if (nav.loadEventEnd - nav.loadEventStart > 0.5) {
              handlers.push({ c: "load handlers", u: null, s: nav.loadEventStart, e: nav.loadEventEnd });
            }
          }
        } catch (e) {}
        return {
          ok: true, period: o.period, from: Math.max(o.from, since), to: o.on ? performance.now() : o.to,
          blocks: o.blocks.filter(function (b) { return b.s >= since; }),
          spans: spans.concat(handlers),
          totals: Object.keys(o.totals).map(function (k) { return o.totals[k]; }),
          layouts: Object.keys(o.layouts).map(function (k) { return o.layouts[k]; }),
          scripts: o.scripts,
          res: lh_resourceSpans(),
          fcp: finite(lh_fcpMs)
        };
      }

      try {
        if (window === window.top && sessionStorage.getItem("__orbitLHArm") === "1") {
          sessionStorage.removeItem("__orbitLHArm");
          lh_startObservation(60000);
        }
      } catch (e) {}

      ops["lh.arm"] = function () {
        try { sessionStorage.setItem("__orbitLHArm", "1"); } catch (e) {}
      };

      ops["lh.probe"] = function () {
        post({ t: "lh.probe", obs: lh_observationPayload(0) });
      };

      ops["lh.reset"] = function () {
        lh_fcpMs = null; lh_lcpMs = null; lh_lcpElement = null; lh_lcpSelector = "";
        lh_lcpURL = ""; lh_lcpTag = ""; lh_lcpSnippet = ""; lh_lcpLoadMs = null; lh_lcpRenderMs = null;
        lh_clsScore = 0; lh_clsShifts = []; lh_clsShiftsTruncated = false; lh_inpMax = null;
        lh_longTasks = []; lh_longTasksOk = false; lh_loadedPosted = false;
        lh_docWriteDetected = false; lh_syncXHRDetected = false;
        lh_geoDetected = false; lh_notifDetected = false; lh_unloadDetected = false;
        lh_setupObservers();
      };

      ops["lh.timespanStart"] = function () {
        lh_timespanStartMs = (typeof performance !== "undefined") ? performance.now() : null;
        if (lh_obs && !lh_obs.on) { lh_obs = null; }
        lh_startObservation(600000);
        lh_clsAtTimespanStart = lh_clsScore;
        lh_longTasksAtTimespanStart = lh_longTasks.length;
      };

      ops["lh.collect"] = function (msg) {
        try {
          var isTimespan = msg && msg.timespan;
          // Stopped first, so the audit's own DOM reads below are neither slowed nor counted.
          lh_stopObservation();
          var observation = lh_observationPayload(isTimespan ? (lh_timespanStartMs || 0) : 0);

          // The Frameworks tool's own scan, captured as it posts, so library versions come from one detector.
          var fwEvidence = null;
          try {
            if (typeof fw_scanEvidence === "function") {
              var realPost = post;
              post = function (m) { if (m && m.t === "fw.evidence") { fwEvidence = m; } return realPost(m); };
              try { fw_scanEvidence(); } finally { post = realPost; }
            }
          } catch (e) {}

          var navEntry = null;
          try {
            var navEntries = performance.getEntriesByType ? performance.getEntriesByType("navigation") : [];
            navEntry = navEntries.length ? navEntries[0] : null;
          } catch (e) {}
          var ttfb = navEntry ? finite(navEntry.responseStart) : null;
          var httpStatus = navEntry && navEntry.responseStatus ? navEntry.responseStatus : 200;

          var clsVal = isTimespan ? Math.max(0, lh_clsScore - lh_clsAtTimespanStart) : lh_clsScore;
          var shifts = isTimespan
            ? lh_clsShifts.filter(function (s) { return lh_timespanStartMs === null || s.t >= lh_timespanStartMs; })
            : lh_clsShifts;
          var tasks  = isTimespan ? lh_longTasks.slice(lh_longTasksAtTimespanStart) : lh_longTasks;
          var timespanDur = (isTimespan && lh_timespanStartMs !== null)
            ? finite(performance.now() - lh_timespanStartMs) : null;

          var doc = document.documentElement;
          var lang = doc ? doc.getAttribute("lang") : null;
          var hasTitle = !!document.title && document.title.length > 0;
          var titleText = hasTitle ? document.title.slice(0, 300) : "";
          var hasDoctype = !!(document.doctype);
          var charsetMeta = document.querySelector("meta[charset]");
          var charset = charsetMeta ? (charsetMeta.getAttribute("charset") || "UTF-8") : null;
          if (!charset) {
            var ceq = document.querySelector("meta[http-equiv='Content-Type']");
            charset = ceq ? "UTF-8" : null;
          }
          var viewportMeta = document.querySelector("meta[name='viewport']");
          var hasViewport = !!viewportMeta;
          var viewportContent = viewportMeta ? (viewportMeta.getAttribute("content") || "") : "";
          var descMeta = document.querySelector("meta[name='description']");
          var metaDesc = descMeta ? (descMeta.getAttribute("content") || "").slice(0, 400) : "";
          var canonEl = document.querySelector("link[rel='canonical']");
          var canonical = canonEl ? canonEl.getAttribute("href") || "" : "";
          var robotsMeta = document.querySelector("meta[name='robots']");
          var robotsContent = robotsMeta ? (robotsMeta.getAttribute("content") || "") : "";

          var hreflangLinks = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("link[rel='alternate'][hreflang]"),
              function (el) {
                hreflangLinks.push({ lang: el.getAttribute("hreflang") || "", href: el.getAttribute("href") || "" });
              }
            );
          } catch (e) {}

          var headings = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("h1,h2,h3,h4,h5,h6"),
              function (el) {
                if (headings.length >= 200 || isOurs(el)) { return; }
                headings.push({
                  level: parseInt(el.tagName[1], 10),
                  text: (el.textContent || "").trim().slice(0, 100),
                  id: idOf(el), sel: lh_cssSelector(el)
                });
              }
            );
          } catch (e) {}

          var images = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("img"),
              function (img) {
                if (images.length >= 200 || isOurs(img)) { return; }
                var rect = img.getBoundingClientRect();
                images.push({
                  src: (img.currentSrc || img.src || img.getAttribute("src") || "").slice(0, 300),
                  alt: img.hasAttribute("alt") ? img.getAttribute("alt") : null,
                  nw: img.naturalWidth, nh: img.naturalHeight,
                  dw: Math.round(rect.width), dh: Math.round(rect.height),
                  hw: img.hasAttribute("width"), hh: img.hasAttribute("height"),
                  loading: img.getAttribute("loading") || "",
                  id: idOf(img), sel: lh_cssSelector(img),
                  snip: lh_snippet(img),
                  above: rect.top < window.innerHeight
                });
              }
            );
          } catch (e) {}

          var links = [];
          var genericTexts = { "click here": 1, "here": 1, "more": 1, "read more": 1, "learn more": 1,
            "click": 1, "this": 1, "link": 1, "continue": 1, "download": 1 };
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("a"),
              function (a) {
                if (links.length >= 300 || isOurs(a)) { return; }
                var href = (a.getAttribute("href") || "").trim();
                var text = (a.textContent || "").trim().slice(0, 100);
                var isGeneric = !!genericTexts[text.toLowerCase()];
                var isCrawlable = href.length > 0
                  && !href.startsWith("javascript:")
                  && !href.startsWith("void:")
                  && href !== "#";
                var target = (a.getAttribute("target") || "").toLowerCase();
                var rel = (a.getAttribute("rel") || "").toLowerCase();
                var isBlank = target === "_blank";
                var hasNoopener = rel.indexOf("noopener") >= 0 || rel.indexOf("noreferrer") >= 0;
                var isCross = href.indexOf("//") >= 0 && href.indexOf(location.hostname) < 0;
                links.push({
                  href: href.slice(0, 300), text: text, sel: lh_cssSelector(a), id: idOf(a),
                  generic: isGeneric, crawlable: isCrawlable,
                  blank: isBlank, noopener: hasNoopener, cross: isCross
                });
              }
            );
          } catch (e) {}

          var buttons = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("button,[role='button']"),
              function (el) {
                if (buttons.length >= 200 || isOurs(el)) { return; }
                var name = lh_accessibleName(el) || "";
                buttons.push({ name: name, sel: lh_cssSelector(el), id: idOf(el), snip: lh_snippet(el) });
              }
            );
          } catch (e) {}

          var inputs = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("input,select,textarea"),
              function (el) {
                if (inputs.length >= 200 || isOurs(el)) { return; }
                var elType = (el.getAttribute("type") || "text").toLowerCase();
                var hasLabel = !!lh_accessibleName(el);
                var ac = el.getAttribute("autocomplete") || "";
                inputs.push({ type: elType, label: hasLabel, ac: ac, sel: lh_cssSelector(el), id: idOf(el), snip: lh_snippet(el) });
              }
            );
          } catch (e) {}

          var frames = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("iframe"),
              function (el) {
                if (frames.length >= 50 || isOurs(el)) { return; }
                frames.push({
                  src: (el.src || el.getAttribute("src") || "").slice(0, 300),
                  title: (el.getAttribute("title") || "").slice(0, 100),
                  sel: lh_cssSelector(el), id: idOf(el)
                });
              }
            );
          } catch (e) {}

          var allEls = document.querySelectorAll("*");
          var domNodes = allEls.length;
          var domMaxDepth = 0, domMaxKids = 0;
          var sampleStep = Math.max(1, Math.floor(domNodes / 200));
          for (var di = 0; di < allEls.length; di += sampleStep) {
            var el = allEls[di];
            if (isOurs(el)) { continue; }
            var depth = lh_domDepth(el);
            if (depth > domMaxDepth) { domMaxDepth = depth; }
            var kids = el.children ? el.children.length : 0;
            if (kids > domMaxKids) { domMaxKids = kids; }
          }

          var blockers = [];
          try {
            Array.prototype.forEach.call(
              document.head ? document.head.querySelectorAll("script[src],link[rel='stylesheet']") : [],
              function (el) {
                if (blockers.length >= 50) { return; }
                if (el.tagName === "SCRIPT") {
                  if (el.hasAttribute("async") || el.hasAttribute("defer") || el.type === "module") { return; }
                  blockers.push({ url: (el.src || "").slice(0, 300), type: "script", wastedMs: 0, size: 0 });
                } else {
                  if (el.rel === "preload" || el.rel === "prefetch") { return; }
                  if (el.hasAttribute("disabled")) { return; }
                  // A stylesheet whose media query does not match (media="print") does not block rendering.
                  var linkMedia = el.getAttribute("media");
                  if (linkMedia && linkMedia !== "all" && window.matchMedia && !window.matchMedia(linkMedia).matches) { return; }
                  blockers.push({ url: (el.href || "").slice(0, 300), type: "stylesheet", wastedMs: 0, size: 0 });
                }
              }
            );
          } catch (e) {}

          try {
            var resEntries = performance.getEntriesByType ? performance.getEntriesByType("resource") : [];
            blockers.forEach(function (b) {
              for (var ri = 0; ri < resEntries.length; ri++) {
                var r = resEntries[ri];
                if (r.name === b.url) {
                  b.wastedMs = finite(r.duration) || 0;
                  b.size = r.transferSize ? finite(r.transferSize) || 0 : 0;
                  break;
                }
              }
            });
          } catch (e) {}

          // Unused CSS is selector matching against the current DOM, not a coverage trace; unreadable cross-origin sheets count as skipped.
          var unusedCSS = [];
          var cssSkipped = 0;
          var cssRulesChecked = 0;
          try {
            var cssStart = performance.now();
            var cssBudgetHit = false;
            var cssPseudo = /::?(?:hover|focus|focus-within|focus-visible|active|visited|target|before|after|first-line|first-letter|selection|placeholder|backdrop|marker|-webkit-[a-z-]+|-moz-[a-z-]+|-ms-[a-z-]+)(?:\([^)]*\))?/gi;
            var cssRuleUsed = function (rule) {
              var text = rule.selectorText || "";
              if (!text) { return true; }
              var parts = text.split(",");
              for (var pi = 0; pi < parts.length; pi++) {
                var part = parts[pi].replace(cssPseudo, "").trim();
                if (!part) { return true; }
                try { if (document.querySelector(part)) { return true; } } catch (e) { return true; }
              }
              return false;
            };
            var cssWalk = function (rules, acc) {
              Array.prototype.forEach.call(rules, function (rule) {
                if (cssBudgetHit) { return; }
                if (performance.now() - cssStart > 200 || cssRulesChecked > 6000) { cssBudgetHit = true; return; }
                if (rule.type === 1) {
                  cssRulesChecked++;
                  var size = (rule.cssText || "").length;
                  acc.total += size;
                  if (!cssRuleUsed(rule)) { acc.unused += size; acc.unusedRules++; }
                } else if (rule.cssRules && (rule.type === 4 || rule.type === 12)) {
                  if (rule.type === 4 && rule.media && window.matchMedia && !window.matchMedia(rule.media.mediaText).matches) {
                    return;
                  }
                  cssWalk(rule.cssRules, acc);
                }
              });
            };
            Array.prototype.forEach.call(document.styleSheets, function (sheet) {
              if (unusedCSS.length >= 40 || cssBudgetHit) { return; }
              var owner = sheet.ownerNode;
              if (owner && isOurs(owner)) { return; }
              var rules;
              try { rules = sheet.cssRules; } catch (e) { cssSkipped++; return; }
              if (!rules) { cssSkipped++; return; }
              var acc = { total: 0, unused: 0, unusedRules: 0 };
              cssWalk(rules, acc);
              if (acc.total > 0) {
                unusedCSS.push({
                  url: (sheet.href || "").slice(0, 300),
                  total: acc.total, unused: acc.unused, rules: acc.unusedRules,
                  id: owner ? idOf(owner) : 0,
                  sel: owner ? nodeLabel(owner) : ""
                });
              }
            });
            if (cssBudgetHit) { cssSkipped++; }
          } catch (e) {}

          var lcpFetchPri = false;
          try {
            if (lh_lcpElement) {
              var lcpEl = nodeById(lh_lcpElement);
              if (lcpEl && lcpEl.tagName === "IMG") {
                lcpFetchPri = lcpEl.fetchPriority === "high" || lcpEl.getAttribute("fetchpriority") === "high";
                if (!lcpFetchPri) {
                  var preloadLink = document.querySelector("link[rel='preload'][as='image'][href='" + lcpEl.src + "']");
                  lcpFetchPri = !!preloadLink;
                }
              }
            }
          } catch (e) {}

          var preconnects = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("link[rel='preconnect']"),
              function (el) { preconnects.push(el.getAttribute("href") || ""); }
            );
          } catch (e) {}

          var deprecated = [];
          var deprecTags = ["center", "font", "blink", "marquee", "applet", "basefont", "dir", "isindex", "s", "strike", "tt", "u"];
          try {
            deprecTags.forEach(function (tag) {
              Array.prototype.forEach.call(document.getElementsByTagName(tag), function (el) {
                if (deprecated.length >= 50 || isOurs(el)) { return; }
                deprecated.push({ tag: tag, sel: lh_cssSelector(el), id: idOf(el) });
              });
            });
          } catch (e) {}

          var smallFonts = [];
          var textNodeCount = 0;
          try {
            var walker = document.createTreeWalker(document.body || document.documentElement, 1, null, false);
            var wn;
            while ((wn = walker.nextNode()) && textNodeCount < 500) {
              if (isOurs(wn)) { continue; }
              var wst = getComputedStyle(wn);
              var fs = parseFloat(wst.fontSize);
              if (wst.display !== "none" && wst.visibility !== "hidden") {
                textNodeCount++;
                if (fs > 0 && fs < 12) {
                  smallFonts.push({ sel: lh_cssSelector(wn), id: idOf(wn), size: fs, snip: lh_snippet(wn) });
                }
              }
            }
          } catch (e) {}

          var contrastIssues = [];
          try {
            var textEls = document.querySelectorAll("p,span,a,li,td,th,h1,h2,h3,h4,h5,h6,label,button");
            var cCount = 0;
            Array.prototype.forEach.call(textEls, function (el) {
              if (cCount >= 100 || isOurs(el)) { return; }
              if (!(el.textContent || "").trim()) { return; }
              try {
                var st = getComputedStyle(el);
                if (st.display === "none" || st.visibility === "hidden") { return; }
                var fg = lh_parseRGBA(st.color);
                if (!fg || fg[3] === 0) { return; }
                var bgRes = lh_resolvedBg(el);
                var ratio = lh_contrastRatio(fg, bgRes.color);
                var fsPx = parseFloat(st.fontSize);
                var fw = parseInt(st.fontWeight, 10) || 400;
                var isLarge = fsPx >= 24 || (fsPx >= 18.667 && fw >= 700);
                var required = isLarge ? 3 : 4.5;
                cCount++;
                if (ratio < required || bgRes.needsReview) {
                  contrastIssues.push({
                    sel: lh_cssSelector(el), id: idOf(el),
                    fg: fg, bg: bgRes.color, ratio: ratio, req: required,
                    large: isLarge, review: bgRes.needsReview
                  });
                }
              } catch (e) {}
            });
          } catch (e) {}

          var smallTargets = [];
          var totalTargets = 0;
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("a,button,input,select,textarea,[role='button'],[role='link']"),
              function (el) {
                if (isOurs(el) || totalTargets >= 300) { return; }
                totalTargets++;
                var r = el.getBoundingClientRect();
                if (r.width < 24 || r.height < 24) {
                  smallTargets.push({ sel: lh_cssSelector(el), id: idOf(el), w: r.width, h: r.height, snip: lh_snippet(el) });
                }
              }
            );
          } catch (e) {}

          var ariaIssues = [];
          var validRoles = { "alert":1,"alertdialog":1,"application":1,"article":1,"banner":1,
            "button":1,"cell":1,"checkbox":1,"columnheader":1,"combobox":1,"complementary":1,
            "contentinfo":1,"definition":1,"dialog":1,"document":1,"feed":1,"figure":1,
            "form":1,"grid":1,"gridcell":1,"group":1,"heading":1,"img":1,"link":1,"list":1,
            "listbox":1,"listitem":1,"log":1,"main":1,"marquee":1,"math":1,"menu":1,"menubar":1,
            "menuitem":1,"menuitemcheckbox":1,"menuitemradio":1,"navigation":1,"none":1,"note":1,
            "option":1,"presentation":1,"progressbar":1,"radio":1,"radiogroup":1,"region":1,
            "row":1,"rowgroup":1,"rowheader":1,"scrollbar":1,"search":1,"searchbox":1,
            "separator":1,"slider":1,"spinbutton":1,"status":1,"switch":1,"tab":1,"table":1,
            "tablist":1,"tabpanel":1,"term":1,"textbox":1,"timer":1,"toolbar":1,"tooltip":1,
            "tree":1,"treegrid":1,"treeitem":1 };
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("[role]"),
              function (el) {
                if (ariaIssues.length >= 100 || isOurs(el)) { return; }
                var role = el.getAttribute("role") || "";
                if (role && !validRoles[role]) {
                  ariaIssues.push({ rule: "aria-roles", sel: lh_cssSelector(el), id: idOf(el),
                    snip: lh_snippet(el), detail: "Invalid role: " + role });
                }
              }
            );
            if (document.body && document.body.getAttribute("aria-hidden") === "true") {
              ariaIssues.push({ rule: "aria-hidden-body", sel: "body", id: idOf(document.body),
                snip: "<body aria-hidden=\"true\">", detail: "body is aria-hidden" });
            }
            Array.prototype.forEach.call(
              document.querySelectorAll("[aria-hidden='true']"),
              function (el) {
                if (ariaIssues.length >= 100 || isOurs(el)) { return; }
                var focusable = el.querySelector("a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]");
                if (focusable) {
                  ariaIssues.push({ rule: "aria-hidden-focus", sel: lh_cssSelector(el), id: idOf(el),
                    snip: lh_snippet(el), detail: "Contains focusable element: " + lh_cssSelector(focusable) });
                }
              }
            );
            Array.prototype.forEach.call(
              document.querySelectorAll("[role='checkbox'],[role='radio'],[role='switch']"),
              function (el) {
                if (ariaIssues.length >= 100 || isOurs(el)) { return; }
                if (!el.hasAttribute("aria-checked")) {
                  ariaIssues.push({ rule: "aria-required-attr", sel: lh_cssSelector(el), id: idOf(el),
                    snip: lh_snippet(el), detail: "Missing aria-checked for role=" + el.getAttribute("role") });
                }
              }
            );
          } catch (e) {}

          var dupIDs = [];
          try {
            var idMap = {};
            Array.prototype.forEach.call(document.querySelectorAll("[id]"), function (el) {
              if (isOurs(el)) { return; }
              var eid = el.id;
              if (idMap[eid]) { if (dupIDs.indexOf(eid) < 0) { dupIDs.push(eid); } }
              else { idMap[eid] = true; }
            });
          } catch (e) {}

          var posTabindex = 0;
          var posTabNodes = [];
          try {
            posTabindex = document.querySelectorAll("[tabindex]").length;
            var realPos = 0;
            Array.prototype.forEach.call(document.querySelectorAll("[tabindex]"), function (el) {
              if (parseInt(el.getAttribute("tabindex"), 10) > 0) {
                realPos++;
                if (posTabNodes.length < 20 && !isOurs(el)) { posTabNodes.push(lh_evidence(el)); }
              }
            });
            posTabindex = realPos;
          } catch (e) { posTabindex = 0; }

          var hasMain = !!(document.querySelector("main,[role='main']"));
          var hasSkip = !!(document.querySelector("a[href^='#']"));
          var videosNoCaptions = 0;
          var videoNodes = [];
          try {
            Array.prototype.forEach.call(document.querySelectorAll("video"), function (v) {
              var hasCaps = !!v.querySelector("track[kind='captions'],track[kind='subtitles']");
              if (!hasCaps) {
                videosNoCaptions++;
                if (videoNodes.length < 20 && !isOurs(v)) { videoNodes.push(lh_evidence(v)); }
              }
            });
          } catch (e) {}

          var scrollNotFocus = 0;
          var scrollNodes = [];
          try {
            Array.prototype.forEach.call(document.querySelectorAll("*"), function (el) {
              if (isOurs(el) || scrollNotFocus >= 20) { return; }
              try {
                var st = getComputedStyle(el);
                var scrollable = (st.overflow === "scroll" || st.overflow === "auto" ||
                  st.overflowY === "scroll" || st.overflowY === "auto");
                if (scrollable && el.scrollHeight > el.clientHeight) {
                  var ti = el.getAttribute("tabindex");
                  if (ti === null || parseInt(ti, 10) < 0) { scrollNotFocus++; scrollNodes.push(lh_evidence(el)); }
                }
              } catch (e2) {}
            });
          } catch (e) {}

          var nestedInter = 0;
          var nestedNodes = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("button,a,input,select,textarea"),
              function (el) {
                if (isOurs(el)) { return; }
                var inner = el.querySelector("button,a,input,select,textarea");
                if (inner) {
                  nestedInter++;
                  if (nestedNodes.length < 20) { nestedNodes.push(lh_evidence(el)); }
                }
              }
            );
          } catch (e) {}

          var blankNoopener = links.filter(function (l) { return l.blank && l.cross && !l.noopener; });

          var animList = [];
          try {
            if (typeof document.getAnimations === "function") {
              var anims = document.getAnimations();
              anims.forEach(function (anim) {
                if (animList.length >= 50) { return; }
                var el = anim.effect && anim.effect.target;
                if (!el || isOurs(el)) { return; }
                var props = [];
                try {
                  if (anim.effect && anim.effect.getKeyframes) {
                    var kf = anim.effect.getKeyframes();
                    if (kf.length > 0) {
                      Object.keys(kf[0]).forEach(function (k) {
                        if (k !== "offset" && k !== "easing" && k !== "composite") { props.push(k); }
                      });
                    }
                  }
                } catch (e) {}
                var triggers = lh_animTriggers(props);
                var duration = anim.effect && anim.effect.getTiming ? anim.effect.getTiming().duration : 0;
                var isInfinite = duration === Infinity || duration === "auto";
                var type = anim.animationName ? "css-animation"
                  : (anim.transitionProperty ? "css-transition" : "waapi");
                // Check prefers-reduced-motion (heuristic: check if style sheet has the media query)
                var respectsRM = false;
                try {
                  Array.prototype.forEach.call(document.styleSheets, function (ss) {
                    try {
                      Array.prototype.forEach.call(ss.cssRules, function (rule) {
                        if (rule.media && rule.media.mediaText &&
                            rule.media.mediaText.indexOf("prefers-reduced-motion") >= 0) {
                          respectsRM = true;
                        }
                      });
                    } catch (e) {}
                  });
                } catch (e) {}
                animList.push({
                  sel: lh_cssSelector(el), id: idOf(el), type: type, props: props,
                  paint: triggers.paint, layout: triggers.layout,
                  infinite: isInfinite, rm: respectsRM
                });
              });
            }
          } catch (e) {}

          var jsonLD = [];
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("script[type='application/ld+json']"),
              function (el) {
                if (jsonLD.length < 5) { jsonLD.push((el.textContent || "").slice(0, 2000)); }
              }
            );
          } catch (e) {}

          // The LCP element's position is read now, so it matches the screenshot Orbit takes straight after this.
          var lcpInfo = null;
          try {
            if (lh_lcpMs !== null) {
              var lcpNode = lh_lcpElement ? nodeById(lh_lcpElement) : null;
              var lcpLive = !!(lcpNode && lcpNode.isConnected && !isOurs(lcpNode));
              var resEntry = null;
              if (lh_lcpURL && performance.getEntriesByName) {
                var named = performance.getEntriesByName(lh_lcpURL, "resource");
                if (named.length) { resEntry = named[0]; }
              }
              lcpInfo = {
                sel: lh_lcpSelector.slice(0, 200), tag: lh_lcpTag,
                id: lcpLive ? idOf(lcpNode) : 0,
                snip: lcpLive ? lh_snippet(lcpNode) : lh_lcpSnippet,
                url: lh_lcpURL.slice(0, 300),
                rect: lcpLive ? lh_rect(lcpNode.getBoundingClientRect()) : null,
                load: finite(lh_lcpLoadMs), render: finite(lh_lcpRenderMs),
                lazy: !!(lcpLive && lcpNode.tagName === "IMG" && lcpNode.getAttribute("loading") === "lazy"),
                resStart: resEntry ? finite(resEntry.startTime) : null,
                resEnd: resEntry ? finite(resEntry.responseEnd) : null
              };
            }
          } catch (e) {}

          var shiftsOut = [];
          try {
            shifts.slice(0, 150).forEach(function (s) {
              var det = [];
              (s.det || []).forEach(function (d) {
                var node = d.ref ? nodeById(d.ref) : null;
                var live = null, nid = 0;
                if (node && node.isConnected && !isOurs(node)) { live = lh_rect(node.getBoundingClientRect()); nid = idOf(node); }
                det.push({ sel: d.sel, id: nid, prev: d.prev, cur: d.cur, live: live });
              });
              shiftsOut.push({ v: s.v, t: s.t, srcs: s.srcs, det: det });
            });
          } catch (e) {}

          var ttfbParts = [];
          try {
            if (navEntry) {
              [["Redirects", navEntry.redirectEnd - navEntry.redirectStart],
               ["DNS lookup", navEntry.domainLookupEnd - navEntry.domainLookupStart],
               ["Connection and TLS", navEntry.connectEnd - navEntry.connectStart],
               ["Waiting for the server", navEntry.responseStart - navEntry.requestStart]
              ].forEach(function (p) {
                var ms = finite(p[1]);
                if (ms !== null && ms > 0) { ttfbParts.push({ n: p[0], ms: ms }); }
              });
            }
          } catch (e) {}

          // Content wider than the viewport: the outermost elements past the right edge that no ancestor clips,
          // since those are what makes the page scroll sideways.
          var docW = null;
          var overflow = [];
          try {
            var vw = window.innerWidth;
            docW = finite(Math.max(doc ? doc.scrollWidth : 0, document.body ? document.body.scrollWidth : 0));
            if (docW !== null && vw > 0 && docW > vw + 1) {
              var clips = function (el) {
                var ox = getComputedStyle(el).overflowX;
                return ox === "hidden" || ox === "auto" || ox === "scroll" || ox === "clip";
              };
              var all = document.body ? document.body.getElementsByTagName("*") : [];
              var limit = Math.min(all.length, 5000);
              for (var oi = 0; oi < limit && overflow.length < 15; oi++) {
                var oel = all[oi];
                if (isOurs(oel)) { continue; }
                var orect = oel.getBoundingClientRect();
                if (orect.width === 0 || orect.right + window.scrollX <= vw + 1) { continue; }
                var parent = oel.parentElement, clipped = false, parentOut = false;
                if (parent && parent !== document.body && parent !== doc &&
                    parent.getBoundingClientRect().right + window.scrollX > vw + 1) { parentOut = true; }
                for (var anc = parent; anc && anc !== document.body && anc !== doc; anc = anc.parentElement) {
                  if (clips(anc)) { clipped = true; break; }
                }
                if (clipped || parentOut) { continue; }
                // A fixed element does not widen the scrollable page, so it is not why the page scrolls sideways.
                if (getComputedStyle(oel).position === "fixed") { continue; }
                overflow.push({ sel: lh_cssSelector(oel), id: idOf(oel), right: finite(orect.right + window.scrollX) || 0, snip: lh_snippet(oel) });
              }
            }
          } catch (e) {}

          var bundle = {
            lcpInfo: lcpInfo,
            obs: observation,
            fw: fwEvidence,
            docW: docW,
            overflow: overflow,
            touchPts: (typeof navigator.maxTouchPoints === "number") ? navigator.maxTouchPoints : 0,
            uaMobile: /Mobile|iPhone|iPod|Android/.test(navigator.userAgent || ""),
            ttfbParts: ttfbParts,
            vp: { w: finite(window.innerWidth) || 0, h: finite(window.innerHeight) || 0,
                  sx: finite(window.scrollX) || 0, sy: finite(window.scrollY) || 0 },
            nestedNodes: nestedNodes,
            scrollNodes: scrollNodes,
            videoNodes: videoNodes,
            posTabNodes: posTabNodes,
            clsTruncated: lh_clsShiftsTruncated,
            fcp: finite(lh_fcpMs),
            lcp: finite(lh_lcpMs),
            lcpSel: lh_lcpSelector.slice(0, 200),
            lcpURL: lh_lcpURL.slice(0, 300),
            cls: finite(clsVal) || 0,
            clsShifts: shiftsOut,
            inp: finite(lh_inpMax),
            ttfb: ttfb,
            tasks: tasks.slice(0, 200),
            tasksOk: lh_longTasksOk,
            timespanDur: finite(timespanDur),
            lang: lang,
            hasTitle: hasTitle,
            title: titleText,
            doctype: hasDoctype,
            charset: charset,
            viewport: hasViewport,
            viewportContent: viewportContent.slice(0, 200),
            metaDesc: metaDesc,
            canonical: canonical.slice(0, 300),
            hreflang: hreflangLinks.slice(0, 50),
            robotsMeta: robotsContent.slice(0, 200),
            httpStatus: httpStatus,
            headings: headings,
            images: images,
            links: links.slice(0, 300),
            buttons: buttons,
            inputs: inputs,
            frames: frames,
            ariaIssues: ariaIssues,
            contrastIssues: contrastIssues.slice(0, 50),
            smallTargets: smallTargets.slice(0, 50),
            totalTargets: totalTargets,
            domNodes: domNodes,
            domDepth: domMaxDepth,
            domMaxKids: domMaxKids,
            blockers: blockers,
            dpr: finite(window.devicePixelRatio) || 1,
            unusedCSS: unusedCSS,
            cssSkipped: cssSkipped,
            lcpFetchPri: lcpFetchPri,
            preconnects: preconnects,
            docWrite: lh_docWriteDetected,
            syncXHR: lh_syncXHRDetected,
            geo: lh_geoDetected,
            notif: lh_notifDetected,
            unload: lh_unloadDetected || lh_hasUnloadListener(),
            deprecated: deprecated,
            smallFonts: smallFonts.slice(0, 50),
            textNodes: textNodeCount,
            jsonLD: jsonLD,
            anims: animList,
            hasMain: hasMain,
            hasSkip: hasSkip,
            videoCaps: videosNoCaptions,
            scrollFocus: scrollNotFocus,
            nestedInter: nestedInter,
            dupIDs: dupIDs.slice(0, 30),
            posTabindex: posTabindex,
            blankNoopener: blankNoopener.slice(0, 20)
          };

          post({ t: "lh.bundle", bundle: bundle });
        } catch (err) {
          post({ t: "lh.bundle", bundle: null, error: String(err && err.message || err) });
        }
      };

    """##
}
