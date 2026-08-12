import Foundation

public extension BrowserStore {

    var profiles: [Profile] { state.profiles }

    func profile(_ id: ProfileID) -> Profile? {
        state.profiles.first { $0.id == id }
    }

    var defaultProfile: Profile? {
        state.profiles.filter(\.isPersistent).min(by: { $0.createdAt < $1.createdAt })
            ?? state.profiles.min(by: { $0.createdAt < $1.createdAt })
    }

    @discardableResult
    func createProfile(
        name: String,
        symbolName: String = "person.crop.circle",
        tint: ThemeColor = ThemeColor(red: 0.45, green: 0.42, blue: 0.95),
        isPersistent: Bool = true
    ) -> ProfileID {
        let profile = Profile(name: name, symbolName: symbolName, tint: tint, isPersistent: isPersistent)
        var newState = state
        newState.profiles.append(profile)
        state = newState
        return profile.id
    }

    func renameProfile(_ id: ProfileID, to name: String) {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        var newState = state
        newState.profiles[index].name = name
        state = newState
    }

    func setProfileTint(_ tint: ThemeColor, forProfile id: ProfileID) {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        var newState = state
        newState.profiles[index].tint = tint
        state = newState
    }

    func setProfileSymbol(_ symbolName: String, forProfile id: ProfileID) {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        var newState = state
        newState.profiles[index].symbolName = symbolName
        state = newState
    }

    @discardableResult
    func deleteProfile(_ id: ProfileID) -> Bool {
        guard state.profiles.count > 1, let index = state.profiles.firstIndex(where: { $0.id == id }) else { return false }
        var newState = state
        newState.profiles.remove(at: index)

        let replacementID = newState.profiles.filter(\.isPersistent).min(by: { $0.createdAt < $1.createdAt })?.id
            ?? newState.profiles.min(by: { $0.createdAt < $1.createdAt })?.id
        guard let replacementID else { return false } // unreachable given the guard above; keeps this total

        for spaceIndex in newState.spaces.indices where newState.spaces[spaceIndex].profileID == id {
            newState.spaces[spaceIndex].profileID = replacementID
        }
        state = newState
        return true
    }
}
