//  Triggered by pinning (.orbitTabDidPin), never by didChangeTitle — the latter fires on every page repaint.

import Foundation

@MainActor
final class TidyTabTitlesCoordinator {

    static let shared = TidyTabTitlesCoordinator()

    init() {}

    private var inFlight: Set<TabID> = []
    private var pinObserver: NSObjectProtocol?

    // MARK: - Decisions (pure, testable without a provider)

    func shouldRequest(tabID: TabID, rawTitle: String) -> Bool {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > AssistRuntime.tidyTitleMinimumLength else { return false }
        return !inFlight.contains(tabID)
    }

    func reset() { inFlight.removeAll() }

    // MARK: - The core, sink-taking path

    @discardableResult
    func tidy(
        tabID: TabID,
        rawTitle: String,
        url: URL,
        sink: AssistSink,
        runtime: AssistRuntime = AssistRuntime.shared,
        apply: (TabID, String?) -> Void
    ) async -> String? {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight.insert(tabID)
        defer { inFlight.remove(tabID) }

        let tidied = try? await runtime.tidiedTabTitle(rawTitle: trimmed, url: url, sink: sink)
        apply(tabID, tidied ?? nil)
        return tidied ?? nil
    }

    // MARK: - Production entry points

    func start(env: AppEnvironment) {
        if !AssistSettings.isTidyTabTitlesEnabled {
            env.store.clearAllTidiedTitles()
        }
        guard pinObserver == nil else { return }
        pinObserver = NotificationCenter.default.addObserver(
            forName: .orbitTabDidPin,
            object: nil,
            queue: .main
        ) { [weak env] note in
            guard let env, let tabID = note.userInfo?["tabID"] as? TabID else { return }
            MainActor.assumeIsolated {
                TidyTabTitlesCoordinator.shared.tabWasPinned(tabID: tabID, env: env)
            }
        }
    }

    func tabWasPinned(tabID: TabID, env: AppEnvironment) {
        guard AssistSettings.isTidyTabTitlesEnabled else { return }
        guard let tab = env.tab(tabID) else { return }
        guard shouldRequest(tabID: tabID, rawTitle: tab.title) else { return }
        if let space = env.space(tab.spaceID), env.isIncognito(space) { return }
        guard let sink = AssistRuntime.productionSink(for: env.webContents[tabID]) else { return }

        let title = tab.title
        let url = tab.url
        Task { [weak env] in
            await tidy(tabID: tabID, rawTitle: title, url: url, sink: sink) { id, tidied in
                env?.store.setTidiedTitle(tidied, forTab: id)
            }
        }
    }

    /// `committedURL` is passed in, not read off `tab`: `didCommitNavigationTo` runs before `Tab.url` updates.
    static func shouldClearOnCommit(tab: Tab, committedURL: URL) -> Bool {
        guard tab.tidiedTitle != nil, tab.section == .pinned else { return false }
        guard let pinnedURL = tab.pinnedURL else { return false }
        return Tab.normalizedForPinnedComparison(committedURL) != Tab.normalizedForPinnedComparison(pinnedURL)
    }

    func navigationDidCommit(tabID: TabID, committedURL: URL, env: AppEnvironment) {
        guard let tab = env.tab(tabID) else { return }
        guard Self.shouldClearOnCommit(tab: tab, committedURL: committedURL) else { return }
        env.store.setTidiedTitle(nil, forTab: tabID)
    }
}
