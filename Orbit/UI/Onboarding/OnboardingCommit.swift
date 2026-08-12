import Foundation

enum OnboardingCommit {

    @discardableResult
    static func applySearchEngine(
        _ engine: SearchEngine,
        toProfile profileID: ProfileID?,
        in state: inout OrbitState
    ) -> ProfileID? {
        let targetID = profileID ?? state.profiles.first?.id
        guard let targetID,
              let index = state.profiles.firstIndex(where: { $0.id == targetID })
        else { return nil }
        state.profiles[index].searchEngine = engine
        return targetID
    }

    @discardableResult
    static func applyProfileName(
        _ name: String,
        toProfile profileID: ProfileID?,
        in state: inout OrbitState
    ) -> ProfileID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let targetID = profileID ?? state.profiles.first?.id
        guard let targetID,
              let index = state.profiles.firstIndex(where: { $0.id == targetID })
        else { return nil }
        state.profiles[index].name = trimmed
        return targetID
    }

    // MARK: - Spaces setup

    @discardableResult
    static func applySpacesSetup(
        _ drafts: [OnboardingSpaceDraft],
        profileID: ProfileID?,
        in state: inout OrbitState
    ) -> [SpaceID] {
        let trimmed: [OnboardingSpaceDraft] = drafts.compactMap { draft in
            let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            var copy = draft
            copy.name = trimmedName
            return copy
        }
        let effective = trimmed.isEmpty ? OnboardingSpaceDraft.defaults : trimmed

        guard let targetProfileID = profileID ?? state.profiles.first?.id else { return [] }

        if isReplaceableFirstRunDocument(state) {
            return replaceSpaces(with: effective, profileID: targetProfileID, in: &state)
        }
        return mergeSpaces(effective, profileID: targetProfileID, in: &state)
    }

    static func isReplaceableFirstRunDocument(_ state: OrbitState) -> Bool {
        guard state.spaces.count <= 1 else { return false }
        guard state.spaces.allSatisfy({ $0.pinned.isEmpty }) else { return false }
        return state.tabs.values.allSatisfy { $0.url == BrowserStore.firstRunTabURL }
    }

    private static func replaceSpaces(
        with effective: [OnboardingSpaceDraft],
        profileID: ProfileID,
        in state: inout OrbitState
    ) -> [SpaceID] {
        let themes = SpaceThemePalette.defaultThemes(count: effective.count)
        let carriedFavorites = state.spaces.first?.favorites ?? []
        var createdSpaces: [Space] = effective.enumerated().map { index, draft in
            var space = Space(
                name: draft.name,
                theme: themes[index],
                profileID: profileID,
                order: index
            )
            let trimmedEmoji = draft.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedEmoji.isEmpty {
                space.setIconToNone()
            } else {
                space.setIcon(emoji: trimmedEmoji)
            }
            return space
        }
        if let firstIndex = createdSpaces.indices.first {
            createdSpaces[firstIndex].favorites = carriedFavorites
        }

        // Tabs live in the flat state.tabs dictionary; drop the replaced Spaces' tabs or they orphan.
        let replacedSpaceIDs = Set(state.spaces.map(\.id))
        state.tabs = state.tabs.filter { !replacedSpaceIDs.contains($0.value.spaceID) }

        state.spaces = createdSpaces
        state.activeSpaceID = createdSpaces.first?.id

        if let firstSpaceIndex = state.spaces.indices.first {
            let firstTab = Tab(
                spaceID: state.spaces[firstSpaceIndex].id,
                section: .today,
                url: BrowserStore.firstRunTabURL,
                title: "Orbit"
            )
            state.spaces[firstSpaceIndex].today = [firstTab.id]
            state.tabs[firstTab.id] = firstTab
        }

        return createdSpaces.map(\.id)
    }

    private static func mergeSpaces(
        _ drafts: [OnboardingSpaceDraft],
        profileID: ProfileID,
        in state: inout OrbitState
    ) -> [SpaceID] {
        var resolved: [SpaceID] = []
        var nextOrder = (state.spaces.map(\.order).max() ?? -1) + 1

        for draft in drafts {
            let trimmedEmoji = draft.emoji.trimmingCharacters(in: .whitespacesAndNewlines)

            if let existingIndex = state.spaces.firstIndex(where: { isSameSpaceName($0.name, draft.name) }) {
                if !trimmedEmoji.isEmpty {
                    state.spaces[existingIndex].setIcon(emoji: trimmedEmoji)
                }
                resolved.append(state.spaces[existingIndex].id)
                continue
            }

            let theme = SpaceThemePalette
                .defaultThemes(count: 1, avoiding: state.spaces.map(\.theme))
                .first ?? SpaceTheme()
            var space = Space(
                name: draft.name,
                theme: theme,
                profileID: profileID,
                order: nextOrder
            )
            if trimmedEmoji.isEmpty {
                space.setIconToNone()
            } else {
                space.setIcon(emoji: trimmedEmoji)
            }
            nextOrder += 1
            state.spaces.append(space)
            resolved.append(space.id)
        }

        let liveSpaceIDs = Set(state.spaces.map(\.id))
        if state.activeSpaceID == nil || !liveSpaceIDs.contains(state.activeSpaceID!) {
            state.activeSpaceID = resolved.first ?? state.spaces.first?.id
        }

        return resolved
    }

    private static func isSameSpaceName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(
                rhs.trimmingCharacters(in: .whitespacesAndNewlines),
                options: [.caseInsensitive]
            ) == .orderedSame
    }
}

struct OnboardingSpaceDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var emoji: String

    init(id: UUID = UUID(), name: String, emoji: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
    }

    static var defaults: [OnboardingSpaceDraft] {
        [
            OnboardingSpaceDraft(name: "General", emoji: ""),
        ]
    }
}
