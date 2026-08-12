import Foundation

struct PageTextExtract: Equatable, Sendable {
    var title: String
    var url: String
    var text: String
    var totalCharacters: Int

    /// Rounded down, never up — never claim to have read more than was sent.
    var includedFraction: Double {
        guard totalCharacters > 0 else { return 0 }
        return min(1.0, Double(text.count) / Double(totalCharacters))
    }

    var wasTruncated: Bool { text.count < totalCharacters }

    var truncationNotice: String? {
        guard wasTruncated else { return nil }
        let percent = max(1, Int(includedFraction * 100))
        return "This page was long, so I read the first \(percent)%."
    }
}

enum PageTextExtractor {

    static let characterBudget = 24_000

    /// `innerText`, not `textContent` — the latter includes `<script>`/`<style>`/`display:none` contents, a privacy leak.
    static func script(characterBudget: Int = PageTextExtractor.characterBudget) -> String {
        """
        (function () {
          var root = document.body || document.documentElement;
          var raw = root ? (root.innerText || "") : "";
          raw = raw.replace(/[ \\t\\u00a0]+/g, " ").replace(/\\n{3,}/g, "\\n\\n").trim();
          return {
            title: document.title || "",
            url: location.href || "",
            total: raw.length,
            text: raw.slice(0, \(characterBudget))
          };
        })()
        """
    }

    static func parse(_ value: Any?) -> PageTextExtract? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let text = (dictionary["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let total = (dictionary["total"] as? Int)
            ?? (dictionary["total"] as? NSNumber)?.intValue
            ?? text.count
        return PageTextExtract(
            title: dictionary["title"] as? String ?? "",
            url: dictionary["url"] as? String ?? "",
            text: text,
            totalCharacters: max(total, text.count)
        )
    }

    @MainActor
    static func extract(from contents: any WebContents, characterBudget: Int = PageTextExtractor.characterBudget) async -> PageTextExtract? {
        guard !contents.isClosed else { return nil }
        let value = try? await contents.evaluateJavaScript(script(characterBudget: characterBudget))
        return parse(value)
    }
}
