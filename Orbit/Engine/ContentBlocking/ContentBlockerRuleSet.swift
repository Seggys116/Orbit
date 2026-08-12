import Foundation

nonisolated public struct ContentBlockerRuleSet: Sendable {

    private var blockingByToken: [UInt64: [Int]] = [:]
    private var blockingUntokenized: [Int] = []
    private var blocking: [NetworkFilterRule] = []

    private var exceptionByToken: [UInt64: [Int]] = [:]
    private var exceptionUntokenized: [Int] = []
    private var exceptions: [NetworkFilterRule] = []

    // A $redirect= rule appears both here and in blocking; $redirect-rule=
    // appears only here.
    private var redirectByToken: [UInt64: [Int]] = [:]
    private var redirectUntokenized: [Int] = []
    private var redirects: [NetworkFilterRule] = []

    private var redirectExceptions: [NetworkFilterRule] = []
    private var cosmeticUnblockRules: [NetworkFilterRule] = []
    private var genericBlockRules: [NetworkFilterRule] = []

    private var distinctNetworkRuleCount = 0

    private var genericCosmetic: [String] = []
    private var cosmeticByDomain: [String: [CosmeticFilterRule]] = [:]
    private var cosmeticExceptionsByDomain: [String: [CosmeticFilterRule]] = [:]
    private var genericCosmeticExclusions: [(selector: String, domains: [String])] = []

    private var genericCosmeticDefault: [String] = []
    private var cosmeticCache = CosmeticSelectorCache()

    public private(set) var stats = ContentBlockingCompileStats()
    public private(set) var listIDs: [String] = []

    public init() {}

    // MARK: - Building

    public mutating func add(listText: String, listID: String) {
        add(parsed: FilterListParser.parse(listText, listID: listID), listID: listID)
    }

    mutating func add(parsed: FilterListParser.Output, listID: String) {
        stats = stats + parsed.stats
        if !listIDs.contains(listID) { listIDs.append(listID) }

        for rule in parsed.network {
            distinctNetworkRuleCount += 1

            if !rule.unblockModifiers.isEmpty {
                if rule.unblockModifiers.contains(.genericblock) {
                    genericBlockRules.append(rule)
                }
                if !rule.unblockModifiers.intersection(.allCosmetic).isEmpty {
                    cosmeticUnblockRules.append(rule)
                }
                continue
            }

            // 2. Redirects.
            if let redirect = rule.redirect {
                if rule.isException {
                    redirectExceptions.append(rule)
                    continue
                }
                let index = redirects.count
                redirects.append(rule)
                if let token = rule.token {
                    redirectByToken[token, default: []].append(index)
                } else {
                    redirectUntokenized.append(index)
                }
                if redirect.isRuleOnly { continue }
            }

            if rule.isException {
                let index = exceptions.count
                exceptions.append(rule)
                if let token = rule.token {
                    exceptionByToken[token, default: []].append(index)
                } else {
                    exceptionUntokenized.append(index)
                }
            } else {
                let index = blocking.count
                blocking.append(rule)
                if let token = rule.token {
                    blockingByToken[token, default: []].append(index)
                } else {
                    blockingUntokenized.append(index)
                }
            }
        }

        for rule in parsed.cosmetic {
            if rule.isException {
                for domain in rule.includedDomains {
                    cosmeticExceptionsByDomain[domain, default: []].append(rule)
                }
            } else if rule.includedDomains.isEmpty {
                if rule.excludedDomains.isEmpty {
                    genericCosmetic.append(rule.selector)
                } else {
                    genericCosmeticExclusions.append((rule.selector, rule.excludedDomains))
                }
            } else {
                for domain in rule.includedDomains {
                    cosmeticByDomain[domain, default: []].append(rule)
                }
            }
        }

        genericCosmeticDefault = Self.computeGenericSelectors(
            generic: genericCosmetic,
            exclusions: genericCosmeticExclusions,
            exempted: [],
            suffixes: []
        )
        cosmeticCache = CosmeticSelectorCache()
    }

    // MARK: - Introspection

    public var networkRuleCount: Int { distinctNetworkRuleCount }
    public var cosmeticRuleCount: Int { stats.cosmeticRules }
    public var untokenizedRuleCount: Int { blockingUntokenized.count + exceptionUntokenized.count }

    // MARK: - Matching

    public func decision(
        forURL urlString: String,
        documentURL documentURLString: String,
        resourceType: ContentBlockingResourceType
    ) -> ContentBlockingDecision {
        let urlBytes = Self.lowercasedUTF8Bytes(of: urlString)
        let originalBytes = Array(urlString.utf8)
        let hostBoundaries = Self.hostBoundaries(in: urlBytes)

        let documentHost = ContentBlockingURL.host(ofURLString: documentURLString)
        let requestHost = ContentBlockingURL.host(ofURLString: urlString)
        let isThirdParty = Self.isThirdParty(requestHost: requestHost, documentHost: documentHost)

        let tokens = FilterTokenizer.tokens(forURLBytes: urlBytes)

        func findBlock(skipGenericRules: Bool) -> NetworkFilterRule? {
            var matchedBlock: NetworkFilterRule?

            func consider(_ indices: [Int]) -> Bool {
                for index in indices {
                    let rule = blocking[index]
                    if skipGenericRules && rule.includedDomains.isEmpty { continue }
                    guard matches(rule, urlBytes: urlBytes, originalBytes: originalBytes,
                                  hostBoundaries: hostBoundaries, urlString: urlString,
                                  documentHost: documentHost, isThirdParty: isThirdParty,
                                  resourceType: resourceType) else { continue }
                    if rule.isImportant {
                        matchedBlock = rule
                        return true  // stop everything
                    }
                    if matchedBlock == nil { matchedBlock = rule }
                }
                return false
            }

            var finished = false
            for token in tokens {
                guard let bucket = blockingByToken[token] else { continue }
                if consider(bucket) { finished = true; break }
            }
            if !finished { _ = consider(blockingUntokenized) }
            return matchedBlock
        }

        var matchedBlock = findBlock(skipGenericRules: false)
        if let candidate = matchedBlock,
           candidate.includedDomains.isEmpty,
           !genericBlockRules.isEmpty,
           unblockModifiers(forDocumentURL: documentURLString).contains(.genericblock) {
            matchedBlock = findBlock(skipGenericRules: true)
        }

        guard let blockRule = matchedBlock else { return .allow }

        // $important skips the exception pass, not the redirect pass.
        if blockRule.isImportant {
            return refusal(
                for: blockRule,
                urlBytes: urlBytes, originalBytes: originalBytes, hostBoundaries: hostBoundaries,
                urlString: urlString, documentHost: documentHost,
                isThirdParty: isThirdParty, resourceType: resourceType, tokens: tokens
            )
        }

        for token in tokens {
            guard let bucket = exceptionByToken[token] else { continue }
            for index in bucket {
                let rule = exceptions[index]
                if matches(rule, urlBytes: urlBytes, originalBytes: originalBytes, hostBoundaries: hostBoundaries,
                           urlString: urlString,
                           documentHost: documentHost, isThirdParty: isThirdParty, resourceType: resourceType) {
                    return .exempted(rule: rule.source, listID: rule.listID)
                }
            }
        }
        for index in exceptionUntokenized {
            let rule = exceptions[index]
            if matches(rule, urlBytes: urlBytes, originalBytes: originalBytes, hostBoundaries: hostBoundaries,
                       urlString: urlString,
                       documentHost: documentHost, isThirdParty: isThirdParty, resourceType: resourceType) {
                return .exempted(rule: rule.source, listID: rule.listID)
            }
        }

        return refusal(
            for: blockRule,
            urlBytes: urlBytes, originalBytes: originalBytes, hostBoundaries: hostBoundaries,
            urlString: urlString, documentHost: documentHost,
            isThirdParty: isThirdParty, resourceType: resourceType, tokens: tokens
        )
    }

    // MARK: - Redirects

    // Highest :priority wins among matching redirect directives; ties go to
    // the first found.
    private func refusal(
        for blockRule: NetworkFilterRule,
        urlBytes: [UInt8],
        originalBytes: [UInt8],
        hostBoundaries: [Int],
        urlString: String,
        documentHost: String?,
        isThirdParty: Bool,
        resourceType: ContentBlockingResourceType,
        tokens: [UInt64]
    ) -> ContentBlockingDecision {
        let cancelled = ContentBlockingDecision.block(rule: blockRule.source, listID: blockRule.listID)
        guard !redirects.isEmpty else { return cancelled }

        var winner: NetworkFilterRule?
        func consider(_ indices: [Int]) {
            for index in indices {
                let rule = redirects[index]
                guard let directive = rule.redirect else { continue }
                guard matches(rule, urlBytes: urlBytes, originalBytes: originalBytes,
                              hostBoundaries: hostBoundaries, urlString: urlString,
                              documentHost: documentHost, isThirdParty: isThirdParty,
                              resourceType: resourceType) else { continue }
                if let current = winner?.redirect, current.priority >= directive.priority { continue }
                winner = rule
            }
        }
        for token in tokens {
            if let bucket = redirectByToken[token] { consider(bucket) }
        }
        consider(redirectUntokenized)

        guard let winner, let directive = winner.redirect, !directive.isNone else { return cancelled }

        for rule in redirectExceptions {
            if matches(rule, urlBytes: urlBytes, originalBytes: originalBytes,
                       hostBoundaries: hostBoundaries, urlString: urlString,
                       documentHost: documentHost, isThirdParty: isThirdParty,
                       resourceType: resourceType) {
                return cancelled
            }
        }

        guard let substitution = RedirectResourceLibrary.substitution(for: directive.token) else {
            return cancelled
        }
        return .redirect(rule: winner.source, listID: winner.listID, substitution: substitution)
    }

    // MARK: - Cosmetic filtering

    func unblockModifiers(forDocumentURL documentURLString: String) -> UnblockModifiers {
        var result: UnblockModifiers = []
        guard !cosmeticUnblockRules.isEmpty || !genericBlockRules.isEmpty else { return result }

        let urlBytes = Self.lowercasedUTF8Bytes(of: documentURLString)
        let originalBytes = Array(documentURLString.utf8)
        let hostBoundaries = Self.hostBoundaries(in: urlBytes)
        let host = ContentBlockingURL.host(ofURLString: documentURLString)

        func scan(_ rules: [NetworkFilterRule]) {
            for rule in rules {
                guard matches(rule, urlBytes: urlBytes, originalBytes: originalBytes,
                              hostBoundaries: hostBoundaries, urlString: documentURLString,
                              documentHost: host, isThirdParty: false, resourceType: .document)
                else { continue }
                result.formUnion(rule.unblockModifiers)
            }
        }
        scan(cosmeticUnblockRules)
        scan(genericBlockRules)
        return result
    }

    public func cosmeticSelectors(forHost host: String) -> [String] {
        cosmeticSelectors(forDocumentURL: "https://\(host)/")
    }

    public func cosmeticSelectors(forDocumentURL documentURLString: String) -> [String] {
        guard let context = cosmeticContext(forDocumentURL: documentURLString) else { return [] }
        return cachedSelectors(for: context)
    }

    public func cosmeticStyleSheet(forDocumentURL documentURLString: String) -> String {
        guard let context = cosmeticContext(forDocumentURL: documentURLString) else { return "" }
        if context.cacheable, let cached = cosmeticCache.styleSheet(forHost: context.host) {
            return cached
        }
        let css = Self.chunkedCSS(cachedSelectors(for: context))
        if context.cacheable {
            cosmeticCache.storeStyleSheet(css, forHost: context.host)
        }
        return css
    }

    private func cachedSelectors(for context: CosmeticContext) -> [String] {
        if context.cacheable, let cached = cosmeticCache.selectors(forHost: context.host) {
            return cached
        }
        let computed = selectors(for: context)
        if context.cacheable {
            cosmeticCache.storeSelectors(computed, forHost: context.host)
        }
        return computed
    }

    private struct CosmeticContext {
        let host: String
        let suffixes: [String]
        let skipGeneric: Bool
        let skipSpecific: Bool
        let exempted: Set<String>

        var cacheable: Bool { !skipGeneric && !skipSpecific }
    }

    private func cosmeticContext(forDocumentURL documentURLString: String) -> CosmeticContext? {
        let host = ContentBlockingURL.host(ofURLString: documentURLString) ?? documentURLString
        let modifiers = unblockModifiers(forDocumentURL: documentURLString)

        // $elemhide is the union of $generichide and $specifichide.
        if modifiers.contains(.elemhide) { return nil }
        let skipGeneric = modifiers.contains(.generichide)
        let skipSpecific = modifiers.contains(.specifichide)
        if skipGeneric && skipSpecific { return nil }

        let suffixes = ContentBlockingURL.domainSuffixes(of: host)
        var exempted = Set<String>()
        for suffix in suffixes {
            for rule in cosmeticExceptionsByDomain[suffix] ?? [] {
                exempted.insert(rule.selector)
            }
        }

        return CosmeticContext(
            host: host,
            suffixes: suffixes,
            skipGeneric: skipGeneric,
            skipSpecific: skipSpecific,
            exempted: exempted
        )
    }

    private func selectors(for context: CosmeticContext) -> [String] {
        var selectors: [String] = []
        var seen = Set<String>()

        if !context.skipGeneric {
            for selector in genericSelectors(for: context) {
                if seen.insert(selector).inserted { selectors.append(selector) }
            }
        }
        if !context.skipSpecific {
            for suffix in context.suffixes {
                for rule in cosmeticByDomain[suffix] ?? [] {
                    if context.exempted.contains(rule.selector) { continue }
                    if rule.excludedDomains.contains(where: { context.suffixes.contains($0) }) { continue }
                    if seen.insert(rule.selector).inserted { selectors.append(rule.selector) }
                }
            }
        }
        return selectors
    }

    private func genericSelectors(for context: CosmeticContext) -> [String] {
        let matchesException = !context.exempted.isEmpty
        let matchesExclusion = genericCosmeticExclusions.contains { entry in
            entry.domains.contains { context.suffixes.contains($0) }
        }
        guard matchesException || matchesExclusion else { return genericCosmeticDefault }

        if let cached = cosmeticCache.genericSelectors(forHost: context.host) {
            return cached
        }
        let computed = Self.computeGenericSelectors(
            generic: genericCosmetic,
            exclusions: genericCosmeticExclusions,
            exempted: context.exempted,
            suffixes: context.suffixes
        )
        cosmeticCache.storeGenericSelectors(computed, forHost: context.host)
        return computed
    }

    private static func computeGenericSelectors(
        generic: [String],
        exclusions: [(selector: String, domains: [String])],
        exempted: Set<String>,
        suffixes: [String]
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for selector in generic where !exempted.contains(selector) {
            if seen.insert(selector).inserted { result.append(selector) }
        }
        for entry in exclusions where !exempted.contains(entry.selector) {
            let excluded = entry.domains.contains { suffixes.contains($0) }
            if excluded { continue }
            if seen.insert(entry.selector).inserted { result.append(entry.selector) }
        }
        return result
    }

    // 256 selectors per rule: one pathological selector must not take a whole
    // rule down with it (browsers drop an entire selector list on a parse error).
    private static func chunkedCSS(_ selectors: [String]) -> String {
        guard !selectors.isEmpty else { return "" }
        var css = ""
        for chunk in stride(from: 0, to: selectors.count, by: 256) {
            let slice = selectors[chunk..<min(chunk + 256, selectors.count)]
            css += slice.joined(separator: ",\n") + " { display: none !important; }\n"
        }
        return css
    }

    // Reference type: every value-copy of the owning ContentBlockerRuleSet
    // shares one memo. Its own lock since filled lazily by whichever thread
    // (the engine's IO thread, or the main actor) asks about a host first.
    private final class CosmeticSelectorCache: @unchecked Sendable {
        private let lock = NSLock()
        private var genericSelectorsByHost: [String: [String]] = [:]
        private var selectorsByHost: [String: [String]] = [:]
        private var styleSheetByHost: [String: String] = [:]

        func genericSelectors(forHost host: String) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return genericSelectorsByHost[host]
        }

        func storeGenericSelectors(_ selectors: [String], forHost host: String) {
            lock.lock()
            genericSelectorsByHost[host] = selectors
            lock.unlock()
        }

        func selectors(forHost host: String) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return selectorsByHost[host]
        }

        func storeSelectors(_ selectors: [String], forHost host: String) {
            lock.lock()
            selectorsByHost[host] = selectors
            lock.unlock()
        }

        func styleSheet(forHost host: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return styleSheetByHost[host]
        }

        func storeStyleSheet(_ css: String, forHost host: String) {
            lock.lock()
            styleSheetByHost[host] = css
            lock.unlock()
        }
    }

    // MARK: - Rule evaluation

    private func matches(
        _ rule: NetworkFilterRule,
        urlBytes: [UInt8],
        originalBytes: [UInt8],
        hostBoundaries: [Int],
        urlString: String,
        documentHost: String?,
        isThirdParty: Bool,
        resourceType: ContentBlockingResourceType
    ) -> Bool {
        guard rule.resourceTypes.contains(resourceType) else { return false }
        if let required = rule.thirdParty, required != isThirdParty { return false }

        if !rule.includedDomains.isEmpty {
            guard let documentHost,
                  rule.includedDomains.contains(where: { ContentBlockingURL.host(documentHost, matchesDomain: $0) })
            else { return false }
        }
        if !rule.excludedDomains.isEmpty, let documentHost {
            if rule.excludedDomains.contains(where: { ContentBlockingURL.host(documentHost, matchesDomain: $0) }) {
                return false
            }
        }

        switch rule.body {
        case .regex(let regex):
            let subject = urlString
            let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
            return regex.firstMatch(in: subject, options: [], range: range) != nil

        case .segments(let segments):
            let haystack = rule.matchCase ? originalBytes : urlBytes
            return Self.matchSegments(
                segments,
                in: haystack,
                anchor: rule.anchor,
                anchoredRight: rule.anchoredRight,
                hostBoundaries: hostBoundaries
            )
        }
    }

    // MARK: - Pattern matching primitives

    // Falls back to string.lowercased().utf8 on any non-ASCII byte: full
    // Unicode case folding can change the output byte count (e.g. Turkish
    // İ), which the fast ASCII path below cannot represent.
    static func lowercasedUTF8Bytes(of string: String) -> [UInt8] {
        let utf8 = string.utf8
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count)
        for byte in utf8 {
            guard byte < 0x80 else { return Array(string.lowercased().utf8) }
            bytes.append(byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte)
        }
        return bytes
    }

    // ^ matches any character that is not a letter, digit, or one of _ - . %,
    // and also matches the end of the address.
    @inline(__always)
    static func isSeparator(_ byte: UInt8) -> Bool {
        if FilterTokenizer.isTokenByte(byte) { return false }
        if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") { return false }
        switch byte {
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "%"):
            return false
        default:
            return true
        }
    }

    static func hostBoundaries(in bytes: [UInt8]) -> [Int] {
        guard let schemeEnd = Self.find(Array("://".utf8), in: bytes, from: 0) else {
            return [0]
        }
        var hostStart = schemeEnd + 3
        var scan = hostStart
        var authorityEnd = bytes.count
        while scan < bytes.count {
            let byte = bytes[scan]
            if byte == UInt8(ascii: "/") || byte == UInt8(ascii: "?") || byte == UInt8(ascii: "#") {
                authorityEnd = scan
                break
            }
            scan += 1
        }
        for index in hostStart..<authorityEnd where bytes[index] == UInt8(ascii: "@") {
            hostStart = index + 1
        }

        var result = [hostStart]
        var index = hostStart
        while index < authorityEnd {
            if bytes[index] == UInt8(ascii: ".") && index + 1 < authorityEnd {
                result.append(index + 1)
            }
            index += 1
        }
        return result
    }

    static func matchSegments(
        _ segments: [[UInt8]],
        in bytes: [UInt8],
        anchor: NetworkFilterRule.Anchor,
        anchoredRight: Bool,
        hostBoundaries: [Int]
    ) -> Bool {
        let starts: [Int]
        switch anchor {
        case .start:
            starts = [0]
        case .hostname:
            starts = hostBoundaries
        case .none:
            starts = []
        }

        if anchor == .none {
            return matchSegments(segments, in: bytes, from: nil, anchoredRight: anchoredRight)
        }
        for start in starts {
            if matchSegments(segments, in: bytes, from: start, anchoredRight: anchoredRight) {
                return true
            }
        }
        return false
    }

    private static func matchSegments(
        _ segments: [[UInt8]],
        in bytes: [UInt8],
        from anchoredStart: Int?,
        anchoredRight: Bool
    ) -> Bool {
        guard !segments.isEmpty else { return true }

        var index = 0
        var cursor: Int
        if let anchoredStart {
            if segments[0].isEmpty {
                cursor = anchoredStart
                index = 1
                return matchRemaining(segments, from: index, in: bytes, cursor: cursor,
                                      anchoredRight: anchoredRight, floating: true)
            }
            guard matchLiteral(segments[0], in: bytes, at: anchoredStart) else { return false }
            cursor = anchoredStart + segments[0].count
            index = 1
        } else {
            if segments[0].isEmpty {
                cursor = 0
                index = 1
                return matchRemaining(segments, from: index, in: bytes, cursor: cursor,
                                      anchoredRight: anchoredRight, floating: true)
            }
            guard let found = findLiteral(segments[0], in: bytes, from: 0) else { return false }
            var searchFrom = found
            while true {
                let after = searchFrom + segments[0].count
                if matchRemaining(segments, from: 1, in: bytes, cursor: after,
                                  anchoredRight: anchoredRight, floating: true) {
                    return true
                }
                guard let next = findLiteral(segments[0], in: bytes, from: searchFrom + 1) else { return false }
                searchFrom = next
            }
        }

        return matchRemaining(segments, from: index, in: bytes, cursor: cursor,
                              anchoredRight: anchoredRight, floating: true)
    }

    private static func matchRemaining(
        _ segments: [[UInt8]],
        from index: Int,
        in bytes: [UInt8],
        cursor: Int,
        anchoredRight: Bool,
        floating: Bool
    ) -> Bool {
        if index >= segments.count {
            return anchoredRight ? cursor == bytes.count : true
        }
        let segment = segments[index]
        if segment.isEmpty {
            if index == segments.count - 1 {
                return true
            }
            return matchRemaining(segments, from: index + 1, in: bytes, cursor: cursor,
                                  anchoredRight: anchoredRight, floating: true)
        }

        let isLast = index == segments.count - 1
        if isLast && anchoredRight {
            let start = bytes.count - segment.count
            guard start >= cursor else { return false }
            return matchLiteral(segment, in: bytes, at: start)
        }

        var from = cursor
        while let found = findLiteral(segment, in: bytes, from: from) {
            if matchRemaining(segments, from: index + 1, in: bytes, cursor: found + segment.count,
                              anchoredRight: anchoredRight, floating: true) {
                return true
            }
            from = found + 1
        }
        return false
    }

    @inline(__always)
    private static func matchLiteral(_ segment: [UInt8], in bytes: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0 else { return false }
        var i = 0
        while i < segment.count {
            let expected = segment[i]
            let position = offset + i
            if expected == UInt8(ascii: "^") {
                if position == bytes.count {
                    return i == segment.count - 1
                }
                guard position < bytes.count, isSeparator(bytes[position]) else { return false }
            } else {
                guard position < bytes.count, bytes[position] == expected else { return false }
            }
            i += 1
        }
        return true
    }

    private static func findLiteral(_ segment: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard from <= bytes.count else { return nil }
        if segment.isEmpty { return from }
        // ^ at the end may match end-of-string; allow one position past the last full-width placement.
        let last = bytes.count - segment.count + (segment.last == UInt8(ascii: "^") ? 1 : 0)
        guard last >= from else { return nil }
        var offset = from
        while offset <= last {
            if matchLiteral(segment, in: bytes, at: offset) { return offset }
            offset += 1
        }
        return nil
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var offset = from
        let last = haystack.count - needle.count
        while offset <= last {
            var i = 0
            while i < needle.count && haystack[offset + i] == needle[i] { i += 1 }
            if i == needle.count { return offset }
            offset += 1
        }
        return nil
    }

    // MARK: - Third-party determination

    // Uses "last two labels", not the Public Suffix List: treats a.co.uk and
    // b.co.uk as the same party.
    static func isThirdParty(requestHost: String?, documentHost: String?) -> Bool {
        guard let requestHost, let documentHost else { return false }
        return baseDomain(of: requestHost) != baseDomain(of: documentHost)
    }

    static func baseDomain(of host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }
}
