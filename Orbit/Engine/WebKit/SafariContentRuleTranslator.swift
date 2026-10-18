import Foundation

nonisolated enum SafariContentRuleTranslator {

    static let maximumRulesPerList = 40_000
    static let maximumRedirectPayload = 96 * 1024

    private static let hostAnchorPrefix = "^[^:]+://+([^/]+\\.)?"
    private static let separatorClass = "[/:?&=#]"

    // MARK: Entry points

    static func translate(_ ruleSet: ContentBlockerRuleSet, capabilities: SafariRuleCapabilities) -> SafariTranslation {
        var out = SafariTranslation()
        var tally = Tally()
        var seenBlocks = Set<SafariRule>()
        var seenExceptions = Set<SafariRule>()
        var seenImportant = Set<SafariRule>()
        var seenGenericIgnores = Set<SafariRule>()
        var seenSpecificIgnores = Set<SafariRule>()

        func consume(_ rule: NetworkFilterRule) {
            if !rule.unblockModifiers.isEmpty {
                let produced = hideExceptionRules(for: rule, capabilities: capabilities, tally: &tally)
                let affectsGeneric = !rule.unblockModifiers.intersection([.generichide, .elemhide]).isEmpty
                let affectsSpecific = !rule.unblockModifiers.intersection([.specifichide, .elemhide]).isEmpty
                for item in produced {
                    if affectsGeneric, seenGenericIgnores.insert(item).inserted { out.genericHideIgnores.append(item) }
                    if affectsSpecific, seenSpecificIgnores.insert(item).inserted { out.specificHideIgnores.append(item) }
                }
                return
            }
            for item in networkRules(for: rule, capabilities: capabilities, tally: &tally) {
                if rule.isException {
                    if seenExceptions.insert(item).inserted { out.exceptions.append(item) }
                } else if rule.isImportant {
                    if seenImportant.insert(item).inserted { out.important.append(item) }
                } else if seenBlocks.insert(item).inserted {
                    out.blocks.append(item)
                }
            }
        }
        ruleSet.forEachNetworkRuleForTranslation(consume)

        let cosmetic = cosmeticRules(from: ruleSet.cosmeticRulesForTranslation, tally: &tally)
        out.genericCosmetic = cosmetic.generic
        out.specificCosmetic = cosmetic.specific

        out.report.networkRules = out.blocks.count + out.exceptions.count + out.important.count
        out.report.cosmeticRules = out.genericCosmetic.count + out.specificCosmetic.count
        out.report.skippedRegexRules = tally.skippedRegex
        out.report.skippedUnsupportedRules = tally.skipped.values.reduce(0, +)
        out.report.redirectStubs = tally.redirectStubs
        out.report.redirectsBlockedInstead = tally.redirectsBlockedInstead
        out.report.parserUnsupportedRules = ruleSet.stats.unsupportedRules
        out.report.parserInvalidRegexRules = ruleSet.stats.invalidRegexRules
        for (reason, count) in tally.skipped.sorted(by: { $0.key < $1.key }) {
            out.report.note("Skipped \(count) rule(s): \(reason)")
        }
        if tally.skippedRegex > 0 {
            out.report.note("Skipped \(tally.skippedRegex) regex filter(s) outside WebKit's supported regex subset")
        }
        if ruleSet.stats.unsupportedRules > 0 {
            out.report.note("Parser left out \(ruleSet.stats.unsupportedRules) rule(s) (scriptlets, procedural cosmetics and unsupported options)")
        }
        return out
    }

    static func json(_ rules: [SafariRule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Network rules

    private struct Tally {
        var skipped: [String: Int] = [:]
        var skippedRegex = 0
        var redirectStubs = 0
        var redirectsBlockedInstead = 0

        mutating func skip(_ reason: String) { skipped[reason, default: 0] += 1 }
    }

    static func networkRules(for rule: NetworkFilterRule, capabilities: SafariRuleCapabilities) -> [SafariRule] {
        var tally = Tally()
        return networkRules(for: rule, capabilities: capabilities, tally: &tally)
    }

    private static func networkRules(
        for rule: NetworkFilterRule,
        capabilities: SafariRuleCapabilities,
        tally: inout Tally
    ) -> [SafariRule] {
        let action: SafariRule.Action
        if let redirect = rule.redirect {
            if rule.isException {
                tally.skip("redirect exceptions have no WebKit equivalent")
                return []
            }
            if redirect.isRuleOnly {
                tally.skip("$redirect-rule applies only to requests another rule blocked")
                return []
            }
            action = redirectAction(for: rule, directive: redirect, capabilities: capabilities, tally: &tally)
        } else {
            action = rule.isException ? .ignorePreviousRules : .block
        }

        let filters: [String]
        switch urlFilters(for: rule) {
        case .filters(let values): filters = values
        case .unsupportedRegex:
            tally.skippedRegex += 1
            return []
        case .unsupported(let reason):
            tally.skip(reason)
            return []
        }

        guard let domains = domainRestriction(included: rule.includedDomains, excluded: rule.excludedDomains) else {
            tally.skip("domain list WebKit cannot express")
            return []
        }

        var produced: [SafariRule] = []
        for filter in filters {
            var trigger = SafariRule.Trigger(urlFilter: filter)
            trigger.caseSensitive = rule.matchCase ? true : nil
            trigger.loadType = rule.thirdParty.map { [$0 ? "third-party" : "first-party"] }
            trigger.ifDomain = domains.ifDomain
            trigger.unlessDomain = domains.unlessDomain
            let triggers = typedTriggers(from: trigger, types: rule.resourceTypes, capabilities: capabilities)
            if triggers.isEmpty {
                tally.skip("resource types WebKit cannot match")
                return []
            }
            for item in triggers { produced.append(SafariRule(trigger: item, action: action)) }
        }
        return produced
    }

    private static func redirectAction(
        for rule: NetworkFilterRule,
        directive: RedirectDirective,
        capabilities: SafariRuleCapabilities,
        tally: inout Tally
    ) -> SafariRule.Action {
        // Same fallback as the decision path: a stub that cannot be served becomes a block.
        guard capabilities.redirect, !directive.isNone,
              let substitution = RedirectResourceLibrary.substitution(for: directive.token)
        else {
            tally.redirectsBlockedInstead += 1
            return .block
        }
        let url: String
        switch substitution {
        case .resource(let resource):
            guard resource.content.count <= maximumRedirectPayload else {
                tally.redirectsBlockedInstead += 1
                return .block
            }
            url = "data:\(resource.mimeType);base64,\(Data(resource.content).base64EncodedString())"
        case .empty:
            let types = rule.resourceTypes.types
            let type: ContentBlockingResourceType = types.count == 1 ? types[0] : .other
            url = "data:\(RedirectResourceLibrary.mimeTypeForEmptyStub(resourceType: type)),"
        }
        tally.redirectStubs += 1
        return SafariRule.Action(type: "redirect", redirectURL: url)
    }

    // MARK: Resource types

    private static func typedTriggers(
        from base: SafariRule.Trigger,
        types: ContentBlockingResourceTypeSet,
        capabilities: SafariRuleCapabilities
    ) -> [SafariRule.Trigger] {
        if types == .all { return [base] }

        var triggers: [SafariRule.Trigger] = []
        var names: [String] = []
        for type in types.types where type != .document && type != .subdocument {
            for name in resourceTypeNames(for: type, capabilities: capabilities) where !names.contains(name) {
                names.append(name)
            }
        }
        if !names.isEmpty {
            var trigger = base
            trigger.resourceType = names
            triggers.append(trigger)
        }

        let document = types.contains(.document)
        let subdocument = types.contains(.subdocument)
        if document || subdocument {
            var trigger = base
            trigger.resourceType = ["document"]
            if document && subdocument {
                triggers.append(trigger)
            } else if capabilities.loadContext {
                trigger.loadContext = [document ? "top-frame" : "child-frame"]
                triggers.append(trigger)
            }
        }
        return triggers
    }

    static func resourceTypeNames(for type: ContentBlockingResourceType, capabilities: SafariRuleCapabilities) -> [String] {
        let candidates: [String]
        switch type {
        case .script: candidates = ["script"]
        case .image: candidates = ["image"]
        case .stylesheet: candidates = ["style-sheet"]
        case .font: candidates = ["font"]
        case .media: candidates = ["media"]
        case .xmlhttprequest: candidates = ["raw", "fetch"]
        case .ping, .csp_report: candidates = ["ping"]
        case .websocket: candidates = ["websocket"]
        case .object, .other: candidates = ["other"]
        case .document, .subdocument: candidates = []
        }
        let supported = candidates.filter { capabilities.resourceTypes.contains($0) }
        if supported.isEmpty, type == .other || type == .object, capabilities.resourceTypes.contains("raw") { return ["raw"] }
        return supported
    }

    // MARK: Domains

    // Entries are matched with subdomains, so each gets the "*" prefix.
    static func webKitDomain(_ domain: String) -> String? {
        let value = domain.lowercased()
        guard !value.isEmpty, !value.hasPrefix("."), !value.hasSuffix("."),
              value.utf8.allSatisfy({ byte in
                  (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2e || byte == 0x2d || byte == 0x5f
              })
        else { return nil }
        return "*" + value
    }

    // WebKit rejects a trigger with both lists, and a list it cannot fully express would widen the rule.
    static func domainRestriction(
        included: [String],
        excluded: [String]
    ) -> (ifDomain: [String]?, unlessDomain: [String]?)? {
        let ifDomain = included.compactMap { webKitDomain($0) }
        let unlessDomain = excluded.compactMap { webKitDomain($0) }
        if !included.isEmpty && ifDomain.isEmpty { return nil }
        if included.isEmpty {
            return (nil, unlessDomain.isEmpty ? nil : unlessDomain)
        }
        let conflicting = excluded.contains { exclusion in
            included.contains { ContentBlockingURL.host(exclusion.lowercased(), matchesDomain: $0.lowercased()) }
        }
        if conflicting { return nil }
        return (ifDomain, nil)
    }

    // MARK: URL filters

    enum FilterResult: Equatable {
        case filters([String])
        case unsupportedRegex
        case unsupported(String)
    }

    static func urlFilters(for rule: NetworkFilterRule) -> FilterResult {
        switch rule.body {
        case .regex(let regex):
            guard let converted = webKitRegex(from: regex.pattern, caseSensitive: rule.matchCase) else {
                return .unsupportedRegex
            }
            return .filters([converted])
        case .segments(let segments):
            return patternFilters(
                segments: segments,
                anchor: rule.anchor,
                anchoredRight: rule.anchoredRight
            )
        }
    }

    private static func patternFilters(
        segments: [[UInt8]],
        anchor: NetworkFilterRule.Anchor,
        anchoredRight: Bool
    ) -> FilterResult {
        let bytes = Array(segments.joined(separator: [UInt8(ascii: "*")]))
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else {
            return .unsupported("pattern WebKit cannot match (non-ASCII)")
        }
        let pattern = Array(String(decoding: bytes, as: UTF8.self))

        var body = ""
        var trailingSeparator = false
        // `||host/path` is the hostname, then the path. The port sits between them.
        var beforePath = anchor == .hostname
        for (index, character) in pattern.enumerated() {
            switch character {
            case "*":
                if !body.hasSuffix(".*") { body += ".*" }
            case "^":
                beforePath = false
                if index == pattern.count - 1 {
                    trailingSeparator = true
                } else {
                    body += separatorClass
                }
            case "/":
                if beforePath {
                    body += "(:[0-9]+)?"
                    beforePath = false
                }
                body += "/"
            case "?":
                beforePath = false
                body += escaped(character)
            default:
                body += escaped(character)
            }
        }
        let hostOnly = anchor == .hostname && !pattern.contains("/") && !pattern.contains("?")

        let prefix: String
        switch anchor {
        case .hostname: prefix = hostAnchorPrefix
        case .start: prefix = "^"
        case .none:
            prefix = ""
            if body.hasPrefix(".*") { body.removeFirst(2) }
        }
        if !anchoredRight, !trailingSeparator, body.hasSuffix(".*") { body.removeLast(2) }

        var filters: [String]
        if trailingSeparator && !anchoredRight {
            // The URL always carries a path separator after the host, so a bare host needs no end alternative.
            filters = [prefix + body + separatorClass]
            if !hostOnly { filters.append(prefix + body + "$") }
        } else {
            filters = [prefix + body + (anchoredRight || trailingSeparator ? "$" : "")]
        }
        return .filters(filters.map { $0.isEmpty ? ".*" : $0 })
    }

    private static func escaped(_ character: Character) -> String {
        "\\.+?()[]{}|$^".contains(character) ? "\\" + String(character) : String(character)
    }

    // WebKit's subset: literals, ".", classes and ranges, "*" "+" "?" on one atom or one group, "^" first, "$" last.
    static func webKitRegex(from source: String, caseSensitive: Bool) -> String? {
        guard !source.isEmpty, source.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        let chars = Array(source)
        var out = ""
        var index = 0
        var quantifiable = false
        var inGroup = false
        var groupHasContent = false

        func literal(_ character: Character) -> String {
            let value = caseSensitive ? character : Character(character.lowercased())
            return "\\.+?()[]{}|$^*".contains(value) ? "\\" + String(value) : String(value)
        }

        while index < chars.count {
            let character = chars[index]
            switch character {
            case "^":
                guard index == 0 else { return nil }
                out += "^"
            case "$":
                guard index == chars.count - 1, !inGroup else { return nil }
                out += "$"
                quantifiable = false
            case ".":
                out += "."
                quantifiable = true
                groupHasContent = true
            case "*", "+", "?":
                guard quantifiable else { return nil }
                if index + 1 < chars.count, "?+*".contains(chars[index + 1]) { return nil }
                out.append(character)
                quantifiable = false
            case "(":
                guard !inGroup else { return nil }
                if index + 1 < chars.count, chars[index + 1] == "?" { return nil }
                inGroup = true
                groupHasContent = false
                out += "("
                quantifiable = false
            case ")":
                guard inGroup, groupHasContent else { return nil }
                inGroup = false
                out += ")"
                quantifiable = true
            case "[":
                guard let (parsed, next) = parseClass(chars, from: index, caseSensitive: caseSensitive) else { return nil }
                out += parsed
                index = next
                quantifiable = true
                groupHasContent = true
                continue
            case "\\":
                guard index + 1 < chars.count else { return nil }
                let escapedCharacter = chars[index + 1]
                if escapedCharacter == "d" {
                    out += "[0-9]"
                } else if escapedCharacter == "w" {
                    out += caseSensitive ? "[a-zA-Z0-9_]" : "[a-z0-9_]"
                } else if escapedCharacter.isASCII, !escapedCharacter.isLetter, !escapedCharacter.isNumber {
                    out += "\\.+?()[]{}|$^*".contains(escapedCharacter) ? "\\" + String(escapedCharacter) : String(escapedCharacter)
                } else {
                    return nil
                }
                index += 2
                quantifiable = true
                groupHasContent = true
                continue
            case "|", "{", "}":
                return nil
            default:
                out += literal(character)
                quantifiable = true
                groupHasContent = true
            }
            index += 1
        }
        guard !inGroup else { return nil }
        return out
    }

    private static func parseClass(_ chars: [Character], from start: Int, caseSensitive: Bool) -> (String, Int)? {
        var index = start + 1
        var out = "["
        if index < chars.count, chars[index] == "^" {
            out += "^"
            index += 1
        }
        var items = 0
        while index < chars.count {
            let character = chars[index]
            switch character {
            case "]":
                guard items > 0 else { return nil }
                return (out + "]", index + 1)
            case "[":
                return nil
            case "\\":
                guard index + 1 < chars.count else { return nil }
                let escapedCharacter = chars[index + 1]
                if escapedCharacter == "d" {
                    out += "0-9"
                } else if escapedCharacter == "w" {
                    out += caseSensitive ? "a-zA-Z0-9_" : "a-z0-9_"
                } else if escapedCharacter.isASCII, !escapedCharacter.isLetter, !escapedCharacter.isNumber {
                    out += "\\]^-".contains(escapedCharacter) ? "\\" + String(escapedCharacter) : String(escapedCharacter)
                } else {
                    return nil
                }
                index += 2
            default:
                out += caseSensitive ? String(character) : character.lowercased()
                index += 1
            }
            items += 1
        }
        return nil
    }

    // MARK: Cosmetic rules

    private static func cosmeticRules(
        from rules: [CosmeticFilterRule],
        tally: inout Tally
    ) -> (generic: [SafariRule], specific: [SafariRule]) {
        var exemptions: [String: [CosmeticFilterRule]] = [:]
        for rule in rules where rule.isException {
            exemptions[rule.selector, default: []].append(rule)
        }

        var generic: [SafariRule] = []
        var specific: [SafariRule] = []
        var seen = Set<SafariRule>()

        outer: for rule in rules where !rule.isException {
            guard isUsableSelector(rule.selector) else {
                tally.skip("cosmetic selector WebKit cannot parse")
                continue
            }
            var included = rule.includedDomains
            var excluded = rule.excludedDomains
            let wasSpecific = !included.isEmpty

            // A #@# exception removes the selector from the pages it names: via unless-domain, or by dropping the rule.
            for exception in exemptions[rule.selector] ?? [] {
                if exception.includedDomains.isEmpty { continue outer }
                for domain in exception.includedDomains {
                    if included.isEmpty {
                        excluded.append(domain)
                    } else {
                        included.removeAll { ContentBlockingURL.host($0, matchesDomain: domain) }
                        if included.contains(where: { ContentBlockingURL.host(domain, matchesDomain: $0) }) {
                            tally.skip("cosmetic exception narrower than the rule's domain")
                            continue outer
                        }
                    }
                }
            }
            if wasSpecific && included.isEmpty { continue }

            guard let domains = domainRestriction(included: included, excluded: excluded) else {
                tally.skip("domain list WebKit cannot express")
                continue
            }
            var trigger = SafariRule.Trigger(urlFilter: ".*")
            trigger.ifDomain = domains.ifDomain
            trigger.unlessDomain = domains.unlessDomain
            let item = SafariRule(
                trigger: trigger,
                action: SafariRule.Action(type: "css-display-none", selector: rule.selector)
            )
            guard seen.insert(item).inserted else { continue }
            if wasSpecific { specific.append(item) } else { generic.append(item) }
        }
        return (generic, specific)
    }

    private static func hideExceptionRules(
        for rule: NetworkFilterRule,
        capabilities: SafariRuleCapabilities,
        tally: inout Tally
    ) -> [SafariRule] {
        if rule.unblockModifiers.intersection(.allCosmetic).isEmpty {
            tally.skip("$genericblock has no WebKit equivalent")
            return []
        }
        guard case .filters(let filters) = urlFilters(for: rule) else {
            tally.skip("hide exception pattern WebKit cannot match")
            return []
        }
        guard let domains = domainRestriction(included: rule.includedDomains, excluded: rule.excludedDomains) else {
            tally.skip("domain list WebKit cannot express")
            return []
        }
        return filters.map { filter in
            var trigger = SafariRule.Trigger(urlFilter: filter)
            trigger.caseSensitive = rule.matchCase ? true : nil
            trigger.ifDomain = domains.ifDomain
            trigger.unlessDomain = domains.unlessDomain
            return SafariRule(trigger: trigger, action: .ignorePreviousRules)
        }
    }

    static func isUsableSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= 4000 else { return false }
        var parentheses = 0
        var brackets = 0
        var quote: Character?
        for character in selector {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(": parentheses += 1
            case ")":
                parentheses -= 1
                if parentheses < 0 { return false }
            case "[": brackets += 1
            case "]":
                brackets -= 1
                if brackets < 0 { return false }
            case "{", "}", "\n": return false
            default: break
            }
        }
        return quote == nil && parentheses == 0 && brackets == 0
    }
}
