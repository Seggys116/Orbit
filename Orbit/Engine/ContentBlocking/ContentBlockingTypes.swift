import Foundation

// MARK: - Resource types

// Raw values cross Swift/Objective-C++; do not renumber.
nonisolated public enum ContentBlockingResourceType: Int, Sendable, CaseIterable, Hashable {
    case document = 0
    case subdocument = 1
    case stylesheet = 2
    case script = 3
    case image = 4
    case font = 5
    case object = 6
    case media = 7
    case xmlhttprequest = 8
    case ping = 9
    case websocket = 10
    case csp_report = 11
    case other = 12

    static let optionAliases: [String: ContentBlockingResourceType] = [
        "document": .document,
        "doc": .document,
        "subdocument": .subdocument,
        "frame": .subdocument,
        "stylesheet": .stylesheet,
        "css": .stylesheet,
        "script": .script,
        "image": .image,
        "img": .image,
        "font": .font,
        "object": .object,
        "object-subrequest": .object,
        "media": .media,
        "xmlhttprequest": .xmlhttprequest,
        "xhr": .xmlhttprequest,
        "ping": .ping,
        "beacon": .ping,
        "websocket": .websocket,
        "csp_report": .csp_report,
        "other": .other,
    ]

}

nonisolated public struct ContentBlockingResourceTypeSet: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public init(_ type: ContentBlockingResourceType) {
        self.rawValue = 1 << type.rawValue
    }

    public static let all = ContentBlockingResourceTypeSet(
        rawValue: ContentBlockingResourceType.allCases.reduce(0) { $0 | (1 << $1.rawValue) }
    )

    public func contains(_ type: ContentBlockingResourceType) -> Bool {
        rawValue & (1 << type.rawValue) != 0
    }

    public var types: [ContentBlockingResourceType] {
        ContentBlockingResourceType.allCases.filter { contains($0) }
    }
}

// MARK: - Decisions

nonisolated public enum ContentBlockingDecision: Equatable, Sendable {
    case allow
    case block(rule: String, listID: String)
    case redirect(rule: String, listID: String, substitution: RedirectSubstitution)
    case exempted(rule: String, listID: String)
    case allowlistedSite(host: String)
    case disabled

    public var isBlocked: Bool {
        if case .block = self { return true }
        return false
    }

    public var preventedOriginalResponse: Bool {
        switch self {
        case .block, .redirect: return true
        default: return false
        }
    }
}

// MARK: - Compilation statistics

nonisolated public struct ContentBlockingCompileStats: Equatable, Sendable {
    public var linesRead: Int = 0
    public var blockingRules: Int = 0
    public var exceptionRules: Int = 0
    public var redirectRules: Int = 0
    public var unblockRules: Int = 0
    public var cosmeticRules: Int = 0
    public var cosmeticExceptionRules: Int = 0
    public var unsupportedRules: Int = 0
    public var invalidRegexRules: Int = 0

    public var totalNetworkRules: Int {
        blockingRules + exceptionRules + redirectRules + unblockRules
    }

    public var totalCompiledRules: Int {
        totalNetworkRules + cosmeticRules
    }

    public init() {}

    static func + (lhs: ContentBlockingCompileStats, rhs: ContentBlockingCompileStats) -> ContentBlockingCompileStats {
        var out = ContentBlockingCompileStats()
        out.linesRead = lhs.linesRead + rhs.linesRead
        out.blockingRules = lhs.blockingRules + rhs.blockingRules
        out.exceptionRules = lhs.exceptionRules + rhs.exceptionRules
        out.redirectRules = lhs.redirectRules + rhs.redirectRules
        out.unblockRules = lhs.unblockRules + rhs.unblockRules
        out.cosmeticRules = lhs.cosmeticRules + rhs.cosmeticRules
        out.cosmeticExceptionRules = lhs.cosmeticExceptionRules + rhs.cosmeticExceptionRules
        out.unsupportedRules = lhs.unsupportedRules + rhs.unsupportedRules
        out.invalidRegexRules = lhs.invalidRegexRules + rhs.invalidRegexRules
        return out
    }
}

// MARK: - URL helpers

nonisolated public enum ContentBlockingURL {

    public static func host(ofURLString urlString: String) -> String? {
        guard let schemeEnd = urlString.range(of: "://") else { return nil }
        let afterScheme = urlString[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        var authority = String(authorityEnd.map { afterScheme[..<$0] } ?? afterScheme)
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        if authority.hasPrefix("[") {
            if let close = authority.firstIndex(of: "]") {
                authority = String(authority[...close])
            }
        } else if let colon = authority.lastIndex(of: ":") {
            authority = String(authority[..<colon])
        }
        let host = authority.lowercased()
        return host.isEmpty ? nil : host
    }

    public static func host(_ host: String, matchesDomain domain: String) -> Bool {
        if host == domain { return true }
        guard host.count > domain.count else { return false }
        return host.hasSuffix(domain)
            && host[host.index(host.endIndex, offsetBy: -domain.count - 1)] == "."
    }

    public static func domainSuffixes(of host: String) -> [String] {
        var result: [String] = [host]
        var current = Substring(host)
        while let dot = current.firstIndex(of: ".") {
            current = current[current.index(after: dot)...]
            if current.isEmpty { break }
            result.append(String(current))
        }
        return result
    }
}
