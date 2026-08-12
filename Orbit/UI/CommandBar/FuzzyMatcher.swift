import Foundation

enum FuzzyMatcher {

    enum Strictness {
        // Substring match only: over a long haystack like a full URL, a subsequence match produces false positives that outrank genuine results.
        case substring
        case subsequence
    }

    static func match(pattern: String, in text: String) -> Double? {
        guard !pattern.isEmpty else { return 0.01 }
        guard !text.isEmpty else { return nil }

        let patternChars = Array(pattern.lowercased())
        let textChars = Array(text.lowercased())

        var score: Double = 0
        var patternIndex = 0
        var consecutiveRun = 0
        var previousMatchIndex = -1

        for (index, character) in textChars.enumerated() {
            guard patternIndex < patternChars.count else { break }
            guard character == patternChars[patternIndex] else { continue }

            var characterScore = 1.0

            if previousMatchIndex == index - 1 {
                consecutiveRun += 1
                characterScore += Double(consecutiveRun) * 1.5
            } else {
                consecutiveRun = 0
            }

            let isWordBoundary = index == 0 || textChars[index - 1] == " " || textChars[index - 1] == "."
                || textChars[index - 1] == "/" || textChars[index - 1] == "-"
            if isWordBoundary { characterScore += 2.5 }

            characterScore += max(0, 2.0 - Double(index) * 0.015)

            score += characterScore
            previousMatchIndex = index
            patternIndex += 1
        }

        guard patternIndex == patternChars.count else { return nil }

        score += max(0, 4.0 - Double(textChars.count) * 0.02)
        if text.lowercased().contains(pattern.lowercased()) { score += 6 }
        if text.lowercased().hasPrefix(pattern.lowercased()) { score += 10 }

        return score
    }

    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // Mean of each term's best field score, not the sum: CommandBarEngine's tier offsets are calibrated against single-token magnitudes, and a sum would inflate multi-word scores past them.
    static func matchQuery(_ query: String, in fields: [String], strictness: Strictness = .subsequence) -> Double? {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return 0.01 }
        let populated = fields.filter { !$0.isEmpty }
        guard !populated.isEmpty else { return nil }

        var total: Double = 0
        for term in terms {
            let candidates: [String]
            switch strictness {
            case .substring:
                candidates = populated.filter { $0.range(of: term, options: .caseInsensitive) != nil }
            case .subsequence:
                candidates = populated
            }
            guard let best = candidates.compactMap({ match(pattern: term, in: $0) }).max() else { return nil }
            total += best
        }
        var score = total / Double(terms.count)

        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !phrase.isEmpty, terms.count > 1 {
            if populated.contains(where: { $0.lowercased().contains(phrase) }) { score += 8 }
            if populated.contains(where: { $0.lowercased().hasPrefix(phrase) }) { score += 12 }
        }
        return score
    }
}
