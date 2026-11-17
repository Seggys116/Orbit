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
        var visits: Int
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

    /// A site must have been opened at least this many times in total to count as frequently visited.
    static let minimumFrequentVisits = 2

    /// History collapsed to one accumulator per origin: its newest visit, its summed frecency and its summed visit count.
    private static func collectSites(from entries: [HistoryEntry], now: Date) -> [SiteAccumulator] {
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
                site.visits += entry.visitCount
                // The root takes the scheme and host spelling of the newest visit.
                if entry.visitedAt > site.lastVisit {
                    site.lastVisit = entry.visitedAt
                    site.url = origin.root
                }
                sites[origin.key] = site
            } else {
                sites[origin.key] = SiteAccumulator(
                    key: origin.key, url: origin.root, label: origin.label,
                    lastVisit: entry.visitedAt, score: score, visits: entry.visitCount
                )
            }
        }
        return Array(sites.values)
    }

    private static func tile(_ site: SiteAccumulator) -> SiteTile {
        SiteTile(url: site.url, title: site.label, subtitle: site.label)
    }

    /// The sites visited most recently, newest first, one tile per origin.
    static func recentSites(from entries: [HistoryEntry], limit: Int = maximumRecents, now: Date = Date()) -> [SiteTile] {
        guard limit > 0 else { return [] }
        return collectSites(from: entries, now: now)
            .sorted { $0.lastVisit != $1.lastVisit ? $0.lastVisit > $1.lastVisit : $0.key < $1.key }
            .prefix(limit)
            .map(tile)
    }

    /// The sites opened most often, most visits first, one tile per origin. A site seen only once is recent, not frequent.
    /// Ranked by visit count (frecency only breaks ties), because frecency decays with age and would let last hour's single visit outrank a site opened a thousand times: that is the recent list's job.
    /// This is a ranking of its own, not a merge with the recent one: the same site can appear in both lists.
    static func frequentSites(from entries: [HistoryEntry], limit: Int = maximumRecents, now: Date = Date()) -> [SiteTile] {
        guard limit > 0 else { return [] }
        return collectSites(from: entries, now: now)
            .filter { $0.visits >= minimumFrequentVisits }
            .sorted {
                if $0.visits != $1.visits { return $0.visits > $1.visits }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.key < $1.key
            }
            .prefix(limit)
            .map(tile)
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
        let entries = history
        let frequent = NewTabPageModel.frequentSites(from: entries)
        let recent = NewTabPageModel.recentSites(from: entries)

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
                    if !hasInput {
                        if !frequent.isEmpty {
                            sitesSection("Frequently visited", sites: frequent)
                        }
                        if !recent.isEmpty {
                            sitesSection("Recent", sites: recent, links: recentLinks)
                        }
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

    /// Where the recent list leads: the full history, and the Library views of what was recently fetched or closed.
    private var recentLinks: [NewTabPageLink] {
        [
            NewTabPageLink(title: "History", systemImage: "clock.arrow.circlepath") {
                HistoryWindowController.show()
            },
            NewTabPageLink(title: "Downloads", systemImage: "arrow.down.circle") {
                env.openLibrary(section: .downloads)
            },
            NewTabPageLink(title: "Archived Tabs", systemImage: "archivebox") {
                env.openLibrary(section: .archivedTabs)
            },
        ]
    }

    private func sitesSection(_ title: String, sites: [NewTabPageModel.SiteTile], links: [NewTabPageLink] = []) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ForEach(links) { link in
                    NewTabLinkButton(link: link)
                }
            }

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

private struct NewTabPageLink: Identifiable {
    var title: String
    var systemImage: String
    var action: () -> Void
    var id: String { title }
}

private struct NewTabLinkButton: View {
    var link: NewTabPageLink

    @State private var isHovering = false

    var body: some View {
        Button(action: link.action) {
            HStack(spacing: 4) {
                Image(systemName: link.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(link.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(link.title)
    }
}
