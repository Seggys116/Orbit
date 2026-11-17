import SwiftUI

enum NewTabPageModel {

    static let maximumRecents = 6

    static let url = URL(string: "orbit://new-tab")!

    static func displayHost(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isWebURL(_ url: URL) -> Bool {
        (url.scheme == "http" || url.scheme == "https") && !(url.host() ?? "").isEmpty
    }

    static func distinctWebEntries(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var seen = Set<URL>()
        return entries.filter { isWebURL($0.url) && seen.insert($0.url).inserted }
    }

    static func recents(from entries: [HistoryEntry], limit: Int = maximumRecents) -> [HistoryEntry] {
        Array(distinctWebEntries(entries).prefix(limit))
    }

    /// One site on the page: always an origin root, never a deep link.
    struct SiteTile: Identifiable, Hashable {
        var url: URL
        /// The host, with the port when it is not the scheme's default ("localhost:3000").
        var title: String
        var subtitle: String
        var id: URL { url }
    }

    private struct SiteAccumulator {
        var key: String
        var url: URL
        var label: String
        var lastVisit: Date
        var score: Double
    }

    /// Scheme, host and non-default port of a web URL, plus the label shown for it. Nil for anything that is not http(s).
    /// The key ignores scheme and a leading "www." so http and https (or www and bare) visits of one site count as one tile.
    private static func siteOrigin(of url: URL) -> (key: String, root: URL, label: String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased() else { return nil }
        let bareHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !bareHost.isEmpty else { return nil }

        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : $0 }
        let portSuffix = port.map { ":\($0)" } ?? ""
        let authorityHost = bareHost.contains(":") ? "[\(bareHost)]" : bareHost
        guard let root = URL(string: "\(scheme)://\(authorityHost)\(portSuffix)") else { return nil }

        let shownHost = authorityHost.hasPrefix("www.") ? String(authorityHost.dropFirst(4)) : authorityHost
        let label = shownHost + portSuffix
        return (label, root, label)
    }

    private static func nextUnpicked(in sites: [SiteAccumulator], from index: inout Int, excluding picked: Set<String>) -> SiteAccumulator? {
        while index < sites.count {
            let site = sites[index]
            index += 1
            if !picked.contains(site.key) { return site }
        }
        return nil
    }

    /// The sites to show: history collapsed to one tile per origin, covering both what was visited last and what is visited most.
    /// Origins are ranked twice, newest visit first and highest summed frecency first, and the two rankings are taken in turn
    /// (newest, most frecent, next newest, ...) skipping any origin already taken, until `limit` tiles are chosen.
    static func siteTiles(from entries: [HistoryEntry], limit: Int = maximumRecents, now: Date = Date()) -> [SiteTile] {
        guard limit > 0 else { return [] }

        var sites: [String: SiteAccumulator] = [:]
        for entry in entries {
            guard let origin = siteOrigin(of: entry.url) else { continue }
            let score = HistoryStore.frecencyScore(
                visitCount: entry.visitCount,
                typedCount: entry.wasTyped ? 1 : 0,
                lastVisit: entry.visitedAt,
                now: now
            )
            if var site = sites[origin.key] {
                site.score += score
                // The root takes the scheme and host spelling of the newest visit.
                if entry.visitedAt > site.lastVisit {
                    site.lastVisit = entry.visitedAt
                    site.url = origin.root
                }
                sites[origin.key] = site
            } else {
                sites[origin.key] = SiteAccumulator(
                    key: origin.key, url: origin.root, label: origin.label,
                    lastVisit: entry.visitedAt, score: score
                )
            }
        }

        let newest = sites.values.sorted {
            $0.lastVisit != $1.lastVisit ? $0.lastVisit > $1.lastVisit : $0.key < $1.key
        }
        let mostFrecent = sites.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key
        }

        var chosen: [SiteAccumulator] = []
        var picked = Set<String>()
        var newestIndex = 0
        var frecentIndex = 0
        var takeNewest = true
        while chosen.count < limit {
            let next = takeNewest
                ? nextUnpicked(in: newest, from: &newestIndex, excluding: picked)
                : nextUnpicked(in: mostFrecent, from: &frecentIndex, excluding: picked)
            guard let site = next else { break }
            picked.insert(site.key)
            chosen.append(site)
            takeNewest.toggle()
        }
        return chosen.map { SiteTile(url: $0.url, title: $0.label, subtitle: $0.label) }
    }

    static func isNewTabPage(_ tab: Tab) -> Bool {
        if case .newTab = OrbitScheme.parse(tab.url) { return true }
        return false
    }

    /// A blank page in Today that no split owns; the sidebar's New Tab row stands in for it.
    static func isUnlisted(_ tab: Tab) -> Bool {
        tab.section == .today && tab.splitGroupID == nil && isNewTabPage(tab)
    }

    static func listed(_ tabs: [Tab]) -> [Tab] {
        tabs.filter { !isUnlisted($0) }
    }
}

struct NewTabPageView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme

    var tab: Tab?
    var initialQuery: String?

    @State private var hasInput = false

    private static let contentMaxWidth: CGFloat = 700

    init(tab: Tab?, initialQuery: String? = nil) {
        self.tab = tab
        self.initialQuery = initialQuery
        _hasInput = State(initialValue: !(initialQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var space: Space? {
        tab.flatMap { env.space($0.spaceID) } ?? env.activeSpace
    }

    private var isPrivate: Bool {
        space.map { env.isIncognito($0) } ?? true
    }

    private var history: [HistoryEntry] {
        isPrivate ? [] : env.historyResults(matching: "", limit: 300)
    }

    private var themeTint: Color {
        guard let theme = space?.theme else { return .clear }
        return Color(nsColor: theme.primary.nsColor).opacity(colorScheme == .dark ? 0.16 : 0.07)
    }

    var body: some View {
        let sites = NewTabPageModel.siteTiles(from: history)

        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 30) {
                    CommandBarView(
                        embedding: CommandBarView.Embedding(
                            paneTabID: tab?.id,
                            seedQuery: initialQuery,
                            onInputChange: { hasInput = $0 }
                        )
                    )
                    // Re-creates the embedded bar when the page switches tabs.
                    .id(tab?.id)
                    if !hasInput, !sites.isEmpty {
                        sitesSection(sites)
                    }
                }
                .frame(maxWidth: Self.contentMaxWidth)
                .padding(.horizontal, 32)
                .padding(.top, max(40, proxy.size.height * 0.28))
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
        .background {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                themeTint
            }
        }
    }

    private func sitesSection(_ sites: [NewTabPageModel.SiteTile]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent and frequent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)],
                spacing: 12
            ) {
                ForEach(sites) { site in
                    NewTabOriginCard(site: site) { open(site.url) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ url: URL) {
        if let tab, env.tab(tab.id) != nil {
            env.loadInTab(tab.id, url: url)
            env.activateTab(tab.id)
        } else if let spaceID = space?.id {
            env.openTab(url: url, in: spaceID)
        }
    }
}

private struct NewTabOriginCard: View {
    var site: NewTabPageModel.SiteTile
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FaviconView(url: nil, host: site.url.host() ?? site.url.absoluteString)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(site.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // A site's name is its host, so the second line would only repeat the first.
                    if site.subtitle != site.title {
                        Text(site.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: OrbitRadius.panel, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrbitRadius.panel, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: OrbitRadius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(site.title)
    }
}
