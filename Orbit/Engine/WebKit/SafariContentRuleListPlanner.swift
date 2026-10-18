import Foundation

nonisolated struct SafariRuleListPlan: Sendable {
    enum Kind: String, Sendable {
        case network
        case genericCosmetic = "generic-cosmetic"
        case specificCosmetic = "specific-cosmetic"
    }

    var kind: Kind
    var index: Int
    var rules: [SafariRule]
}

nonisolated struct SafariRulePlanSet: Sendable {
    var lists: [SafariRuleListPlan] = []
    var exceptionsDropped = 0
}

// MARK: - Planner

nonisolated extension SafariContentRuleTranslator {

    static func plan(
        _ translation: SafariTranslation,
        allowlist: Set<String>,
        maxRulesPerList: Int = maximumRulesPerList
    ) -> SafariRulePlanSet {
        var result = SafariRulePlanSet()
        let trailer = allowlistRule(for: allowlist)
        let reserved = trailer == nil ? 0 : 1

        let blockTotal = translation.blocks.count + translation.important.count
        if blockTotal > 0 {
            var exceptions = translation.exceptions
            // Exceptions only cancel rules in their own list, so each list carries all of them.
            let cap = max(1, maxRulesPerList / 2)
            if exceptions.count > cap {
                result.exceptionsDropped = exceptions.count - cap
                exceptions = Array(exceptions.prefix(cap))
            }
            let quota = max(1, maxRulesPerList - exceptions.count - reserved)
            var start = 0
            var index = 0
            while start < blockTotal {
                let end = min(start + quota, blockTotal)
                let blockEnd = min(end, translation.blocks.count)
                var count = exceptions.count + reserved
                if start < blockEnd { count += blockEnd - start }
                var importantRange: Range<Int>?
                if end > translation.blocks.count {
                    let from = max(start, translation.blocks.count) - translation.blocks.count
                    let to = end - translation.blocks.count
                    importantRange = from..<to
                    count += to - from
                }
                // One buffer for the slice, the shared exceptions, and the trailer.
                // Appending onto an exact slice copy reallocates and copies the slice again.
                var rules: [SafariRule] = []
                rules.reserveCapacity(count)
                if start < blockEnd { rules.append(contentsOf: translation.blocks[start..<blockEnd]) }
                rules.append(contentsOf: exceptions)
                if let importantRange { rules.append(contentsOf: translation.important[importantRange]) }
                if let trailer { rules.append(trailer) }
                result.lists.append(SafariRuleListPlan(kind: .network, index: index, rules: rules))
                start = end
                index += 1
            }
        }

        func appendCosmetic(_ kind: SafariRuleListPlan.Kind, _ rules: [SafariRule], ignores: [SafariRule]) {
            guard !rules.isEmpty else { return }
            let quota = max(1, maxRulesPerList - ignores.count - reserved)
            var start = 0
            var index = 0
            while start < rules.count {
                let end = min(start + quota, rules.count)
                var chunk: [SafariRule] = []
                chunk.reserveCapacity((end - start) + ignores.count + reserved)
                chunk.append(contentsOf: rules[start..<end])
                chunk.append(contentsOf: ignores)
                if let trailer { chunk.append(trailer) }
                result.lists.append(SafariRuleListPlan(kind: kind, index: index, rules: chunk))
                start = end
                index += 1
            }
        }
        appendCosmetic(.genericCosmetic, translation.genericCosmetic, ignores: translation.genericHideIgnores)
        appendCosmetic(.specificCosmetic, translation.specificCosmetic, ignores: translation.specificHideIgnores)
        return result
    }

    // The allowlist rule cancels every earlier rule in its list on those pages.
    static func allowlistRule(for hosts: Set<String>) -> SafariRule? {
        let domains = hosts.compactMap { webKitDomain($0) }.sorted()
        guard !domains.isEmpty else { return nil }
        return SafariRule(
            trigger: SafariRule.Trigger(urlFilter: ".*", ifDomain: domains),
            action: .ignorePreviousRules
        )
    }
}
