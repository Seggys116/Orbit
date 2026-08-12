import Foundation

extension AppEnvironment {

    @discardableResult
    func makeDetachedTab(url: URL) -> TabID {
        let spaceID = activeSpace?.id ?? state.spaces.first?.id ?? UUID()
        let tab = Tab(spaceID: spaceID, section: .today, url: url)
        state.tabs[tab.id] = tab
        materializeWebContents(for: tab.id, url: url)
        recordVisit(url: url, title: "", profileID: space(spaceID)?.profileID ?? state.profiles.first?.id ?? UUID())
        return tab.id
    }

    // Stale split group refs after removal below would corrupt persisted state.
    func closeDetachedTab(_ id: TabID) {
        if let group = splitGroup(for: id) {
            separateAllTabs(group.id)
        }
        releaseWebContents(for: id)
        state.tabs.removeValue(forKey: id)
    }

    func promoteDetachedTabToMainWindow(_ id: TabID, destinationSpaceID: SpaceID? = nil) {
        guard var tab = state.tabs[id] else { return }
        let destination = destinationSpaceID ?? activeSpace?.id ?? tab.spaceID
        tab.spaceID = destination
        tab.section = .today
        state.tabs[id] = tab
        if let index = state.spaces.firstIndex(where: { $0.id == destination }) {
            state.spaces[index].today.append(id)
        }
        selectSpace(destination)
        activateTab(id)
    }
}
