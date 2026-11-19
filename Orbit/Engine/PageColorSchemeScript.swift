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

    // MARK: - Settled documents

    /// What a finished document already has: the scheme applied to it, or nil when it was read and has no colour to
    /// derive one from. Lets reselecting a tab skip a script round trip that would compete with the page's first paint.
    public struct SettledDocument: Equatable, Sendable {
        public var url: URL
        public var scheme: Scheme?

        public init(url: URL, scheme: Scheme?) {
            self.url = url
            self.scheme = scheme
        }
    }

    // Keyed by WebContents.id: a re-materialised page behind the same tab is a new document.
    @MainActor private static var settledByContents: [UUID: SettledDocument] = [:]

    // Closed pages are never reported, so the cache is bounded instead; a dropped entry only costs one re-apply.
    static let settledDocumentLimit = 512

    @MainActor
    public static func isSettled(_ document: SettledDocument, for contentsID: UUID) -> Bool {
        settledByContents[contentsID] == document
    }

    @MainActor
    public static func noteSettled(_ document: SettledDocument, for contentsID: UUID) {
        if settledByContents[contentsID] == nil, settledByContents.count >= settledDocumentLimit {
            settledByContents.removeAll()
        }
        settledByContents[contentsID] = document
    }

    /// Call when the page starts a navigation or reload: the next document has not had the scheme applied.
    @MainActor
    public static func forgetSettled(for contentsID: UUID) {
        settledByContents.removeValue(forKey: contentsID)
    }

    #if DEBUG
    @MainActor
    static func _test_resetSettled() {
        settledByContents.removeAll()
    }
    #endif
}
