import Foundation

/// The registrable domain of a URL ("example.co.uk" for "www.shop.example.co.uk"), used to tell links within a site from links to another site.
nonisolated public enum SiteIdentity {

    private static let secondLevelLabels: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac", "or", "ne", "go", "gob", "mil"]

    public static func registrableDomain(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return registrableDomain(ofHost: host)
    }

    public static func registrableDomain(ofHost host: String) -> String {
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        if trimmed.contains(":") || trimmed.allSatisfy({ $0.isNumber || $0 == "." }) { return trimmed }
        let labels = trimmed.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return trimmed }
        let tld = labels[labels.count - 1]
        let second = labels[labels.count - 2]
        let keep = (tld.count == 2 && secondLevelLabels.contains(second)) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    public static func areSameSite(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = registrableDomain(of: lhs), let right = registrableDomain(of: rhs) else { return false }
        return left == right
    }
}
