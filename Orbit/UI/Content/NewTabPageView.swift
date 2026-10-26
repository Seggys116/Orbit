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
        let recents = NewTabPageModel.recents(from: history)

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
                    if !hasInput, !recents.isEmpty {
                        recentsSection(recents)
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

    private func recentsSection(_ entries: [HistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently visited")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)],
                spacing: 12
            ) {
                ForEach(entries) { entry in
                    NewTabRecentCard(entry: entry) { open(entry.url) }
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

private struct NewTabRecentCard: View {
    var entry: HistoryEntry
    var action: () -> Void

    @State private var isHovering = false

    private var title: String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NewTabPageModel.displayHost(entry.url) : trimmed
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FaviconView(url: nil, host: entry.url.host() ?? entry.url.absoluteString)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(NewTabPageModel.displayHost(entry.url))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}
