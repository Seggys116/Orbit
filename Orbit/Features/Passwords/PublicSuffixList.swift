import Foundation

/// Which part of a host a single party controls, from the Public Suffix List. A saved login is only ever offered within one registrable domain, so `alice.github.io` and `evil.github.io` are different sites even though both sit under `github.io`.
nonisolated enum PublicSuffixList {

    private struct Tables {
        var rules: Set<String> = []
        var wildcards: Set<String> = []
        var exceptions: Set<String> = []
    }

    private static let tables: Tables = {
        var tables = Tables()
        for line in PublicSuffixData.rules.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("!") {
                tables.exceptions.insert(String(line.dropFirst()))
            } else if line.hasPrefix("*.") {
                tables.wildcards.insert(String(line.dropFirst(2)))
            } else {
                tables.rules.insert(String(line))
            }
        }
        return tables
    }()

    /// The host itself when it is an IP address, a single label, or a public suffix; otherwise the public suffix plus one label. Lower case, no trailing dot.
    static func registrableDomain(ofHost rawHost: String) -> String {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count > 1, !labels.contains("") else { return host }

        let count = labels.count
        // An unlisted top-level domain is a public suffix of one label, the list's default rule.
        var suffixLabels = 1
        for index in 0..<count {
            let candidate = labels[index...].joined(separator: ".")
            if tables.exceptions.contains(candidate) {
                suffixLabels = count - index - 1
                break
            }
            if tables.rules.contains(candidate) {
                suffixLabels = count - index
                break
            }
            if index + 1 < count, tables.wildcards.contains(labels[(index + 1)...].joined(separator: ".")) {
                suffixLabels = count - index
                break
            }
        }
        guard count > suffixLabels else { return host }
        return labels[(count - suffixLabels - 1)...].joined(separator: ".")
    }
}
