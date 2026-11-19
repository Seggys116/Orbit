extension OrbitInspectAgent {
    static let consoleSource = ##"""
      var con_reg = (typeof Map !== "undefined") ? new Map() : null;
      var con_regSeq = 0;
      var con_regCap = 1000;

      function con_register(value) {
        if (!con_reg) return 0;
        var id = ++con_regSeq;
        con_reg.set(id, value);
        if (con_reg.size > con_regCap) {
          var firstKey = con_reg.keys().next().value;
          con_reg.delete(firstKey);
        }
        return id;
      }

      var con_batch = [];
      var con_flushing = false;
      var con_seq = 0;
      var con_timers = {};
      var con_counts = {};
      var con_nativeConsole = {};
      var con_wrappers = {};
      var con_live = null;

      var con_disposed = false;
      var con_listeners = [];
      // Caps bursts so a page logging in a tight loop cannot grow the queue without bound between flushes.
      var con_batchCap = 2000;

      function con_listen(target, type, handler, capture) {
        target.addEventListener(type, handler, capture);
        con_listeners.push([target, type, handler, capture]);
      }

      function con_queueFlush() {
        if (con_flushing) return;
        con_flushing = true;
        setTimeout(function () {
          con_flushing = false;
          if (con_disposed) { con_batch = []; return; }
          var entries = con_batch.splice(0, con_batch.length);
          if (entries.length > 0) post({ t: "con.batch", entries: entries });
        }, 50);
      }

      function con_addEntry(entry) {
        if (con_disposed) return;
        if (con_batch.length >= con_batchCap) con_batch.shift();
        con_batch.push(entry);
        con_queueFlush();
      }


      function con_className(value) {
        if (!value || typeof value !== "object") return null;
        if (Array.isArray(value)) return "Array";
        if (typeof Map !== "undefined" && value instanceof Map) return "Map";
        if (typeof Set !== "undefined" && value instanceof Set) return "Set";
        if (typeof WeakMap !== "undefined" && value instanceof WeakMap) return "WeakMap";
        if (typeof WeakSet !== "undefined" && value instanceof WeakSet) return "WeakSet";
        if (typeof ArrayBuffer !== "undefined" && value instanceof ArrayBuffer) return "ArrayBuffer";
        if (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(value)) {
          return Object.prototype.toString.call(value).slice(8, -1);
        }
        if (typeof Promise !== "undefined" && value instanceof Promise) return "Promise";
        var ctor = value.constructor;
        if (ctor && ctor !== Object && typeof ctor.name === "string" && ctor.name) return ctor.name;
        if (typeof Symbol !== "undefined" && Symbol.toStringTag) {
          var tag = value[Symbol.toStringTag];
          if (tag && typeof tag === "string") return tag;
        }
        return "Object";
      }

      function con_serialize(value, depth) {
        try {
          if (value === null) return { k: "nu" };
          if (value === undefined) return { k: "u" };
          var t = typeof value;
          if (t === "string") {
            var s = value.length > 10000 ? value.slice(0, 10000) + "\u2026[truncated]" : value;
            return { k: "s", v: s };
          }
          if (t === "number") {
            if (isNaN(value)) return { k: "n", s: "NaN" };
            if (!isFinite(value)) return { k: "n", s: value > 0 ? "Infinity" : "-Infinity" };
            return { k: "n", v: value };
          }
          if (t === "boolean") return { k: "b", v: value };
          if (t === "bigint") return { k: "bi", v: String(value) + "n" };
          if (t === "symbol") return { k: "sym", v: String(value) };
          if (t === "function") {
            var fnPrev = "";
            try {
              var src = Function.prototype.toString.call(value);
              var m = src.match(/^(?:async\s+)?(?:function\s*[*]?\s*(\w+)?\s*)?\(([^)]*)\)|^(\w+)\s*=>/);
              var fname = value.name || (m && m[1]) || "";
              var fparams = (m && m[2]) || "";
              fnPrev = fname ? "\u0192 " + fname + "(" + fparams + ")" : "\u0192 (" + fparams + ")";
            } catch (fe) {
              fnPrev = value.name ? "\u0192 " + value.name + "()" : "\u0192 ()";
            }
            var fid = con_register(value);
            return { k: "fn", id: fid, preview: fnPrev };
          }
          if (typeof value === "object") {
            if (value instanceof Error) {
              var eid = con_register(value);
              var eprev = (value.name || "Error") + ": " + (value.message || "");
              return { k: "err", id: eid, preview: eprev, stack: value.stack ? String(value.stack) : "" };
            }
            if (value instanceof Date) {
              var did = con_register(value);
              return { k: "date", id: did, preview: value.toISOString() };
            }
            if (value instanceof RegExp) {
              var rid = con_register(value);
              return { k: "re", id: rid, preview: String(value) };
            }
            if (value instanceof Node) {
              var nid2 = refOf(value);
              var nid_reg = con_register(value);
              return { k: "dn", id: nid_reg, nid: nid2, preview: nodeLabel(value) };
            }
            if (depth <= 0) {
              var refId = con_register(value);
              return { k: "ref", id: refId, cls: con_className(value), preview: preview(value, 1, new WeakSet()) };
            }
            if (Array.isArray(value)) {
              var arrId = con_register(value);
              var slice = value.slice(0, 6);
              var items = slice.map(function (v) { return preview(v, 0, new WeakSet()); }).join(", ");
              var arrPrev = "(" + value.length + ") [" + items + (value.length > 6 ? ", \u2026" : "") + "]";
              return { k: "ref", id: arrId, cls: "Array", len: value.length, preview: arrPrev };
            }
            if (typeof Map !== "undefined" && value instanceof Map) {
              var mapId = con_register(value);
              return { k: "ref", id: mapId, cls: "Map", len: value.size, preview: "Map(" + value.size + ") {\u2026}" };
            }
            if (typeof Set !== "undefined" && value instanceof Set) {
              var setId = con_register(value);
              return { k: "ref", id: setId, cls: "Set", len: value.size, preview: "Set(" + value.size + ") {\u2026}" };
            }
            var objId = con_register(value);
            var objPrev = preview(value, 1, new WeakSet());
            return { k: "ref", id: objId, cls: con_className(value), preview: objPrev };
          }
          return { k: "s", v: String(value) };
        } catch (err2) {
          return { k: "s", v: "???" };
        }
      }


      function con_getPropsImpl(id) {
        if (!con_reg) return null;
        var obj = con_reg.get(id);
        if (obj === undefined) return null;
        var own = [];
        try {
          var names = Object.getOwnPropertyNames(obj).slice(0, 200);
          for (var i = 0; i < names.length; i++) {
            var name = names[i];
            try {
              var desc = Object.getOwnPropertyDescriptor(obj, name);
              if (!desc) continue;
              var prop = {
                name: name,
                enumerable: !!desc.enumerable,
                configurable: !!desc.configurable,
                writable: !!desc.writable,
                getter: !!desc.get
              };
              if (desc.get) {
                prop.value = { k: "fn", id: 0, preview: "get " + name + "()" };
              } else {
                prop.value = con_serialize(desc.value, 1);
              }
              own.push(prop);
            } catch (pe) {}
          }
        } catch (e) {}
        var proto = null;
        try {
          var p = Object.getPrototypeOf(obj);
          if (p && p !== Object.prototype && p !== Function.prototype
              && p !== Array.prototype && p !== null) {
            proto = con_serialize(p, 0);
          }
        } catch (e) {}
        return { own: own, proto: proto };
      }

      function con_getEntriesImpl(id) {
        if (!con_reg) return [];
        var obj = con_reg.get(id);
        if (!obj) return [];
        var result = [];
        try {
          if (typeof Map !== "undefined" && obj instanceof Map) {
            obj.forEach(function (val, key) {
              if (result.length >= 200) return;
              result.push({ key: con_serialize(key, 1), value: con_serialize(val, 1) });
            });
          } else if (typeof Set !== "undefined" && obj instanceof Set) {
            obj.forEach(function (val) {
              if (result.length >= 200) return;
              result.push({ key: con_serialize(val, 1), value: con_serialize(val, 1) });
            });
          }
        } catch (e) {}
        return result;
      }

      function con_getSliceImpl(id, start, end_) {
        if (!con_reg) return [];
        var arr = con_reg.get(id);
        if (!Array.isArray(arr) && !(typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(arr))) return [];
        try {
          return Array.prototype.slice.call(arr, start, end_).map(function (v) { return con_serialize(v, 1); });
        } catch (e) { return []; }
      }

      function con_completeAtImpl(path, prefix) {
        var obj = window;
        for (var i = 0; i < path.length && obj != null; i++) {
          try { obj = obj[path[i]]; } catch (e) { obj = null; }
        }
        if (obj == null) return [];
        var names = {};
        try {
          var cur = obj;
          var depth2 = 0;
          while (cur && depth2 < 5) {
            var ns = Object.getOwnPropertyNames(cur);
            for (var j = 0; j < ns.length; j++) {
              var n = ns[j];
              if (n.indexOf(prefix) === 0) names[n] = true;
            }
            cur = Object.getPrototypeOf(cur);
            depth2++;
          }
        } catch (e) {}
        return Object.keys(names).slice(0, 50);
      }

      function con_serializeTable(data, cols) {
        var rows = [];
        try {
          var keys = Array.isArray(data)
            ? data.map(function (_, i) { return String(i); })
            : Object.keys(data);
          keys.slice(0, 200).forEach(function (key) {
            var row = data[key];
            var rowData = { "(index)": { k: "s", v: key } };
            if (row && typeof row === "object" && !Array.isArray(row)) {
              var rcols = cols || Object.keys(row).slice(0, 20);
              rcols.forEach(function (col) {
                rowData[col] = con_serialize(row[col], 1);
              });
            } else {
              rowData["Value"] = con_serialize(row, 1);
            }
            rows.push(rowData);
          });
        } catch (e) {}
        return rows;
      }


      var con_methodNames = [
        "log", "info", "warn", "error", "debug", "trace",
        "dir", "dirxml", "table",
        "group", "groupCollapsed", "groupEnd",
        "time", "timeLog", "timeEnd",
        "count", "countReset",
        "assert", "clear"
      ];

      function con_captureMethod(name, args, stack) {
        var ts = typeof performance !== "undefined" ? performance.now() : 0;
        var seq = String(++con_seq);
        var entry = { seq: seq, level: name, ts: ts, args: [], stack: stack };

        switch (name) {
          case "assert":
            if (args[0]) return; // assertion passed — nothing to log
            entry.level = "assert";
            var assertMsg = typeof args[1] === "string" ? args[1] : "Assertion failed";
            entry.args = [{ k: "s", v: "Assertion failed: " + assertMsg }].concat(
              args.slice(2).map(function (a) { return con_serialize(a, 2); })
            );
            break;

          case "clear":
            entry.level = "clear";
            break;

          case "group":
          case "groupCollapsed":
            entry.args = args.map(function (a) { return con_serialize(a, 2); });
            entry.isGroupStart = true;
            break;

          case "groupEnd":
            entry.isGroupEnd = true;
            break;

          case "count": {
            var clabel = (args[0] !== undefined && args[0] !== null) ? String(args[0]) : "default";
            con_counts[clabel] = (con_counts[clabel] || 0) + 1;
            entry.level = "count";
            entry.args = [{ k: "s", v: clabel + ": " + con_counts[clabel] }];
            break;
          }

          case "countReset": {
            var crlabel = (args[0] !== undefined && args[0] !== null) ? String(args[0]) : "default";
            con_counts[crlabel] = 0;
            entry.level = "count";
            entry.args = [{ k: "s", v: crlabel + ": 0" }];
            break;
          }

          case "time": {
            var tlabel = (args[0] !== undefined && args[0] !== null) ? String(args[0]) : "default";
            con_timers[tlabel] = ts;
            return; // no message
          }

          case "timeLog": {
            var tllabel = (args[0] !== undefined && args[0] !== null) ? String(args[0]) : "default";
            var elapsed = con_timers[tllabel] !== undefined
              ? (ts - con_timers[tllabel]).toFixed(3) + " ms"
              : "Timer '" + tllabel + "' does not exist";
            entry.level = "time";
            entry.args = [{ k: "s", v: tllabel + ": " + elapsed }];
            break;
          }

          case "timeEnd": {
            var telabel = (args[0] !== undefined && args[0] !== null) ? String(args[0]) : "default";
            var telapsed = con_timers[telabel] !== undefined
              ? (ts - con_timers[telabel]).toFixed(3) + " ms"
              : "Timer '" + telabel + "' does not exist";
            delete con_timers[telabel];
            entry.level = "time";
            entry.args = [{ k: "s", v: telabel + ": " + telapsed }];
            break;
          }

          case "table":
            entry.level = "table";
            entry.args = args.map(function (a) { return con_serialize(a, 2); });
            if (args[0] && typeof args[0] === "object") {
              try { entry.tableRows = con_serializeTable(args[0], args[1]); } catch (te) {}
            }
            break;

          case "dir":
          case "dirxml":
            entry.args = args.map(function (a) { return con_serialize(a, 2); });
            break;

          case "trace":
            if (args.length > 0) {
              entry.args = args.map(function (a) { return con_serialize(a, 2); });
            } else {
              entry.args = [{ k: "s", v: "console.trace()" }];
            }
            break;

          default:
            entry.args = args.map(function (a) { return con_serialize(a, 2); });
            if (args.length > 1 && typeof args[0] === "string" && /%[sdifocO]/.test(args[0])) {
              entry.fmt = args[0];
            }
            break;
        }

        con_addEntry(entry);
      }


      // Takes what the early-capture stub buffered before this agent loaded. Objects the page has since released show as their label.
      function con_adoptEarly() {
        var early = window.__orbitInspectEarly;
        if (!early || !early.con || !early.con.length) return;
        var items = early.con.splice(0, early.con.length);
        items.forEach(function (item) {
          try {
            if (item.final) {
              item.seq = String(++con_seq);
              con_addEntry(item);
              return;
            }
            var args = item.a.map(function (captured) {
              if (captured[0] === 0) return con_serialize(captured[1], 2);
              var live = captured[1] ? captured[1].deref() : undefined;
              return live !== undefined ? con_serialize(live, 2) : { k: "s", v: captured[2] };
            });
            var entry = { seq: String(++con_seq), level: item.level, ts: item.ts, args: args, stack: "" };
            if (item.e) {
              try { entry.stack = (item.e.stack || "").split("\n").slice(1).join("\n"); } catch (e) {}
            }
            if (item.level === "assert") {
              var detail = typeof item.a[1] !== "undefined" && item.a[1][0] === 0 && typeof item.a[1][1] === "string" ? item.a[1][1] : "Assertion failed";
              entry.args = [{ k: "s", v: "Assertion failed: " + detail }].concat(args.slice(2));
            } else if (item.level === "trace" && args.length === 0) {
              entry.args = [{ k: "s", v: "console.trace()" }];
            } else if ((item.level === "log" || item.level === "info" || item.level === "warn" || item.level === "error" || item.level === "debug")
                       && args.length > 1 && item.a[0][0] === 0 && typeof item.a[0][1] === "string" && /%[sdifocO]/.test(item.a[0][1])) {
              entry.fmt = item.a[0][1];
            }
            con_addEntry(entry);
          } catch (e) {}
        });
      }

      ops["con.clear"] = function () {
        con_batch = [];
        con_seq = 0;
        con_timers = {};
        con_counts = {};
        if (con_reg) con_reg.clear();
        con_regSeq = 0;
      };

      ops["con.storeGlobal"] = function (msg) {
        if (!con_reg) return;
        var obj = con_reg.get(msg.id);
        if (obj === undefined) return;
        var name = "temp1";
        try {
          for (var i = 1; i <= 10; i++) {
            if (window["temp" + i] === undefined) { name = "temp" + i; break; }
          }
          window[name] = obj;
          post({ t: "con.batch", entries: [{
            seq: String(++con_seq),
            level: "log",
            ts: typeof performance !== "undefined" ? performance.now() : 0,
            args: [{ k: "s", v: name + " = " }, con_serialize(obj, 1)],
            stack: ""
          }]});
        } catch (e) {}
      };


      inits.push(function () {
        con_disposed = false;
        var orig = window.console;
        if (!orig) return;
        var live = { on: true };
        con_live = live;
        con_wrappers = {};

        con_methodNames.forEach(function (mname) {
          if (typeof orig[mname] !== "function") return;
          var native = orig[mname];
          con_nativeConsole[mname] = native;
          var wrapped = function () {
            // Always call original first — preserve behaviour, stack trace, DevTools output
            try { native.apply(orig, arguments); } catch (ce) {}
            if (!live.on) return;
            var args = Array.prototype.slice.call(arguments);
            var capturedStack = "";
            try {
              var err = new Error();
              capturedStack = (err.stack || "").split("\n").slice(1).join("\n");
            } catch (e) {}
            try { con_captureMethod(mname, args, capturedStack); } catch (e) {}
          };
          try {
            Object.defineProperty(wrapped, "name", { value: mname, configurable: true });
            Object.defineProperty(wrapped, "length", { value: native.length, configurable: true });
          } catch (e) {}
          try { orig[mname] = wrapped; con_wrappers[mname] = wrapped; } catch (e) {}
        });

        con_listen(window, "error", function (e) {
          try {
            // The capture phase also sees failed <img>/<script>/<link> loads; the document listener reports those.
            if (typeof ErrorEvent !== "undefined" && !(e instanceof ErrorEvent)) return;
            if (e.target && e.target !== window) return;
            var msg = String(e.message || "");
            var errStack = "";
            try { if (e.error && e.error.stack) errStack = String(e.error.stack); } catch (se) {}
            con_addEntry({
              seq: String(++con_seq),
              level: "exception",
              ts: typeof performance !== "undefined" ? performance.now() : 0,
              args: [{ k: "s", v: msg }],
              stack: errStack,
              url: String(e.filename || ""),
              line: e.lineno || 0,
              col: e.colno || 0
            });
          } catch (ee) {}
        }, true);

        con_listen(window, "unhandledrejection", function (e) {
          try {
            var reason = e.reason;
            var rmsg = (reason instanceof Error) ? String(reason.message) : String(reason);
            var rstack = (reason instanceof Error && reason.stack) ? String(reason.stack) : "";
            con_addEntry({
              seq: String(++con_seq),
              level: "unhandledrejection",
              ts: typeof performance !== "undefined" ? performance.now() : 0,
              args: [{ k: "s", v: "Uncaught (in promise) " + rmsg }],
              stack: rstack,
              url: "",
              line: 0,
              col: 0
            });
          } catch (ee) {}
        }, true);

        con_listen(document, "error", function (e) {
          try {
            var target = e.target;
            if (!target || isOurs(target)) return;
            var tag = (target.tagName || "").toLowerCase();
            var resourceTags = { img: 1, script: 1, link: 1, video: 1, audio: 1, source: 1, iframe: 1 };
            if (!resourceTags[tag]) return;
            var url2 = target.src || target.href || target.currentSrc || "";
            if (!url2) return;
            con_addEntry({
              seq: String(++con_seq),
              level: "resourceError",
              ts: typeof performance !== "undefined" ? performance.now() : 0,
              args: [{ k: "s", v: "Failed to load resource: " + String(url2) }],
              stack: "",
              url: String(url2),
              line: 0,
              col: 0
            });
          } catch (ee) {}
        }, true);

        con_listen(document, "securitypolicyviolation", function (e) {
          try {
            var blockedURI = String(e.blockedURI || "(unknown)");
            var directive  = String(e.violatedDirective || e.effectiveDirective || "");
            var cspMsg = "Refused to load '" + blockedURI + "'"
              + (directive ? " because it violates the Content Security Policy directive \u201c" + directive + "\u201d" : "");
            con_addEntry({
              seq: String(++con_seq),
              level: "cspViolation",
              ts: typeof performance !== "undefined" ? performance.now() : 0,
              args: [{ k: "s", v: cspMsg }],
              stack: "",
              url: String(e.sourceFile || ""),
              line: e.lineNumber || 0,
              col: e.columnNumber || 0
            });
          } catch (ee) {}
        }, true);

        // Runs after coreTail has created window.__orbitInspect.
        try {
          var oi = window.__orbitInspect;
          if (oi) {
            oi.con_serResult = function (value) {
              try { return con_serialize(value, 2); } catch (e) { return { k: "u" }; }
            };
            oi.con_getProps   = con_getPropsImpl;
            oi.con_getEntries = con_getEntriesImpl;
            oi.con_getSlice   = con_getSliceImpl;
            oi.con_completeAt = con_completeAtImpl;
            oi.con_getNode    = nodeById;
            if (oi.con_lastResult === undefined) oi.con_lastResult = undefined;
            // Expose reg for JSON copy (con_reg is closure-scoped so we expose a getter)
            oi._con_reg = con_reg;
          }
        } catch (ie) {}
        con_adoptEarly();
      });


      disposers.push(function () {
        // Closing the inspector must leave nothing running in the page.
        con_disposed = true;
        con_batch = [];
        con_listeners.forEach(function (entry) {
          try { entry[0].removeEventListener(entry[1], entry[2], entry[3]); } catch (e) {}
        });
        con_listeners = [];
        var orig = window.console;
        if (!orig) return;
        if (con_live) con_live.on = false;
        con_methodNames.forEach(function (mname) {
          if (con_nativeConsole[mname] && con_wrappers[mname]) {
            restoreIfOurs(orig, mname, con_wrappers[mname], con_nativeConsole[mname]);
          }
        });
        con_wrappers = {};
      });

    """##
}
