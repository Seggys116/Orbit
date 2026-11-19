import Foundation

// nonisolated: the Command Bar scores history and tabs on a background task.
nonisolated enum FuzzyMatcher {

    nonisolated enum Strictness {
        // Substring match only: over a long haystack like a full URL, a subsequence match produces false positives that outrank genuine results.
        case substring
        case subsequence
    }

    // MARK: Prepared text

    /// A haystack lowercased once, so matching it against many terms (or many keystrokes, when the owner caches it) never re-lowercases.
    nonisolated struct PreparedText: Sendable {
        let original: String
        let lowered: String
        /// The lowered UTF-8, only when the original is pure ASCII. There every Character is one byte, so byte-wise matching is exactly the Character-wise algorithm; anything else takes the original String path.
        let bytes: [UInt8]?

        init(_ text: String) {
            original = text
            lowered = text.lowercased()
            // CR is excluded because "\r\n" is a single Character.
            bytes = text.utf8.allSatisfy { $0 < 128 && $0 != 13 } ? Array(lowered.utf8) : nil
        }

        var isEmpty: Bool { original.isEmpty }

        /// True when this text contains the already-lowercased term.
        func containsLowered(_ term: PreparedQuery.Term) -> Bool {
            if let pattern = term.bytes, let text = bytes { return FuzzyMatcher.contains(text, pattern) }
            return lowered.contains(term.lowered)
        }
    }

    /// A query split into terms and lowercased once per results call.
    nonisolated struct PreparedQuery: Sendable {
        nonisolated struct Term: Sendable {
            let original: String
            let lowered: String
            /// Lowered UTF-8 when the term is pure ASCII; see PreparedText.bytes.
            let bytes: [UInt8]?
            /// Lowered Characters, only built when `bytes` is nil.
            let characters: [Character]

            init(_ text: String) {
                original = text
                lowered = text.lowercased()
                if text.utf8.allSatisfy({ $0 < 128 && $0 != 13 }) {
                    bytes = Array(lowered.utf8)
                    characters = []
                } else {
                    bytes = nil
                    characters = Array(lowered)
                }
            }
        }

        let text: String
        let terms: [Term]
        /// The whole trimmed query, lowercased: what a multi-word query is compared to as a phrase.
        let phrase: String
        let phraseBytes: [UInt8]?

        init(_ query: String) {
            text = query
            terms = FuzzyMatcher.terms(in: query).map(Term.init)
            phrase = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            phraseBytes = query.utf8.allSatisfy({ $0 < 128 && $0 != 13 }) ? Array(phrase.utf8) : nil
        }
    }

    // MARK: Matching

    static func match(pattern: String, in text: String) -> Double? {
        guard !pattern.isEmpty else { return 0.01 }
        guard !text.isEmpty else { return nil }
        return match(term: PreparedQuery.Term(pattern), in: PreparedText(text))
    }

    private static func match(term: PreparedQuery.Term, in text: PreparedText) -> Double? {
        if let pattern = term.bytes, let textBytes = text.bytes {
            guard var score = subsequenceScore(pattern: pattern, text: textBytes, isBoundary: { $0 == 32 || $0 == 46 || $0 == 47 || $0 == 45 }) else {
                return nil
            }
            score += max(0, 4.0 - Double(textBytes.count) * 0.02)
            if contains(textBytes, pattern) { score += 6 }
            if textBytes.starts(with: pattern) { score += 10 }
            return score
        }

        let patternChars = term.bytes != nil ? Array(term.lowered) : term.characters
        let textChars = Array(text.lowered)
        guard var score = subsequenceScore(pattern: patternChars, text: textChars, isBoundary: { $0 == " " || $0 == "." || $0 == "/" || $0 == "-" }) else {
            return nil
        }
        score += max(0, 4.0 - Double(textChars.count) * 0.02)
        if text.lowered.contains(term.lowered) { score += 6 }
        if text.lowered.hasPrefix(term.lowered) { score += 10 }
        return score
    }

    // The per-character scoring loop shared by the ASCII (byte) and general (Character) paths, so the two cannot drift apart.
    private static func subsequenceScore<Element: Equatable>(pattern: [Element], text: [Element], isBoundary: (Element) -> Bool) -> Double? {
        var score: Double = 0
        var patternIndex = 0
        var consecutiveRun = 0
        var previousMatchIndex = -1

        for index in text.indices {
            guard patternIndex < pattern.count else { break }
            guard text[index] == pattern[patternIndex] else { continue }

            var characterScore = 1.0

            if previousMatchIndex == index - 1 {
                consecutiveRun += 1
                characterScore += Double(consecutiveRun) * 1.5
            } else {
                consecutiveRun = 0
            }

            if index == 0 || isBoundary(text[index - 1]) { characterScore += 2.5 }

            characterScore += max(0, 2.0 - Double(index) * 0.015)

            score += characterScore
            previousMatchIndex = index
            patternIndex += 1
        }

        return patternIndex == pattern.count ? score : nil
    }

    fileprivate static func contains(_ text: [UInt8], _ pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty else { return true }
        guard text.count >= pattern.count else { return false }
        let last = text.count - pattern.count
        var start = 0
        while start <= last {
            if text[start] == pattern[0] {
                var offset = 1
                while offset < pattern.count, text[start + offset] == pattern[offset] { offset += 1 }
                if offset == pattern.count { return true }
            }
            start += 1
        }
        return false
    }

    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // Mean of each term's best field score, not the sum: CommandBarEngine's tier offsets are calibrated against single-token magnitudes, and a sum would inflate multi-word scores past them.
    static func matchQuery(_ query: String, in fields: [String], strictness: Strictness = .subsequence) -> Double? {
        let prepared = PreparedQuery(query)
        guard !prepared.terms.isEmpty else { return 0.01 }
        return matchQuery(prepared, in: fields.map(PreparedText.init), strictness: strictness)
    }

    /// The same scoring as `matchQuery(_:in:strictness:)` over text the caller lowercased already.
    static func matchQuery(_ query: PreparedQuery, in fields: [PreparedText], strictness: Strictness = .subsequence) -> Double? {
        guard !query.terms.isEmpty else { return 0.01 }
        guard fields.contains(where: { !$0.isEmpty }) else { return nil }

        var total: Double = 0
        for term in query.terms {
            var best: Double?
            for field in fields where !field.isEmpty {
                if strictness == .substring, !containsSubstring(term, in: field) { continue }
                guard let score = match(term: term, in: field) else { continue }
                if best == nil || score > best! { best = score }
            }
            guard let best else { return nil }
            total += best
        }
        var score = total / Double(query.terms.count)

        if !query.phrase.isEmpty, query.terms.count > 1 {
            if fields.contains(where: { containsPhrase(query, in: $0) }) { score += 8 }
            if fields.contains(where: { startsWithPhrase(query, in: $0) }) { score += 12 }
        }
        return score
    }

    // Case-insensitive substring test. ASCII takes the byte path; anything else keeps the Foundation search so exotic case folding behaves as it always did.
    private static func containsSubstring(_ term: PreparedQuery.Term, in text: PreparedText) -> Bool {
        if let pattern = term.bytes, let bytes = text.bytes { return contains(bytes, pattern) }
        return text.original.range(of: term.original, options: .caseInsensitive) != nil
    }

    private static func containsPhrase(_ query: PreparedQuery, in text: PreparedText) -> Bool {
        if let pattern = query.phraseBytes, let bytes = text.bytes { return contains(bytes, pattern) }
        return text.lowered.contains(query.phrase)
    }

    private static func startsWithPhrase(_ query: PreparedQuery, in text: PreparedText) -> Bool {
        if let pattern = query.phraseBytes, let bytes = text.bytes { return bytes.starts(with: pattern) }
        return text.lowered.hasPrefix(query.phrase)
    }
}
