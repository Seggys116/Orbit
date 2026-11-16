import Foundation

extension AppEnvironment {

    var isTornOffWindow: Bool {
        isTornOffWindowSession
    }

    func isTornOffWindow(for space: Space?) -> Bool {
        guard space != nil else { return false }
        return isTornOffWindowSession
    }

    var pagerSpaces: [Space] {
        // An independent ordinary window pages through the same Spaces as the first window; only Incognito and torn-off windows are limited to their own.
        guard isWindowScoped, !isIndependentStandardWindow else { return spaces }
        return [activeSpace].compactMap { $0 }
    }
}
