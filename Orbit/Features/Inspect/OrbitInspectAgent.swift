// All fragments share ONE JS function scope, so prefix top-level names with the module prefix and make inits safe to run twice.

import WebKit

enum OrbitInspectAgent {
    static let handlerName = "orbitInspect"
    static let version = 3

    static let fullMarker = "/* orbit-inspect */"
    static let stubMarker = "/* orbit-inspect-stub */"

    /// Controllers whose inspector is open: their pages get the full agent from document start, so reloads and navigations stay instrumented.
    private static let presentedControllers = NSHashTable<WKUserContentController>.weakObjects()

    /// Every page gets only the small early-capture stub. The full agent is added while an inspector is open on that page.
    static func install(on controller: WKUserContentController) {
        OrbitInspectBridge.shared.attach(to: controller)
        let existing = controller.userScripts
        if !existing.contains(where: { $0.source.hasPrefix(stubMarker) }) {
            controller.addUserScript(WKUserScript(source: stubSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if presentedControllers.contains(controller), !existing.contains(where: { $0.source.hasPrefix(fullMarker) }) {
            controller.addUserScript(fullScript())
        }
    }

    /// WKUserContentController removes every script at once, so the others are put straight back, as the device toolbar does.
    static func setFullAgentScript(_ on: Bool, on controller: WKUserContentController) {
        let existing = controller.userScripts
        let hasFull = existing.contains { $0.source.hasPrefix(fullMarker) }
        if on {
            presentedControllers.add(controller)
            if !hasFull { controller.addUserScript(fullScript()) }
        } else {
            presentedControllers.remove(controller)
            guard hasFull else { return }
            let kept = existing.filter { !$0.source.hasPrefix(fullMarker) }
            controller.removeAllUserScripts()
            for script in kept { controller.addUserScript(script) }
        }
    }

    private static func fullScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    static let source: String = [
        coreHead,
        elementsSource,
        consoleSource,
        sourcesSource,
        networkSource,
        performanceSource,
        animationsSource,
        applicationSource,
        lighthouseSource,
        securitySource,
        frameworksSource,
        coreTail,
    ].joined(separator: "\n")

    /// What every page carries while the inspector is closed: console output, uncaught errors and event listeners are buffered cheaply so the full agent can adopt them when it loads. Nothing else runs in the page.
    static let stubSource = ##"""
    /* orbit-inspect-stub */
    (function () {
      if (window.__orbitInspectEarly || window.__orbitInspect) return;
      var E = { paused: false, con: [], listeners: new WeakMap() };
      try { Object.defineProperty(window, "__orbitInspectEarly", { value: E, configurable: true }); } catch (e) { return; }
      var CAP = 1000;
      var STACK_FREE = 200;
      var top = true;
      try { top = window.top === window; } catch (e) { top = false; }
      if (!top) {
        // Only the frame handle is wanted from a subframe, so the inspector can load its agent there on open.
        try { window.webkit.messageHandlers.orbitInspect.postMessage(JSON.stringify({ t: "hello", href: String(location.href), title: "", version: 0, attached: false })); } catch (e) {}
      }
      var now = function () { return typeof performance !== "undefined" ? performance.now() : 0; };

      function push(entry) {
        E.con.push(entry);
        if (E.con.length > CAP + 200) E.con.splice(0, E.con.length - CAP);
      }

      // Primitives are kept by value; objects weakly with a short label, so a closed page never holds a logged object alive.
      function capture(value) {
        var type = typeof value;
        if (value === null || type === "undefined" || type === "boolean" || type === "number" || type === "bigint" || type === "symbol") return [0, value];
        if (type === "string") return [0, value.length > 10000 ? value.slice(0, 10000) + "…[truncated]" : value];
        var label;
        try {
          if (type === "function") label = "ƒ " + (value.name || "") + "()";
          else if (value instanceof Error) label = (value.name || "Error") + ": " + (value.message || "");
          else if (Array.isArray(value)) label = "Array(" + value.length + ")";
          else label = Object.prototype.toString.call(value).slice(8, -1);
        } catch (e) { label = "Object"; }
        return [1, typeof WeakRef === "function" ? new WeakRef(value) : null, label];
      }

      var console_ = window.console;
      if (console_) {
        ["log", "info", "warn", "error", "debug", "trace", "dir", "dirxml", "assert", "clear"].forEach(function (name) {
          var native = console_[name];
          if (typeof native !== "function") return;
          var wrapped = function () {
            try { native.apply(console_, arguments); } catch (e) {}
            if (E.paused) return;
            try {
              if (name === "clear") { E.con.length = 0; return; }
              if (name === "assert" && arguments[0]) return;
              // The stack is read only when the agent adopts the entry; after the first entries only warnings and errors pay for capturing one.
              var cheap = E.con.length < STACK_FREE || name === "warn" || name === "error" || name === "trace" || name === "assert";
              var error = cheap ? new Error() : null;
              var args = [];
              for (var i = 0; i < arguments.length && i < 20; i++) args.push(capture(arguments[i]));
              push({ level: name, ts: now(), a: args, e: error });
            } catch (e) {}
          };
          try {
            Object.defineProperty(wrapped, "name", { value: name, configurable: true });
            Object.defineProperty(wrapped, "length", { value: native.length, configurable: true });
          } catch (e) {}
          try { console_[name] = wrapped; } catch (e) {}
        });
      }

      function exception(level, message, stack, url, line, col) {
        push({ final: true, level: level, ts: now(), args: [{ k: "s", v: message }], stack: stack, url: url, line: line, col: col });
      }

      window.addEventListener("error", function (event) {
        if (E.paused) return;
        try {
          if (typeof ErrorEvent !== "undefined" && event instanceof ErrorEvent) {
            if (event.target && event.target !== window) return;
            var stack = "";
            try { if (event.error && event.error.stack) stack = String(event.error.stack); } catch (e) {}
            exception("exception", String(event.message || ""), stack, String(event.filename || ""), event.lineno || 0, event.colno || 0);
            return;
          }
          var target = event.target;
          if (!target || target === window) return;
          var tag = (target.tagName || "").toLowerCase();
          if (!/^(img|script|link|video|audio|source|iframe)$/.test(tag)) return;
          var url = target.src || target.href || target.currentSrc || "";
          if (url) exception("resourceError", "Failed to load resource: " + String(url), "", String(url), 0, 0);
        } catch (e) {}
      }, true);

      window.addEventListener("unhandledrejection", function (event) {
        if (E.paused) return;
        try {
          var reason = event.reason;
          var isError = reason instanceof Error;
          exception("unhandledrejection", "Uncaught (in promise) " + (isError ? String(reason.message) : String(reason)),
            isError && reason.stack ? String(reason.stack) : "", "", 0, 0);
        } catch (e) {}
      }, true);

      window.addEventListener("securitypolicyviolation", function (event) {
        if (E.paused) return;
        try {
          var blocked = String(event.blockedURI || "(unknown)");
          var directive = String(event.violatedDirective || event.effectiveDirective || "");
          exception("cspViolation", "Refused to load '" + blocked + "'" + (directive ? " because it violates the Content Security Policy directive “" + directive + "”" : ""),
            "", String(event.sourceFile || ""), event.lineNumber || 0, event.columnNumber || 0);
        } catch (e) {}
      }, true);

      // Same records the Elements panel makes while it is open, so listeners added before it opened can still be listed.
      var proto = typeof EventTarget !== "undefined" ? EventTarget.prototype : null;
      if (proto) {
        var origAdd = proto.addEventListener;
        var origRemove = proto.removeEventListener;
        proto.addEventListener = function (type, handler, options) {
          var result = origAdd.apply(this, arguments);
          if (E.paused || typeof handler !== "function") return result;
          try {
            var list = E.listeners.get(this);
            if (!list) { list = []; E.listeners.set(this, list); }
            var object = options && typeof options === "object";
            list.push({
              type: type,
              capture: typeof options === "boolean" ? options : !!(object && options.capture),
              passive: !!(object && options.passive),
              once: !!(object && options.once),
              handlerSource: "", sourceURL: null, sourceLine: null, handler: handler, beforeOpen: true
            });
          } catch (e) {}
          return result;
        };
        try { Object.defineProperty(proto.addEventListener, "length", { value: origAdd.length }); } catch (e) {}
        proto.addEventListener.toString = function () { return origAdd.toString(); };
        proto.removeEventListener = function (type, handler, options) {
          if (!E.paused) {
            try {
              var list = E.listeners.get(this);
              if (list) {
                var capture = typeof options === "boolean" ? options : !!(options && options.capture);
                for (var i = list.length - 1; i >= 0; i--) {
                  if (list[i].type === type && list[i].handler === handler && list[i].capture === capture) { list.splice(i, 1); break; }
                }
              }
            } catch (e) {}
          }
          return origRemove.apply(this, arguments);
        };
        proto.removeEventListener.toString = function () { return origRemove.toString(); };
      }
    })();
    """##

    static let coreHead = ##"""
    /* orbit-inspect */
    (function () {
      if (window.__orbitInspect) return;
      var VERSION = 3;

      var state = {
        seq: 1,
        nodes: new WeakMap(),
        ids: new Map(),
        hoverEl: null,
        treeHover: false,
        picking: false,
        detached: false,
        navWrapped: false,
        // True only while the inspector is open; page-costly work for the panels waits for it.
        presented: false
      };
      var ops = {};
      var inits = [];
      var disposers = [];
      var navHooks = [];
      var presenceHooks = [];
      // Detach keeps these script-time disposers and drops init-registered ones, which attach re-registers.
      var permanentDisposerCount = 0;

      function setPresented(on) {
        on = !!on;
        if (state.presented === on) return;
        state.presented = on;
        presenceHooks.forEach(function (hook) { try { (on ? hook.on : hook.off)(); } catch (error) {} });
      }

      // Restores only if our wrapper is still installed, so a later wrapper (Zone.js, Sentry) keeps its patch.
      function restoreIfOurs(owner, key, wrapper, original) {
        try {
          if (owner[key] === wrapper) { owner[key] = original; return true; }
        } catch (error) {}
        return false;
      }

      function post(payload) {
        try {
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.orbitInspect;
          if (!handler) return;
          handler.postMessage(JSON.stringify(payload));
        } catch (error) {}
      }

      function finite(value) {
        return typeof value === "number" && isFinite(value) ? value : null;
      }

      function postHello() {
        post({ t: "hello", href: String(location.href), title: String(document.title || ""), version: VERSION, attached: !state.detached });
      }

      function preview(value, depth, seen) {
        try {
          if (value === null) return "null";
          if (value === undefined) return "undefined";
          var type = typeof value;
          if (type === "string") return JSON.stringify(value.length > 2000 ? value.slice(0, 2000) + "…" : value);
          if (type === "number" || type === "boolean") return String(value);
          if (type === "bigint") return String(value) + "n";
          if (type === "symbol") return String(value);
          if (type === "function") return value.name ? "ƒ " + value.name + "()" : "ƒ ()";
          if (value instanceof Error) return (value.name || "Error") + ": " + (value.message || "");
          if (value instanceof Node) return nodeLabel(value);
          if (depth <= 0) return Object.prototype.toString.call(value);
          if (seen.has(value)) return "[Circular]";
          seen.add(value);
          if (Array.isArray(value)) {
            return "[" + value.slice(0, 20).map(function (item) { return preview(item, depth - 1, seen); }).join(", ") + (value.length > 20 ? ", …" : "") + "]";
          }
          var keys = Object.keys(value).slice(0, 12);
          return "{ " + keys.map(function (key) { return key + ": " + preview(value[key], depth - 1, seen); }).join(", ") + (Object.keys(value).length > 12 ? ", …" : "") + " }";
        } catch (error) {
          return String(value);
        }
      }

      function isOurs(node) {
        if (!node || node.nodeType !== 1) return false;
        if (node.id === "orbit-inspect-root") return true;
        var root = node.getRootNode && node.getRootNode();
        if (root && root.host && root.host.id === "orbit-inspect-root") return true;
        return !!(node.closest && node.closest("#orbit-inspect-root"));
      }

      // Ids map to nodes weakly so removed page DOM stays collectable.
      var nodeIdFinalizer = typeof FinalizationRegistry === "function"
        ? new FinalizationRegistry(function (id) { state.ids.delete(id); })
        : null;

      function idOf(node) {
        if (!node) return 0;
        var existing = state.nodes.get(node);
        if (existing) return existing;
        var id = state.seq++;
        state.nodes.set(node, id);
        if (typeof WeakRef === "function") {
          state.ids.set(id, new WeakRef(node));
          if (nodeIdFinalizer) nodeIdFinalizer.register(node, id);
        } else {
          state.ids.set(id, { deref: function () { return node; } });
        }
        return id;
      }

      var pendingNodes = new Map();
      var pendingKeys = new WeakMap();
      var pendingSeq = 0;

      // Always-on observers name a node with this: while closed it is a negative key held weakly, numbered only if a panel asks for it.
      function refOf(node) {
        if (!node) return 0;
        if (state.presented) return idOf(node);
        var existing = state.nodes.get(node) || pendingKeys.get(node);
        if (existing) return existing;
        if (typeof WeakRef !== "function") return 0;
        var key = -(++pendingSeq);
        pendingKeys.set(node, key);
        pendingNodes.set(key, new WeakRef(node));
        if (pendingNodes.size > 256) {
          var oldest = pendingNodes.keys().next().value;
          var evicted = pendingNodes.get(oldest).deref();
          if (evicted) pendingKeys.delete(evicted);
          pendingNodes.delete(oldest);
        }
        return key;
      }

      function nodeById(id) {
        if (id < 0) {
          var pending = pendingNodes.get(id);
          var pendingNode = pending ? pending.deref() : null;
          if (!pendingNode) pendingNodes.delete(id);
          return pendingNode || null;
        }
        var ref = state.ids.get(id);
        var node = ref ? ref.deref() : null;
        if (!node && ref) state.ids.delete(id);
        return node || null;
      }

      function nodeLabel(node) {
        if (!node || node.nodeType !== 1) return node && node.nodeName ? node.nodeName.toLowerCase() : "";
        var name = (node.tagName || "").toLowerCase();
        if (node.id) name += "#" + node.id;
        var className = typeof node.className === "string" ? node.className.trim() : "";
        if (className) name += "." + className.split(/\s+/).slice(0, 2).join(".");
        return name;
      }

      // The wire shape of one DOM node: { id, kind: el|text|comment|doctype|shadow, name, attrs, childCount, text }.
      function describe(node) {
        var id = idOf(node);
        if (!node) return { id: id, kind: "el", name: "?", attrs: {}, childCount: 0, text: "" };
        if (node.nodeType === 3) {
          return { id: id, kind: "text", name: "#text", attrs: {}, childCount: 0, text: String(node.textContent || "").replace(/\s+/g, " ").trim().slice(0, 200) };
        }
        if (node.nodeType === 8) {
          return { id: id, kind: "comment", name: "#comment", attrs: {}, childCount: 0, text: String(node.textContent || "").replace(/\s+/g, " ").trim().slice(0, 200) };
        }
        if (node.nodeType === 10) {
          return { id: id, kind: "doctype", name: "#doctype", attrs: {}, childCount: 0, text: node.name || "html" };
        }
        if (node.nodeType === 11) {
          return { id: id, kind: "shadow", name: "#shadow-root", attrs: {}, childCount: node.childNodes.length, text: "" };
        }
        var attrs = {};
        if (node.attributes) {
          Array.prototype.slice.call(node.attributes, 0, 40).forEach(function (attribute) {
            attrs[attribute.name] = String(attribute.value).slice(0, 400);
          });
        }
        var childCount = node.childNodes ? node.childNodes.length : 0;
        if (node.shadowRoot) childCount += 1;
        if (node.tagName === "IFRAME") {
          try { if (node.contentDocument) childCount += 1; } catch (error) {}
        }
        return { id: id, kind: "el", name: (node.tagName || "").toLowerCase(), attrs: attrs, childCount: childCount, text: "" };
      }

      function childrenOf(node) {
        var list = [];
        if (!node) return list;
        if (node.shadowRoot) list.push(node.shadowRoot);
        if (node.tagName === "IFRAME") {
          try { if (node.contentDocument && node.contentDocument.documentElement) list.push(node.contentDocument.documentElement); } catch (error) {}
        }
        if (node.childNodes) {
          Array.prototype.forEach.call(node.childNodes, function (child) { list.push(child); });
        }
        return list.filter(function (child) {
          if (!child || isOurs(child)) return false;
          if (child.nodeType === 3 && !String(child.textContent || "").trim()) return false;
          return child.nodeType === 1 || child.nodeType === 3 || child.nodeType === 8 || child.nodeType === 10 || child.nodeType === 11;
        }).slice(0, 1000);
      }

      function parentOf(node) {
        if (!node) return null;
        if (node.parentNode && node.parentNode.nodeType !== 9) return node.parentNode;
        if (node.host) return node.host;
        if (node.nodeType === 1 && node.ownerDocument && node.ownerDocument.defaultView && node.ownerDocument.defaultView !== window) {
          try { return node.ownerDocument.defaultView.frameElement; } catch (error) {}
        }
        return null;
      }

      function lineage(node) {
        var list = [];
        var current = node;
        var guard = 0;
        while (current && current.nodeType !== 9 && guard < 120) {
          list.push(current);
          current = parentOf(current);
          guard += 1;
        }
        return list.reverse();
      }

      function px(value) {
        var number = parseFloat(value);
        return isFinite(number) ? number : 0;
      }

      function pageOrigin(node) {
        var x = 0;
        var y = 0;
        var view = node.ownerDocument && node.ownerDocument.defaultView;
        while (view && view !== window) {
          var frame = view.frameElement;
          if (!frame) break;
          var rect = frame.getBoundingClientRect();
          x += rect.left;
          y += rect.top;
          view = frame.ownerDocument && frame.ownerDocument.defaultView;
        }
        return { x: x, y: y };
      }

      // ----- overlay: one shadow-DOM host that page CSS cannot reach, used for hover highlight and the picker -----

      function pin(element, declarations) {
        String(declarations).split(";").forEach(function (part) {
          var split = part.indexOf(":");
          if (split < 1) return;
          element.style.setProperty(part.slice(0, split).trim(), part.slice(split + 1).trim(), "important");
        });
      }

      // Each box-model layer paints only its own band (margin, border and padding are rings, content is the middle), so the colours never stack into something opaque, and the translucency is low enough to read the page through.
      var fills = {
        margin: "rgba(246, 178, 107, 0.42)",
        border: "rgba(255, 229, 153, 0.50)",
        padding: "rgba(147, 196, 125, 0.42)",
        content: "rgba(111, 168, 220, 0.30)"
      };

      function ensureOverlay() {
        var host = document.getElementById("orbit-inspect-root");
        if (host && !host.shadowRoot) host.remove();
        host = document.getElementById("orbit-inspect-root");
        if (host && host.shadowRoot) return host.shadowRoot;
        host = document.createElement("div");
        host.id = "orbit-inspect-root";
        host.setAttribute("aria-hidden", "true");
        pin(host, "all:initial;position:fixed;inset:0;width:100vw;height:100vh;margin:0;padding:0;border:0;transform:none;pointer-events:none;z-index:2147483647;background:transparent");
        var shadow = host.attachShadow({ mode: "open" });
        var style = document.createElement("style");
        style.textContent = "div{all:initial;position:fixed;margin:0;padding:0;border:0;pointer-events:none;box-sizing:border-box;display:none}";
        shadow.appendChild(style);
        ["margin", "border", "padding", "content", "label", "shield"].forEach(function (part) {
          var layer = document.createElement("div");
          layer.id = part === "shield" ? "orbit-inspect-shield" : "";
          layer.dataset.part = part;
          shadow.appendChild(layer);
        });
        (document.documentElement || document.body).appendChild(host);
        var shield = shadow.getElementById("orbit-inspect-shield");
        shield.addEventListener("mousemove", function (event) {
          if (!state.picking) return;
          var element = nodeAt(event.clientX, event.clientY);
          state.hoverEl = element;
          if (element) draw(element);
          else hideHighlight();
        });
        shield.addEventListener("click", function (event) {
          event.preventDefault();
          event.stopPropagation();
          var element = nodeAt(event.clientX, event.clientY);
          stopPick();
          hideHighlight();
          if (element && typeof selectNode === "function") selectNode(element);
        }, true);
        shield.addEventListener("contextmenu", function (event) {
          event.preventDefault();
          event.stopPropagation();
        }, true);
        return shadow;
      }

      function hideHighlight() {
        var host = document.getElementById("orbit-inspect-root");
        var root = host && host.shadowRoot;
        if (!root) return;
        Array.prototype.forEach.call(root.querySelectorAll("[data-part]"), function (child) {
          if (child.dataset.part === "shield") return;
          child.style.setProperty("display", "none", "important");
        });
      }

      function draw(element) {
        if (!element || element.nodeType !== 1 || isOurs(element) || element === document.body || element === document.documentElement) {
          hideHighlight();
          return;
        }
        var root = ensureOverlay();
        var style = getComputedStyle(element);
        var rect = element.getBoundingClientRect();
        var origin = pageOrigin(element);
        var x = rect.left + origin.x;
        var y = rect.top + origin.y;
        function sides(prefix, suffix) {
          return {
            top: Math.max(0, px(style[prefix + "Top" + suffix])),
            right: Math.max(0, px(style[prefix + "Right" + suffix])),
            bottom: Math.max(0, px(style[prefix + "Bottom" + suffix])),
            left: Math.max(0, px(style[prefix + "Left" + suffix]))
          };
        }
        var margin = sides("margin", "");
        var border = sides("border", "Width");
        var padding = sides("padding", "");
        // Outer box of each band and the thickness of that band on each side. Content has no band: it fills its box.
        var bands = {
          margin: { x: x - margin.left, y: y - margin.top, w: rect.width + margin.left + margin.right, h: rect.height + margin.top + margin.bottom, edge: margin },
          border: { x: x, y: y, w: rect.width, h: rect.height, edge: border },
          padding: { x: x + border.left, y: y + border.top, w: rect.width - border.left - border.right, h: rect.height - border.top - border.bottom, edge: padding },
          content: { x: x + border.left + padding.left, y: y + border.top + padding.top, w: rect.width - border.left - border.right - padding.left - padding.right, h: rect.height - border.top - border.bottom - padding.top - padding.bottom, edge: null }
        };
        var labelTop = bands.margin.y;
        var labelLeft = bands.margin.x;
        Array.prototype.forEach.call(root.querySelectorAll("[data-part]"), function (layer) {
          var part = layer.dataset.part;
          if (part === "shield") return;
          if (part === "label") {
            pin(layer, "display:block;left:" + Math.max(0, labelLeft) + "px;top:" + (labelTop > 20 ? labelTop - 18 : labelTop) + "px;width:auto;height:auto;background:rgba(20,20,20,0.92);color:white;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;padding:2px 6px;border-radius:4px;white-space:nowrap");
            layer.textContent = nodeLabel(element) + " " + Math.round(rect.width) + "×" + Math.round(rect.height);
            return;
          }
          var box = bands[part];
          if (!box) return;
          var position = "display:block;left:" + box.x + "px;top:" + box.y + "px;width:" + Math.max(0, box.w) + "px;height:" + Math.max(0, box.h) + "px;";
          if (box.edge) {
            // The band is the layer's own border, drawn inside its outer box, so the middle stays clear.
            pin(layer, position + "background:transparent;border-style:solid;border-color:" + fills[part] + ";border-width:" + box.edge.top + "px " + box.edge.right + "px " + box.edge.bottom + "px " + box.edge.left + "px");
          } else {
            pin(layer, position + "background:" + fills[part] + ";border-width:0px");
          }
        });
      }

      // True when a text node directly inside `el` is drawn under the point.
      function ownsTextAt(el, x, y) {
        var children = el.childNodes;
        for (var index = 0; index < children.length && index < 60; index++) {
          var child = children[index];
          if (child.nodeType !== 3 || !/\S/.test(child.nodeValue || "")) continue;
          var range = document.createRange();
          range.selectNodeContents(child);
          var rects = range.getClientRects();
          for (var r = 0; r < rects.length; r++) {
            var box = rects[r];
            if (x >= box.left && x <= box.right && y >= box.top && y <= box.bottom) return true;
          }
        }
        return false;
      }

      // True when `el` paints something solid, so whatever is below it in the stack is not visible through it.
      function paintsSolid(el) {
        if (/^(IMG|VIDEO|CANVAS|SVG|IFRAME|PICTURE|OBJECT|EMBED)$/i.test(el.tagName)) return true;
        var style = getComputedStyle(el);
        if (style.backgroundImage && style.backgroundImage !== "none") return true;
        var match = /rgba?\(([^)]*)\)/.exec(style.backgroundColor || "");
        if (!match) return false;
        var parts = match[1].split(/[ ,\/]+/).filter(Boolean);
        var alpha = parts.length > 3 ? parseFloat(parts[3]) : 1;
        return alpha >= 0.9;
      }

      // The element a person is pointing at: the topmost one, unless text sits under the point beneath nothing but see-through boxes, in which case the text's own element. Without this, a transparent box laid over a heading (or a heading whose pointer-events is off) is picked and the highlight lands on the background.
      function chooseFromStack(stack, x, y) {
        for (var index = 0; index < stack.length; index++) {
          var el = stack[index];
          if (ownsTextAt(el, x, y)) return el;
          if (paintsSolid(el)) break;
        }
        return stack[0];
      }

      // Hit testing normally skips pointer-events:none, which hides text in decorative layers and picks whatever is behind. Only while picking is every element made hit-testable.
      function setHitTestAll(on) {
        var existing = document.getElementById("orbit-inspect-hit-all");
        if (!on) {
          if (existing) existing.remove();
          return;
        }
        if (existing) return;
        var style = document.createElement("style");
        style.id = "orbit-inspect-hit-all";
        style.textContent = "*:not(#orbit-inspect-root){pointer-events:auto !important}";
        (document.head || document.documentElement).appendChild(style);
      }

      // Topmost real page element at a viewport point, looking through our overlay and into same-origin iframes.
      function nodeAt(x, y) {
        var host = document.getElementById("orbit-inspect-root");
        function fromStack() {
          var raw = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
          if (!raw.length) {
            var one = document.elementFromPoint(x, y);
            raw = one ? [one] : [];
          }
          var stack = [];
          for (var index = 0; index < raw.length && stack.length < 16; index++) {
            var candidate = raw[index];
            if (!candidate || isOurs(candidate) || candidate === document.body || candidate === document.documentElement) continue;
            stack.push(candidate);
          }
          if (!stack.length) return null;
          var el = chooseFromStack(stack, x, y);
          if (el.tagName === "IFRAME") {
            try {
              var inner = el.contentDocument;
              if (inner) {
                var frame = el.getBoundingClientRect();
                var nested = inner.elementFromPoint(x - frame.left, y - frame.top);
                if (nested && !isOurs(nested) && nested !== inner.body) return nested;
              }
            } catch (error) {}
          }
          return el;
        }
        var oneShot = !state.picking;
        if (oneShot) setHitTestAll(true);
        var found;
        try {
          found = fromStack();
          if (!found && host) {
            pin(host, "pointer-events:none");
            found = fromStack();
            if (state.picking) pin(host, "pointer-events:auto");
          }
        } finally {
          if (oneShot) setHitTestAll(false);
        }
        return found;
      }

      function stopPick() {
        state.picking = false;
        setHitTestAll(false);
        state.hoverEl = null;
        var host = document.getElementById("orbit-inspect-root");
        var shield = host && host.shadowRoot && host.shadowRoot.getElementById("orbit-inspect-shield");
        if (shield) pin(shield, "display:none;pointer-events:none");
        if (host) pin(host, "pointer-events:none");
        post({ t: "picking", on: false });
      }

      function startPick() {
        var shadow = ensureOverlay();
        var shield = shadow.getElementById("orbit-inspect-shield");
        var host = document.getElementById("orbit-inspect-root");
        pin(shield, "display:block;position:fixed;inset:0;width:100vw;height:100vh;cursor:crosshair;background:transparent;pointer-events:auto;z-index:2147483646");
        if (host) pin(host, "pointer-events:auto");
        state.picking = true;
        setHitTestAll(true);
        state.treeHover = false;
        post({ t: "picking", on: true });
      }

      window.addEventListener("keydown", function (event) {
        if (event.key === "Escape" && state.picking) {
          stopPick();
          hideHighlight();
        }
      }, true);
      window.addEventListener("scroll", function () {
        if ((state.picking || state.treeHover) && state.hoverEl) draw(state.hoverEl);
      }, true);
      window.addEventListener("resize", function () {
        if ((state.picking || state.treeHover) && state.hoverEl) draw(state.hoverEl);
      });

      function emit(parent, nodes) {
        post({ t: "el.dom", parent: parent, nodes: nodes.map(describe) });
      }


      // The early-capture stub keeps recording underneath our wrappers only while they are off, so nothing is captured twice.
      var early = window.__orbitInspectEarly || null;
      inits.push(function () {
        if (!early) return;
        early.paused = true;
        disposers.push(function () { early.paused = false; });
      });

      inits.push(function () {
        // History wrapping and the popstate listener are permanent (they only feed navHooks), so wrap once.
        if (state.navWrapped) return;
        state.navWrapped = true;
        function wrap(name) {
          var original = history[name];
          if (typeof original !== "function") return;
          history[name] = function () {
            var result = original.apply(this, arguments);
            navHooks.forEach(function (hook) { try { hook(); } catch (error) {} });
            post({ t: "navigate", href: String(location.href), title: String(document.title || "") });
            return result;
          };
        }
        wrap("pushState");
        wrap("replaceState");
        window.addEventListener("popstate", function () {
          navHooks.forEach(function (hook) { try { hook(); } catch (error) {} });
          post({ t: "navigate", href: String(location.href), title: String(document.title || "") });
        });
      });


      ops.ping = function () { postHello(); };

      ops.pick = function (message) {
        if (message.on) startPick(); else stopPick();
      };

      ops.inspect = function (message) {
        var element = nodeAt(message.x, message.y);
        if (element && typeof selectNode === "function") selectNode(element);
      };

      ops.highlight = function (message) {
        state.treeHover = true;
        state.hoverEl = nodeById(message.id);
        if (state.hoverEl) draw(state.hoverEl);
        else hideHighlight();
      };

      ops.clearHighlight = function () {
        state.treeHover = false;
        state.hoverEl = null;
        if (!state.picking) hideHighlight();
      };

      ops.present = function (message) { setPresented(message.on); };

      ops.detach = function () {
        stopPick();
        hideHighlight();
        setPresented(false);
        state.detached = true;
        disposers.forEach(function (dispose) { try { dispose(); } catch (error) {} });
        disposers.length = permanentDisposerCount;
        var overlay = document.getElementById("orbit-inspect-root");
        if (overlay) overlay.remove();
      };

      // Runs every init again, only after a detach, so a stray attach cannot double-install anything.
      ops.attach = function () {
        if (!state.detached) return;
        state.detached = false;
        inits.forEach(function (init) { try { init(); } catch (error) {} });
      };

      function cmd(raw) {
        var message = raw;
        try { if (typeof raw === "string") message = JSON.parse(raw); } catch (error) { return; }
        if (!message || !message.op) return;
        var handler = ops[message.op];
        if (!handler) return;
        try {
          handler(message);
        } catch (error) {
          post({ t: "agentError", op: message.op, message: String(error && error.message || error) });
        }
      }

    """##

    static let coreTail = ##"""
      window.__orbitInspect = {
        version: VERSION,
        cmd: cmd,
        el_selectedElement: typeof el_selectedElement === "function" ? el_selectedElement : null,
        fw_selectedComponent: typeof fw_selectedComponent === "function" ? fw_selectedComponent : null,
        // What the agent is costing the page right now, for diagnostics and tests. Counts only, no content.
        stats: function () {
          return {
            presented: state.presented,
            detached: state.detached,
            observingDOM: typeof el_observer !== "undefined" && !!el_observer,
            trackedNodes: state.ids.size,
            pendingNodes: pendingNodes.size,
            disposers: disposers.length,
            permanentDisposers: permanentDisposerCount
          };
        }
      };
      permanentDisposerCount = disposers.length;
      inits.forEach(function (init) { try { init(); } catch (error) {} });
      try { postHello(); } catch (error) {}
      window.addEventListener("pageshow", function (event) {
        if (event.persisted) postHello();
      });
    })();
    """##
}

final class OrbitInspectBridge: NSObject, WKScriptMessageHandler {
    static let shared = OrbitInspectBridge()

    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    func attach(to controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controller.add(self, name: OrbitInspectAgent.handlerName)
        controllers.add(controller)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body
        let webView = message.webView
        let frameInfo = message.frameInfo
        let main = frameInfo.isMainFrame
        let frame = frameInfo.request.url?.absoluteString
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                OrbitDevToolsStore.shared.receive(body, webView: webView, isMainFrame: main, frameURL: frame, frameInfo: frameInfo)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OrbitDevToolsStore.shared.receive(body, webView: webView, isMainFrame: main, frameURL: frame, frameInfo: frameInfo)
                }
            }
        }
    }
}
