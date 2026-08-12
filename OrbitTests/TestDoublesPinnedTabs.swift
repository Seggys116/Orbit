import Foundation

@MainActor
extension AppEnvironment {

    /// `openingPriorURLInNewTab` is a no-op in this double; the real behavior
    /// is covered by `OrbitAppTests/PinnedTabResetTests.swift`.
    func resetPinnedTab(_ id: TabID, openingPriorURLInNewTab: Bool = false) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        guard let origin = tab.pinnedURL, tab.hasNavigatedAwayFromPinnedURL else { return }
        state.tabs[id]?.url = origin
        state.tabs[id]?.title = tab.pinnedTitle ?? ""
    }

    func replacePinnedURLWithCurrent(_ id: TabID) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        state.tabs[id]?.pinnedURL = tab.url
        state.tabs[id]?.pinnedTitle = tab.title.isEmpty ? nil : tab.title
    }

    func setPinnedURL(_ id: TabID, to url: URL) {
        guard let tab = state.tabs[id], tab.section == .pinned else { return }
        state.tabs[id]?.pinnedURL = url
        state.tabs[id]?.pinnedTitle = nil
    }
}
