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
        guard isWindowScoped else { return spaces }
        return [activeSpace].compactMap { $0 }
    }
}
