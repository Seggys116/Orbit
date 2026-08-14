import Foundation

// Two separate paths: committing text or a URL stays in the current Space; only a picked .switchToSpaceAndTab row leaves it.
@MainActor
enum CommandBarActivation {

    @discardableResult
    static func activate(_ result: CommandResult, in env: AppEnvironment, instant: Bool = false) -> Bool {
        guard let spaceID = env.activeSpace?.id else { return false }
        if instant, let instantURL = result.instantOpenURL {
            navigate(to: instantURL, in: env, spaceID: spaceID)
            return true
        }
        switch result.kind.activationIntent {
        case .navigate(let url):
            navigate(to: url, in: env, spaceID: spaceID)
        case .searchGoogle(let text):
            guard let url = env.searchEngine.searchURL(for: text) else { break }
            navigate(to: url, in: env, spaceID: spaceID)
        case .switchToTab(let tabID):
            env.activateTab(tabID)
        case .switchToSpaceAndTab(let targetSpaceID, let tabID):
            env.selectSpace(targetSpaceID)
            env.activateTab(tabID)
        case .activateFavoriteResult(let favorite):
            env.activateFavorite(favorite, in: spaceID)
        case .runAction:
            if case .action(let action) = result.kind { action.perform(env) }
        }
        return true
    }

    // Same three rules, same order, as CommandBarEngine.results' row 1, so this backstop can never disagree with the list about where a query goes.
    @discardableResult
    static func commitTypedText(_ text: String, siteEngine: SiteSearchEngine?, in env: AppEnvironment) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let spaceID = env.activeSpace?.id else { return false }
        let destination: URL?
        if let siteEngine {
            destination = SiteSearchMatcher.searchURL(for: trimmed, using: siteEngine)
        } else {
            destination = CommandBarEngine.detectTypedURL(trimmed) ?? env.searchEngine.searchURL(for: trimmed)
        }
        guard let destination else { return false }
        navigate(to: destination, in: env, spaceID: spaceID)
        return true
    }

    // spaceID is always the caller's current Space: a URL that happens to be open elsewhere is opened here, never jumped to.
    static func navigate(to url: URL, in env: AppEnvironment, spaceID: SpaceID) {
        switch env.commandBarMode {
        case .newTab, .chatGPT:
            env.openTab(url: url, in: spaceID)
        case .blankPane(let tabID):
            // Falls back to a new tab only if the pane went away underneath the bar while it was open.
            if env.tab(tabID) != nil {
                env.loadInTab(tabID, url: url)
                env.activateTab(tabID)
            } else {
                env.openTab(url: url, in: spaceID)
            }
        case .editURL:
            if let tabID = env.activeTabID {
                // loadInTab, not the tab's live WebContents directly: a tab still waiting on content blocking's readiness gate has a deferred load queued, and only loadInTab's bookkeeping lets it notice this one superseded it.
                env.loadInTab(tabID, url: url)
                env.activateTab(tabID)
            } else {
                env.openTab(url: url, in: spaceID)
            }
        }
    }
}
