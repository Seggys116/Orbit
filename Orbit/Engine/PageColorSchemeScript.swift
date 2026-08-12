import Foundation

public enum PageColorSchemeScript {

    /// `normal` is deliberately not a case: it's the "said nothing" state this moves a page out of.
    public enum Scheme: String, Equatable, Sendable {
        case light
        case dark
    }

    public struct Outcome: Equatable, Sendable {
        public var applied: Scheme?
        /// `true` when the page already declares its own `color-scheme` — this does nothing in that case.
        public var authorDeclared: Bool

        public init(applied: Scheme?, authorDeclared: Bool) {
            self.applied = applied
            self.authorDeclared = authorDeclared
        }
    }

    public static let undeclaredDocumentCanvas = ThemeColor(red: 1, green: 1, blue: 1)

    /// Shares `PaneHeaderColorResolver.foreground(for:)` so the scroller and header never disagree.
    @MainActor
    public static func scheme(for pageColor: ThemeColor) -> Scheme {
        let painted = pageColor.composited(over: undeclaredDocumentCanvas)
        switch PaneHeaderColorResolver.foreground(for: painted) {
        case .dark: return .light
        case .light: return .dark
        }
    }

    /// Inline style, not a `<style>` rule, which would outrank an author's `html {}`.
    public static func source(applying scheme: Scheme) -> String {
        """
        (function () {
          var value = '\(scheme.rawValue)';
          var root = document.documentElement;
          if (!root) { return { applied: null, authorDeclared: false }; }

          var MARKER = '__orbitAppliedColorScheme';
          var previouslyApplied = root[MARKER];

          if (previouslyApplied === undefined) {
            var declared = '';
            try {
              declared = (window.getComputedStyle(root).colorScheme || '').trim();
            } catch (e) {
              return { applied: null, authorDeclared: true };
            }
            // 'normal' is the initial value -- the document has said nothing.
            if (declared !== '' && declared !== 'normal') {
              return { applied: null, authorDeclared: true };
            }
          }

          if (previouslyApplied !== value) {
            try {
              root.style.setProperty('color-scheme', value);
            } catch (e) {
              return { applied: null, authorDeclared: false };
            }
            try {
              Object.defineProperty(root, MARKER, {
                value: value, enumerable: false, configurable: true, writable: true
              });
            } catch (e) {}
          }
          return { applied: value, authorDeclared: false };
        })();
        """
    }

    public static func decode(_ raw: Any?) -> Outcome? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        let authorDeclared = (dictionary["authorDeclared"] as? Bool)
            ?? ((dictionary["authorDeclared"] as? NSNumber)?.boolValue ?? false)
        let applied = (dictionary["applied"] as? String).flatMap(Scheme.init(rawValue:))
        return Outcome(applied: applied, authorDeclared: authorDeclared)
    }

    @MainActor
    @discardableResult
    public static func apply(_ scheme: Scheme, to contents: any WebContents) async -> Outcome? {
        let raw = try? await contents.evaluateJavaScript(source(applying: scheme))
        return decode(raw)
    }
}
