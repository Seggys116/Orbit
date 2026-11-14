extension OrbitInspectAgent {
    // Always-on work goes in inits.push; the frame sampler and drift probe run only while recording.
    static let performanceSource = ##"""

      var perf_observers = [];
      var perf_pendingBatch = [];
      var perf_flushTimer = null;
      var perf_rafHandle = null;
      var perf_driftTimer = null;
      var perf_sampling = false;
      var perf_lastFrameTime = null;
      var perf_frameSeq = 0;
      var perf_driftSeq = 0;

      function perf_flush() {
        perf_flushTimer = null;
        if (!perf_pendingBatch.length) return;
        var batch = perf_pendingBatch;
        perf_pendingBatch = [];
        post({ t: "perf.batch", entries: batch });
      }

      function perf_schedule() {
        if (perf_flushTimer !== null) return;
        perf_flushTimer = setTimeout(perf_flush, 100);
      }

      function perf_push(entry) {
        perf_pendingBatch.push(entry);
        if (perf_pendingBatch.length >= 200) { perf_flush(); } else { perf_schedule(); }
      }

      function perf_sel(el) {
        if (!el || el.nodeType !== 1) return "";
        var name = (el.tagName || "").toLowerCase();
        if (el.id) return name + "#" + String(el.id).slice(0, 60);
        if (typeof el.className === "string") {
          var c = el.className.trim().split(/\s+/).slice(0, 2).join(".");
          if (c) return name + "." + c.slice(0, 60);
        }
        return name;
      }

      // Feature-detect and register a PerformanceObserver for one entry type.
      function perf_observe(type, handler) {
        if (typeof PerformanceObserver === "undefined") return;
        try {
          var po = new PerformanceObserver(function(list) {
            try { list.getEntries().forEach(handler); } catch (e) {}
          });
          po.observe({ type: type, buffered: true });
          perf_observers.push(po);
        } catch (e) {}
      }

      inits.push(function () {

        perf_observe("paint", function(entry) {
          perf_push({ et: "paint", name: String(entry.name), ts: finite(entry.startTime) });
        });

        perf_observe("largest-contentful-paint", function(entry) {
          var el = entry.element || null;
          var nid = el ? idOf(el) : 0;
          var sel = perf_sel(el);
          var isLazy = el && el.getAttribute && el.getAttribute("loading") === "lazy" ? true : false;
          perf_push({
            et: "lcp",
            ts: finite(entry.startTime),
            rt: finite(entry.renderTime),
            lt: finite(entry.loadTime),
            size: finite(entry.size),
            url: entry.url ? String(entry.url).slice(0, 400) : "",
            eid: entry.id ? String(entry.id).slice(0, 100) : "",
            nid: nid,
            sel: sel,
            lazy: isLazy
          });
        });

        perf_observe("layout-shift", function(entry) {
          var sources = [];
          if (entry.sources) {
            try {
              Array.prototype.forEach.call(entry.sources, function(src) {
                var node = src.node || null;
                var pr = src.previousRect;
                var cr = src.currentRect;
                sources.push({
                  nid: node ? idOf(node) : 0,
                  tag: node ? (node.tagName || "").toLowerCase() : "",
                  sel: perf_sel(node),
                  pr: pr ? { x: finite(pr.x), y: finite(pr.y), w: finite(pr.width), h: finite(pr.height) } : null,
                  cr: cr ? { x: finite(cr.x), y: finite(cr.y), w: finite(cr.width), h: finite(cr.height) } : null
                });
              });
            } catch (e) {}
          }
          perf_push({
            et: "layout-shift",
            ts: finite(entry.startTime),
            val: finite(entry.value),
            had: entry.hadRecentInput === true,
            sources: sources
          });
        });

        perf_observe("longtask", function(entry) {
          var attr = null;
          try {
            if (entry.attribution && entry.attribution[0]) {
              var a = entry.attribution[0];
              attr = {
                url: String(a.scriptURL || a.url || "").slice(0, 400),
                ct: String(a.containerType || ""),
                cn: String(a.containerName || "").slice(0, 100),
                ci: String(a.containerId || "").slice(0, 100)
              };
            }
          } catch (e) {}
          perf_push({ et: "longtask", ts: finite(entry.startTime), dur: finite(entry.duration), attr: attr });
        });

        perf_observe("event", function(entry) {
          var nid = entry.target ? (function() { try { return idOf(entry.target); } catch(e) { return 0; } })() : 0;
          perf_push({
            et: "event",
            name: String(entry.name || "").slice(0, 80),
            ts: finite(entry.startTime),
            ps: finite(entry.processingStart),
            pe: finite(entry.processingEnd),
            dur: finite(entry.duration),
            iid: finite(entry.interactionId),
            nid: nid
          });
        });

        perf_observe("first-input", function(entry) {
          var nid = entry.target ? (function() { try { return idOf(entry.target); } catch(e) { return 0; } })() : 0;
          perf_push({
            et: "first-input",
            name: String(entry.name || "").slice(0, 80),
            ts: finite(entry.startTime),
            ps: finite(entry.processingStart),
            pe: finite(entry.processingEnd),
            dur: finite(entry.duration),
            nid: nid
          });
        });

        perf_observe("navigation", function(entry) {
          perf_push({
            et: "navigation",
            ts: finite(entry.startTime),
            dur: finite(entry.duration),
            rs: finite(entry.redirectStart),
            re: finite(entry.redirectEnd),
            fs: finite(entry.fetchStart),
            ds: finite(entry.domainLookupStart),
            de: finite(entry.domainLookupEnd),
            cs: finite(entry.connectStart),
            ce: finite(entry.connectEnd),
            scs: finite(entry.secureConnectionStart),
            rqs: finite(entry.requestStart),
            rss: finite(entry.responseStart),
            rse: finite(entry.responseEnd),
            dcls: finite(entry.domContentLoadedEventStart),
            dcle: finite(entry.domContentLoadedEventEnd),
            les: finite(entry.loadEventStart),
            lee: finite(entry.loadEventEnd),
            xfr: finite(entry.transferSize),
            body: finite(entry.decodedBodySize),
            dom: finite(entry.domInteractive)
          });
        });

        perf_observe("resource", function(entry) {
          perf_push({
            et: "resource",
            url: String(entry.name || "").slice(0, 400),
            ts: finite(entry.startTime),
            dur: finite(entry.duration),
            xfr: finite(entry.transferSize),
            body: finite(entry.decodedBodySize),
            init: String(entry.initiatorType || ""),
            proto: String(entry.nextHopProtocol || "").slice(0, 20)
          });
        });

        perf_observe("mark", function(entry) {
          perf_push({ et: "mark", name: String(entry.name || "").slice(0, 200), ts: finite(entry.startTime) });
        });

        perf_observe("measure", function(entry) {
          perf_push({ et: "measure", name: String(entry.name || "").slice(0, 200), ts: finite(entry.startTime), dur: finite(entry.duration) });
        });

        // element timing (optional — only on elements with elementtiming="..." attribute)
        perf_observe("element", function(entry) {
          var nid = entry.element ? (function() { try { return idOf(entry.element); } catch(e) { return 0; } })() : 0;
          perf_push({
            et: "element",
            id: String(entry.identifier || entry.id || "").slice(0, 100),
            ts: finite(entry.startTime),
            rt: finite(entry.renderTime),
            lt: finite(entry.loadTime),
            url: String(entry.url || "").slice(0, 400),
            nid: nid
          });
        });

        window.addEventListener("DOMContentLoaded", function() {
          try {
            var head = document.head || document.getElementsByTagName("head")[0];
            var scripts = head ? Array.prototype.slice.call(head.querySelectorAll("script[src]")) : [];
            var blocking = scripts.filter(function(s) { return !s.async && !s.defer; });
            var nodeCount = document.querySelectorAll ? document.querySelectorAll("*").length : 0;
            perf_push({
              et: "dom-scan",
              blockingScripts: blocking.map(function(s) { return String(s.src).slice(0, 400); }),
              nodeCount: nodeCount
            });
            perf_flush();
          } catch (e) {}
        }, { once: true });

        window.addEventListener("pageshow", function(evt) {
          if (evt.persisted) {
            perf_push({ et: "bfcache", ts: finite(performance.now()) });
          }
        });

      }); // end inits.push


      function perf_frameTick(now) {
        if (!perf_sampling) return;
        if (perf_lastFrameTime !== null && now > perf_lastFrameTime) {
          var dur = now - perf_lastFrameTime;
          perf_frameSeq++;
          perf_pendingBatch.push({ et: "frame", ts: finite(now), dur: finite(dur) });
          perf_schedule();
        }
        perf_lastFrameTime = now;
        perf_rafHandle = requestAnimationFrame(perf_frameTick);
      }


      function perf_driftTick() {
        if (!perf_sampling) return;
        var before = performance.now();
        perf_driftTimer = setTimeout(function() {
          if (!perf_sampling) return;
          var actual = performance.now() - before;
          perf_driftSeq++;
          perf_pendingBatch.push({ et: "drift", ts: finite(performance.now()), exp: 250, act: finite(actual) });
          perf_schedule();
          perf_driftTick();
        }, 250);
      }

      ops["perf.startSampling"] = function() {
        if (perf_sampling) return;
        perf_sampling = true;
        perf_lastFrameTime = null;
        perf_rafHandle = requestAnimationFrame(perf_frameTick);
        perf_driftTick();
      };

      ops["perf.stopSampling"] = function() {
        perf_sampling = false;
        if (perf_rafHandle !== null) { try { cancelAnimationFrame(perf_rafHandle); } catch(e) {} perf_rafHandle = null; }
        if (perf_driftTimer !== null) { try { clearTimeout(perf_driftTimer); } catch(e) {} perf_driftTimer = null; }
        perf_lastFrameTime = null;
      };

      ops["perf.snapshot"] = function() {
        perf_flush();
      };

      navHooks.push(function() {
        perf_push({ et: "softnav", ts: finite(performance.now()) });
        perf_flush();
      });

      disposers.push(function() {
        ops["perf.stopSampling"]({});
        perf_observers.forEach(function(po) { try { po.disconnect(); } catch(e) {} });
        perf_observers = [];
        if (perf_flushTimer !== null) { clearTimeout(perf_flushTimer); perf_flushTimer = null; }
        perf_pendingBatch = [];
      });

    """##
}
