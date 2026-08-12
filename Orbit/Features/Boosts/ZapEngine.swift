import Foundation

struct ZapPick: Decodable, Sendable, Equatable {
    var ladder: [String]
    var tag: String
    var rect: ZapRect

    struct ZapRect: Decodable, Sendable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }
}

enum ZapEngine {

    static let activateScript = """
    (function() {
      if (window.__orbitZapActive) { return true; }
      window.__orbitZapActive = true;

      var overlay = document.createElement('div');
      overlay.id = '__orbit_zap_overlay__';
      overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' +
        'border:2px solid #ff5a36;background:rgba(255,90,54,0.14);border-radius:3px;' +
        'transition:all 0.05s ease-out;display:none;box-sizing:border-box;';
      var label = document.createElement('div');
      label.id = '__orbit_zap_label__';
      label.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' +
        'background:#ff5a36;color:#fff;font:600 11px -apple-system,BlinkMacSystemFont,sans-serif;' +
        'padding:2px 6px;border-radius:4px;display:none;white-space:nowrap;';
      document.documentElement.appendChild(overlay);
      document.documentElement.appendChild(label);

      function cssEscape(s) {
        return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/([^a-zA-Z0-9_-])/g, '\\\\$1');
      }

      function classList(el) {
        return el.classList ? Array.from(el.classList).filter(Boolean) : [];
      }

      function selectorForElement(el) {
        if (el.id) return '#' + cssEscape(el.id);
        var path = [];
        var node = el;
        var depth = 0;
        while (node && node.nodeType === 1 && depth < 6) {
          var seg = node.tagName.toLowerCase();
          var cls = classList(node);
          if (cls.length) seg += '.' + cls.slice(0, 3).map(cssEscape).join('.');
          var parent = node.parentElement;
          if (parent) {
            var siblings = Array.from(parent.children).filter(function(c) { return c.tagName === node.tagName; });
            if (siblings.length > 1) {
              seg += ':nth-child(' + (Array.from(parent.children).indexOf(node) + 1) + ')';
            }
          }
          path.unshift(seg);
          if (node === document.body) break;
          node = parent;
          depth++;
        }
        return path.join(' > ');
      }

      function generalizationLadder(el) {
        var ladder = [];
        ladder.push(selectorForElement(el));
        var cls = classList(el);
        var tag = el.tagName.toLowerCase();
        if (cls.length > 1) ladder.push(tag + '.' + cls.map(cssEscape).join('.'));
        if (cls.length >= 1) ladder.push(tag + '.' + cssEscape(cls[0]));
        if (cls.length >= 1) ladder.push('.' + cssEscape(cls[0]));
        if (el.parentElement) {
          var parentSel = selectorForElement(el.parentElement);
          if (parentSel) ladder.push(parentSel + ' > ' + tag);
        }
        ladder.push(tag);
        var seen = {};
        return ladder.filter(function(s) {
          if (!s || seen[s]) return false;
          seen[s] = true;
          return true;
        });
      }

      function onMove(e) {
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === overlay || el === label) return;
        window.__orbitZapHoverTarget = el;
        var r = el.getBoundingClientRect();
        overlay.style.display = 'block';
        overlay.style.left = r.left + 'px';
        overlay.style.top = r.top + 'px';
        overlay.style.width = r.width + 'px';
        overlay.style.height = r.height + 'px';
        label.style.display = 'block';
        label.style.left = r.left + 'px';
        label.style.top = Math.max(0, r.top - 20) + 'px';
        var cls = classList(el);
        label.textContent = el.tagName.toLowerCase() + (cls.length ? '.' + cls.slice(0, 2).join('.') : '');
      }

      function onClick(e) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        var el = window.__orbitZapHoverTarget || document.elementFromPoint(e.clientX, e.clientY);
        if (!el) return false;
        var ladder = generalizationLadder(el);
        var r = el.getBoundingClientRect();
        window.__orbitZapPick = JSON.stringify({
          ladder: ladder,
          tag: el.tagName.toLowerCase(),
          rect: { x: r.left, y: r.top, w: r.width, h: r.height }
        });
        return false;
      }

      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('click', onClick, true);
      window.__orbitZapCleanup = function() {
        document.removeEventListener('mousemove', onMove, true);
        document.removeEventListener('click', onClick, true);
        overlay.remove();
        label.remove();
        var previewStyle = document.getElementById('__orbit_zap_preview_style__');
        if (previewStyle) previewStyle.remove();
        window.__orbitZapActive = false;
      };
      return true;
    })();
    """

    static let deactivateScript = """
    (function() {
      if (window.__orbitZapCleanup) { window.__orbitZapCleanup(); }
      return true;
    })();
    """

    static let pollScript = """
    (function() {
      if (window.__orbitZapPick) {
        var p = window.__orbitZapPick;
        window.__orbitZapPick = null;
        return p;
      }
      return null;
    })();
    """

    static func previewScript(selector: String) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String]
        }?.first ?? selector
        let jsonLiteral = jsStringLiteral(encoded)
        return """
        (function() {
          var style = document.getElementById('__orbit_zap_preview_style__');
          if (!style) {
            style = document.createElement('style');
            style.id = '__orbit_zap_preview_style__';
            document.head.appendChild(style);
          }
          var sel = \(jsonLiteral);
          var count = 0;
          try {
            if (sel) {
              style.textContent = sel + ' { outline: 3px solid #ff5a36 !important; outline-offset: -2px !important; background: rgba(255,90,54,0.10) !important; }';
              count = document.querySelectorAll(sel).length;
            } else {
              style.textContent = '';
            }
          } catch (e) {
            style.textContent = '';
            count = -1;
          }
          return count;
        })();
        """
    }

    static let clearPreviewScript = """
    (function() {
      var style = document.getElementById('__orbit_zap_preview_style__');
      if (style) style.textContent = '';
      return true;
    })();
    """

    static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }

    static func decodePick(_ raw: Any?) -> ZapPick? {
        guard let string = raw as? String, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ZapPick.self, from: data)
    }
}
