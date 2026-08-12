import Foundation

extension AppEnvironment {

    // Nothing here reverts automatically; see testNothingRevertsAPinnedTabAutomatically.
    func resetPinnedTab(_ id: TabID, openingPriorURLInNewTab: Bool = false) {
        guard let tab = state.tabs[id], let origin = tab.pinnedURL else { return }
        guard let priorURL = store.resetPinnedTab(id) else { return }

        // loadInTab, not webContents[id]?.load(url) — lets a deferred content-blocking load see it was superseded.
        loadInTab(id, url: origin)

        if openingPriorURLInNewTab {
            openTab(url: priorURL, in: tab.spaceID, section: .today, activate: false)
        }
    }

    func replacePinnedURLWithCurrent(_ id: TabID) {
        store.replacePinnedURLWithCurrent(id)
    }

    func setPinnedURL(_ id: TabID, to url: URL) {
        store.setPinnedURL(id, to: url)
    }
}
