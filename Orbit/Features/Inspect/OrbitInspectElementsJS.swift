import WebKit

extension OrbitInspectAgent {
    static let elementsSource = ##"""

      var el_selected = null;
      var el_history = [null, null, null, null, null]; // $0..$4
      var el_listeners = new WeakMap();
      var el_mutationBuffer = [];
      var el_mutationTimer = null;
      var el_forceStateMap = {};
      var el_forceStyleEl = null;
      var el_cssPropertyList = [];
      var el_inheritableProps = new Set([
        "color","cursor","direction","font","font-family","font-kerning","font-optical-sizing",
        "font-size","font-size-adjust","font-stretch","font-style","font-variant",
        "font-variant-caps","font-variant-ligatures","font-variant-numeric","font-weight",
        "letter-spacing","line-height","list-style","list-style-image","list-style-position",
        "list-style-type","orphans","pointer-events","quotes","tab-size","text-align",
        "text-align-last","text-decoration","text-indent","text-justify","text-orientation",
        "text-shadow","text-transform","visibility","white-space","widows","word-break",
        "word-spacing","word-wrap","writing-mode","border-collapse","border-spacing",
        "caption-side","empty-cells"
      ]);

      // Every page edit records how to reverse and replay itself by entry id; Swift owns the undo and redo order.
      var el_journal = {};
      var el_entrySeq = 0;

      function el_record(label, undo, redo) {
        var entry = ++el_entrySeq;
        el_journal[entry] = { undo: undo, redo: redo };
        post({ t: "el.edited", entry: entry, label: label });
        return entry;
      }

      function el_replay(msg, direction) {
        var record = el_journal[msg.entry];
        var ok = false;
        if (record) {
          try { ok = record[direction]() !== false; } catch(e) { ok = false; }
        }
        if (!ok) {
          delete el_journal[msg.entry];
          post({ t: "el.editFailed", entry: msg.entry, direction: direction });
          return;
        }
        if (el_selected && el_selected.nodeType === 1 && el_selected.isConnected) el_postStyle(el_selected);
      }

      // Overlays are SVG in the shadow-DOM overlay host (fixed, pointer-events:none) so page layout never changes.
      var el_layoutOn = {};
      var el_layoutSvg = null;
      var el_layoutFrame = 0;
      var el_layoutListening = false;
      var el_svgNS = "http://www.w3.org/2000/svg";

      function el_layoutKindOf(node) {
        if (!node || node.nodeType !== 1) return "";
        try {
          var display = getComputedStyle(node).display;
          if (display === "flex" || display === "inline-flex") return "flex";
          if (display === "grid" || display === "inline-grid") return "grid";
        } catch(e) {}
        return "";
      }

      // `includeNone` also reports plain elements so a badge disappears when a style edit removes the layout.
      function el_postLayoutKinds(nodes, includeNone) {
        var kinds = {};
        var any = false;
        var budget = 400;
        for (var i = 0; i < nodes.length && budget > 0; i++) {
          var node = nodes[i];
          if (!node || node.nodeType !== 1) continue;
          budget--;
          var kind = el_layoutKindOf(node);
          if (kind || includeNone) { kinds[idOf(node)] = kind; any = true; }
        }
        if (any) post({ t: "el.layoutKinds", kinds: kinds });
      }

      function el_layoutCount() { return Object.keys(el_layoutOn).length; }

      function el_layoutPostState() { post({ t: "el.layoutOverlays", overlays: el_layoutOn }); }

      function el_layoutScheduleDraw() {
        if (el_layoutFrame || !el_layoutCount()) return;
        el_layoutFrame = requestAnimationFrame(function() {
          el_layoutFrame = 0;
          el_layoutDraw();
        });
      }

      function el_layoutHandler() { el_layoutScheduleDraw(); }

      function el_layoutSync() {
        var active = el_layoutCount() > 0;
        if (active && !el_layoutListening) {
          window.addEventListener("scroll", el_layoutHandler, true);
          window.addEventListener("resize", el_layoutHandler);
          el_layoutListening = true;
        } else if (!active && el_layoutListening) {
          window.removeEventListener("scroll", el_layoutHandler, true);
          window.removeEventListener("resize", el_layoutHandler);
          el_layoutListening = false;
        }
        if (active) {
          el_layoutDraw();
        } else {
          if (el_layoutFrame) { try { cancelAnimationFrame(el_layoutFrame); } catch(e) {} el_layoutFrame = 0; }
          if (el_layoutSvg) { try { el_layoutSvg.remove(); } catch(e) {} el_layoutSvg = null; }
        }
      }

      function el_svg(tag, attrs, parent) {
        var shape = document.createElementNS(el_svgNS, tag);
        for (var key in attrs) shape.setAttribute(key, String(attrs[key]));
        if (parent) parent.appendChild(shape);
        return shape;
      }

      function el_layoutDraw() {
        var keys = Object.keys(el_layoutOn);
        if (!keys.length) { el_layoutSync(); return; }
        var shadow = ensureOverlay();
        if (!el_layoutSvg || el_layoutSvg.getRootNode() !== shadow) {
          el_layoutSvg = el_svg("svg", { "aria-hidden": "true" });
          pin(el_layoutSvg, "display:block;position:fixed;left:0;top:0;width:100vw;height:100vh;overflow:visible;pointer-events:none");
          shadow.appendChild(el_layoutSvg);
        }
        while (el_layoutSvg.firstChild) el_layoutSvg.removeChild(el_layoutSvg.firstChild);
        var pruned = false;
        keys.forEach(function(key) {
          var node = nodeById(parseInt(key, 10));
          if (!node || node.nodeType !== 1 || !node.isConnected) { delete el_layoutOn[key]; pruned = true; return; }
          try {
            if (el_layoutOn[key] === "grid") el_layoutDrawGrid(node, el_layoutSvg);
            else el_layoutDrawFlex(node, el_layoutSvg);
          } catch(e) {}
        });
        if (pruned) { el_layoutPostState(); el_layoutSync(); }
      }

      var el_flexStyle = { stroke: "rgba(140, 92, 230, 0.95)", fill: "rgba(140, 92, 230, 0.10)", gap: "rgba(140, 92, 230, 0.26)" };
      var el_gridStyle = { stroke: "rgba(214, 86, 140, 0.95)", gap: "rgba(214, 86, 140, 0.22)" };

      function el_layoutLabel(svg, text, x, y, color) {
        var width = text.length * 6.4 + 10;
        var top = y > 18 ? y - 17 : y + 2;
        el_svg("rect", { x: x, y: top, width: width, height: 15, rx: 4, fill: "rgba(20, 20, 24, 0.92)" }, svg);
        var label = el_svg("text", { x: x + 5, y: top + 11, fill: "white", "font-size": 10.5,
          "font-family": "ui-monospace, SFMono-Regular, Menlo, monospace" }, svg);
        label.textContent = text;
      }

      function el_layoutDrawFlex(node, svg) {
        var cs = getComputedStyle(node);
        var rect = node.getBoundingClientRect();
        var origin = pageOrigin(node);
        el_svg("rect", { x: rect.left + origin.x, y: rect.top + origin.y, width: rect.width, height: rect.height,
          fill: "none", stroke: el_flexStyle.stroke, "stroke-width": 1, "stroke-dasharray": "4 3" }, svg);
        var items = [];
        var children = node.children;
        for (var i = 0; i < children.length && items.length < 300; i++) {
          var child = children[i];
          if (isOurs(child)) continue;
          var ccs = getComputedStyle(child);
          if (ccs.display === "none" || ccs.position === "absolute" || ccs.position === "fixed") continue;
          var r = child.getBoundingClientRect();
          items.push({ left: r.left + origin.x, top: r.top + origin.y, right: r.right + origin.x, bottom: r.bottom + origin.y });
        }
        items.forEach(function(r) {
          el_svg("rect", { x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top,
            fill: el_flexStyle.fill, stroke: el_flexStyle.stroke, "stroke-width": 1 }, svg);
        });
        var rowAxis = String(cs.flexDirection).indexOf("row") === 0;
        var sorted = items.slice().sort(function(a, b) { return rowAxis ? a.left - b.left : a.top - b.top; });
        for (var j = 1; j < sorted.length; j++) {
          var a = sorted[j - 1], b = sorted[j];
          if (rowAxis) {
            var lo = Math.max(a.top, b.top), hi = Math.min(a.bottom, b.bottom), gap = b.left - a.right;
            if (hi > lo && gap > 0.5) el_svg("rect", { x: a.right, y: lo, width: gap, height: hi - lo, fill: el_flexStyle.gap }, svg);
          } else {
            var left = Math.max(a.left, b.left), right = Math.min(a.right, b.right), vgap = b.top - a.bottom;
            if (right > left && vgap > 0.5) el_svg("rect", { x: left, y: a.bottom, width: right - left, height: vgap, fill: el_flexStyle.gap }, svg);
          }
        }
        el_layoutLabel(svg, "flex", rect.left + origin.x, rect.top + origin.y, el_flexStyle.stroke);
      }

      function el_gridTracks(value) {
        return String(value || "").split(/\s+/).filter(function(token) { return /^-?[\d.]+px$/.test(token); }).map(parseFloat);
      }

      function el_layoutDrawGrid(node, svg) {
        var cs = getComputedStyle(node);
        var rect = node.getBoundingClientRect();
        var origin = pageOrigin(node);
        var left = rect.left + origin.x, top = rect.top + origin.y;
        el_svg("rect", { x: left, y: top, width: rect.width, height: rect.height,
          fill: "none", stroke: el_gridStyle.stroke, "stroke-width": 1, "stroke-dasharray": "4 3" }, svg);
        var contentLeft = left + px(cs.borderLeftWidth) + px(cs.paddingLeft);
        var contentTop = top + px(cs.borderTopWidth) + px(cs.paddingTop);
        var columns = el_gridTracks(cs.gridTemplateColumns);
        var rows = el_gridTracks(cs.gridTemplateRows);
        var colGap = px(cs.columnGap), rowGap = px(cs.rowGap);
        var totalWidth = columns.reduce(function(sum, w) { return sum + w; }, 0) + colGap * Math.max(0, columns.length - 1);
        var totalHeight = rows.reduce(function(sum, h) { return sum + h; }, 0) + rowGap * Math.max(0, rows.length - 1);
        var x = contentLeft;
        columns.forEach(function(width, index) {
          el_svg("line", { x1: x, y1: contentTop, x2: x, y2: contentTop + totalHeight, stroke: el_gridStyle.stroke, "stroke-width": 1 }, svg);
          el_svg("text", { x: x + 3, y: contentTop - 3, fill: el_gridStyle.stroke, "font-size": 9.5, "font-family": "ui-monospace, Menlo, monospace" }, svg).textContent = String(index + 1);
          if (colGap > 0.5 && index < columns.length - 1) {
            el_svg("rect", { x: x + width, y: contentTop, width: colGap, height: totalHeight, fill: el_gridStyle.gap }, svg);
          }
          x += width;
          if (index === columns.length - 1) {
            el_svg("line", { x1: x, y1: contentTop, x2: x, y2: contentTop + totalHeight, stroke: el_gridStyle.stroke, "stroke-width": 1 }, svg);
          }
          x += colGap;
        });
        var y = contentTop;
        rows.forEach(function(height, index) {
          el_svg("line", { x1: contentLeft, y1: y, x2: contentLeft + totalWidth, y2: y, stroke: el_gridStyle.stroke, "stroke-width": 1 }, svg);
          el_svg("text", { x: contentLeft - 12, y: y + 10, fill: el_gridStyle.stroke, "font-size": 9.5, "font-family": "ui-monospace, Menlo, monospace" }, svg).textContent = String(index + 1);
          if (rowGap > 0.5 && index < rows.length - 1) {
            el_svg("rect", { x: contentLeft, y: y + height, width: totalWidth, height: rowGap, fill: el_gridStyle.gap }, svg);
          }
          y += height;
          if (index === rows.length - 1) {
            el_svg("line", { x1: contentLeft, y1: y, x2: contentLeft + totalWidth, y2: y, stroke: el_gridStyle.stroke, "stroke-width": 1 }, svg);
          }
          y += rowGap;
        });
        el_layoutLabel(svg, "grid", left, top, el_gridStyle.stroke);
      }

      function selectNode(element) {
        if (!element || isOurs(element)) return;
        el_selected = element;
        el_history = [element, el_history[0], el_history[1], el_history[2], el_history[3]];
        var id = idOf(element);
        var path = lineage(element);
        var listed = [];
        path.forEach(function(node) {
          var kids = childrenOf(node);
          emit(describe(node), kids);
          listed.push(node);
          kids.forEach(function(kid) { listed.push(kid); });
        });
        post({ t: "el.select", id: id, path: path.map(describe) });
        el_postLayoutKinds(listed, false);
        el_postStyle(element);
      }

      function el_selectedElement() {
        return el_history[0];
      }


      ops["el.snapshot"] = function() {
        var root = document.documentElement;
        if (!root) return;
        var rootKids = childrenOf(root);
        emit(describe(root), rootKids);
        var listed = [root].concat(rootKids);
        if (el_selected) {
          var path = lineage(el_selected);
          path.forEach(function(node) {
            var kids = childrenOf(node);
            emit(describe(node), kids);
            listed.push(node);
            kids.forEach(function(kid) { listed.push(kid); });
          });
        }
        el_postLayoutKinds(listed, false);
        post({ t: "el.snapshotDone" });
      };

      ops["el.expand"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node) return;
        var kids = childrenOf(node);
        var cap = 200;
        var offset = msg.offset || 0;
        var slice = kids.slice(offset, offset + cap);
        post({ t: "el.children",
               id: msg.id,
               children: slice.map(describe),
               totalCount: kids.length,
               offset: offset });
        el_postLayoutKinds(slice, false);
      };

      ops["el.select"] = function(msg) {
        var node = nodeById(msg.id);
        if (node) selectNode(node);
      };

      // A row picked in the tree becomes the page's selection ($0) without the full el.select round trip.
      ops["el.markSelected"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || node === el_selected || isOurs(node)) return;
        el_selected = node;
        el_history = [node, el_history[0], el_history[1], el_history[2], el_history[3]];
      };

      ops["el.style"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (node && node.nodeType === 1) el_postStyle(node);
      };

      ops["el.computed"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (!node || node.nodeType !== 1) return;
        el_postComputed(node);
      };

      ops["el.boxModel"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (!node || node.nodeType !== 1) return;
        var cs = getComputedStyle(node);
        var rect = node.getBoundingClientRect();
        post({
          t: "el.boxModel", id: idOf(node),
          width: finite(rect.width), height: finite(rect.height),
          marginTop: cs.marginTop, marginRight: cs.marginRight,
          marginBottom: cs.marginBottom, marginLeft: cs.marginLeft,
          borderTop: cs.borderTopWidth, borderRight: cs.borderRightWidth,
          borderBottom: cs.borderBottomWidth, borderLeft: cs.borderLeftWidth,
          paddingTop: cs.paddingTop, paddingRight: cs.paddingRight,
          paddingBottom: cs.paddingBottom, paddingLeft: cs.paddingLeft,
          position: cs.position,
          top: cs.top, right: cs.right, bottom: cs.bottom, left: cs.left,
          display: cs.display,
          flexContainer: cs.display === "flex" || cs.display === "inline-flex",
          gridContainer: cs.display === "grid" || cs.display === "inline-grid"
        });
      };

      ops["el.listeners"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (!node) return;
        el_postListeners(node, msg.includeAncestors !== false);
      };

      ops["el.a11y"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (!node || node.nodeType !== 1) return;
        el_postA11y(node);
      };

      function el_attrState(node, name) {
        return node.hasAttribute(name) ? { has: true, value: node.getAttribute(name) } : { has: false, value: null };
      }

      function el_applyAttr(node, name, state) {
        if (state.has) node.setAttribute(name, state.value);
        else node.removeAttribute(name);
        post({ t: "el.attrDone", id: idOf(node), attrs: el_attrs(node) });
        return true;
      }

      ops["el.attr"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || node.nodeType !== 1) return;
        try {
          var before = el_attrState(node, msg.name);
          if (msg.remove) node.removeAttribute(msg.name);
          else node.setAttribute(msg.name, String(msg.value));
          var after = el_attrState(node, msg.name);
          post({ t: "el.attrDone", id: msg.id, attrs: el_attrs(node) });
          if (before.has !== after.has || before.value !== after.value) {
            var name = msg.name;
            el_record("Edit attribute",
              function() { return el_applyAttr(node, name, before); },
              function() { return el_applyAttr(node, name, after); });
          }
        } catch(e) {
          post({ t: "agentError", op: "el.attr", message: String(e && e.message || e) });
        }
      };

      // outerHTML cannot be assigned on the document element and head/body must keep their identity, so attributes and children are swapped.
      function el_isDocumentPart(node) {
        return node === document.documentElement || node === document.body || node === document.head;
      }

      function el_documentPartState(node) {
        var attrs = [];
        Array.prototype.forEach.call(node.attributes, function(a) { attrs.push([a.name, a.value]); });
        var state = { attrs: attrs };
        if (node === document.documentElement) {
          state.head = document.head ? document.head.innerHTML : "";
          state.body = document.body ? document.body.innerHTML : "";
        } else {
          state.inner = node.innerHTML;
        }
        return state;
      }

      function el_applyDocumentPart(node, state) {
        Array.prototype.slice.call(node.attributes).forEach(function(a) { node.removeAttribute(a.name); });
        state.attrs.forEach(function(pair) { try { node.setAttribute(pair[0], pair[1]); } catch(e) {} });
        if (node === document.documentElement) {
          if (document.head) document.head.innerHTML = state.head;
          if (document.body) document.body.innerHTML = state.body;
        } else {
          node.innerHTML = state.inner;
        }
        return true;
      }

      function el_parseDocumentPart(node, html) {
        var parsed = new DOMParser().parseFromString(html, "text/html");
        var source = node === document.documentElement ? parsed.documentElement : (node === document.body ? parsed.body : parsed.head);
        var state = el_documentPartState(source);
        if (node === document.documentElement) {
          state.head = parsed.head.innerHTML;
          state.body = parsed.body.innerHTML;
        }
        return state;
      }

      ops["el.editHTML"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || node.nodeType !== 1) {
          post({ t: "el.editDone", id: msg.id, ok: false, error: "The element is no longer on the page." });
          return;
        }
        var html = String(msg.html == null ? "" : msg.html);
        try {
          if (el_isDocumentPart(node)) {
            var oldState = el_documentPartState(node);
            var newState = el_parseDocumentPart(node, html);
            el_applyDocumentPart(node, newState);
            el_record("Edit HTML",
              function() { return el_applyDocumentPart(node, oldState); },
              function() { return el_applyDocumentPart(node, newState); });
            post({ t: "el.editDone", id: msg.id, ok: true });
            return;
          }
          var parent = node.parentNode;
          if (!parent) throw new Error("The element is not attached to the page.");
          var next = node.nextSibling;
          var template = document.createElement("template");
          template.innerHTML = html;
          var inserted = Array.prototype.slice.call(template.content.childNodes);
          if (!inserted.length) throw new Error("The markup produced no elements.");
          parent.insertBefore(template.content, node);
          parent.removeChild(node);
          el_record("Edit HTML",
            function() {
              var first = inserted.filter(function(n) { return n.parentNode; })[0];
              var host = first ? first.parentNode : parent;
              host.insertBefore(node, first || (next && next.parentNode === host ? next : null));
              inserted.forEach(function(n) { if (n.parentNode) n.parentNode.removeChild(n); });
              return true;
            },
            function() {
              var host = node.parentNode;
              if (!host) return false;
              inserted.forEach(function(n) { host.insertBefore(n, node); });
              host.removeChild(node);
              return true;
            });
          post({ t: "el.editDone", id: msg.id, ok: true });
          var replacement = inserted.filter(function(n) { return n.nodeType === 1; })[0];
          if (replacement && el_selected === node) selectNode(replacement);
        } catch(e) {
          post({ t: "el.editDone", id: msg.id, ok: false, error: String(e && e.message || e) });
        }
      };

      ops["el.getText"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || (node.nodeType !== 3 && node.nodeType !== 8)) return;
        post({ t: "el.text", id: msg.id, text: String(node.data || "") });
      };

      // Attribute values reach the tree cut to 400 characters, so editing one asks for the whole value.
      ops["el.getAttr"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || node.nodeType !== 1 || !node.hasAttribute(msg.name)) return;
        post({ t: "el.attrValue", id: msg.id, name: String(msg.name), value: String(node.getAttribute(msg.name)) });
      };

      ops["el.editText"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || (node.nodeType !== 3 && node.nodeType !== 8)) return;
        try {
          var before = String(node.data || "");
          var after = String(msg.text == null ? "" : msg.text);
          if (before === after) return;
          node.data = after;
          el_record("Edit text",
            function() { node.data = before; return true; },
            function() { node.data = after; return true; });
        } catch(e) {
          post({ t: "agentError", op: "el.editText", message: String(e && e.message || e) });
        }
      };

      function el_adoptChildren(from, to) {
        while (from.firstChild) to.appendChild(from.firstChild);
      }

      ops["el.rename"] = function(msg) {
        var node = nodeById(msg.id);
        var name = String(msg.name || "");
        if (!node || node.nodeType !== 1 || !node.parentNode || el_isDocumentPart(node)) return;
        if (!/^[a-zA-Z][a-zA-Z0-9.-]*$/.test(name)) return;
        try {
          var replacement = node.namespaceURI === "http://www.w3.org/1999/xhtml"
            ? document.createElement(name)
            : document.createElementNS(node.namespaceURI, name);
          Array.prototype.forEach.call(node.attributes, function(a) {
            try { replacement.setAttributeNS(a.namespaceURI, a.name, a.value); } catch(e) {}
          });
          el_adoptChildren(node, replacement);
          node.parentNode.replaceChild(replacement, node);
          var wasSelected = el_selected === node;
          el_record("Rename tag",
            function() {
              if (!replacement.parentNode) return false;
              el_adoptChildren(replacement, node);
              replacement.parentNode.replaceChild(node, replacement);
              if (el_selected === replacement) selectNode(node);
              return true;
            },
            function() {
              if (!node.parentNode) return false;
              el_adoptChildren(node, replacement);
              node.parentNode.replaceChild(replacement, node);
              if (el_selected === node) selectNode(replacement);
              return true;
            });
          if (wasSelected) selectNode(replacement);
        } catch(e) {
          post({ t: "agentError", op: "el.rename", message: String(e && e.message || e) });
        }
      };

      ops["el.move"] = function(msg) {
        var node = nodeById(msg.id);
        var parent = nodeById(msg.parentId);
        var before = msg.beforeId ? nodeById(msg.beforeId) : null;
        if (!node || !parent || isOurs(parent) || node === parent || node === before) return;
        if (node.nodeType === 9 || node.nodeType === 10 || node.nodeType === 11 || el_isDocumentPart(node)) return;
        if (node.contains && node.contains(parent)) return;
        if (before && before.parentNode !== parent) return;
        var oldParent = node.parentNode;
        var oldNext = node.nextSibling;
        if (!oldParent) return;
        try {
          parent.insertBefore(node, before);
          el_record("Move node",
            function() {
              oldParent.insertBefore(node, oldNext && oldNext.parentNode === oldParent ? oldNext : null);
              return true;
            },
            function() {
              parent.insertBefore(node, before && before.parentNode === parent ? before : null);
              return true;
            });
        } catch(e) {
          post({ t: "agentError", op: "el.move", message: String(e && e.message || e) });
        }
      };

      ops["el.remove"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || !node.parentNode || el_isDocumentPart(node)) return;
        try {
          var parent = node.parentNode;
          var next = node.nextSibling;
          node.remove();
          el_record("Delete node",
            function() {
              parent.insertBefore(node, next && next.parentNode === parent ? next : null);
              return true;
            },
            function() {
              if (!node.parentNode) return false;
              node.parentNode.removeChild(node);
              return true;
            });
        } catch(e) {}
      };

      ops["el.duplicate"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || !node.parentNode || el_isDocumentPart(node)) return;
        try {
          var parent = node.parentNode;
          var clone = node.cloneNode(true);
          parent.insertBefore(clone, node.nextSibling);
          el_record("Duplicate node",
            function() {
              if (clone.parentNode) clone.parentNode.removeChild(clone);
              return true;
            },
            function() {
              if (!node.parentNode) return false;
              node.parentNode.insertBefore(clone, node.nextSibling);
              return true;
            });
        } catch(e) {}
      };

      ops["el.hide"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || node.nodeType !== 1) return;
        try {
          var before = el_attrState(node, "style");
          if (node.style.visibility === "hidden") node.style.removeProperty("visibility");
          else node.style.setProperty("visibility", "hidden", "important");
          var after = el_attrState(node, "style");
          el_record("Toggle visibility",
            function() { return el_applyAttr(node, "style", before); },
            function() { return el_applyAttr(node, "style", after); });
        } catch(e) {}
      };

      ops["el.undo"] = function(msg) { el_replay(msg, "undo"); };
      ops["el.redo"] = function(msg) { el_replay(msg, "redo"); };

      ops["el.discard"] = function(msg) {
        (msg.entries || []).forEach(function(entry) { delete el_journal[entry]; });
      };

      ops["el.layoutOverlay"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node || node.nodeType !== 1) return;
        var key = String(msg.id);
        if (msg.on && (msg.kind === "flex" || msg.kind === "grid")) el_layoutOn[key] = msg.kind;
        else delete el_layoutOn[key];
        el_layoutSync();
        el_layoutPostState();
      };

      ops["el.focus"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (node && node.focus) { try { node.focus(); } catch(e) {} }
      };

      ops["el.scrollIntoView"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (node && node.scrollIntoView) {
          try { node.scrollIntoView({ behavior: "smooth", block: "center" }); } catch(e) {}
        }
      };

      function el_declState(style, property) {
        return { value: style.getPropertyValue(property), priority: style.getPropertyPriority(property) };
      }

      function el_applyDecl(style, property, state) {
        if (state.value === "") style.removeProperty(property);
        else style.setProperty(property, state.value, state.priority || "");
        if (el_selected && el_selected.nodeType === 1) el_postStyle(el_selected);
        return true;
      }

      function el_editDecl(style, msg, label) {
        // An unchecked declaration is edited where it is kept, so it stays unchecked until checked again.
        if (el_disabledIndex(style, msg.property) >= 0) {
          return el_changeDisabled(style, msg.property, label, function(list, at) {
            if (msg.remove) { list.splice(at, 1); return true; }
            var value = String(msg.value), priority = msg.priority || "";
            if (list[at].value === value && list[at].priority === priority) return false;
            list[at].value = value;
            list[at].priority = priority;
            return true;
          });
        }
        var before = el_declState(style, msg.property);
        if (msg.remove) style.removeProperty(msg.property);
        else style.setProperty(msg.property, String(msg.value), msg.priority || "");
        var after = el_declState(style, msg.property);
        if (before.value === after.value && before.priority === after.priority) return false;
        var property = msg.property;
        el_record(label,
          function() { return el_applyDecl(style, property, before); },
          function() { return el_applyDecl(style, property, after); });
        return true;
      }

      ops["el.setProp"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (!node || node.nodeType !== 1) return;
        try {
          el_editDecl(node.style, msg, "Edit style");
          el_postStyle(node);
          el_postLayoutKinds([node], true);
        } catch(e) {}
      };

      ops["el.setRuleProp"] = function(msg) {
        try {
          var rule = el_getRule(msg.sheetIdx, msg.ruleIdx, msg.rulePath);
          if (!rule || !rule.style) return;
          el_editDecl(rule.style, msg, "Edit style rule");
          if (el_selected) el_postStyle(el_selected);
        } catch(e) {}
      };

      // Unchecking takes a declaration out of the style, as Chrome does; it is kept by style object with its list position.
      var el_disabledDecls = new WeakMap();

      function el_disabledFor(style) {
        return (style && el_disabledDecls.get(style)) || [];
      }

      function el_declarationText(d) {
        return d.property + ": " + d.value + (d.priority === "important" ? " !important" : "");
      }

      function el_styleState(style) {
        return { cssText: String(style.cssText || ""),
                 disabled: el_disabledFor(style).map(function(d) { return { property: d.property, value: d.value, priority: d.priority, index: d.index }; }) };
      }

      function el_applyStyleState(style, state) {
        style.cssText = state.cssText;
        el_disabledDecls.set(style, state.disabled.map(function(d) { return { property: d.property, value: d.value, priority: d.priority, index: d.index }; }));
        if (el_selected && el_selected.nodeType === 1) el_postStyle(el_selected);
        return true;
      }

      function el_disabledIndex(style, property) {
        var list = el_disabledFor(style);
        for (var i = 0; i < list.length; i++) { if (list[i].property === property) return i; }
        return -1;
      }

      function el_changeDisabled(style, property, label, change) {
        var before = el_styleState(style);
        var list = before.disabled.map(function(d) { return { property: d.property, value: d.value, priority: d.priority, index: d.index }; });
        var at = -1;
        for (var i = 0; i < list.length; i++) { if (list[i].property === property) { at = i; break; } }
        if (at < 0 || !change(list, at)) return false;
        el_disabledDecls.set(style, list);
        var after = el_styleState(style);
        el_record(label,
          function() { return el_applyStyleState(style, before); },
          function() { return el_applyStyleState(style, after); });
        return true;
      }

      function el_renameDeclaration(style, from, to) {
        if (!from || !to || from === to) return false;
        if (el_disabledIndex(style, from) >= 0) {
          return el_changeDisabled(style, from, "Rename property", function(list, at) {
            list[at].property = to;
            return true;
          });
        }
        var listed = el_styleDeclarations(style, null);
        if (!listed.some(function(d) { return d.property === from && !d.disabled; })) return false;
        var before = el_styleState(style);
        style.cssText = listed.filter(function(d) { return !d.disabled; }).map(function(d) {
          return el_declarationText(d.property === from ? { property: to, value: d.value, priority: d.priority } : d);
        }).join("; ");
        var after = el_styleState(style);
        el_record("Rename property",
          function() { return el_applyStyleState(style, before); },
          function() { return el_applyStyleState(style, after); });
        return true;
      }

      function el_targetStyle(msg) {
        if (msg.id) {
          var node = nodeById(msg.id);
          return node && node.nodeType === 1 ? { style: node.style, node: node } : null;
        }
        var rule = el_getRule(msg.sheetIdx, msg.ruleIdx, msg.rulePath);
        return rule && rule.style ? { style: rule.style, node: null } : null;
      }

      ops["el.renameDecl"] = function(msg) {
        try {
          var target = el_targetStyle(msg);
          if (!target || !el_renameDeclaration(target.style, msg.from, msg.to)) return;
          var node = target.node || el_selected;
          if (node && node.nodeType === 1) el_postStyle(node);
          if (target.node) el_postLayoutKinds([target.node], true);
        } catch(e) {}
      };

      function el_toggleDeclaration(style, property, enabled) {
        var listed = el_styleDeclarations(style, null);
        var disabled = el_disabledFor(style).slice();
        if (enabled) {
          var at = -1;
          for (var i = 0; i < disabled.length; i++) { if (disabled[i].property === property) { at = i; break; } }
          if (at < 0) return false;
          disabled.splice(at, 1);
          var text = listed.filter(function(d) { return !d.disabled || d.property === property; })
                           .map(el_declarationText).join("; ");
          style.cssText = text;
          el_disabledDecls.set(style, disabled);
          return true;
        }
        var position = -1;
        for (var j = 0; j < listed.length; j++) {
          if (listed[j].property === property && !listed[j].disabled) { position = j; break; }
        }
        if (position < 0) return false;
        disabled.push({ property: property, value: style.getPropertyValue(property),
                        priority: style.getPropertyPriority(property), index: position });
        style.removeProperty(property);
        el_disabledDecls.set(style, disabled);
        return true;
      }

      ops["el.toggleDecl"] = function(msg) {
        try {
          var style = null, node = null;
          if (msg.id) {
            node = nodeById(msg.id);
            if (!node || node.nodeType !== 1) return;
            style = node.style;
          } else {
            var rule = el_getRule(msg.sheetIdx, msg.ruleIdx, msg.rulePath);
            style = rule && rule.style;
          }
          if (!style) return;
          var before = el_styleState(style);
          if (!el_toggleDeclaration(style, msg.property, !!msg.enabled)) return;
          var after = el_styleState(style);
          el_record(msg.enabled ? "Enable property" : "Disable property",
            function() { return el_applyStyleState(style, before); },
            function() { return el_applyStyleState(style, after); });
          var target = node || el_selected;
          if (target && target.nodeType === 1) el_postStyle(target);
          if (node) el_postLayoutKinds([node], true);
        } catch(e) {}
      };

      ops["el.setRuleSelector"] = function(msg) {
        try {
          var rule = el_getRule(msg.sheetIdx, msg.ruleIdx, msg.rulePath);
          if (!rule) return;
          var before = rule.selectorText;
          rule.selectorText = msg.selector;
          var after = rule.selectorText;
          if (before !== after) {
            var apply = function(text) {
              rule.selectorText = text;
              if (el_selected) el_postStyle(el_selected);
              return true;
            };
            el_record("Edit selector", function() { return apply(before); }, function() { return apply(after); });
          }
          if (el_selected) el_postStyle(el_selected);
        } catch(e) {}
      };

      function el_ruleSlot(sheetIdx, path) {
        var sheet = document.styleSheets[sheetIdx];
        if (!sheet || !sheet.cssRules || !path.length) return null;
        var parent = sheet;
        var list = sheet.cssRules;
        for (var i = 0; i < path.length - 1; i++) {
          var group = list[path[i]];
          if (!group || !group.cssRules) return null;
          parent = group;
          list = group.cssRules;
        }
        return { parent: parent, index: path[path.length - 1] };
      }

      ops["el.deleteRule"] = function(msg) {
        try {
          var path = (msg.rulePath && msg.rulePath.length) ? msg.rulePath : [msg.ruleIdx];
          var slot = el_ruleSlot(msg.sheetIdx, path);
          if (!slot) return;
          var removed = slot.parent.cssRules[slot.index];
          var cssText = removed ? removed.cssText : "";
          slot.parent.deleteRule(slot.index);
          if (cssText) {
            el_record("Delete rule",
              function() {
                slot.parent.insertRule(cssText, Math.min(slot.index, slot.parent.cssRules.length));
                if (el_selected) el_postStyle(el_selected);
                return true;
              },
              function() {
                slot.parent.deleteRule(slot.index);
                if (el_selected) el_postStyle(el_selected);
                return true;
              });
          }
          if (el_selected) el_postStyle(el_selected);
        } catch(e) {}
      };

      ops["el.addRule"] = function(msg) {
        var sel = msg.selector;
        if (!sel && el_selected && el_selected.nodeType === 1) sel = el_cssSelector(el_selected);
        if (!sel) return;
        var styleEl = document.getElementById("orbit-inspector-stylesheet");
        if (!styleEl) {
          styleEl = document.createElement("style");
          styleEl.id = "orbit-inspector-stylesheet";
          (document.head || document.documentElement).appendChild(styleEl);
        }
        try {
          var sheet = styleEl.sheet;
          if (!sheet) return;
          var idx = sheet.cssRules ? sheet.cssRules.length : 0;
          var ruleText = sel + " { " + (msg.declarations || "") + " }";
          sheet.insertRule(ruleText, idx);
          el_record("Add rule",
            function() {
              sheet.deleteRule(idx);
              if (el_selected) el_postStyle(el_selected);
              return true;
            },
            function() {
              sheet.insertRule(ruleText, Math.min(idx, sheet.cssRules.length));
              if (el_selected) el_postStyle(el_selected);
              return true;
            });
          if (el_selected) el_postStyle(el_selected);
        } catch(e) {}
      };

      ops["el.forceState"] = function(msg) {
        var node = msg.id ? nodeById(msg.id) : el_selected;
        if (!node || node.nodeType !== 1) return;
        var nodeId = idOf(node);
        var old = el_forceStateMap[nodeId];
        if (old) { try { node.classList.remove(old.className); } catch(e) {} }
        var states = msg.states || [];
        if (!states.length) {
          delete el_forceStateMap[nodeId];
        } else {
          var className = "orbit-fs-" + nodeId;
          try { node.classList.add(className); } catch(e) {}
          el_forceStateMap[nodeId] = { states: states, className: className };
        }
        el_rebuildForceStyles();
        if (el_selected) el_postStyle(el_selected);
      };

      ops["el.outerHTML"] = function(msg) {
        var node = nodeById(msg.id);
        if (!node) return;
        try { post({ t: "el.outerHTML", id: msg.id, html: node.outerHTML || "" }); } catch(e) {}
      };

      ops["el.injectCSS"] = function(msg) {
        var link = null;
        var links = document.querySelectorAll('link[rel="stylesheet"]');
        for (var i = 0; i < links.length; i++) {
          if (links[i].href === msg.href) { link = links[i]; break; }
        }
        if (!link) return;
        var style = document.createElement("style");
        style.textContent = msg.content;
        style.dataset.orbitInjected = "true";
        link.parentNode.insertBefore(style, link);
        link.remove();
        if (el_selected) el_postStyle(el_selected);
      };


      function el_postStyle(node) {
        if (!node || node.nodeType !== 1) return;
        var result = [];

        var inlineDecls = el_styleDeclarations(node.style, null);
        result.push({
          ruleType: "inline", selector: "element.style",
          sheetIdx: -1, ruleIdx: -1, specificity: [1, 0, 0, 0],
          declarations: inlineDecls, mediaQuery: null, sheetHref: null
        });

        var sheets = document.styleSheets;
        for (var si = 0; si < sheets.length; si++) {
          var rules;
          try { rules = sheets[si].cssRules; }
          catch(e) {
            result.push({
              ruleType: "crossorigin", selector: "(cross-origin stylesheet)",
              sheetIdx: si, ruleIdx: -1, specificity: [0,0,0,0],
              sheetHref: sheets[si].href || "", declarations: [], mediaQuery: null
            });
            continue;
          }
          if (!rules) continue;
          el_walkRules(rules, [], el_rootRuleContext(), function(rule, selector, path, ctx) {
            el_collectRule(rule, selector, node, si, path, ctx, result);
          });
        }

        // Which element each inherited rule belongs to, kept out of the posted JSON; every other rule applies to the node itself.
        var ownerOf = new Map();
        var ancestor = node.parentElement;
        var ancestorLevel = 0;
        while (ancestor && ancestor.nodeType === 1 && ancestorLevel < 5) {
          var inheritedForAncestor = [];
          var aSheets = document.styleSheets;
          var aInline = { ruleType: "inherited", selector: "element.style",
            sheetIdx: -1, ruleIdx: -1, specificity: [1,0,0,0],
            declarations: [], sheetHref: null, mediaQuery: null,
            ancestorLabel: el_nodeLabel(ancestor) };
          aInline.declarations = el_styleDeclarations(ancestor.style, el_isInheritable);
          if (aInline.declarations.length) inheritedForAncestor.push(aInline);
          for (var asi = 0; asi < aSheets.length; asi++) {
            var aRules;
            try { aRules = aSheets[asi].cssRules; } catch(e) { continue; }
            if (!aRules) continue;
            el_walkRules(aRules, [], el_rootRuleContext(), function(rule, selector, path, ctx) {
              el_collectInheritedRule(rule, selector, ancestor, asi, path, ctx, inheritedForAncestor);
            });
          }
          if (inheritedForAncestor.length) {
            result.push({ ruleType: "inherited-header",
              selector: "", sheetIdx: -1, ruleIdx: -1, specificity: [0,0,0,0],
              declarations: [], mediaQuery: null, sheetHref: null,
              ancestorLabel: "Inherited from " + el_nodeLabel(ancestor) });
            var headerOwner = ancestor;
            inheritedForAncestor.forEach(function(r) { ownerOf.set(r, headerOwner); result.push(r); });
          }
          ancestor = ancestor.parentElement;
          ancestorLevel++;
        }

        var inlineR = result.filter(function(r) { return r.ruleType === "inline"; });
        var directR = result.filter(function(r) { return r.ruleType === "rule" || r.ruleType === "pseudo" || r.ruleType === "crossorigin"; });
        var inherited = result.filter(function(r) { return r.ruleType === "inherited-header" || r.ruleType === "inherited"; });

        // Cascade order, winner first: unlayered beats @layer, then higher specificity, then later source position.
        directR.sort(function(a, b) {
          if (!!a.layered !== !!b.layered) return a.layered ? 1 : -1;
          var sa = a.specificity, sb = b.specificity;
          for (var j = 0; j < 3; j++) {
            if (sa[j] !== sb[j]) return sb[j] - sa[j];
          }
          if (a.sheetIdx !== b.sheetIdx) return b.sheetIdx - a.sheetIdx;
          var pa = a.rulePath || [a.ruleIdx], pb = b.rulePath || [b.ruleIdx];
          for (var k = 0; k < Math.min(pa.length, pb.length); k++) {
            if (pa[k] !== pb[k]) return pb[k] - pa[k];
          }
          return pb.length - pa.length;
        });

        var finalResult = inlineR.concat(directR).concat(inherited);

        el_markOverrides(finalResult);

        try {
          var cs = getComputedStyle(node);
          finalResult.forEach(function(rule) {
            var owner = ownerOf.get(rule) || node;
            var isPseudo = rule.ruleType === "pseudo" || !!rule.pseudoElement;
            rule.declarations.forEach(function(d) {
              [d].concat(d.longhands || []).forEach(function(entry) {
                if (entry.value && entry.value.indexOf("var(") >= 0) {
                  try { entry.computedValue = cs.getPropertyValue(entry.property); } catch(e) {}
                  return;
                }
                var hint = el_inheritHint(owner, isPseudo, entry.property, entry.value);
                if (hint) {
                  entry.computedValue = hint.value;
                  entry.inheritedFrom = hint.from;
                }
              });
            });
          });
        } catch(e) {}

        post({ t: "el.style", id: idOf(node), rules: finalResult, cssVars: el_getCssVars() });
      }

      // Style rules live at any depth (@media, @layer, nesting); the walker yields each with its effective selector and index path.

      function el_rootRuleContext() {
        return { groups: [], media: null, supports: null, scopes: [], containers: [], inactive: false, layered: false,
                 parentSelector: null, parentWritten: null };
      }

      function el_childContext(ctx) {
        return { groups: ctx.groups, media: ctx.media, supports: ctx.supports, scopes: ctx.scopes,
                 containers: ctx.containers, inactive: ctx.inactive, layered: ctx.layered,
                 parentSelector: ctx.parentSelector, parentWritten: ctx.parentWritten };
      }

      function el_isGroupingRule(rule) {
        if (rule.type === 4 || rule.type === 12 || rule.type === 13) return true;
        if (rule.type === 7) return false; // @keyframes: its children are keyframes, not style rules
        return typeof CSSGroupingRule !== "undefined" && rule instanceof CSSGroupingRule;
      }

      function el_ruleCondition(rule) {
        try {
          if (rule.type === 4) return "@media " + (rule.conditionText || (rule.media && rule.media.mediaText) || "");
          if (rule.type === 12) return "@supports " + (rule.conditionText || "");
          if (typeof CSSLayerBlockRule !== "undefined" && rule instanceof CSSLayerBlockRule) return "@layer" + (rule.name ? " " + rule.name : "");
          if (typeof CSSContainerRule !== "undefined" && rule instanceof CSSContainerRule) {
            return "@container " + (rule.conditionText || [rule.containerName, rule.containerQuery].filter(Boolean).join(" "));
          }
        } catch(e) {}
        var text = String(rule.cssText || "");
        var brace = text.indexOf("{");
        return brace > 0 ? text.slice(0, brace).trim() : "@group";
      }

      function el_splitSelectorList(text) {
        var parts = [], depth = 0, quote = null, start = 0;
        for (var i = 0; i < text.length; i++) {
          var c = text[i];
          if (quote) { if (c === "\\") i++; else if (c === quote) quote = null; continue; }
          if (c === '"' || c === "'") quote = c;
          else if (c === "(" || c === "[") depth++;
          else if (c === ")" || c === "]") depth--;
          else if (c === "," && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
        }
        parts.push(text.slice(start));
        return parts.map(function(part) { return part.trim(); }).filter(Boolean);
      }

      // The selector a nested rule matches with: `&` stands for the parent, and a part without `&` is a descendant.
      function el_resolveNestedSelector(selector, parent) {
        if (!parent) return selector;
        var wrapped = ":is(" + parent + ")";
        return el_splitSelectorList(selector).map(function(part) {
          return part.indexOf("&") >= 0 ? part.split("&").join(wrapped) : wrapped + " " + part;
        }).join(", ");
      }

      function el_walkRules(list, path, ctx, visit) {
        if (!list) return;
        for (var i = 0; i < list.length; i++) {
          var rule = list[i];
          if (!rule) continue;
          var rulePath = path.concat([i]);
          if (rule.type === 1) {
            var written = rule.selectorText || "";
            if (!written) continue;
            var resolved = el_resolveNestedSelector(written, ctx.parentSelector);
            visit(rule, resolved, rulePath, ctx);
            if (rule.cssRules && rule.cssRules.length) {
              var nested = el_childContext(ctx);
              nested.groups = ctx.groups.concat([written]);
              nested.parentSelector = resolved;
              nested.parentWritten = written;
              el_walkRules(rule.cssRules, rulePath, nested, visit);
            }
          } else if (el_isGroupingRule(rule)) {
            var next = el_childContext(ctx);
            next.groups = ctx.groups.concat([el_ruleCondition(rule)]);
            if (rule.type === 4) {
              next.media = rule.conditionText || (rule.media && rule.media.mediaText) || null;
              if (next.media && !el_mediaMatches(next.media)) next.inactive = true;
            }
            if (rule.type === 12) {
              next.supports = rule.conditionText || null;
              try { if (next.supports && window.CSS && CSS.supports && !CSS.supports(next.supports)) next.inactive = true; } catch(e) {}
            }
            if (typeof CSSLayerBlockRule !== "undefined" && rule instanceof CSSLayerBlockRule) next.layered = true;
            if (typeof CSSContainerRule !== "undefined" && rule instanceof CSSContainerRule) {
              next.containers = ctx.containers.concat([{ name: rule.containerName || "", query: rule.containerQuery || rule.conditionText || "" }]);
            }
            if (typeof CSSScopeRule !== "undefined" && rule instanceof CSSScopeRule && rule.start) {
              next.scopes = ctx.scopes.concat([rule.start]);
            }
            try { el_walkRules(rule.cssRules, rulePath, next, visit); } catch(e) {}
          } else if (ctx.parentSelector && rule.style && rule.keyText === undefined) {
            visit(rule, ctx.parentSelector, rulePath, ctx);
          }
        }
      }

      function el_mediaMatches(text) {
        try { return window.matchMedia(text).matches; } catch(e) { return true; }
      }

      function el_queryLength(text, container) {
        var m = /^(-?[\d.]+)(px|em|rem)?$/.exec(String(text).trim());
        if (!m) return null;
        var n = parseFloat(m[1]);
        if (!m[2] || m[2] === "px") return n;
        if (m[2] === "rem") return n * px(getComputedStyle(document.documentElement).fontSize);
        return n * px(getComputedStyle(container).fontSize);
      }

      // Returns null when a container query cannot be evaluated, so the rule is not judged.
      function el_containerQueryMatches(query, container) {
        var cs = getComputedStyle(container);
        var width = container.clientWidth - px(cs.paddingLeft) - px(cs.paddingRight);
        var height = container.clientHeight - px(cs.paddingTop) - px(cs.paddingBottom);
        var parts = String(query).split(/\)\s*and\s*\(/i);
        var known = true, result = true;
        parts.forEach(function(raw) {
          var part = raw.replace(/^[\s(]+|[\s)]+$/g, "");
          var m = /^(min-|max-)?(width|height|inline-size|block-size)\s*:\s*(.+)$/i.exec(part);
          var r = /^(width|height|inline-size|block-size)\s*(>=|<=|>|<|=)\s*(.+)$/i.exec(part);
          var axis, op, value;
          if (m) { axis = m[2]; op = m[1] === "min-" ? ">=" : m[1] === "max-" ? "<=" : "="; value = m[3]; }
          else if (r) { axis = r[1]; op = r[2]; value = r[3]; }
          else { known = false; return; }
          var limit = el_queryLength(value, container);
          if (limit === null) { known = false; return; }
          var size = /height|block/i.test(axis) ? height : width;
          var ok = op === ">=" ? size >= limit : op === "<=" ? size <= limit : op === ">" ? size > limit
                 : op === "<" ? size < limit : Math.abs(size - limit) < 0.5;
          if (!ok) result = false;
        });
        return known ? result : null;
      }

      function el_queryContainer(node, name) {
        var current = node.parentElement;
        while (current) {
          var cs = getComputedStyle(current);
          var type = cs.containerType || cs.getPropertyValue("container-type");
          if (type && type !== "normal") {
            if (!name) return current;
            var names = String(cs.containerName || cs.getPropertyValue("container-name") || "").split(/\s+/);
            if (names.indexOf(name) >= 0) return current;
          }
          current = current.parentElement;
        }
        return null;
      }

      function el_ruleIsActive(node, ctx) {
        if (ctx.inactive) return false;
        for (var i = 0; i < ctx.containers.length; i++) {
          var container = el_queryContainer(node, ctx.containers[i].name);
          if (!container) return false;
          if (el_containerQueryMatches(ctx.containers[i].query, container) === false) return false;
        }
        return true;
      }

      function el_isInheritable(prop) { return el_inheritableProps.has(prop); }

      function el_splitDeclarationText(text) {
        var parts = [], depth = 0, quote = null, start = 0;
        for (var i = 0; i < text.length; i++) {
          var c = text[i];
          if (quote) { if (c === "\\") i++; else if (c === quote) quote = null; continue; }
          if (c === '"' || c === "'") quote = c;
          else if (c === "(" || c === "[") depth++;
          else if (c === ")" || c === "]") depth--;
          else if (c === ";" && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
        }
        parts.push(text.slice(start));
        return parts.map(function(part) { return part.trim(); }).filter(Boolean);
      }

      var el_scratchStyle = null;

      function el_longhandNames(property, value) {
        if (property.indexOf("--") === 0) return [];
        try {
          if (!el_scratchStyle) el_scratchStyle = document.createElement("div").style;
          el_scratchStyle.cssText = "";
          el_scratchStyle.setProperty(property, value);
          var names = [];
          for (var i = 0; i < el_scratchStyle.length; i++) names.push(el_scratchStyle[i]);
          el_scratchStyle.cssText = "";
          if (names.length === 1 && names[0] === property) return [];
          return names;
        } catch(e) { return []; }
      }

      function el_longhandValues(property, value) {
        var names = el_longhandNames(property, value);
        if (!names.length) return [];
        try {
          el_scratchStyle.cssText = "";
          el_scratchStyle.setProperty(property, value);
          var values = names.map(function(name) { return { property: name, value: el_scratchStyle.getPropertyValue(name) }; });
          el_scratchStyle.cssText = "";
          return values;
        } catch(e) { return []; }
      }

      function el_declaration(property, value, priority) {
        return { property: property, value: value, priority: priority || "",
                 disabled: false, overridden: false, computedValue: null, inheritedFrom: null, longhands: [] };
      }

      // What an `inherit` (or an `unset` on an inherited property) takes: the parent's computed value. A pseudo-element's parent is the element it hangs off; the root has no parent, so it takes the initial value.
      function el_inheritHint(owner, isPseudo, property, value) {
        var keyword = String(value || "").trim().toLowerCase();
        var inheritsOnUnset = property.indexOf("--") === 0 || el_isInheritable(property);
        if (keyword !== "inherit" && !(keyword === "unset" && inheritsOnUnset)) return null;
        var parent = isPseudo ? owner : (owner.parentElement || (owner.getRootNode && owner.getRootNode().host) || null);
        try {
          var inherited = getComputedStyle(parent || owner).getPropertyValue(property);
          if (!inherited) return null;
          return { value: inherited, from: parent ? el_nodeLabel(parent) : "initial value" };
        } catch(e) { return null; }
      }

      function el_styleDeclarations(style, filter) {
        var result = [];
        if (!style) return result;
        var seen = {};
        el_splitDeclarationText(String(style.cssText || "")).forEach(function(part) {
          var colon = part.indexOf(":");
          if (colon < 1) return;
          var property = part.slice(0, colon).trim();
          if (property.indexOf("--") !== 0) property = property.toLowerCase();
          if (seen[property]) return;
          seen[property] = true;
          var written = part.slice(colon + 1).trim().replace(/\s*!\s*important\s*$/i, "");
          var value = style.getPropertyValue(property) || written;
          var decl = el_declaration(property, value, style.getPropertyPriority(property));
          decl.longhands = el_longhandNames(property, value).map(function(name) {
            seen[name] = true;
            return el_declaration(name, style.getPropertyValue(name), style.getPropertyPriority(name) || decl.priority);
          });
          if (filter && !filter(property)) {
            decl.longhands = decl.longhands.filter(function(l) { return filter(l.property); });
            if (!decl.longhands.length) return;
          }
          result.push(decl);
        });
        for (var i = 0; i < style.length; i++) {
          var name = style[i];
          if (seen[name] || (filter && !filter(name))) continue;
          seen[name] = true;
          result.push(el_declaration(name, style.getPropertyValue(name), style.getPropertyPriority(name)));
        }
        el_disabledFor(style).slice().sort(function(a, b) { return a.index - b.index; }).forEach(function(d) {
          if (filter && !filter(d.property)) return;
          var decl = el_declaration(d.property, d.value, d.priority);
          decl.disabled = true;
          decl.longhands = el_longhandValues(d.property, d.value).map(function(l) {
            var longhand = el_declaration(l.property, l.value, d.priority);
            longhand.disabled = true;
            return longhand;
          });
          result.splice(Math.min(Math.max(d.index, 0), result.length), 0, decl);
        });
        return result;
      }

      function el_inScopes(node, scopes) {
        for (var i = 0; i < scopes.length; i++) {
          try { if (!node.closest(scopes[i])) return false; } catch(e) { return false; }
        }
        return true;
      }

      function el_ruleSpecificity(rule, ctx) {
        var own = el_specificity(el_splitSelectorList(String(rule.selectorText || "").replace(/&/g, " "))[0] || "");
        if (!ctx.parentWritten) return own;
        var parent = el_specificity(el_splitSelectorList(ctx.parentWritten)[0] || "");
        return [own[0] + parent[0], own[1] + parent[1], own[2] + parent[2]];
      }

      function el_collectRule(rule, selector, node, sheetIdx, path, ctx, result) {
        if (!el_inScopes(node, ctx.scopes)) return;
        var baseSelector = selector.replace(/::[a-zA-Z][\w-]*(\([^)]*\))?/g, "").trim();
        var pseudoMatch = selector.match(/::([\w-]+)(\([^)]*\))?/);
        var matches = false;
        try {
          if (baseSelector) matches = node.matches(baseSelector);
          else if (pseudoMatch) matches = true;
        } catch(e) {}
        if (!matches) return;
        result.push({
          ruleType: pseudoMatch ? "pseudo" : "rule",
          selector: rule.selectorText || ctx.parentWritten || selector,
          specificity: el_ruleSpecificity(rule, ctx),
          sheetIdx: sheetIdx, ruleIdx: path.length ? path[path.length - 1] : -1,
          rulePath: path,
          sheetHref: (function() { try { return document.styleSheets[sheetIdx].href || null; } catch(e) { return null; } })(),
          mediaQuery: ctx.media || null,
          supportsQuery: ctx.supports || null,
          groupingRules: ctx.groups,
          inactive: !el_ruleIsActive(node, ctx),
          layered: ctx.layered,
          declarations: el_styleDeclarations(rule.style, null),
          pseudoElement: pseudoMatch ? pseudoMatch[1] : null,
          ancestorLabel: null
        });
      }

      function el_collectInheritedRule(rule, selector, ancestor, sheetIdx, path, ctx, result) {
        if (!el_inScopes(ancestor, ctx.scopes)) return;
        var matches = false;
        try { matches = ancestor.matches(selector); } catch(e) {}
        if (!matches) return;
        if (!el_ruleIsActive(ancestor, ctx)) return;
        var decls = el_styleDeclarations(rule.style, el_isInheritable);
        if (!decls.length) return;
        result.push({
          ruleType: "inherited", selector: rule.selectorText || ctx.parentWritten || selector,
          specificity: el_ruleSpecificity(rule, ctx),
          sheetIdx: sheetIdx, ruleIdx: path.length ? path[path.length - 1] : -1,
          rulePath: path,
          sheetHref: null, mediaQuery: ctx.media || null, supportsQuery: ctx.supports || null,
          groupingRules: ctx.groups,
          declarations: decls, pseudoElement: null,
          ancestorLabel: null
        });
      }

      function el_specificity(selector) {
        if (!selector) return [0, 0, 0];
        var ids = (selector.match(/#[\w-]+/g) || []).length;
        var classes = (selector.match(/\.[\w-]+/g) || []).length;
        var attrs = (selector.match(/\[[^\]]*\]/g) || []).length;
        var pseudoClasses = (selector.match(/(?<!:):[a-zA-Z][\w-]*(?!\()/g) || []).length;
        var elements = (selector.match(/(?:^|[\s>+~])([a-zA-Z][\w-]*)/g) || []).length;
        var pseudoEls = (selector.match(/::[a-zA-Z][\w-]*/g) || []).length;
        return [ids, classes + attrs + pseudoClasses, elements + pseudoEls];
      }

      // `rules` is in cascade order; !important is settled before normal, shorthands are judged per longhand, and pseudo-element rules take no part.
      function el_markOverrides(rules) {
        var ordered = rules.filter(function(r) {
          return (r.ruleType === "inline" || r.ruleType === "rule") && !r.inactive;
        });
        var won = {};
        ["important", "normal"].forEach(function(level) {
          ordered.forEach(function(rule) {
            for (var di = rule.declarations.length - 1; di >= 0; di--) {
              var d = rule.declarations[di];
              if (d.disabled) continue; // not in the style, so it takes no part in the cascade
              var entries = d.longhands && d.longhands.length ? d.longhands : [d];
              entries.forEach(function(entry) {
                var important = (entry.priority || d.priority) === "important";
                if (important !== (level === "important")) return;
                if (won[entry.property]) entry.overridden = true;
                else won[entry.property] = true;
              });
            }
          });
        });
        ordered.forEach(function(rule) {
          rule.declarations.forEach(function(d) {
            if (d.longhands && d.longhands.length && !d.disabled) {
              d.overridden = d.longhands.every(function(l) { return l.overridden; });
            }
          });
        });
      }


      function el_postComputed(node) {
        var cs = getComputedStyle(node);
        var props = [];
        for (var i = 0; i < cs.length; i++) {
          props.push({ property: cs[i], value: cs.getPropertyValue(cs[i]), isInherited: false });
        }
        post({ t: "el.computed", id: idOf(node), properties: props });
      }


      function el_handlerText(handler) {
        try { return typeof handler === "function" ? handler.toString().slice(0, 400) : ""; } catch(e) { return ""; }
      }

      function el_postListeners(node, includeAncestors) {
        var results = [];
        function collect(target, nid, isAnc, isWin) {
          var list = el_listeners.get(target);
          if (!list) return;
          list.forEach(function(l) {
            results.push({
              nodeId: nid, isAncestor: isAnc, isWindow: isWin,
              type: l.type, capture: !!l.capture, passive: !!l.passive, once: !!l.once,
              handlerSource: l.handlerSource || el_handlerText(l.handler), sourceURL: l.sourceURL || null,
              sourceLine: l.sourceLine || null, beforeOpen: !!l.beforeOpen
            });
          });
        }
        collect(node, idOf(node), false, false);
        if (includeAncestors) {
          var ancestors = lineage(node).slice(0, -1);
          for (var i = 0; i < ancestors.length; i++) {
            collect(ancestors[i], idOf(ancestors[i]), true, false);
          }
          collect(window, 0, true, true);
        }
        post({ t: "el.listeners", id: idOf(node), listeners: results });
      }


      function el_postA11y(node) {
        var role = node.getAttribute("role") || el_implicitRole(node);
        var ariaAttrs = {};
        if (node.attributes) {
          var attrArr = Array.prototype.slice.call(node.attributes);
          attrArr.forEach(function(a) {
            if (a.name.indexOf("aria-") === 0) ariaAttrs[a.name] = a.value;
          });
        }
        var nameInfo = el_accessibleName(node);
        var focusable = el_isFocusable(node);
        var contrastRatio = null;
        try {
          var cs = getComputedStyle(node);
          var fg = el_parseColorComponents(cs.color);
          var bg = el_parseColorComponents(el_effectiveBg(node));
          if (fg && bg) {
            var fgL = el_luminance(fg), bgL = el_luminance(bg);
            var lighter = Math.max(fgL, bgL), darker = Math.min(fgL, bgL);
            contrastRatio = (lighter + 0.05) / (darker + 0.05);
          }
        } catch(e) {}
        post({
          t: "el.a11y", id: idOf(node),
          role: role, name: nameInfo.text, nameFrom: nameInfo.from,
          ariaAttrs: ariaAttrs, focusable: focusable,
          contrastRatio: finite(contrastRatio)
        });
      }

      function el_implicitRole(node) {
        var t = (node.tagName || "").toLowerCase();
        var m = { a:"link",button:"button",input:"textbox",select:"listbox",textarea:"textbox",
          h1:"heading",h2:"heading",h3:"heading",h4:"heading",h5:"heading",h6:"heading",
          img:"img",nav:"navigation",main:"main",aside:"complementary",header:"banner",
          footer:"contentinfo",section:"region",article:"article",ul:"list",ol:"list",
          li:"listitem",table:"table",tr:"row",th:"columnheader",td:"cell",form:"form",
          dialog:"dialog",details:"group",summary:"button" };
        return m[t] || "generic";
      }

      function el_accessibleName(node) {
        var lb = node.getAttribute("aria-labelledby");
        if (lb) {
          var parts = lb.split(/\s+/).map(function(id) {
            var el = document.getElementById(id);
            return el ? (el.textContent || "").trim() : "";
          }).filter(Boolean);
          if (parts.length) return { text: parts.join(" "), from: "aria-labelledby" };
        }
        var ariaLabel = node.getAttribute("aria-label");
        if (ariaLabel) return { text: ariaLabel.trim(), from: "aria-label" };
        var alt = node.getAttribute("alt");
        if (alt !== null) return { text: alt.trim(), from: "alt" };
        var tag = (node.tagName || "").toLowerCase();
        if (tag === "input" || tag === "select" || tag === "textarea") {
          var nid = node.id;
          if (nid) {
            var label = document.querySelector('label[for="' + nid + '"]');
            if (label) return { text: (label.textContent || "").trim(), from: "label" };
          }
        }
        var title = node.getAttribute("title");
        if (title) return { text: title, from: "title" };
        var txt = (node.textContent || "").trim().slice(0, 200);
        if (txt) return { text: txt, from: "content" };
        return { text: "", from: "none" };
      }

      function el_isFocusable(node) {
        var tag = (node.tagName || "").toLowerCase();
        var native = ["a","button","input","select","textarea","details","summary"];
        if (native.indexOf(tag) >= 0 && !node.disabled) {
          var ti = node.getAttribute("tabindex");
          return ti === null || ti !== "-1";
        }
        var tabindex = node.getAttribute("tabindex");
        return tabindex !== null && tabindex !== "-1";
      }

      function el_effectiveBg(node) {
        var cur = node, guard = 0;
        while (cur && cur.nodeType === 1 && guard < 20) {
          var bg = getComputedStyle(cur).backgroundColor;
          if (bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") return bg;
          cur = cur.parentElement;
          guard++;
        }
        return "rgb(255, 255, 255)";
      }

      function el_parseColorComponents(str) {
        var m = String(str || "").match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
        if (!m) return null;
        return [parseInt(m[1]), parseInt(m[2]), parseInt(m[3])];
      }

      function el_luminance(rgb) {
        return rgb.map(function(c) {
          var v = c / 255;
          return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        }).reduce(function(acc, c, i) { return acc + c * [0.2126, 0.7152, 0.0722][i]; }, 0);
      }


      function el_rebuildForceStyles() {
        if (!el_forceStyleEl) {
          el_forceStyleEl = document.createElement("style");
          el_forceStyleEl.id = "orbit-force-state-style";
          (document.head || document.documentElement).appendChild(el_forceStyleEl);
        }
        var newRules = [];
        var keys = Object.keys(el_forceStateMap);
        for (var ki = 0; ki < keys.length; ki++) {
          var info = el_forceStateMap[keys[ki]];
          var states = info.states;
          var className = info.className;
          var sheets = document.styleSheets;
          for (var si = 0; si < sheets.length; si++) {
            var sheetRules;
            try { sheetRules = sheets[si].cssRules; } catch(e) { continue; }
            if (!sheetRules) continue;
            for (var ri = 0; ri < sheetRules.length; ri++) {
              var rule = sheetRules[ri];
              if (!rule.selectorText || !rule.style) continue;
              for (var sti = 0; sti < states.length; sti++) {
                var state = states[sti];
                if (rule.selectorText.indexOf(":" + state) >= 0) {
                  var newSel = rule.selectorText.replace(new RegExp(":" + state, "g"), "." + className);
                  newRules.push(newSel + " { " + rule.style.cssText + " }");
                }
              }
            }
          }
        }
        el_forceStyleEl.textContent = newRules.join("\n");
      }


      function el_attrs(node) {
        var result = {};
        if (!node.attributes) return result;
        var arr = Array.prototype.slice.call(node.attributes, 0, 40);
        arr.forEach(function(a) { result[a.name] = String(a.value).slice(0, 400); });
        return result;
      }

      function el_cssSelector(node) {
        if (!node || node.nodeType !== 1) return "*";
        if (node.id) {
          var escaped = typeof CSS !== "undefined" && CSS.escape ? CSS.escape(node.id) : node.id.replace(/[^\w-]/g, "\\$&");
          return "#" + escaped;
        }
        var parts = [];
        var cur = node;
        var guard = 0;
        while (cur && cur.nodeType === 1 && guard < 10) {
          var tag = cur.tagName.toLowerCase();
          if (cur.id) {
            var esc2 = typeof CSS !== "undefined" && CSS.escape ? CSS.escape(cur.id) : cur.id;
            parts.unshift("#" + esc2);
            break;
          }
          var nth = 1;
          var sib = cur.previousElementSibling;
          while (sib) { nth++; sib = sib.previousElementSibling; }
          parts.unshift(tag + ":nth-child(" + nth + ")");
          cur = cur.parentElement;
          guard++;
        }
        return parts.join(" > ") || node.tagName.toLowerCase();
      }

      function el_nodeLabel(node) {
        if (!node || node.nodeType !== 1) return "";
        var name = (node.tagName || "").toLowerCase();
        if (node.id) name += "#" + node.id;
        var cls = typeof node.className === "string" ? node.className.trim() : "";
        if (cls) name += "." + cls.split(/\s+/).slice(0, 2).join(".");
        return name;
      }

      function el_getRule(sheetIdx, ruleIdx, rulePath) {
        var sheet = document.styleSheets[sheetIdx];
        if (!sheet) return null;
        var rules;
        try { rules = sheet.cssRules; } catch(e) { return null; }
        if (!rules) return null;
        var path = (rulePath && rulePath.length) ? rulePath : [ruleIdx];
        var cursor = null;
        var list = rules;
        for (var i = 0; i < path.length; i++) {
          if (!list) return null;
          cursor = list[path[i]];
          if (!cursor) return null;
          list = cursor.cssRules || null;
        }
        return cursor;
      }

      function el_getCssVars() {
        var vars = [];
        try {
          var cs = getComputedStyle(document.documentElement);
          for (var i = 0; i < cs.length; i++) {
            if (cs[i].indexOf("--") === 0) vars.push(cs[i]);
          }
        } catch(e) {}
        return vars.slice(0, 300);
      }


      // Mutations are recorded as cheap references and described once per node per flush, not once per record.
      var el_mutationIndex = {};
      var el_mutationCap = 5000;

      function el_isListed(child) {
        if (!child || isOurs(child)) return false;
        if (child.nodeType === 3 && !String(child.textContent || "").trim()) return false;
        return child.nodeType === 1 || child.nodeType === 3 || child.nodeType === 8 || child.nodeType === 10 || child.nodeType === 11;
      }

      function el_queueMutation(entry, coalesceKey) {
        if (coalesceKey) {
          var existing = el_mutationIndex[coalesceKey];
          if (existing) return;
          el_mutationIndex[coalesceKey] = entry;
        }
        el_mutationBuffer.push(entry);
        if (el_mutationBuffer.length > el_mutationCap) {
          el_mutationBuffer.length = 0;
          el_mutationIndex = {};
          post({ t: "el.navigate" });
        }
      }

      function el_scheduleMutationFlush() {
        if (el_mutationTimer || el_mutationDisposed) return;
        el_mutationTimer = setTimeout(el_flushMutations, 50);
      }

      function el_flushMutations() {
        el_mutationTimer = null;
        if (el_mutationDisposed) { el_mutationBuffer.length = 0; el_mutationIndex = {}; return; }
        var raw = el_mutationBuffer.splice(0, 200);
        el_mutationIndex = {};
        var batch = [];
        var attrNodes = [];
        raw.forEach(function(entry) {
          if (entry.kind === "added") {
            var n = entry.node;
            // childrenOf() leaves out whitespace-only text, so mutations must too or line breaks show up as empty #text rows.
            if (!n.isConnected || isOurs(n) || !el_isListed(n)) return;
            var parent = n.parentNode;
            var prev = n.previousSibling;
            while (prev && !el_isListed(prev)) prev = prev.previousSibling;
            batch.push({ kind: "added", node: describe(n), parentId: idOf(parent), afterId: prev ? idOf(prev) : 0 });
          } else if (entry.kind === "removed") {
            batch.push({ kind: "removed", nodeId: idOf(entry.node), parentId: entry.parentId });
          } else if (entry.kind === "attrs") {
            batch.push({ kind: "attrs", nodeId: idOf(entry.node), attrs: el_attrs(entry.node) });
            if (attrNodes.length < 20) attrNodes.push(entry.node);
          } else if (entry.kind === "text") {
            batch.push({ kind: "text", nodeId: idOf(entry.node),
              text: String(entry.node.textContent || "").replace(/\s+/g, " ").trim().slice(0, 200) });
          }
        });
        if (batch.length) post({ t: "el.mutation", mutations: batch });
        if (attrNodes.length) el_postLayoutKinds(attrNodes, true);
        if (el_layoutCount()) el_layoutScheduleDraw();
        if (el_mutationBuffer.length) el_scheduleMutationFlush();
      }

      // The DOM observer runs only while the inspector is open: describing every mutation is work no page should pay for unwatched.
      var el_observer = null;
      var el_mutationDisposed = true;

      function el_startObserving() {
        if (el_observer) return;
        var target = document.documentElement || document.body;
        if (!target) return;
        el_mutationDisposed = false;
        el_observer = new MutationObserver(function(mutations) {
          mutations.forEach(function(m) {
            if (isOurs(m.target)) return;
            if (m.type === "childList") {
              m.addedNodes.forEach(function(n) {
                if (!isOurs(n)) el_queueMutation({ kind: "added", node: n }, null);
              });
              m.removedNodes.forEach(function(n) {
                el_queueMutation({ kind: "removed", node: n, parentId: idOf(m.target) }, null);
              });
            } else if (m.type === "attributes") {
              el_queueMutation({ kind: "attrs", node: m.target }, "a" + idOf(m.target));
            } else if (m.type === "characterData") {
              el_queueMutation({ kind: "text", node: m.target }, "t" + idOf(m.target));
            }
          });
          el_scheduleMutationFlush();
        });
        el_observer.observe(target, { childList: true, subtree: true, attributes: true, characterData: true });
      }

      function el_stopObserving() {
        if (el_observer) { el_observer.disconnect(); el_observer = null; }
        el_mutationDisposed = true;
        if (el_mutationTimer) { clearTimeout(el_mutationTimer); el_mutationTimer = null; }
        el_mutationBuffer.length = 0;
        el_mutationIndex = {};
      }

      presenceHooks.push({ on: el_startObserving, off: el_stopObserving });


      inits.push(function() {
        if (typeof EventTarget === "undefined") return;
        var origAdd = EventTarget.prototype.addEventListener;
        var origRemove = EventTarget.prototype.removeEventListener;
        // Off once disposed: a wrapper left inside someone else's later patch only passes calls through.
        var active = true;

        var addWrap = EventTarget.prototype.addEventListener = function(type, handler, options) {
          var result = origAdd.apply(this, arguments);
          if (!active) return result;
          try {
            if (typeof handler === "function") {
              // Only type and flags are kept while the inspector is closed; the stack and handler text cost every addEventListener.
              var list = el_listeners.get(this);
              if (!list) { list = []; el_listeners.set(this, list); }
              var capture = typeof options === "boolean" ? options : !!(options && options.capture);
              var passive = !!(options && typeof options === "object" && options.passive);
              var once    = !!(options && typeof options === "object" && options.once);
              if (!state.presented) {
                list.push({ type: type, capture: capture, passive: passive, once: once,
                            handlerSource: "", sourceURL: null, sourceLine: null, handler: handler, beforeOpen: true });
                return result;
              }
              var src = "", url = null, line = null;
              try { src = handler.toString().slice(0, 400); } catch(e2) {}
              try {
                var stack = new Error().stack || "";
                var lines = stack.split("\n");
                for (var si = 2; si < Math.min(lines.length, 8); si++) {
                  var lm = lines[si].match(/(https?:\/\/[^:)\s]+):(\d+)/);
                  if (lm) { url = lm[1]; line = parseInt(lm[2]); break; }
                }
              } catch(e3) {}
              list.push({ type: type, capture: capture, passive: passive, once: once,
                          handlerSource: src, sourceURL: url, sourceLine: line, handler: handler });
            }
          } catch(e) {}
          return result;
        };
        Object.defineProperty(EventTarget.prototype.addEventListener, "length", { value: origAdd.length });
        EventTarget.prototype.addEventListener.toString = function() { return origAdd.toString(); };

        var removeWrap = EventTarget.prototype.removeEventListener = function(type, handler, options) {
          if (!active) return origRemove.apply(this, arguments);
          try {
            var list = el_listeners.get(this);
            if (list) {
              var capture = typeof options === "boolean" ? options : !!(options && options.capture);
              for (var i = list.length - 1; i >= 0; i--) {
                if (list[i].type === type && list[i].handler === handler && list[i].capture === capture) {
                  list.splice(i, 1); break;
                }
              }
            }
          } catch(e) {}
          return origRemove.apply(this, arguments);
        };
        EventTarget.prototype.removeEventListener.toString = function() { return origRemove.toString(); };

        disposers.push(function() {
          active = false;
          restoreIfOurs(EventTarget.prototype, "addEventListener", addWrap, origAdd);
          restoreIfOurs(EventTarget.prototype, "removeEventListener", removeWrap, origRemove);
        });
      });


      inits.push(function() {
        try {
          var cs = getComputedStyle(document.documentElement);
          for (var i = 0; i < cs.length; i++) {
            var p = cs[i];
            if (p && p.indexOf("--") !== 0) el_cssPropertyList.push(p);
          }
        } catch(e) {}
      });


      navHooks.push(function() {
        if (state.presented) post({ t: "el.navigate" });
      });


      disposers.push(function() {
        // Layout overlays and the edit journal do not outlive the inspector.
        el_layoutOn = {};
        el_layoutSync();
        el_journal = {};
        var keys = Object.keys(el_forceStateMap);
        for (var ki = 0; ki < keys.length; ki++) {
          var info = el_forceStateMap[keys[ki]];
          var node = nodeById(parseInt(keys[ki]));
          if (node) { try { node.classList.remove(info.className); } catch(e) {} }
        }
        el_forceStateMap = {};
        if (el_forceStyleEl) {
          try { el_forceStyleEl.remove(); } catch(e) {}
          el_forceStyleEl = null;
        }
        var injected = document.getElementById("orbit-inspector-stylesheet");
        if (injected) { try { injected.remove(); } catch(e) {} }
        var fsStyle = document.getElementById("orbit-force-state-style");
        if (fsStyle) { try { fsStyle.remove(); } catch(e) {} }
      });
    """##
}
