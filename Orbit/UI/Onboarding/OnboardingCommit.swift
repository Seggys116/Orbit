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
        // Drafts linked to existing Spaces (an import created them) are edited in place: replacing the first-run document would discard the imported data.
        let editsExistingSpaces = drafts.contains { $0.existingSpaceID != nil }
        let effective = (trimmed.isEmpty && !editsExistingSpaces) ? OnboardingSpaceDraft.defaults : trimmed

        guard let targetProfileID = profileID ?? state.profiles.first?.id else { return [] }

        if !editsExistingSpaces, isReplaceableFirstRunDocument(state) {
            return replaceSpaces(with: effective, profileID: targetProfileID, in: &state)
        }
        return mergeSpaces(effective, profileID: targetProfileID, in: &state)
    }

    static func isReplaceableFirstRunDocument(_ state: OrbitState) -> Bool {
        guard state.spaces.count <= 1 else { return false }
        guard state.spaces.allSatisfy({ $0.pinned.isEmpty }) else { return false }
        return state.tabs.values.allSatisfy { $0.url == BrowserStore.firstRunTabURL }
    }

    /// One theme per draft: its own pick, else the next default no other pick or earlier default uses; with no picks this equals `SpaceThemePalette.defaultThemes(count:)`.
    static func resolvedThemes(
        for drafts: [OnboardingSpaceDraft],
        avoiding existing: [SpaceTheme] = []
    ) -> [SpaceTheme] {
        var used = existing + drafts.compactMap(\.theme)
        return drafts.map { draft in
            if let chosen = draft.theme { return chosen }
            let next = SpaceThemePalette.nextDefaultTheme(avoiding: used)
            used.append(next)
            return next
        }
    }

    private static func replaceSpaces(
        with effective: [OnboardingSpaceDraft],
        profileID: ProfileID,
        in state: inout OrbitState
    ) -> [SpaceID] {
        let themes = resolvedThemes(for: effective)
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

            if let linkedID = draft.existingSpaceID,
               let linkedIndex = state.spaces.firstIndex(where: { $0.id == linkedID }) {
                state.spaces[linkedIndex].name = draft.name
                if !trimmedEmoji.isEmpty {
                    state.spaces[linkedIndex].setIcon(emoji: trimmedEmoji)
                }
                if let chosen = draft.theme {
                    state.spaces[linkedIndex].theme = chosen
                }
                resolved.append(linkedID)
                continue
            }

            if let existingIndex = state.spaces.firstIndex(where: { isSameSpaceName($0.name, draft.name) }) {
                if !trimmedEmoji.isEmpty {
                    state.spaces[existingIndex].setIcon(emoji: trimmedEmoji)
                }
                if let chosen = draft.theme {
                    state.spaces[existingIndex].theme = chosen
                }
                resolved.append(state.spaces[existingIndex].id)
                continue
            }

            let theme = draft.theme ?? SpaceThemePalette
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
    /// The Space's chosen theme; nil lets the commit assign the next unused default.
    var theme: SpaceTheme?
    /// Set when the draft stands for a Space an import already created, so the commit renames and re-themes it rather than adding another.
    var existingSpaceID: SpaceID?

    init(id: UUID = UUID(), name: String, emoji: String, theme: SpaceTheme? = nil, existingSpaceID: SpaceID? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.theme = theme
        self.existingSpaceID = existingSpaceID
    }

    static func drafts(from spaces: [Space]) -> [OnboardingSpaceDraft] {
        spaces.sorted { $0.order < $1.order }.map { space in
            var emoji = ""
            if case .emoji(let value) = space.resolvedIcon { emoji = value }
            return OnboardingSpaceDraft(
                name: space.name,
                emoji: emoji,
                theme: space.theme,
                existingSpaceID: space.id
            )
        }
    }

    static var defaults: [OnboardingSpaceDraft] {
        [
            OnboardingSpaceDraft(name: "General", emoji: ""),
        ]
    }
}
