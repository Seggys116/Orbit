import Foundation
import Observation

@MainActor
@Observable
public final class BrowserStore {

    // MARK: - Persisted document

    public internal(set) var state: OrbitState {
        didSet {
            recordActiveTabTransitions(from: oldValue)
            scheduleAutosave()
        }
    }

    // MARK: - Recently closed (session-only; not persisted)

    var recentlyClosedRecords: [ClosedTabRecord] = []
    let recentlyClosedCapacity = 25

    public var recentlyClosed: [Tab] {
        recentlyClosedRecords.compactMap { state.tabs[$0.tabID] }
    }

    // MARK: - Active-tab history (session-only; not persisted)

    // Per-space history of previously active tabs, oldest first; fallbackActiveTab uses it to
    // return to the tab the user came from. Populated automatically from every transition.
    var activationHistoryBySpace: [SpaceID: [TabID]] = [:]
    private let activationHistoryCapacity = 25

    private func recordActiveTabTransitions(from oldValue: OrbitState) {
        guard oldValue.activeTabBySpace != state.activeTabBySpace else { return }
        for (spaceID, previouslyActiveID) in oldValue.activeTabBySpace
        where state.activeTabBySpace[spaceID] != previouslyActiveID {
            var history = activationHistoryBySpace[spaceID] ?? []
            history.removeAll { $0 == previouslyActiveID }
            history.append(previouslyActiveID)
            if history.count > activationHistoryCapacity {
                history.removeFirst(history.count - activationHistoryCapacity)
            }
            activationHistoryBySpace[spaceID] = history
        }
    }

    // MARK: - Persistence

    let stateStore: StateStore

    private var autosaveTask: Task<Void, Never>?

    // MARK: - Auto-archive

    private var autoArchiveTask: Task<Void, Never>?

    // MARK: - Init

    public init(stateStore: StateStore = .shared, autoArchiveInterval: TimeInterval? = 300) {
        self.stateStore = stateStore
        if let loaded = try? stateStore.load() {
            self.state = loaded
        } else {
            self.state = OrbitState()
        }
        bootstrapIfNeeded()
        migrateRetiredDefaultSpaceIcon()
        migrateSpaceArchivePolicyToProfile()
        purgeIncognitoResidue()
        runArchiveSweep()
        repairSidebarMembership()
        if let autoArchiveInterval {
            startAutoArchiveTimer(interval: autoArchiveInterval)
        }
        wireDebouncedSaveFailureReporting()
    }

    private func wireDebouncedSaveFailureReporting() {
        let store = stateStore
        Task {
            await store.onDebouncedSaveFailure { _ in
                Task { @MainActor in
                    PersistenceToastPresenter.shared.announceSaveFailed()
                }
            }
        }
    }

    private func migrateRetiredDefaultSpaceIcon() {
        let retired = "sparkles"
        let replacement = "house"
        guard state.spaces.contains(where: { !$0.iconIsEmoji && $0.icon == retired }) else { return }
        var newState = state
        for index in newState.spaces.indices where
            !newState.spaces[index].iconIsEmoji && newState.spaces[index].icon == retired {
            newState.spaces[index].icon = replacement
        }
        state = newState
    }

    private func migrateSpaceArchivePolicyToProfile() {
        guard state.spaces.contains(where: { $0.legacyArchivePolicy != nil }) else { return }
        var newState = state

        for profileIndex in newState.profiles.indices {
            let profileID = newState.profiles[profileIndex].id
            let adopted = newState.spaces
                .filter { $0.profileID == profileID && $0.legacyArchivePolicy != nil }
                .sorted {
                    if $0.order != $1.order { return $0.order < $1.order }
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .first?
                .legacyArchivePolicy
                .flatMap(ArchivePolicy.init(rawValue:))
            guard let adopted else { continue }
            newState.profiles[profileIndex].archivePolicy = adopted
        }

        for spaceIndex in newState.spaces.indices {
            newState.spaces[spaceIndex].legacyArchivePolicy = nil
        }
        state = newState
    }

    func repairSidebarMembership() {
        guard let repaired = state.repairingSidebarMembership() else { return }
        state = repaired
    }

    private func purgeIncognitoResidue() {
        let purged = state.strippingEphemeralEntities()
        guard purged.profiles.count != state.profiles.count
            || purged.spaces.count != state.spaces.count
            || purged.tabs.count != state.tabs.count
            || purged.activeSpaceID != state.activeSpaceID
            || purged.spaces.map(\.profileID) != state.spaces.map(\.profileID)
        else { return }
        state = purged
    }

    // MARK: - Autosave

    // Chained, not fire-and-forget: unstructured tasks reach the actor in no guaranteed order, so an older snapshot could arrive last and become the one written.
    private func scheduleAutosave() {
        let snapshot = state
        let store = stateStore
        let previous = autosaveTask
        autosaveTask = Task {
            await previous?.value
            await store.scheduleSave(snapshot)
        }
    }

    public func saveNow() throws {
        try stateStore.saveNow(state)
    }

    // MARK: - First-run bootstrap

    func bootstrapIfNeeded() {
        guard state.profiles.isEmpty else { return }

        var newState = state
        let profile = Profile(name: "default")
        newState.profiles = [profile]

        var space = Space(
            name: "Home",
            icon: "house",
            iconIsEmoji: false,
            theme: SpaceTheme(
                style: .mesh,
                colors: SpaceTheme.defaultPalette,
                angle: 18,
                grain: 0.35
            ),
            profileID: profile.id,
            order: 0,
            favorites: BrowserStore.defaultFavorites()
        )

        let firstTab = Tab(
            spaceID: space.id,
            section: .today,
            url: BrowserStore.firstRunTabURL,
            title: "Orbit"
        )
        space.today = [firstTab.id]
        newState.tabs[firstTab.id] = firstTab

        newState.spaces = [space]
        newState.activeSpaceID = space.id
        state = newState
    }

    static let firstRunTabURL = URL(string: "https://orbit-browser.app")!

    private static func defaultFavorites() -> [Favorite] {
        [
            Favorite(url: URL(string: "https://www.google.com")!, title: "Google"),
            Favorite(url: URL(string: "https://www.apple.com")!, title: "Apple"),
            Favorite(url: URL(string: "https://en.wikipedia.org")!, title: "Wikipedia"),
            Favorite(url: URL(string: "https://news.ycombinator.com")!, title: "Hacker News"),
        ]
    }

    // MARK: - Media currently playing (session-only; not persisted)

    public internal(set) var tabsPlayingMedia: Set<TabID> = []

    func setMediaState(_ mediaState: MediaState, forTab tabID: TabID) {
        if mediaState.isMediaActive {
            tabsPlayingMedia.insert(tabID)
        } else {
            tabsPlayingMedia.remove(tabID)
        }
    }

    func clearMediaState(forTab tabID: TabID) {
        tabsPlayingMedia.remove(tabID)
    }

    // MARK: - Auto-archive sweep

    public func runArchiveSweep(now: Date = Date()) {
        var newState = state
        var changed = false

        for space in newState.spaces {
            guard let profile = newState.profiles.first(where: { $0.id == space.profileID }),
                  let interval = profile.archivePolicy.interval
            else { continue }
            let activeTabID = newState.activeTabBySpace[space.id]

            for tabID in space.today {
                guard let tab = newState.tabs[tabID] else { continue }
                guard tabID != activeTabID else { continue }
                guard tab.splitGroupID == nil else { continue }
                guard !tabsPlayingMedia.contains(tabID) else { continue }
                guard now.timeIntervalSince(tab.lastAccessedAt) > interval else { continue }

                if let spaceIndex = newState.spaces.firstIndex(where: { $0.id == space.id }) {
                    newState.spaces[spaceIndex].today.removeAll { $0 == tabID }
                }
                var archived = tab
                archived.section = .archived
                archived.archivedAt = now
                archived.isUnloaded = true
                newState.tabs[tabID] = archived
                changed = true
            }
        }

        if changed {
            state = newState
        }
    }

    private func startAutoArchiveTimer(interval: TimeInterval) {
        autoArchiveTask?.cancel()
        autoArchiveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                self?.runArchiveSweep()
            }
        }
    }

    public func stopAutoArchiveTimer() {
        autoArchiveTask?.cancel()
        autoArchiveTask = nil
    }
}

