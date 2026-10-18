import AppKit
import Foundation

// What WebKit's extension window and tab protocols ask this window for. Each verb runs the same
// AppEnvironment path the sidebar uses, so the UI follows what an extension does.
extension AppEnvironment {

    /// This window's live WebKit tabs in sidebar order (pinned trees, then Today, per Space),
    /// followed by any live tab the sidebar does not list.
    func extensionTabContents() -> (listed: [WebKitWebContents], unlisted: [WebKitWebContents]) {
        let owned = extensionOwnedSpaceIDs()
        let order = owned.flatMap { pinnedNodes(in: $0).flatMap(\.allTabIDs) + (space($0)?.today ?? []) }
        var seen = Set<TabID>()
        var listed: [WebKitWebContents] = []
        for tabID in order where seen.insert(tabID).inserted {
            if let contents = webContents[tabID] as? WebKitWebContents { listed.append(contents) }
        }
        let unlisted = webContents.compactMap { tabID, contents -> WebKitWebContents? in
            guard !seen.contains(tabID), let webKit = contents as? WebKitWebContents else { return nil }
            guard let spaceID = state.tabs[tabID]?.spaceID, owned.contains(spaceID) else { return nil }
            return webKit
        }
        return (listed, unlisted)
    }

    /// Spaces whose tabs belong in this Orbit window. A torn-off or Incognito window owns only
    /// its own Space; the shared window does not list those.
    private func extensionOwnedSpaceIDs() -> [SpaceID] {
        if isWindowScoped { return [activeSpace?.id].compactMap { $0 } }
        let claimed = Set((engine as? WebKitEngine)?.extensionWindows.compactMap { window -> SpaceID? in
            guard let other = window.environment, other !== self, other.isWindowScoped else { return nil }
            return other.activeSpace?.id
        } ?? [])
        return spaces.map(\.id).filter { !claimed.contains($0) }
    }

    var extensionWindowIsPrivate: Bool {
        activeSpace.map(isIncognito) ?? false
    }

    var extensionActiveContents: WebKitWebContents? {
        activeTabID.flatMap { webContents[$0] as? WebKitWebContents }
    }

    func extensionTabIsPinned(_ contents: WebKitWebContents) -> Bool {
        guard let tabID = tabID(for: contents) else { return false }
        return state.tabs[tabID]?.section == .pinned
    }

    @discardableResult
    func extensionSetPinned(_ contents: WebKitWebContents, pinned: Bool) -> Bool {
        guard let tabID = tabID(for: contents), let tab = state.tabs[tabID] else { return false }
        guard (tab.section == .pinned) != pinned else { return true }
        if pinned { pinTab(tabID) } else { unpinTab(tabID) }
        return true
    }

    @discardableResult
    func extensionSetMuted(_ contents: WebKitWebContents, muted: Bool) -> Bool {
        guard let tabID = tabID(for: contents), state.tabs[tabID] != nil else { return false }
        muteTab(tabID, muted: muted)
        return true
    }

    @discardableResult
    func extensionActivate(_ contents: WebKitWebContents) -> Bool {
        guard let tabID = tabID(for: contents) else { return false }
        activateTab(tabID)
        return true
    }

    @discardableResult
    func extensionClose(_ contents: WebKitWebContents) -> Bool {
        guard let tabID = tabID(for: contents) else { return false }
        // didCloseTab asks for the window's active tab while this one is already
        // out of the tabs array. Point active at a survivor first so that answer
        // is still a member of the array.
        if activeTabID == tabID {
            let listing = extensionTabContents()
            if let survivor = (listing.listed + listing.unlisted).first(where: { $0 !== contents }),
               let survivorID = self.tabID(for: survivor) {
                activateTab(survivorID)
            }
        }
        // Leave the WKWebView allocated. WebKit is inside its close callback, and
        // deallocating the view on that stack kills the process that owes the reply.
        closeTabPreservingBookmark(tabID, destroyRenderer: false)
        return true
    }

    @discardableResult
    func extensionLoad(_ url: URL, in contents: WebKitWebContents) -> Bool {
        guard let tabID = tabID(for: contents) else { return false }
        loadInTab(tabID, url: url)
        return true
    }

    /// Opens a tab the way the new-tab command does, then places and flags it as asked.
    /// `windowIndex` counts the way chrome.tabs does: across the whole window, pinned tabs first.
    func extensionOpenTab(
        url: URL?,
        in spaceID: SpaceID? = nil,
        windowIndex: Int?,
        active: Bool,
        pinned: Bool,
        muted: Bool
    ) -> WebKitWebContents? {
        guard let spaceID = spaceID ?? activeSpace?.id else { return nil }
        let target = url ?? URL(string: "orbit://new-tab")!
        let tabID = openTab(url: target, in: spaceID, section: .today, activate: active)
        if pinned { pinTab(tabID) }
        if muted { muteTab(tabID, muted: true) }
        if let windowIndex, !pinned { placeTodayTab(tabID, atWindowIndex: windowIndex, in: spaceID) }
        return webContents[tabID] as? WebKitWebContents
    }

    func extensionDuplicate(
        _ contents: WebKitWebContents,
        windowIndex: Int?,
        active: Bool,
        pinned: Bool,
        muted: Bool
    ) -> WebKitWebContents? {
        guard let tabID = tabID(for: contents), let tab = state.tabs[tabID] else { return nil }
        let source = contents.navigationState.url ?? tab.url
        let afterOriginal = extensionTabContents().listed.firstIndex { $0 === contents }.map { $0 + 1 }
        return extensionOpenTab(
            url: source,
            in: tab.spaceID,
            windowIndex: windowIndex ?? afterOriginal,
            active: active,
            pinned: pinned,
            muted: muted
        )
    }

    // A window index past the end, or one that names a tab in another Space, leaves the tab last in Today.
    private func placeTodayTab(_ placedID: TabID, atWindowIndex windowIndex: Int, in spaceID: SpaceID) {
        let others = extensionTabContents().listed.compactMap { tabID(for: $0) }.filter { $0 != placedID }
        guard windowIndex >= 0, windowIndex < others.count else { return }
        let today = todayTabs(in: spaceID).map(\.id)
        let anchor = others[windowIndex]
        if let todayIndex = today.firstIndex(of: anchor) {
            moveTodayTab(placedID, toIndex: todayIndex, in: spaceID)
        } else if state.tabs[anchor]?.section == .pinned {
            moveTodayTab(placedID, toIndex: 0, in: spaceID)
        }
    }

    /// chrome.windows.create: a window of its own, since a standard Orbit window shares its tabs
    /// with every other standard window and so could not be told apart by an extension.
    /// `movingTabs` are existing tabs the new window takes over, which Incognito cannot receive.
    @discardableResult
    func extensionOpenWindow(
        urls: [URL],
        movingTabs: [WebKitWebContents],
        private isPrivate: Bool,
        focused: Bool
    ) -> AppEnvironment? {
        let host = rootEnvironment
        let environment: AppEnvironment
        if isPrivate {
            let controller = OrbitWindowController.openIncognitoWindow(on: host)
            environment = controller.session.environment
            if let spaceID = environment.activeSpace?.id {
                for (offset, url) in urls.enumerated() {
                    environment.openTab(url: url, in: spaceID, activate: offset == 0)
                }
            }
        } else {
            let movable = movingTabs.compactMap { contents -> (owner: AppEnvironment, tabID: TabID)? in
                guard let owner = contents.delegate as? AppEnvironment, let tabID = owner.tabID(for: contents) else { return nil }
                return (owner, tabID)
            }
            let controller: OrbitWindowController
            if let first = movable.first {
                guard let torn = OrbitWindowController.openTornOffWindow(adopting: first.tabID, on: first.owner) else { return nil }
                controller = torn
            } else {
                guard let spaceID = host.activeSpace?.id ?? host.spaces.first?.id else { return nil }
                let seed = host.openTab(url: urls.first ?? URL(string: "orbit://new-tab")!, in: spaceID, activate: false)
                guard let torn = OrbitWindowController.openTornOffWindow(adopting: seed, on: host) else {
                    host.closeTab(seed)
                    return nil
                }
                controller = torn
            }
            environment = controller.session.environment
            if let spaceID = environment.activeSpace?.id {
                for extra in movable.dropFirst() {
                    environment.store.moveTab(extra.tabID, toSpace: spaceID, section: .today)
                    environment.adoptWebContents(for: extra.tabID, from: extra.owner)
                }
                // The seed tab already took the first URL when nothing was moved.
                let remaining = movable.isEmpty ? Array(urls.dropFirst()) : urls
                for url in remaining { environment.openTab(url: url, in: spaceID, activate: false) }
            }
        }
        if !focused {
            OrbitWindowController.controller(for: environment)?.window?.orderBack(nil)
        }
        return environment
    }
}
