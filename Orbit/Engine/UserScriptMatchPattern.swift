import Foundation

struct MatchPattern: Hashable {
    enum SchemeMatch: Hashable {
        case any
        case exact(String)
    }

    enum HostMatch: Hashable {
        case any
        /// The literal host, or any subdomain (`*.example.com`).
        case suffix(String)
        case exact(String)
    }

    let isAllURLs: Bool
    let scheme: SchemeMatch
    let host: HostMatch
    /// `nil` when the pattern is `<all_urls>`.
    let pathRegex: NSRegularExpression?

    /// Chrome-extension match-pattern grammar; must match the engine's own parser.
    init?(pattern: String) {
        if pattern == "<all_urls>" {
            isAllURLs = true
            scheme = .any
            host = .any
            pathRegex = nil
            return
        }
        isAllURLs = false

        guard let schemeRange = pattern.range(of: "://") else { return nil }
        let schemePart = String(pattern[pattern.startIndex..<schemeRange.lowerBound])
        let rest = String(pattern[schemeRange.upperBound...])

        scheme = schemePart == "*" ? .any : .exact(schemePart.lowercased())

        let hostAndPath: (host: String, path: String)
        if let slashIndex = rest.firstIndex(of: "/") {
            hostAndPath = (String(rest[rest.startIndex..<slashIndex]), String(rest[slashIndex...]))
        } else {
            // Bare "scheme://host" isn't valid Chrome grammar; lenient as "/*".
            hostAndPath = (rest, "/*")
        }

        if hostAndPath.host.isEmpty {
            return nil
        } else if hostAndPath.host == "*" {
            host = .any
        } else if hostAndPath.host.hasPrefix("*.") {
            host = .suffix(String(hostAndPath.host.dropFirst(2)).lowercased())
        } else {
            host = .exact(hostAndPath.host.lowercased())
        }

        pathRegex = MatchPattern.regex(forPathPattern: hostAndPath.path)
    }

    /// `*` matches any run of characters, including `/` — Chrome does not
    /// treat path separators specially.
    private static func regex(forPathPattern path: String) -> NSRegularExpression? {
        var escaped = ""
        escaped.reserveCapacity(path.count * 2)
        for character in path {
            if character == "*" {
                escaped += ".*"
            } else {
                escaped += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        let full = "^\(escaped)$"
        return try? NSRegularExpression(pattern: full)
    }

    func matches(_ url: URL) -> Bool {
        if isAllURLs { return true }

        guard let urlScheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case .any:
            guard urlScheme == "http" || urlScheme == "https" else { return false }
        case .exact(let expected):
            guard urlScheme == expected else { return false }
        }

        guard let urlHost = url.host?.lowercased() else {
            // file:// has no host; only host "*" patterns match it.
            if case .any = host, urlScheme == "file" {
                return matchesPath(url)
            }
            return false
        }

        switch host {
        case .any:
            break
        case .exact(let expected):
            guard urlHost == expected else { return false }
        case .suffix(let suffix):
            guard urlHost == suffix || urlHost.hasSuffix(".\(suffix)") else { return false }
        }

        return matchesPath(url)
    }

    private func matchesPath(_ url: URL) -> Bool {
        guard let pathRegex else { return true }
        var path = url.path
        if path.isEmpty { path = "/" }
        if let query = url.query, !query.isEmpty {
            path += "?" + query
        }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return pathRegex.firstMatch(in: path, range: range) != nil
    }
}

/// OR'd match patterns, as `UserScript.matchPatterns` uses them.
struct MatchPatternSet {
    private let patterns: [MatchPattern]

    init(_ raw: [String]) {
        patterns = raw.compactMap(MatchPattern.init(pattern:))
    }

    /// An empty/unparseable list matches nothing, never everything.
    func matches(_ url: URL) -> Bool {
        patterns.contains { $0.matches(url) }
    }
}
