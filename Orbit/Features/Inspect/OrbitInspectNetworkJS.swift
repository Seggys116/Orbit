extension OrbitInspectAgent {
    static let networkSource = ##"""
      var net_queue = [];
      var net_flushTimer = null;
      var net_seq = 0;

      // Set by the disposer: a page that kept a reference to a wrapped fetch or XHR must not feed a closed inspector.
      var net_disposed = false;
      disposers.push(function () { net_disposed = true; net_queue = []; });

      function net_enqueue(entry) {
        if (net_disposed) return;
        net_queue.push(entry);
        if (net_flushTimer === null) {
          net_flushTimer = setTimeout(function () {
            net_flushTimer = null;
            if (net_queue.length === 0) return;
            var batch = net_queue;
            net_queue = [];
            post({ t: "net.batch", entries: batch });
          }, 100);
        }
      }

      function net_makeId() {
        return "js-" + (++net_seq) + "-" + Date.now();
      }

      // Pages pass relative URLs to fetch and XHR, but the native record they merge with always carries the absolute one without a fragment.
      function net_absolute(url) {
        try {
          var resolved = new URL(String(url), document.baseURI || location.href);
          resolved.hash = "";
          return resolved.href;
        } catch (e) {
          return String(url);
        }
      }

      function net_bodyInfo(body) {
        try {
          if (body === null || body === undefined) return null;
          if (typeof body === "string") {
            return { type: "string", size: body.length };
          }
          if (typeof FormData !== "undefined" && body instanceof FormData) {
            var count = 0;
            try { body.forEach(function () { count++; }); } catch (e) {}
            return { type: "FormData", fields: count };
          }
          if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
            return { type: "URLSearchParams", size: body.toString().length };
          }
          if (typeof Blob !== "undefined" && body instanceof Blob) {
            return { type: "Blob", size: body.size, mime: body.type };
          }
          if (typeof ArrayBuffer !== "undefined" && body instanceof ArrayBuffer) {
            return { type: "ArrayBuffer", size: body.byteLength };
          }
        } catch (e) {}
        return null;
      }

      function net_stack() {
        try {
          var raw = (new Error()).stack || "";
          return raw.split("\n").slice(4, 9).join("\n").slice(0, 500);
        } catch (e) { return ""; }
      }

      // Hooks are transparent: they never alter behaviour, timing, return values or instanceof results visible to page code.

      // Response bodies are kept for the Network panel only while it can be shown, and only up to this size.
      var net_bodyCap = 8192;

      // Reads at most net_bodyCap characters then cancels, so a streaming or never-ending body is never pulled to completion.
      function net_readBodyCapped(response, done) {
        try {
          if (!response.body || typeof response.body.getReader !== "function" || typeof TextDecoder === "undefined") return;
          var reader = response.body.getReader();
          var decoder = new TextDecoder();
          var text = "";
          var pump = function () {
            reader.read().then(function (chunk) {
              if (chunk.done) { done(text, false); return; }
              text += decoder.decode(chunk.value, { stream: true });
              if (text.length >= net_bodyCap) {
                try { reader.cancel(); } catch (e) {}
                done(text.slice(0, net_bodyCap), true);
                return;
              }
              pump();
            }, function () {});
          };
          pump();
        } catch (e) {}
      }

      function net_wantsBody(contentType) {
        var ct = (contentType || "").toLowerCase();
        if (ct.indexOf("text/event-stream") >= 0) return false;
        return ct.indexOf("text/") >= 0 || ct.indexOf("json") >= 0 || ct.indexOf("javascript") >= 0;
      }

      inits.push(function net_installHooks() {
        net_disposed = false;
        // Disposing turns this off; a wrapper still referenced by the page or a later patch then only passes calls through.
        var live = { on: true };
        disposers.push(function () { live.on = false; });

        try {
          if (typeof fetch !== "undefined") {
            var net_origFetch = fetch;
            var net_fetchWrap = function fetch(input, init) {
              if (!live.on) return net_origFetch.apply(this, arguments);
              var method = "GET";
              var url = "";
              try {
                if (typeof input === "string") url = input;
                else if (input && typeof input.url === "string") url = input.url;
                else url = String(input);
                var m = (init && init.method) || (input && input.method);
                if (m) method = String(m).toUpperCase();
              } catch (e) {}
              var id = net_makeId();
              var t0 = finite(performance.now());
              var reqHeaders = {};
              try {
                var hSrc = (init && init.headers) ? new Headers(init.headers)
                         : (input && input.headers) ? input.headers : null;
                if (hSrc) hSrc.forEach(function (v, k) { reqHeaders[k] = v; });
              } catch (e) {}
              net_enqueue({ k: "req", id: id, url: net_absolute(url), method: method,
                            headers: reqHeaders, body: net_bodyInfo(init && init.body),
                            initiator: net_stack(), src: "fetch", t: t0 });
              var promise;
              try {
                promise = net_origFetch.apply(this, arguments);
              } catch (err) {
                net_enqueue({ k: "done", id: id, failed: true, t: finite(performance.now()) });
                throw err;
              }
              return promise.then(function (response) {
                // Only clone (which tees the stream) when the body will be shown, and only for text.
                var cloned = null;
                if (state.presented && net_wantsBody(response.headers.get("content-type"))) {
                  try { cloned = response.clone(); } catch (e) {}
                }
                var respHeaders = {};
                try { response.headers.forEach(function (v, k) { respHeaders[k] = v; }); } catch (e) {}
                var t1 = finite(performance.now());
                net_enqueue({ k: "resp_headers", id: id, status: response.status,
                              headers: respHeaders, mime: response.headers.get("content-type") || "",
                              url: response.url || url, t: t1, dur: t1 - t0 });
                if (cloned) {
                  net_readBodyCapped(cloned, function (text, truncated) {
                    net_enqueue({ k: "resp_body", id: id, body: text, truncated: truncated });
                  });
                }
                net_enqueue({ k: "done", id: id, failed: false, t: finite(performance.now()) });
                return response;
              }, function (err) {
                net_enqueue({ k: "done", id: id, failed: true,
                              err: String(err && err.message ? err.message : err),
                              t: finite(performance.now()) });
                throw err;
              });
            };
            try { Object.defineProperty(net_fetchWrap, "name", { value: "fetch", configurable: true }); } catch (e) {}
            try { Object.defineProperty(net_fetchWrap, "length", { value: 2, configurable: true }); } catch (e) {}
            window.fetch = net_fetchWrap;
            disposers.push(function () { restoreIfOurs(window, "fetch", net_fetchWrap, net_origFetch); });
          }
        } catch (e) {}

        try {
          if (typeof XMLHttpRequest !== "undefined") {
            var net_origOpen = XMLHttpRequest.prototype.open;
            var net_origSend = XMLHttpRequest.prototype.send;
            var net_origSetHeader = XMLHttpRequest.prototype.setRequestHeader;

            var net_openWrap = XMLHttpRequest.prototype.open = function (method, url) {
              if (!live.on) return net_origOpen.apply(this, arguments);
              try {
                this._net_id = net_makeId();
                this._net_method = String(method || "GET").toUpperCase();
                this._net_url = net_absolute(url || "");
                this._net_headers = {};
                this._net_t0 = 0;
              } catch (e) {}
              return net_origOpen.apply(this, arguments);
            };

            var net_setHeaderWrap = XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
              if (!live.on) return net_origSetHeader.apply(this, arguments);
              try { if (this._net_headers) this._net_headers[String(name)] = String(value); } catch (e) {}
              return net_origSetHeader.apply(this, arguments);
            };

            var net_sendWrap = XMLHttpRequest.prototype.send = function (body) {
              if (!live.on) return net_origSend.apply(this, arguments);
              try {
                if (this._net_id) {
                  var self = this;
                  self._net_t0 = finite(performance.now());
                  net_enqueue({ k: "req", id: self._net_id, url: self._net_url,
                                method: self._net_method, headers: self._net_headers || {},
                                body: net_bodyInfo(body), initiator: net_stack(),
                                src: "xhr", t: self._net_t0 });

                  self.addEventListener("readystatechange", function () {
                    if (self.readyState !== 2) return; // HEADERS_RECEIVED
                    var hdrs = {};
                    try {
                      var raw = self.getAllResponseHeaders() || "";
                      raw.trim().split("\r\n").forEach(function (line) {
                        var idx = line.indexOf(": ");
                        if (idx > 0) hdrs[line.slice(0, idx)] = line.slice(idx + 2);
                      });
                    } catch (e) {}
                    net_enqueue({ k: "resp_headers", id: self._net_id, status: self.status,
                                  headers: hdrs, mime: self.getResponseHeader("content-type") || "",
                                  url: self.responseURL || self._net_url,
                                  t: finite(performance.now()), dur: finite(performance.now()) - self._net_t0 });
                  });

                  self.addEventListener("load", function () {
                    var respBody = "";
                    try {
                      var ct = (self.getResponseHeader("content-type") || "").toLowerCase();
                      var textual = self.responseType === "" || self.responseType === "text";
                      if (state.presented && textual && net_wantsBody(ct)) {
                        var cap = net_bodyCap;
                        var raw = self.responseText;
                        respBody = raw.length > cap ? raw.slice(0, cap) : raw;
                        if (respBody) {
                          net_enqueue({ k: "resp_body", id: self._net_id,
                                        body: respBody, truncated: raw.length > cap });
                        }
                      }
                    } catch (e) {}
                    net_enqueue({ k: "done", id: self._net_id, failed: false, t: finite(performance.now()) });
                  });

                  self.addEventListener("error", function () {
                    net_enqueue({ k: "done", id: self._net_id, failed: true, t: finite(performance.now()) });
                  });

                  self.addEventListener("abort", function () {
                    net_enqueue({ k: "done", id: self._net_id, cancelled: true, t: finite(performance.now()) });
                  });
                }
              } catch (e) {}
              return net_origSend.apply(this, arguments);
            };

            disposers.push(function () {
              restoreIfOurs(XMLHttpRequest.prototype, "open", net_openWrap, net_origOpen);
              restoreIfOurs(XMLHttpRequest.prototype, "send", net_sendWrap, net_origSend);
              restoreIfOurs(XMLHttpRequest.prototype, "setRequestHeader", net_setHeaderWrap, net_origSetHeader);
            });
          }
        } catch (e) {}

        try {
          if (typeof WebSocket !== "undefined") {
            var net_OrigWS = WebSocket;
            var net_WSWrap = function WebSocket(url, protocols) {
              var ws = protocols !== undefined
                ? new net_OrigWS(url, protocols)
                : new net_OrigWS(url);
              if (!live.on) return ws;
              var id = net_makeId();
              var urlStr = String(url);
              net_enqueue({ k: "ws_open", id: id, url: urlStr, t: finite(performance.now()) });

              ws.addEventListener("open", function () {
                net_enqueue({ k: "ws_state", id: id, state: "open", t: finite(performance.now()) });
              });
              ws.addEventListener("close", function (e) {
                net_enqueue({ k: "ws_state", id: id, state: "closed",
                              code: e.code, reason: e.reason, t: finite(performance.now()) });
              });
              ws.addEventListener("error", function () {
                net_enqueue({ k: "ws_state", id: id, state: "error", t: finite(performance.now()) });
              });
              ws.addEventListener("message", function (e) {
                var data = e.data;
                var preview = ""; var binary = false; var len = 0;
                if (typeof data === "string") {
                  len = data.length;
                  preview = len > 200 ? data.slice(0, 200) : data;
                } else if (typeof ArrayBuffer !== "undefined" && data instanceof ArrayBuffer) {
                  binary = true; len = data.byteLength;
                  preview = "[Binary " + len + " B]";
                } else if (typeof Blob !== "undefined" && data instanceof Blob) {
                  binary = true; len = data.size;
                  preview = "[Blob " + len + " B]";
                }
                net_enqueue({ k: "ws_frame", id: id, dir: "in",
                              data: preview, binary: binary, len: len, t: finite(performance.now()) });
              });

              var origSend = ws.send.bind(ws);
              ws.send = function (data) {
                try {
                  var preview = ""; var binary = false; var len = 0;
                  if (typeof data === "string") {
                    len = data.length; preview = len > 200 ? data.slice(0, 200) : data;
                  } else if (typeof ArrayBuffer !== "undefined" && data instanceof ArrayBuffer) {
                    binary = true; len = data.byteLength; preview = "[Binary " + len + " B]";
                  } else if (typeof Blob !== "undefined" && data instanceof Blob) {
                    binary = true; len = data.size; preview = "[Blob " + len + " B]";
                  }
                  net_enqueue({ k: "ws_frame", id: id, dir: "out",
                                data: preview, binary: binary, len: len, t: finite(performance.now()) });
                } catch (e) {}
                return origSend(data);
              };

              return ws;
            };
            // ws is a real net_OrigWS instance and the prototypes are shared, so instanceof still works.
            net_WSWrap.prototype = net_OrigWS.prototype;
            try { Object.setPrototypeOf(net_WSWrap, net_OrigWS); } catch (e) {}
            try { net_WSWrap.CONNECTING = net_OrigWS.CONNECTING; net_WSWrap.OPEN = net_OrigWS.OPEN;
                  net_WSWrap.CLOSING = net_OrigWS.CLOSING; net_WSWrap.CLOSED = net_OrigWS.CLOSED; } catch (e) {}
            try { Object.defineProperty(net_WSWrap, "name", { value: "WebSocket", configurable: true }); } catch (e) {}
            try { Object.defineProperty(net_WSWrap, "length", { value: 1, configurable: true }); } catch (e) {}
            window.WebSocket = net_WSWrap;
            disposers.push(function () { restoreIfOurs(window, "WebSocket", net_WSWrap, net_OrigWS); });
          }
        } catch (e) {}

        try {
          if (typeof EventSource !== "undefined") {
            var net_OrigES = EventSource;
            var net_ESWrap = function EventSource(url, init) {
              var es = init !== undefined ? new net_OrigES(url, init) : new net_OrigES(url);
              if (!live.on) return es;
              var id = net_makeId();
              var urlStr = String(url);
              net_enqueue({ k: "sse_open", id: id, url: urlStr, t: finite(performance.now()) });

              var origAddListener = es.addEventListener.bind(es);
              origAddListener("message", function (e) {
                net_enqueue({ k: "sse_msg", id: id, event: e.type || "message",
                              data: String(e.data || "").slice(0, 500), t: finite(performance.now()) });
              });
              origAddListener("error", function () {
                net_enqueue({ k: "done", id: id, failed: true, t: finite(performance.now()) });
              });

              return es;
            };
            net_ESWrap.prototype = net_OrigES.prototype;
            try { Object.setPrototypeOf(net_ESWrap, net_OrigES); } catch (e) {}
            try { Object.defineProperty(net_ESWrap, "name", { value: "EventSource", configurable: true }); } catch (e) {}
            try { Object.defineProperty(net_ESWrap, "length", { value: 1, configurable: true }); } catch (e) {}
            window.EventSource = net_ESWrap;
            disposers.push(function () { restoreIfOurs(window, "EventSource", net_ESWrap, net_OrigES); });
          }
        } catch (e) {}

        try {
          if (navigator && typeof navigator.sendBeacon === "function") {
            var net_origBeacon = navigator.sendBeacon.bind(navigator);
            var net_beaconWrap = navigator.sendBeacon = function (url, data) {
              if (!live.on) return net_origBeacon(url, data);
              net_enqueue({ k: "req", id: net_makeId(), url: net_absolute(url), method: "POST",
                            headers: {}, body: net_bodyInfo(data), initiator: net_stack(),
                            src: "beacon", t: finite(performance.now()) });
              return net_origBeacon(url, data);
            };
            disposers.push(function () {
              // sendBeacon was an own property we added; delete it to expose the prototype's again.
              try { if (navigator.sendBeacon === net_beaconWrap) delete navigator.sendBeacon; } catch (e) {}
              restoreIfOurs(navigator, "sendBeacon", net_beaconWrap, net_origBeacon);
            });
          }
        } catch (e) {}

        try {
          if (typeof PerformanceObserver !== "undefined") {
            var net_perfObs = new PerformanceObserver(function (list) {
              list.getEntries().forEach(function (entry) {
                if (entry.entryType !== "resource") return;
                var st = [];
                if (entry.serverTiming) {
                  entry.serverTiming.forEach(function (s) {
                    st.push({ name: s.name, dur: finite(s.duration), desc: s.description || "" });
                  });
                }
                net_enqueue({
                  k: "timing",
                  url: entry.name,
                  st: finite(entry.startTime),
                  fetchStart: finite(entry.fetchStart),
                  rdStart: finite(entry.redirectStart),
                  rdEnd: finite(entry.redirectEnd),
                  dnsStart: finite(entry.domainLookupStart),
                  dnsEnd: finite(entry.domainLookupEnd),
                  connStart: finite(entry.connectStart),
                  connEnd: finite(entry.connectEnd),
                  tlsStart: finite(entry.secureConnectionStart),
                  reqStart: finite(entry.requestStart),
                  respStart: finite(entry.responseStart),
                  respEnd: finite(entry.responseEnd),
                  xfer: entry.transferSize || 0,
                  encBody: entry.encodedBodySize || 0,
                  decBody: entry.decodedBodySize || 0,
                  proto: entry.nextHopProtocol || "",
                  init: entry.initiatorType || "",
                  dur: finite(entry.duration),
                  serverTiming: st
                });
              });
            });
            try { net_perfObs.observe({ type: "resource", buffered: true }); } catch (e) {
              try { net_perfObs.observe({ entryTypes: ["resource"] }); } catch (e2) {}
            }
            disposers.push(function () { try { net_perfObs.disconnect(); } catch (e) {} });
          }
        } catch (e) {}

        try {
          function net_postNavTiming() {
            try {
              var t = performance && performance.timing;
              if (!t) return;
              var origin = performance.timeOrigin || 0;
              var navStart = t.navigationStart || 0;
              var dcl = t.domContentLoadedEventStart > 0 ? t.domContentLoadedEventStart - navStart : null;
              var load = t.loadEventStart > 0 ? t.loadEventStart - navStart : null;
              post({ t: "net.nav", origin: finite(origin), dcl: dcl, load: load });
            } catch (e) {}
          }
          if (document.readyState === "complete") {
            setTimeout(net_postNavTiming, 0);
          } else {
            window.addEventListener("load", function () { setTimeout(net_postNavTiming, 50); });
          }
        } catch (e) {}

      }); // end inits.push

      ops["net.refresh"] = function () {
        try {
          if (typeof performance !== "undefined" && typeof performance.getEntriesByType === "function") {
            var entries = performance.getEntriesByType("resource");
            entries.forEach(function (entry) {
              var st = [];
              if (entry.serverTiming) {
                entry.serverTiming.forEach(function (s) {
                  st.push({ name: s.name, dur: finite(s.duration), desc: s.description || "" });
                });
              }
              net_enqueue({
                k: "timing", url: entry.name,
                st: finite(entry.startTime), fetchStart: finite(entry.fetchStart),
                rdStart: finite(entry.redirectStart), rdEnd: finite(entry.redirectEnd),
                dnsStart: finite(entry.domainLookupStart), dnsEnd: finite(entry.domainLookupEnd),
                connStart: finite(entry.connectStart), connEnd: finite(entry.connectEnd),
                tlsStart: finite(entry.secureConnectionStart),
                reqStart: finite(entry.requestStart), respStart: finite(entry.responseStart),
                respEnd: finite(entry.responseEnd),
                xfer: entry.transferSize || 0, encBody: entry.encodedBodySize || 0,
                decBody: entry.decodedBodySize || 0,
                proto: entry.nextHopProtocol || "", init: entry.initiatorType || "",
                dur: finite(entry.duration), serverTiming: st
              });
            });
          }
        } catch (e) {}
      };

    """##
}
