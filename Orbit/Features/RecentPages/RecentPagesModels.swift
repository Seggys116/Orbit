import Foundation

// MARK: - Service

public enum RecentPagesService: String, CaseIterable, Hashable, Sendable {
    case notion
    case figma
    case linear
    case confluence

    // Cheap pre-filter only; matches(_:) below is the authoritative test.
    public var urlFragment: String {
        switch self {
        case .notion: return "notion."
        case .figma: return "figma.com/"
        case .linear: return "linear.app/"
        case .confluence: return "atlassian.net/wiki/"
        }
    }

    public var displayName: String {
        switch self {
        case .notion: return "Notion"
        case .figma: return "Figma"
        case .linear: return "Linear"
        case .confluence: return "Confluence"
        }
    }

    public var cardHeading: String {
        switch self {
        case .notion: return "Recent Notion docs"
        case .figma: return "Recent Figma files"
        case .linear: return "Recent Linear projects and issues"
        case .confluence: return "Recent Confluence pages"
        }
    }

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        switch self {
        case .notion:
            return Self.host(host, isOrIsSubdomainOf: "notion.so")
                || Self.host(host, isOrIsSubdomainOf: "notion.com")
                || Self.host(host, isOrIsSubdomainOf: "notion.site")
        case .figma:
            return Self.host(host, isOrIsSubdomainOf: "figma.com")
        case .linear:
            return Self.host(host, isOrIsSubdomainOf: "linear.app")
        case .confluence:
            return Self.host(host, isOrIsSubdomainOf: "atlassian.net")
                && url.path().lowercased().hasPrefix("/wiki/")
        }
    }

    private static func host(_ host: String, isOrIsSubdomainOf domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    public static func matching(_ url: URL) -> RecentPagesService? {
        allCases.first { $0.matches(url) }
    }
}

// MARK: - Item

public struct RecentPagesItem: Identifiable, Hashable, Sendable {
    public var url: URL
    public var title: String
    public var tidyTitle: String
    public var lastVisitDate: Date
    public var documentID: String?

    public var id: URL { url }

    public init(url: URL, title: String, tidyTitle: String, lastVisitDate: Date, documentID: String?) {
        self.url = url
        self.title = title
        self.tidyTitle = tidyTitle
        self.lastVisitDate = lastVisitDate
        self.documentID = documentID
    }

    // tidyTitle is empty exactly when the raw title was empty or pure branding, so falling back to
    // it would show the row tidy() just rejected; the URL's last path component is used instead.
    public var displayTitle: String {
        if !tidyTitle.isEmpty { return tidyTitle }
        let component = url.lastPathComponent
        if !component.isEmpty, component != "/" { return component }
        return title
    }
}

// MARK: - Data

public struct RecentPagesData: Equatable, Hashable, Sendable {
    public var service: RecentPagesService
    public var items: [RecentPagesItem]

    public init?(service: RecentPagesService, items: [RecentPagesItem]) {
        guard !items.isEmpty else { return nil }
        self.service = service
        self.items = items
    }

    public var iconHost: String {
        items.first?.url.host() ?? ""
    }
}

// MARK: - Title tidying

public enum RecentPagesTidyTitle {

    // hasSuffix, not contains: " | Notion Calendar" is never partially consumed by " | Notion".
    static func suffixes(for service: RecentPagesService) -> [String] {
        switch service {
        case .notion:
            return [" | Notion Calendar", " – Notion", " - Notion", " | Notion"]
        case .figma:
            return [" – Figma", " - Figma", " | Figma", " — Figma"]
        case .linear:
            return [" · Linear", " – Linear", " - Linear", " | Linear"]
        case .confluence:
            return [" - Confluence", " – Confluence", " | Confluence"]
        }
    }

    public static func tidy(_ title: String, for service: RecentPagesService) -> String {
        var working = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in suffixes(for: service) where working.count > suffix.count {
            if working.lowercased().hasSuffix(suffix.lowercased()) {
                working = String(working.dropLast(suffix.count))
                break
            }
        }
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        if working.caseInsensitiveCompare(service.displayName) == .orderedSame { return "" }
        return working
    }
}

// MARK: - Document identity

// Returns nil rather than guessing: a wrong ID silently merges two distinct pages into one row.
public enum RecentPagesDocumentID {

    public static func parse(_ url: URL, service: RecentPagesService) -> String? {
        let segments = url.path().split(separator: "/").map(String.init)
        switch service {
        case .notion:
            // .../Some-Page-Title-<32 hex>  or  .../<32 hex>
            guard let last = segments.last else { return nil }
            return trailingHexID(in: last, length: 32)
        case .figma:
            // /file/<key>/Name, /design/<key>/Name, /board/<key>/Name
            guard let index = segments.firstIndex(where: { ["file", "design", "board", "proto"].contains($0) }),
                  segments.indices.contains(index + 1) else { return nil }
            return segments[index + 1]
        case .linear:
            // /<workspace>/issue/<TEAM-123>/slug
            guard let index = segments.firstIndex(of: "issue"),
                  segments.indices.contains(index + 1) else { return nil }
            return segments[index + 1].uppercased()
        case .confluence:
            // /wiki/spaces/<SPACE>/pages/<id>/Title
            guard let index = segments.firstIndex(of: "pages"),
                  segments.indices.contains(index + 1),
                  segments[index + 1].allSatisfy(\.isNumber) else { return nil }
            return segments[index + 1]
        }
    }

    // The ID must be preceded by "-" or by nothing, so hex-ish letters at the end of a title alone don't count.
    static func trailingHexID(in component: String, length: Int) -> String? {
        guard component.count >= length else { return nil }
        let candidate = String(component.suffix(length))
        guard candidate.allSatisfy({ $0.isHexDigit }) else { return nil }
        if component.count == length { return candidate.lowercased() }
        let boundary = component[component.index(component.endIndex, offsetBy: -(length + 1))]
        guard boundary == "-" else { return nil }
        return candidate.lowercased()
    }
}
