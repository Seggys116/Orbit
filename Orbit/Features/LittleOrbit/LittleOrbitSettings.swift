import Foundation

enum LittleOrbitSettings {

    enum ArchiveInterval: String, CaseIterable, Identifiable, Sendable {
        case oneHour
        case sixHours
        case twelveHours
        case twentyFourHours
        case never

        var id: String { rawValue }

        // nil means "never close on a timer".
        var seconds: TimeInterval? {
            switch self {
            case .oneHour: return 3600
            case .sixHours: return 6 * 3600
            case .twelveHours: return 12 * 3600
            case .twentyFourHours: return 24 * 3600
            case .never: return nil
            }
        }

        var label: String {
            switch self {
            case .oneHour: return "1 hour"
            case .sixHours: return "6 hours (default)"
            case .twelveHours: return "12 hours"
            case .twentyFourHours: return "24 hours"
            case .never: return "Never"
            }
        }
    }

    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    private static let modifierClickKey = "OrbitLittleOrbitOpensOnModifierClick"
    private static let archiveIntervalKey = "OrbitLittleOrbitArchiveInterval"

    static var opensOnModifierClick: Bool {
        get { defaults.object(forKey: modifierClickKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: modifierClickKey) }
    }

    static var archiveInterval: ArchiveInterval {
        get {
            guard let raw = defaults.string(forKey: archiveIntervalKey),
                  let interval = ArchiveInterval(rawValue: raw) else { return .sixHours }
            return interval
        }
        set { defaults.set(newValue.rawValue, forKey: archiveIntervalKey) }
    }
}
