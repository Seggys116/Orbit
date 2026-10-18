import AppKit
import Foundation

public enum PageThemeColorScript {

    /// `color` is the chrome colour (top edge of the page); `documentColor`
    /// is the document's own background — distinct because a page can be a
    /// white document under a dark nav.
    public struct Reading: Equatable {
        public var color: NSColor?
        /// `nil` when neither `<body>` nor `<html>` paints an opaque background.
        public var documentColor: NSColor?
        /// `false` while `document.readyState == "loading"`.
        public var isReady: Bool

        public init(color: NSColor?, documentColor: NSColor? = nil, isReady: Bool) {
            self.color = color
            self.documentColor = documentColor
            self.isReady = isReady
        }
    }

    public static let minimumOpaqueAlpha: Double = 0.05

    // MARK: - The painted top band

    /// Sized to the pane header it has to agree with, not a round number.
    public static let bandHeight: Double = 44

    /// Paired with `bandMinimumDistinctRows`: five rows so thin strips can be excluded.
    public static let bandSampleRows: [Double] = [0.08, 0.3, 0.5, 0.7, 0.92]

    /// Inset from both edges: scrollbars and page gutters live there.
    public static let bandSampleColumns: [Double] = [0.08, 0.3, 0.5, 0.7, 0.92]

    public static let bandDominance: Double = 0.6

    /// Distinct rows the winner must appear in — not the dominance ratio.
    public static let bandMinimumDistinctRows: Int = 3

    public static let bandMinimumReadableFraction: Double = 0.5

    private static var bandSampleRowsJS: String {
        "[" + bandSampleRows.map { String($0) }.joined(separator: ", ") + "]"
    }

    private static var bandSampleColumnsJS: String {
        "[" + bandSampleColumns.map { String($0) }.joined(separator: ", ") + "]"
    }

    /// `color` is `"#rrggbb"` or `"rgba(r, g, b, a)"`. WebKit's computed style
    /// is `rgb()`, so the script rewrites that (and `color(srgb ...)`) into
    /// those two forms before posting; the decoder does not accept `rgb()`.
    /// Mutates nothing: no element inserted, no style changed, canvas never
    /// attached to the document.
    public static let resolverSource: String = #"""
      var __orbitColorContext;
      // WebKit's getComputedStyle serialises as rgb()/rgba(), and a 2d context is
      // sometimes unavailable at document start. The host decoder accepts only
      // #rrggbb and rgba(); posting the raw computed form is decoded as "no
      // colour" and the address bar stays the neutral gray. Rewrite the forms
      // WebKit actually emits before anything asks the canvas.
      function __orbitCanonicalize(serialized) {
        if (typeof serialized !== 'string') { return null; }
        var text = serialized.trim();
        var hex = text.match(/^#([0-9a-f]{6})$/i);
        if (hex) { return '#' + hex[1].toLowerCase(); }
        var comma = text.match(/^rgba?\(\s*([\d.]+%?)\s*,\s*([\d.]+%?)\s*,\s*([\d.]+%?)\s*(?:,\s*([\d.]+%?)\s*)?\)$/i);
        var space = text.match(/^rgba?\(\s*([\d.]+%?)\s+([\d.]+%?)\s+([\d.]+%?)\s*(?:\/\s*([\d.]+%?)\s*)?\)$/i);
        var match = comma || space;
        if (!match) {
          var srgb = text.match(/^color\(\s*srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)(?:\s*\/\s*([\d.]+))?\s*\)$/i);
          if (!srgb) { return null; }
          match = [null, Number(srgb[1]) * 255, Number(srgb[2]) * 255, Number(srgb[3]) * 255, srgb[4]];
        }
        function __orbitChannel(text) {
          var raw = String(text).trim();
          if (raw.charAt(raw.length - 1) === '%') { return parseFloat(raw) / 100 * 255; }
          return Number(raw);
        }
        function __orbitAlpha(text) {
          if (text === undefined) { return 1; }
          var raw = String(text).trim();
          if (raw.charAt(raw.length - 1) === '%') { return parseFloat(raw) / 100; }
          return Number(raw);
        }
        var red = __orbitChannel(match[1]);
        var green = __orbitChannel(match[2]);
        var blue = __orbitChannel(match[3]);
        var alpha = __orbitAlpha(match[4]);
        if (!(alpha >= 0) || !(red >= 0) || !(green >= 0) || !(blue >= 0)) { return null; }
        if (alpha >= 1) {
          return '#' + __orbitHexComponent(red) + __orbitHexComponent(green) + __orbitHexComponent(blue);
        }
        return 'rgba(' + Math.round(red) + ', ' + Math.round(green) + ', ' + Math.round(blue) + ', ' + alpha + ')';
      }

      function __orbitNormalizeColor(value) {
        if (typeof value !== 'string') { return null; }
        var trimmed = value.trim();
        if (!trimmed) { return null; }
        var direct = __orbitCanonicalize(trimmed);
        if (direct) { return direct; }
        try {
          // A failed getContext must not be cached: the first read often runs
          // before a 2d context exists, and a stored null would drop every
          // later theme-color and background for the life of the document.
          if (!__orbitColorContext) {
            var canvas = document.createElement('canvas');
            canvas.width = 1;
            canvas.height = 1;
            var created = canvas.getContext('2d');
            if (!created) { return null; }
            __orbitColorContext = created;
          }
          var ctx = __orbitColorContext;
          ctx.fillStyle = '#000000';
          ctx.fillStyle = trimmed;
          var first = ctx.fillStyle;
          ctx.fillStyle = '#ffffff';
          ctx.fillStyle = trimmed;
          if (ctx.fillStyle !== first) { return null; }
          return __orbitCanonicalize(first);
        } catch (e) {
          return null;
        }
      }

      function __orbitOpaqueEnough(serialized) {
        if (typeof serialized !== 'string') { return false; }
        var match = serialized.match(/^rgba\(\s*[\d.]+\s*,\s*[\d.]+\s*,\s*[\d.]+\s*,\s*([\d.]+)\s*\)$/);
        if (!match) { return true; }
        return parseFloat(match[1]) > \#(minimumOpaqueAlpha);
      }

      function __orbitDeclaredThemeColor() {
        var metas = document.querySelectorAll('meta[name="theme-color"]');
        var chosen = null;
        for (var i = 0; i < metas.length; i++) {
          var meta = metas[i];
          var media = meta.getAttribute('media');
          if (media) {
            try {
              if (!window.matchMedia || !window.matchMedia(media).matches) { continue; }
            } catch (e) {
              continue;
            }
          }
          var normalized = __orbitNormalizeColor(meta.getAttribute('content'));
          if (normalized && __orbitOpaqueEnough(normalized)) { chosen = normalized; }
        }
        return chosen;
      }

      var __ORBIT_BAND_HEIGHT = \#(bandHeight);
      var __ORBIT_BAND_ROWS = \#(bandSampleRowsJS);
      var __ORBIT_BAND_COLUMNS = \#(bandSampleColumnsJS);
      var __ORBIT_BAND_DOMINANCE = \#(bandDominance);
      var __ORBIT_BAND_MIN_ROWS = \#(bandMinimumDistinctRows);
      var __ORBIT_BAND_MIN_READABLE = \#(bandMinimumReadableFraction);

      function __orbitColorComponents(serialized) {
        if (typeof serialized !== 'string') { return null; }
        var hex = serialized.match(/^#([0-9a-f]{6})$/i);
        if (hex) {
          var packed = parseInt(hex[1], 16);
          return [(packed >> 16) & 255, (packed >> 8) & 255, packed & 255, 1];
        }
        var rgba = serialized.match(/^rgba\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*\)$/);
        if (rgba) {
          return [parseFloat(rgba[1]), parseFloat(rgba[2]), parseFloat(rgba[3]), parseFloat(rgba[4])];
        }
        return null;
      }

      function __orbitHexComponent(value) {
        var rounded = Math.max(0, Math.min(255, Math.round(value)));
        return (rounded < 16 ? '0' : '') + rounded.toString(16);
      }

      // A CSS gradient is a real colour. Treating it as unreadable dropped the
      // bar back to the document's white or black, which reads as light/dark mode.
      function __orbitGradientColor(image) {
        if (!image || image === 'none' || image.indexOf('gradient') === -1) { return null; }
        var hex = image.match(/#([0-9a-f]{3,8})/i);
        if (hex) {
          var normalized = __orbitNormalizeColor(hex[0].length === 4
            ? '#' + hex[1][0] + hex[1][0] + hex[1][1] + hex[1][1] + hex[1][2] + hex[1][2]
            : hex[0]);
          if (normalized && __orbitOpaqueEnough(normalized)) { return normalized; }
        }
        var rgb = image.match(/rgba?\([^)]+\)/i);
        if (!rgb) { return null; }
        var normalizedRGB = __orbitNormalizeColor(rgb[0]);
        if (normalizedRGB && __orbitOpaqueEnough(normalizedRGB)) { return normalizedRGB; }
        return null;
      }

      // Returns null ("unreadable") for a background image, not "transparent".
      // A gradient contributes its first opaque stop instead.
      function __orbitPaintedColorAt(x, y) {
        var stack;
        try { stack = document.elementsFromPoint(x, y); } catch (e) { return null; }
        if (!stack || !stack.length) { return null; }
        var r = 0, g = 0, b = 0, a = 0;
        for (var i = 0; i < stack.length; i++) {
          var style;
          try { style = window.getComputedStyle(stack[i]); } catch (e) { continue; }
          if (!style) { continue; }
          var image = style.backgroundImage;
          if (image && image !== 'none') {
            var fromGradient = __orbitGradientColor(image);
            if (!fromGradient) { return null; }
            var gradientComponents = __orbitColorComponents(fromGradient);
            if (!gradientComponents || gradientComponents[3] <= 0) { return null; }
            return fromGradient;
          }
          var components = __orbitColorComponents(__orbitNormalizeColor(style.backgroundColor));
          if (!components || components[3] <= 0) { continue; }
          var contribution = components[3] * (1 - a);
          r += components[0] * contribution;
          g += components[1] * contribution;
          b += components[2] * contribution;
          a += contribution;
          if (a >= 0.995) {
            return '#' + __orbitHexComponent(r / a) + __orbitHexComponent(g / a) + __orbitHexComponent(b / a);
          }
        }
        return null;
      }

      function __orbitTopBandColor() {
        if (!document.body || typeof document.elementsFromPoint !== 'function') { return null; }
        var width = window.innerWidth || (document.documentElement ? document.documentElement.clientWidth : 0) || 0;
        var height = window.innerHeight || (document.documentElement ? document.documentElement.clientHeight : 0) || 0;
        if (width <= 0 || height <= 0) { return null; }
        var band = Math.min(__ORBIT_BAND_HEIGHT, height);

        var counts = {};
        var rowsSeen = {};
        var readable = 0;
        var total = 0;

        for (var row = 0; row < __ORBIT_BAND_ROWS.length; row++) {
          var y = Math.min(height - 1, Math.max(0, band * __ORBIT_BAND_ROWS[row]));
          for (var column = 0; column < __ORBIT_BAND_COLUMNS.length; column++) {
            var x = Math.min(width - 1, Math.max(0, width * __ORBIT_BAND_COLUMNS[column]));
            total++;
            var painted = __orbitPaintedColorAt(x, y);
            if (!painted) { continue; }
            readable++;
            counts[painted] = (counts[painted] || 0) + 1;
            if (!rowsSeen[painted]) { rowsSeen[painted] = {}; }
            rowsSeen[painted][row] = true;
          }
        }

        if (total === 0 || readable / total < __ORBIT_BAND_MIN_READABLE) { return null; }

        var best = null;
        var bestCount = 0;
        for (var key in counts) {
          if (!Object.prototype.hasOwnProperty.call(counts, key)) { continue; }
          if (counts[key] > bestCount) { best = key; bestCount = counts[key]; }
        }
        if (!best || bestCount / readable < __ORBIT_BAND_DOMINANCE) { return null; }

        var distinctRows = 0;
        for (var seen in rowsSeen[best]) {
          if (Object.prototype.hasOwnProperty.call(rowsSeen[best], seen)) { distinctRows++; }
        }
        if (distinctRows < __ORBIT_BAND_MIN_ROWS) { return null; }
        return best;
      }

      function __orbitBackgroundOf(element) {
        if (!element) { return null; }
        var style = null;
        try {
          style = window.getComputedStyle(element);
        } catch (e) {
          return null;
        }
        if (!style) { return null; }
        var normalized = __orbitNormalizeColor(style.backgroundColor);
        if (!normalized || !__orbitOpaqueEnough(normalized)) { return null; }
        return normalized;
      }

      // Enumerates the same metas __orbitDeclaredThemeColor chooses between, for the observer's own subscriptions.
      function __orbitDeclaredMediaQueries() {
        var queries = [];
        try {
          var metas = document.querySelectorAll('meta[name="theme-color"][media]');
          for (var i = 0; i < metas.length; i++) {
            var media = metas[i].getAttribute('media');
            if (media && queries.indexOf(media) === -1) { queries.push(media); }
          }
        } catch (e) {}
        return queries;
      }

      function __orbitDocumentColor() {
        return __orbitBackgroundOf(document.body)
          || __orbitBackgroundOf(document.documentElement)
          || null;
      }

      function __orbitReadPageColor() {
        var documentColor = __orbitDocumentColor();
        // The painted top of the viewport wins over <meta theme-color>. A fixed
        // meta stays put while the page scrolls through a different colour, and
        // a meta of plain white or black is what made the bar look like a
        // light/dark switch. theme-color is the fallback when the top band is
        // a photo or otherwise unreadable.
        var band = __orbitTopBandColor();
        var declared = __orbitDeclaredThemeColor();
        var color = band || declared || documentColor || null;
        return {
          color: color,
          document: documentColor,
          ready: document.readyState !== 'loading'
        };
      }
    """#

    /// One-shot read for `PaneHeaderColorResolver`'s pull.
    public static let source: String = """
    (function () {
    \(resolverSource)
      return __orbitReadPageColor();
    })();
    """

    /// The Swift half of `minimumOpaqueAlpha`, for values reaching Orbit outside `resolverSource`. `nil` is not opaque.
    public static func isEffectivelyOpaque(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        let alpha = Double((color.usingColorSpace(.sRGB) ?? color).alphaComponent)
        return alpha > minimumOpaqueAlpha
    }

    /// `nil` when the payload isn't this script's shape — "no reading", never a colour.
    public static func decode(_ raw: Any?) -> Reading? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        let isReady = (dictionary["ready"] as? Bool)
            ?? ((dictionary["ready"] as? NSNumber)?.boolValue ?? false)
        // Absent `document` decodes to `nil`, matching every payload from before this key existed.
        let documentColor = (dictionary["document"] as? String).flatMap(color(fromSerialized:))
        guard let serialized = dictionary["color"] as? String else {
            return Reading(color: nil, documentColor: documentColor, isReady: isReady)
        }
        return Reading(
            color: color(fromSerialized: serialized),
            documentColor: documentColor,
            isReady: isReady
        )
    }

    /// Parses only the two forms the canvas colour serialiser emits — not a general CSS colour parser.
    public static func color(fromSerialized serialized: String) -> NSColor? {
        let text = serialized.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if text.hasPrefix("#") {
            let hex = String(text.dropFirst())
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: 1.0
            )
        }

        guard text.hasPrefix("rgba("), text.hasSuffix(")") else { return nil }
        let body = text.dropFirst("rgba(".count).dropLast()
        let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let red = Double(parts[0]), let green = Double(parts[1]),
              let blue = Double(parts[2]), let alpha = Double(parts[3])
        else { return nil }

        return NSColor(
            srgbRed: CGFloat(min(max(red, 0), 255)) / 255.0,
            green: CGFloat(min(max(green, 0), 255)) / 255.0,
            blue: CGFloat(min(max(blue, 0), 255)) / 255.0,
            alpha: CGFloat(min(max(alpha, 0), 1))
        )
    }
}
