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

      // Bodies are kept for the Network panel only up to this many characters.
      var net_bodyCap = 65536;
      var net_fieldCap = 200;
      var net_imageCap = 1572864;

      function net_clip(text) {
        return text.length > net_bodyCap ? text.slice(0, net_bodyCap) : text;
      }

      function net_bytesInfo(bytes, type) {
        var info = { type: type, size: bytes.byteLength };
        try {
          if (bytes.byteLength > net_bodyCap) {
            info.note = "Large payload; its content is not captured.";
          } else if (typeof TextDecoder !== "undefined") {
            info.text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
          }
        } catch (e) {
          info.note = "Binary payload; its content cannot be shown as text.";
        }
        return info;
      }

      // Describes a request body as far as script can see it; a Blob or Request body is read later by net_lateRequestBody.
      function net_bodyInfo(body) {
        try {
          if (body === null || body === undefined) return null;
          if (typeof body === "string") {
            return { type: "string", size: body.length, text: net_clip(body),
                     truncated: body.length > net_bodyCap, ct: "text/plain;charset=UTF-8" };
          }
          if (typeof FormData !== "undefined" && body instanceof FormData) {
            var entries = [];
            var count = 0;
            try {
              body.forEach(function (value, name) {
                count++;
                if (entries.length >= net_fieldCap) return;
                if (typeof value === "string") {
                  entries.push({ n: name, v: value.length > 2000 ? value.slice(0, 2000) : value });
                } else {
                  entries.push({ n: name, v: "", f: String(value && value.name || ""), s: value && value.size });
                }
              });
            } catch (e) {}
            return { type: "FormData", count: count, entries: entries, ct: "multipart/form-data" };
          }
          if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
            var text = body.toString();
            var pairs = [];
            body.forEach(function (value, name) {
              if (pairs.length < net_fieldCap) pairs.push({ n: name, v: value });
            });
            return { type: "URLSearchParams", size: text.length, text: net_clip(text), truncated: text.length > net_bodyCap,
                     entries: pairs, ct: "application/x-www-form-urlencoded;charset=UTF-8" };
          }
          if (typeof Blob !== "undefined" && body instanceof Blob) {
            return { type: "Blob", size: body.size, mime: body.type, ct: body.type || null };
          }
          if (typeof ArrayBuffer !== "undefined" && body instanceof ArrayBuffer) {
            return net_bytesInfo(body, "ArrayBuffer");
          }
          if (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView(body)) {
            return net_bytesInfo(new Uint8Array(body.buffer, body.byteOffset, body.byteLength), "ArrayBuffer");
          }
          if (typeof ReadableStream !== "undefined" && body instanceof ReadableStream) {
            return { type: "ReadableStream", note: "A streamed request body cannot be read without consuming it." };
          }
          return { type: "other", note: "This request body type cannot be read by the inspector." };
        } catch (e) {}
        return null;
      }

      // Reads the bodies that need a promise (a text Blob, a Request object), before the page's call consumes them.
      function net_lateRequestBody(id, input, body) {
        try {
          if (body !== undefined && body !== null) {
            if (typeof Blob !== "undefined" && body instanceof Blob && net_wantsBody(body.type) && body.size <= net_bodyCap) {
              body.text().then(function (text) {
                net_enqueue({ k: "req_body", id: id, body: { type: "Blob", size: body.size, mime: body.type, text: text } });
              }, function () {});
            }
            return;
          }
          if (typeof Request !== "undefined" && input instanceof Request && input.body && !input.bodyUsed
              && net_wantsBody(input.headers.get("content-type"))) {
            input.clone().text().then(function (text) {
              net_enqueue({ k: "req_body", id: id, body: { type: "Request", size: text.length, text: net_clip(text),
                                                            truncated: text.length > net_bodyCap } });
            }, function () {});
          }
        } catch (e) {}
      }

      // The first two frames are net_stack and the hook that called it; the frames after them are the page's own.
      function net_stack() {
        try {
          var raw = (new Error()).stack || "";
          return raw.split("\n").slice(2, 14).join("\n").slice(0, 2000);
        } catch (e) { return ""; }
      }

      // Hooks are transparent: they never alter behaviour, timing, return values or instanceof results visible to page code.

      // Reads at most net_bodyCap characters then cancels, so a streaming or never-ending body is never pulled to completion.
      function net_readBodyCapped(response, done, failed) {
        var fail = function () { if (failed) failed(); };
        try {
          if (!response.body || typeof response.body.getReader !== "function" || typeof TextDecoder === "undefined") { fail(); return; }
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
            }, fail);
          };
          pump();
        } catch (e) { fail(); }
      }

      function net_wantsBody(contentType) {
        var ct = (contentType || "").toLowerCase();
        if (ct.indexOf("text/event-stream") >= 0) return false;
        return ct.indexOf("text/") >= 0 || ct.indexOf("json") >= 0 || ct.indexOf("javascript") >= 0
            || ct.indexOf("xml") >= 0 || ct.indexOf("x-www-form-urlencoded") >= 0 || ct.indexOf("graphql") >= 0;
      }

      // Why a response body was not read, so the panel can say so instead of showing an empty pane.
      function net_skipReason(contentType) {
        return (contentType || "").toLowerCase().indexOf("text/event-stream") >= 0 ? "stream" : "type";
      }

      function net_timingEntry(entry) {
        var st = [];
        if (entry.serverTiming) {
          entry.serverTiming.forEach(function (s) {
            st.push({ name: s.name, dur: finite(s.duration), desc: s.description || "" });
          });
        }
        return {
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
        };
      }

      // Windows in which resource-timing entries belong to the panel's own body re-read, not to a page request.
      var net_refetches = [];
      var net_rawFetch = null;

      function net_isOwnRefetch(entry) {
        for (var i = 0; i < net_refetches.length; i++) {
          var w = net_refetches[i];
          if (w.url === entry.name && entry.startTime >= w.t0 - 1 && (w.t1 === null || entry.startTime <= w.t1 + 1)) return true;
        }
        return false;
      }

      // The document itself is a navigation entry, not a resource entry, so it is reported separately once its response is in.
      function net_postNavigationEntry() {
        try {
          if (typeof performance === "undefined" || typeof performance.getEntriesByType !== "function") return;
          var nav = performance.getEntriesByType("navigation")[0];
          if (!nav || !(nav.responseEnd > 0)) return;
          var entry = net_timingEntry(nav);
          entry.url = nav.name || String(location.href);
          entry.init = "navigation";
          entry.dur = finite(nav.responseEnd - nav.startTime);
          net_enqueue(entry);
        } catch (e) {}
      }

      inits.push(function net_installHooks() {
        net_disposed = false;
        // Disposing turns this off; a wrapper still referenced by the page or a later patch then only passes calls through.
        var live = { on: true };
        disposers.push(function () { live.on = false; });

        try {
          if (typeof fetch !== "undefined") {
            var net_origFetch = fetch;
            net_rawFetch = net_origFetch;
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
              var reqBody = init ? init.body : undefined;
              net_enqueue({ k: "req", id: id, url: net_absolute(url), method: method,
                            headers: reqHeaders, body: net_bodyInfo(reqBody),
                            initiator: net_stack(), src: "fetch", t: t0 });
              net_lateRequestBody(id, input, reqBody);
              var promise;
              try {
                promise = net_origFetch.apply(this, arguments);
              } catch (err) {
                net_enqueue({ k: "done", id: id, failed: true, t: finite(performance.now()) });
                throw err;
              }
              return promise.then(function (response) {
                var ctype = response.headers.get("content-type") || "";
                // Only clone (which tees the stream) when the body will be shown, and only for text.
                var cloned = null;
                var skip = "";
                if (response.type === "opaque" || response.type === "opaqueredirect") skip = "opaque";
                else if (response.status === 204 || response.status === 205) skip = "empty";
                else if (!state.presented) skip = "closed";
                else if (!net_wantsBody(ctype)) skip = net_skipReason(ctype);
                else {
                  try { cloned = response.clone(); } catch (e) { skip = "unreadable"; }
                }
                var respHeaders = {};
                try { response.headers.forEach(function (v, k) { respHeaders[k] = v; }); } catch (e) {}
                var t1 = finite(performance.now());
                net_enqueue({ k: "resp_headers", id: id, status: response.status,
                              headers: respHeaders, mime: ctype, rtype: response.type || "",
                              url: response.url || url, t: t1, dur: t1 - t0 });
                if (cloned) {
                  net_readBodyCapped(cloned, function (text, truncated) {
                    net_enqueue({ k: "resp_body", id: id, body: text, truncated: truncated });
                  }, function () {
                    net_enqueue({ k: "resp_body", id: id, skip: "unreadable" });
                  });
                } else if (skip) {
                  net_enqueue({ k: "resp_body", id: id, skip: skip, mime: ctype });
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
                  net_lateRequestBody(self._net_id, null, body);

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
                    try {
                      var ct = self.getResponseHeader("content-type") || "";
                      var type = self.responseType;
                      var text = null;
                      var skip = "";
                      if (!state.presented) skip = "closed";
                      else if (self.status === 204 || self.status === 205) skip = "empty";
                      else if (type === "json") {
                        try { text = self.response === null ? "" : JSON.stringify(self.response); } catch (e) { skip = "unreadable"; }
                      } else if (type !== "" && type !== "text") skip = "responseType";
                      else if (!net_wantsBody(ct)) skip = net_skipReason(ct);
                      else text = self.responseText;
                      if (text !== null) {
                        if (text === "") skip = "empty";
                        else net_enqueue({ k: "resp_body", id: self._net_id, body: net_clip(text),
                                           truncated: text.length > net_bodyCap });
                      }
                      if (skip) net_enqueue({ k: "resp_body", id: self._net_id, skip: skip, mime: ct });
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
              var id = net_makeId();
              net_enqueue({ k: "req", id: id, url: net_absolute(url), method: "POST",
                            headers: {}, body: net_bodyInfo(data), initiator: net_stack(),
                            src: "beacon", t: finite(performance.now()) });
              net_lateRequestBody(id, null, data);
              return net_origBeacon(url, data);
            };
            disposers.push(function () {
              // sendBeacon was an own property we added; delete it to expose the prototype's again.
              try { if (navigator.sendBeacon === net_beaconWrap) delete navigator.sendBeacon; } catch (e) {}
              restoreIfOurs(navigator, "sendBeacon", net_beaconWrap, net_origBeacon);
            });
          }
        } catch (e) {}

        // A form post is a navigation, so no fetch hook sees its body; the page's own submit event is the only place script can read it.
        // It is posted at once, not queued, because the page is about to unload.
        try {
          var net_onSubmit = function (event) {
            if (!live.on || net_disposed) return;
            try {
              var form = event.target;
              if (!form || String(form.tagName).toUpperCase() !== "FORM") return;
              var submitter = event.submitter || null;
              var attr = function (name) {
                var own = submitter && submitter.getAttribute ? submitter.getAttribute("form" + name) : null;
                return own || form.getAttribute(name);
              };
              var method = String(attr("method") || "get").toUpperCase();
              if (method !== "POST") return;
              var action = attr("action");
              var enctype = String(attr("enctype") || "application/x-www-form-urlencoded").toLowerCase();
              var data;
              try { data = new FormData(form, submitter || undefined); } catch (e) { data = new FormData(form); }
              var info = net_bodyInfo(data);
              if (!info) return;
              if (enctype.indexOf("multipart/") < 0) {
                var parts = new URLSearchParams();
                data.forEach(function (value, name) { if (typeof value === "string") parts.append(name, value); });
                var encoded = parts.toString();
                info.text = net_clip(encoded);
                info.truncated = encoded.length > net_bodyCap;
                info.size = encoded.length;
                info.ct = enctype.indexOf("text/plain") >= 0 ? "text/plain" : "application/x-www-form-urlencoded";
              }
              post({ t: "net.form", url: net_absolute(action || location.href), method: method, body: info });
            } catch (e) {}
          };
          document.addEventListener("submit", net_onSubmit, true);
          disposers.push(function () { document.removeEventListener("submit", net_onSubmit, true); });
        } catch (e) {}

        try {
          if (typeof PerformanceObserver !== "undefined") {
            var net_perfObs = new PerformanceObserver(function (list) {
              list.getEntries().forEach(function (entry) {
                if (entry.entryType !== "resource" || net_isOwnRefetch(entry)) return;
                net_enqueue(net_timingEntry(entry));
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
              net_postNavigationEntry();
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
            performance.getEntriesByType("resource").forEach(function (entry) {
              if (!net_isOwnRefetch(entry)) net_enqueue(net_timingEntry(entry));
            });
            net_postNavigationEntry();
          }
        } catch (e) {}
      };

      // Re-reads one response body from inside the page, with the HTTP cache preferred, for loads the hooks never saw (scripts, styles, images, documents).
      ops["net.body"] = function (message) {
        var id = String(message.id || "");
        var url = String(message.url || "");
        var reply = function (fields) {
          fields.t = "net.body";
          fields.id = id;
          post(fields);
        };
        var send = net_rawFetch || (typeof fetch === "function" ? fetch : null);
        if (!send) { reply({ kind: "unavailable", reason: "error", detail: "fetch is not available" }); return; }
        var span = { url: url, t0: finite(performance.now()), t1: null };
        net_refetches.push(span);
        if (net_refetches.length > 64) net_refetches.shift();
        var finish = function () { span.t1 = finite(performance.now()); };
        var fail = function (err) {
          finish();
          reply({ kind: "unavailable", reason: "error", detail: String(err && err.message ? err.message : err) });
        };
        try {
          send.call(window, url, { cache: "force-cache" }).then(function (response) {
            var ctype = response.headers.get("content-type") || "";
            if (response.type === "opaque" || response.type === "opaqueredirect") {
              finish(); reply({ kind: "unavailable", reason: "opaque" }); return;
            }
            if (net_wantsBody(ctype)) {
              if (!response.body) { finish(); reply({ kind: "text", text: "", truncated: false }); return; }
              net_readBodyCapped(response, function (text, truncated) {
                finish(); reply({ kind: "text", text: text, truncated: truncated });
              }, function () {
                finish(); reply({ kind: "unavailable", reason: "error", detail: "the body could not be read" });
              });
              return;
            }
            if (ctype.toLowerCase().indexOf("image/") === 0) {
              response.blob().then(function (blob) {
                finish();
                if (blob.size > net_imageCap) { reply({ kind: "unavailable", reason: "too_large", detail: String(blob.size) }); return; }
                var reader = new FileReader();
                reader.onload = function () {
                  var data = String(reader.result || "");
                  var comma = data.indexOf(",");
                  reply({ kind: "image", b64: comma >= 0 ? data.slice(comma + 1) : "", mime: blob.type });
                };
                reader.onerror = function () { reply({ kind: "unavailable", reason: "error", detail: "the image could not be read" }); };
                reader.readAsDataURL(blob);
              }, fail);
              return;
            }
            try { if (response.body) response.body.cancel(); } catch (e) {}
            finish();
            reply({ kind: "unavailable", reason: "binary", detail: ctype });
          }, fail);
        } catch (e) { fail(e); }
      };

    """##
}
