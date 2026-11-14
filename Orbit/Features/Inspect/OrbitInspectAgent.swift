// All fragments share ONE JS function scope, so prefix top-level names with the module prefix and make inits safe to run twice.

import WebKit

enum OrbitInspectAgent {
    static let handlerName = "orbitInspect"
    static let version = 3

    static func install(on controller: WKUserContentController) {
        OrbitInspectBridge.shared.attach(to: controller)
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix("/* orbit-inspect */") }) else { return }
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
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

      function nodeById(id) {
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

      var fills = {
        margin: "rgba(246, 178, 107, 0.66)",
        border: "rgba(255, 229, 153, 0.72)",
        padding: "rgba(147, 196, 125, 0.66)",
        content: "rgba(111, 168, 220, 0.55)"
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
        var margin = { top: px(style.marginTop), right: px(style.marginRight), bottom: px(style.marginBottom), left: px(style.marginLeft) };
        var border = { top: px(style.borderTopWidth), right: px(style.borderRightWidth), bottom: px(style.borderBottomWidth), left: px(style.borderLeftWidth) };
        var padding = { top: px(style.paddingTop), right: px(style.paddingRight), bottom: px(style.paddingBottom), left: px(style.paddingLeft) };
        var boxes = {
          margin: { x: x - margin.left, y: y - margin.top, w: rect.width + margin.left + margin.right, h: rect.height + margin.top + margin.bottom },
          border: { x: x, y: y, w: rect.width, h: rect.height },
          padding: { x: x + border.left, y: y + border.top, w: rect.width - border.left - border.right, h: rect.height - border.top - border.bottom },
          content: { x: x + border.left + padding.left, y: y + border.top + padding.top, w: rect.width - border.left - border.right - padding.left - padding.right, h: rect.height - border.top - border.bottom - padding.top - padding.bottom }
        };
        Array.prototype.forEach.call(root.querySelectorAll("[data-part]"), function (layer) {
          var part = layer.dataset.part;
          if (part === "shield") return;
          if (part === "label") {
            pin(layer, "display:block;left:" + Math.max(0, boxes.margin.x) + "px;top:" + (boxes.margin.y > 20 ? boxes.margin.y - 18 : boxes.margin.y) + "px;width:auto;height:auto;background:rgba(20,20,20,0.92);color:white;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;padding:2px 6px;border-radius:4px;white-space:nowrap");
            layer.textContent = nodeLabel(element) + " " + Math.round(rect.width) + "×" + Math.round(rect.height);
            return;
          }
          var box = boxes[part];
          if (!box) return;
          pin(layer, "display:block;left:" + box.x + "px;top:" + box.y + "px;width:" + Math.max(0, box.w) + "px;height:" + Math.max(0, box.h) + "px;background:" + fills[part]);
        });
      }

      // Topmost real page element at a viewport point, looking through our overlay and into same-origin iframes.
      function nodeAt(x, y) {
        var host = document.getElementById("orbit-inspect-root");
        function fromStack() {
          var stack = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
          if (!stack.length) {
            var one = document.elementFromPoint(x, y);
            stack = one ? [one] : [];
          }
          for (var index = 0; index < stack.length; index++) {
            var el = stack[index];
            if (!el || isOurs(el) || el === document.body || el === document.documentElement) continue;
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
          return null;
        }
        var found = fromStack();
        if (!found && host) {
          pin(host, "pointer-events:none");
          found = fromStack();
          if (state.picking) pin(host, "pointer-events:auto");
        }
        return found;
      }

      function stopPick() {
        state.picking = false;
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
