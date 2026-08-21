import Foundation

// Filter-list regex bodies are third-party downloads, so a hostile list could ship a
// catastrophic-backtracking pattern. Rejects those shapes before NSRegularExpression.
enum FilterRegexBounds {
    static let maxPatternLength = 2048
    static let maxGroupDepth = 32
    static let maxExplicitRepetition = 1000

    private struct Quantifier {
        var exists: Bool
        var isUnbounded: Bool
        var requiresAtLeastOnce: Bool
        var invalid: Bool
        var endIndex: Int

        static func none(at index: Int) -> Quantifier {
            Quantifier(exists: false, isUnbounded: false, requiresAtLeastOnce: false, invalid: false, endIndex: index)
        }

        static func bad(at index: Int) -> Quantifier {
            Quantifier(exists: true, isUnbounded: false, requiresAtLeastOnce: false, invalid: true, endIndex: index)
        }
    }

    private struct GroupFrame {
        var hasUnbounded = false
        var hasMandatory = false
        var pipeIndices: [Int] = []
        var contentStart: Int
    }

    static func isSafe(_ pattern: String) -> Bool {
        guard pattern.utf8.count <= maxPatternLength else { return false }

        let chars = Array(pattern)
        var index = 0
        var stack: [GroupFrame] = []

        while index < chars.count {
            let ch = chars[index]

            switch ch {
            case "(":
                stack.append(GroupFrame(contentStart: index + 1))
                if stack.count > maxGroupDepth { return false }
                index += 1

            case "|":
                if !stack.isEmpty {
                    stack[stack.count - 1].pipeIndices.append(index)
                }
                index += 1

            case ")":
                guard let frame = stack.popLast() else { return false }
                let quantifier = readQuantifier(chars, at: index + 1)
                if quantifier.invalid { return false }

                if quantifier.exists, quantifier.isUnbounded, !frame.pipeIndices.isEmpty {
                    let boundaries = [frame.contentStart - 1] + frame.pipeIndices + [index]
                    var seenBranches: Set<String> = []
                    for (lower, upper) in zip(boundaries, boundaries.dropFirst()) {
                        let branch = String(chars[(lower + 1)..<upper])
                        if branch.isEmpty || !seenBranches.insert(branch).inserted {
                            return false
                        }
                    }
                }

                if quantifier.exists, quantifier.isUnbounded, frame.hasUnbounded, !frame.hasMandatory {
                    return false
                }

                apply(quantifier, to: &stack)
                index = quantifier.endIndex

            case "\\":
                let atomEnd = min(index + 2, chars.count)
                let quantifier = readQuantifier(chars, at: atomEnd)
                if quantifier.invalid { return false }
                apply(quantifier, to: &stack)
                index = quantifier.endIndex

            case "[":
                guard let classEnd = scanCharClass(chars, openIndex: index) else { return false }
                let quantifier = readQuantifier(chars, at: classEnd)
                if quantifier.invalid { return false }
                apply(quantifier, to: &stack)
                index = quantifier.endIndex

            default:
                let quantifier = readQuantifier(chars, at: index + 1)
                if quantifier.invalid { return false }
                apply(quantifier, to: &stack)
                index = quantifier.endIndex
            }
        }

        return stack.isEmpty
    }

    private static func apply(_ quantifier: Quantifier, to stack: inout [GroupFrame]) {
        guard !stack.isEmpty else { return }
        if !quantifier.exists {
            stack[stack.count - 1].hasMandatory = true
        } else if quantifier.isUnbounded {
            stack[stack.count - 1].hasUnbounded = true
        } else if quantifier.requiresAtLeastOnce {
            stack[stack.count - 1].hasMandatory = true
        }
    }

    private static func scanCharClass(_ chars: [Character], openIndex: Int) -> Int? {
        var i = openIndex + 1
        if i < chars.count, chars[i] == "^" { i += 1 }
        if i < chars.count, chars[i] == "]" { i += 1 }
        while i < chars.count {
            if chars[i] == "\\" {
                i = min(i + 2, chars.count)
                continue
            }
            if chars[i] == "]" { return i + 1 }
            i += 1
        }
        return nil
    }

    private static func readQuantifier(_ chars: [Character], at index: Int) -> Quantifier {
        guard index < chars.count else { return .none(at: index) }
        var endIndex: Int
        var isUnbounded: Bool
        var requiresAtLeastOnce: Bool

        switch chars[index] {
        case "*":
            endIndex = index + 1
            isUnbounded = true
            requiresAtLeastOnce = false
        case "+":
            endIndex = index + 1
            isUnbounded = true
            requiresAtLeastOnce = true
        case "?":
            endIndex = index + 1
            isUnbounded = false
            requiresAtLeastOnce = false
        case "{":
            guard let brace = parseBraceQuantifier(chars, openIndex: index) else { return .none(at: index) }
            guard brace.valid else { return .bad(at: brace.endIndex) }
            endIndex = brace.endIndex
            isUnbounded = brace.isUnbounded
            requiresAtLeastOnce = brace.minValue >= 1
        default:
            return .none(at: index)
        }

        if endIndex < chars.count, chars[endIndex] == "?" {
            endIndex += 1
        }

        return Quantifier(
            exists: true,
            isUnbounded: isUnbounded,
            requiresAtLeastOnce: requiresAtLeastOnce,
            invalid: false,
            endIndex: endIndex
        )
    }

    private struct BraceQuantifier {
        var isUnbounded: Bool
        var minValue: Int
        var endIndex: Int
        var valid: Bool
    }

    private static func parseBraceQuantifier(_ chars: [Character], openIndex: Int) -> BraceQuantifier? {
        guard chars[openIndex] == "{" else { return nil }
        var i = openIndex + 1
        var minDigits = ""
        while i < chars.count, chars[i].isASCII, chars[i].isNumber {
            minDigits.append(chars[i])
            i += 1
        }
        guard !minDigits.isEmpty else { return nil }

        var isUnbounded = false
        var maxDigits: String?
        if i < chars.count, chars[i] == "," {
            i += 1
            var digits = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                digits.append(chars[i])
                i += 1
            }
            if digits.isEmpty {
                isUnbounded = true
            } else {
                maxDigits = digits
            }
        }
        guard i < chars.count, chars[i] == "}" else { return nil }
        let endIndex = i + 1

        guard let minValue = Int(minDigits), minValue <= maxExplicitRepetition else {
            return BraceQuantifier(isUnbounded: isUnbounded, minValue: 0, endIndex: endIndex, valid: false)
        }
        if let maxDigits {
            guard let maxValue = Int(maxDigits), maxValue <= maxExplicitRepetition, maxValue >= minValue else {
                return BraceQuantifier(isUnbounded: isUnbounded, minValue: minValue, endIndex: endIndex, valid: false)
            }
        }
        return BraceQuantifier(isUnbounded: isUnbounded, minValue: minValue, endIndex: endIndex, valid: true)
    }
}
