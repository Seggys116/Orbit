import Foundation

// MARK: - Rule modifiers

nonisolated public struct RedirectDirective: Sendable, Equatable {
    public var token: String
    public var priority: Int
    public var isRuleOnly: Bool
    public var isNone: Bool

    public init(token: String, priority: Int, isRuleOnly: Bool, isNone: Bool) {
        self.token = token
        self.priority = priority
        self.isRuleOnly = isRuleOnly
        self.isNone = isNone
    }
}

nonisolated public struct UnblockModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let generichide = UnblockModifiers(rawValue: 1 << 0)
    public static let specifichide = UnblockModifiers(rawValue: 1 << 1)
    // elemhide implies both of the above; ContentBlockerRuleSet treats it that way.
    public static let elemhide = UnblockModifiers(rawValue: 1 << 2)
    public static let genericblock = UnblockModifiers(rawValue: 1 << 3)

    public static let allCosmetic: UnblockModifiers = [.generichide, .specifichide, .elemhide]

    static let optionAliases: [String: UnblockModifiers] = [
        "generichide": .generichide,
        "specifichide": .specifichide,
        "elemhide": .elemhide,
        "genericblock": .genericblock,
    ]
}

// MARK: - Compiled network rule

nonisolated struct NetworkFilterRule: Sendable {

    enum Anchor: UInt8, Sendable {
        case none
        case hostname
        case start
    }

    enum Body: Sendable {
        case segments([[UInt8]])
        case regex(NSRegularExpression)
    }

    var body: Body
    var anchor: Anchor
    var anchoredRight: Bool
    var isException: Bool
    var isImportant: Bool
    var matchCase: Bool
    var resourceTypes: ContentBlockingResourceTypeSet
    var thirdParty: Bool?
    var includedDomains: [String]
    var excludedDomains: [String]
    var redirect: RedirectDirective? = nil
    var unblockModifiers: UnblockModifiers = []
    var token: UInt64?
    var source: String
    var listID: String
}

// MARK: - Compiled cosmetic rule

nonisolated struct CosmeticFilterRule: Sendable {
    var selector: String
    var includedDomains: [String]
    var excludedDomains: [String]
    var isException: Bool
}

// MARK: - Parser

nonisolated enum FilterListParser {

    struct Output {
        var network: [NetworkFilterRule] = []
        var cosmetic: [CosmeticFilterRule] = []
        var stats = ContentBlockingCompileStats()
    }

    private static let unsupportedOptionPrefixes = [
        "csp", "removeparam", "replace", "urltransform",
        "permissions", "header", "method", "to", "from", "denyallow", "badfilter",
        "inline-script",
        "inline-font", "empty", "mp4", "stealth", "cookie", "app", "network",
        "extension", "queryprune", "rewrite", "ipaddress",
    ]

    static func parse(_ text: String, listID: String) -> Output {
        var out = Output()
        text.enumerateLines { line, _ in
            out.stats.linesRead += 1
            parse(line: line, listID: listID, into: &out)
        }
        return out
    }

    private static func parse(line rawLine: String, listID: String, into out: inout Output) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        if line.hasPrefix("!") || line.hasPrefix("[Adblock") { return }

        if let cosmetic = parseCosmetic(line: line) {
            switch cosmetic {
            case .rule(let rule):
                if rule.isException {
                    out.stats.cosmeticExceptionRules += 1
                } else {
                    out.stats.cosmeticRules += 1
                }
                out.cosmetic.append(rule)
            case .unsupported:
                out.stats.unsupportedRules += 1
            }
            return
        }

        switch parseNetwork(line: line, listID: listID) {
        case .rule(let rule):
            if !rule.unblockModifiers.isEmpty {
                out.stats.unblockRules += 1
            } else if rule.redirect != nil {
                out.stats.redirectRules += 1
            } else if rule.isException {
                out.stats.exceptionRules += 1
            } else {
                out.stats.blockingRules += 1
            }
            out.network.append(rule)
        case .unsupported:
            out.stats.unsupportedRules += 1
        case .invalidRegex:
            out.stats.invalidRegexRules += 1
        case .notAFilter:
            break
        }
    }

    // MARK: Cosmetic

    private enum CosmeticResult {
        case rule(CosmeticFilterRule)
        case unsupported
    }

    private static func parseCosmetic(line: String) -> CosmeticResult? {
        guard let hashIndex = line.firstIndex(of: "#") else { return nil }
        var cursor = line.index(after: hashIndex)
        var isException = false
        var isProcedural = false

        if cursor < line.endIndex, line[cursor] == "@" {
            isException = true
            cursor = line.index(after: cursor)
        }
        if cursor < line.endIndex, line[cursor] == "?" || line[cursor] == "$" || line[cursor] == "%" {
            isProcedural = true
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex, line[cursor] == "#" else {
            return nil
        }
        let body = String(line[line.index(after: cursor)...])
        let domainPart = String(line[line.startIndex..<hashIndex])

        if isProcedural || body.hasPrefix("+js(") || body.isEmpty {
            return .unsupported
        }
        if body.contains(":has-text(") || body.contains(":matches-css")
            || body.contains(":xpath(") || body.contains(":upward(")
            || body.contains(":remove(") || body.contains(":style(") {
            return .unsupported
        }

        var included: [String] = []
        var excluded: [String] = []
        for entry in domainPart.split(separator: ",") where !entry.isEmpty {
            let name = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if name.hasPrefix("~") {
                excluded.append(String(name.dropFirst()))
            } else if !name.isEmpty {
                included.append(name)
            }
        }

        return .rule(CosmeticFilterRule(
            selector: body,
            includedDomains: included,
            excludedDomains: excluded,
            isException: isException
        ))
    }

    // MARK: Network

    private enum NetworkResult {
        case rule(NetworkFilterRule)
        case unsupported
        case invalidRegex
        case notAFilter
    }

    private static func parseNetwork(line rawLine: String, listID: String) -> NetworkResult {
        var line = rawLine
        var isException = false
        if line.hasPrefix("@@") {
            isException = true
            line = String(line.dropFirst(2))
        }

        var patternText = line
        var optionText: String?
        if let dollar = optionSeparatorIndex(in: line) {
            patternText = String(line[line.startIndex..<dollar])
            optionText = String(line[line.index(after: dollar)...])
        }
        if patternText.isEmpty && optionText == nil { return .notAFilter }

        var resourceTypes = ContentBlockingResourceTypeSet()
        var negatedTypes = ContentBlockingResourceTypeSet()
        var thirdParty: Bool?
        var matchCase = false
        var isImportant = false
        var included: [String] = []
        var excluded: [String] = []
        var redirect: RedirectDirective?
        var unblockModifiers: UnblockModifiers = []

        if let optionText {
            for option in splitOptions(optionText) {
                var name = option
                var negated = false
                if name.hasPrefix("~") {
                    negated = true
                    name = String(name.dropFirst())
                }
                let key = name.lowercased()

                if let equals = key.firstIndex(of: "=") {
                    let bare = String(key[key.startIndex..<equals])
                    if bare == "domain" {
                        let value = String(name[name.index(after: name.firstIndex(of: "=")!)...])
                        for entry in value.split(separator: "|") where !entry.isEmpty {
                            let domain = entry.lowercased()
                            if domain.hasPrefix("~") {
                                excluded.append(String(domain.dropFirst()))
                            } else {
                                included.append(domain)
                            }
                        }
                        continue
                    }
                    if bare == "redirect" || bare == "redirect-rule" {
                        let value = String(key[key.index(after: equals)...])
                        guard let directive = parseRedirect(
                            value,
                            isRuleOnly: bare == "redirect-rule",
                            onException: isException
                        ) else { return .unsupported }
                        if redirect != nil { return .unsupported }
                        redirect = directive
                        continue
                    }
                    if unsupportedOptionPrefixes.contains(bare) { return .unsupported }
                    return .unsupported
                }

                if let modifier = UnblockModifiers.optionAliases[key] {
                    guard isException, !negated else { return .unsupported }
                    unblockModifiers.insert(modifier)
                    continue
                }

                if let type = ContentBlockingResourceType.optionAliases[key] {
                    if negated { negatedTypes.insert(.init(type)) } else { resourceTypes.insert(.init(type)) }
                    continue
                }

                switch key {
                case "third-party", "3p":
                    thirdParty = !negated
                case "first-party", "1p":
                    thirdParty = negated
                case "match-case":
                    matchCase = !negated
                case "important":
                    isImportant = true
                case "all":
                    resourceTypes = .all
                case "popup":
                    if negated { negatedTypes.insert(.init(.document)) } else { resourceTypes.insert(.init(.document)) }
                case "redirect", "redirect-rule":
                    guard isException, !negated else { return .unsupported }
                    if redirect != nil { return .unsupported }
                    redirect = RedirectDirective(
                        token: "",
                        priority: 0,
                        isRuleOnly: key == "redirect-rule",
                        isNone: true
                    )
                case "":
                    continue
                default:
                    if unsupportedOptionPrefixes.contains(key) { return .unsupported }
                    return .unsupported
                }
            }
        }

        if redirect != nil && !unblockModifiers.isEmpty { return .unsupported }

        var effectiveTypes: ContentBlockingResourceTypeSet
        if resourceTypes.isEmpty {
            effectiveTypes = .all
        } else {
            effectiveTypes = resourceTypes
        }
        if !negatedTypes.isEmpty {
            effectiveTypes = ContentBlockingResourceTypeSet(
                rawValue: effectiveTypes.rawValue & ~negatedTypes.rawValue
            )
        }
        if effectiveTypes.isEmpty { return .unsupported }

        if patternText.count > 2, patternText.hasPrefix("/"), patternText.hasSuffix("/") {
            let source = String(patternText.dropFirst().dropLast())
            guard FilterRegexBounds.isSafe(source) else { return .invalidRegex }
            var options: NSRegularExpression.Options = []
            if !matchCase { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: source, options: options) else {
                return .invalidRegex
            }
            return .rule(NetworkFilterRule(
                body: .regex(regex),
                anchor: .none,
                anchoredRight: false,
                isException: isException,
                isImportant: isImportant,
                matchCase: matchCase,
                resourceTypes: effectiveTypes,
                thirdParty: thirdParty,
                includedDomains: included,
                excludedDomains: excluded,
                redirect: redirect,
                unblockModifiers: unblockModifiers,
                token: nil,
                source: rawLine,
                listID: listID
            ))
        }

        var anchor = NetworkFilterRule.Anchor.none
        var pattern = patternText
        if pattern.hasPrefix("||") {
            anchor = .hostname
            pattern = String(pattern.dropFirst(2))
        } else if pattern.hasPrefix("|") {
            anchor = .start
            pattern = String(pattern.dropFirst())
        }
        var anchoredRight = false
        if pattern.hasSuffix("|") && !pattern.hasSuffix("\\|") {
            anchoredRight = true
            pattern = String(pattern.dropLast())
        }
        if pattern.isEmpty { return .notAFilter }

        let normalised = matchCase ? pattern : pattern.lowercased()
        let segments = normalised
            .split(separator: "*", omittingEmptySubsequences: false)
            .map { Array($0.utf8) }

        // Refuse an all-wildcard pattern (blocks the whole web) unless
        // $domain= bounds it; that shape is how uBO writes most redirect rules.
        if segments.allSatisfy({ $0.isEmpty }) && anchor == .none && included.isEmpty {
            return .unsupported
        }

        let token = matchCase
            ? nil
            : FilterTokenizer.bestToken(
                forPattern: normalised,
                leftAnchored: anchor != .none,
                rightAnchored: anchoredRight
            )

        return .rule(NetworkFilterRule(
            body: .segments(segments),
            anchor: anchor,
            anchoredRight: anchoredRight,
            isException: isException,
            isImportant: isImportant,
            matchCase: matchCase,
            resourceTypes: effectiveTypes,
            thirdParty: thirdParty,
            includedDomains: included,
            excludedDomains: excluded,
            redirect: redirect,
            unblockModifiers: unblockModifiers,
            token: token,
            source: rawLine,
            listID: listID
        ))
    }

    // A $redirect= whose token this build cannot serve must drop the whole
    // rule (nil), not fall through to a plain block.
    private static func parseRedirect(
        _ value: String,
        isRuleOnly: Bool,
        onException: Bool
    ) -> RedirectDirective? {
        var token = value
        var priority = 0
        if let colon = value.lastIndex(of: ":"),
           case let suffix = String(value[value.index(after: colon)...]),
           !suffix.isEmpty,
           let parsed = Int(suffix) {
            token = String(value[value.startIndex..<colon])
            priority = parsed
        }
        if token.isEmpty {
            guard onException else { return nil }
            return RedirectDirective(token: "", priority: priority, isRuleOnly: isRuleOnly, isNone: true)
        }

        let isNone = RedirectResourceLibrary.isNoRedirectToken(token)
        if !onException && !isNone && RedirectResourceLibrary.substitution(for: token) == nil {
            return nil
        }
        return RedirectDirective(
            token: isNone ? RedirectResourceLibrary.noRedirectToken : token.lowercased(),
            priority: priority,
            isRuleOnly: isRuleOnly,
            isNone: isNone || onException
        )
    }

    private static func optionSeparatorIndex(in line: String) -> String.Index? {
        let chars = Array(line)
        guard !chars.isEmpty else { return nil }
        var searchStart = 0
        if chars[0] == "/" {
            var i = chars.count - 1
            while i > 0 {
                if chars[i] == "/" { break }
                i -= 1
            }
            if i > 0 { searchStart = i }
        }
        var i = chars.count - 1
        while i >= searchStart {
            if chars[i] == "$" {
                if i + 1 < chars.count {
                    return line.index(line.startIndex, offsetBy: i)
                }
            }
            i -= 1
        }
        return nil
    }

    private static func splitOptions(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
    }
}
