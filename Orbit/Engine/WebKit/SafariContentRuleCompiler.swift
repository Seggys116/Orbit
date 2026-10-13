import Foundation
import WebKit

/// Turns the filter lists ContentBlocker already compiled into Safari content rules
/// so WebKit blocks the same network requests and hides the same cosmetic selectors.
@MainActor
enum SafariContentRuleCompiler {
    private static let identifier = "orbit-content-blocking"

    static func json(for blocker: ContentBlocker?) async -> String {
        guard let blocker else { return "[]" }
        let store = FilterListStore(directory: FilterListStore.defaultDirectory())
        var rules: [[String: Any]] = []
        for listID in blocker.currentRuleSet.listIDs {
            guard let text = await store.cachedText(for: listID) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                guard rules.count < 50_000 else { break }
                if let rule = rule(from: String(line)) { rules.append(rule) }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    static func compile(_ json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private static func rule(from rawLine: String) -> [String: Any]? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return nil }
        let exception = line.hasPrefix("@@")
        if exception { line.removeFirst(2) }
        let pieces = line.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        let pattern = String(pieces[0])
        if let selectorRange = pattern.range(of: "##") {
            let selector = String(pattern[selectorRange.upperBound...])
            guard !selector.isEmpty else { return nil }
            return [
                "trigger": ["url-filter": ".*"],
                "action": ["type": "css-display-none", "selector": selector],
            ]
        }
        guard let filter = urlFilter(from: pattern) else { return nil }
        return [
            "trigger": ["url-filter": filter],
            "action": ["type": exception ? "ignore-previous-rules" : "block"],
        ]
    }

    private static func urlFilter(from pattern: String) -> String? {
        var text = pattern
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        if text.hasPrefix("/") && text.hasSuffix("/") && text.count > 2 {
            return String(text.dropFirst().dropLast())
        }
        var anchoredLeft = false
        var anchoredRight = false
        if text.hasPrefix("||") {
            anchoredLeft = true
            text.removeFirst(2)
        } else if text.hasPrefix("|") {
            anchoredLeft = true
            text.removeFirst()
        }
        if text.hasSuffix("^") || text.hasSuffix("|") {
            anchoredRight = true
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }
        var regex = NSRegularExpression.escapedPattern(for: text)
        regex = regex.replacingOccurrences(of: "\\*", with: ".*")
        if anchoredLeft { regex = "^[^:]+://+([^/]+\\\\.)?" + regex }
        if anchoredRight { regex += "[^\\w\\-.%]?" }
        return regex
    }
}
