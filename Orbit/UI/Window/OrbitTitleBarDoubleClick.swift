import AppKit

// Protocol-typed, not a real UserDefaults suite: a fresh UUID-suffixed suite reads back a stale "Maximize" once any real NSWindow exists in-process.
protocol OrbitPreferenceReading {
    func string(forKey defaultName: String) -> String?
}

extension UserDefaults: OrbitPreferenceReading {}

enum OrbitTitleBarDoubleClick {
    static let preferenceKey = "AppleActionOnDoubleClick"

    enum Action: String {
        case minimize = "Minimize"
        case zoom = "Maximize"
        case none = "None"
    }

    static func resolveAction(defaults: OrbitPreferenceReading = UserDefaults.standard) -> Action {
        guard let raw = defaults.string(forKey: preferenceKey), let action = Action(rawValue: raw) else {
            return .zoom
        }
        return action
    }

    static func handle(on window: NSWindow?, defaults: OrbitPreferenceReading = UserDefaults.standard) {
        guard let window else { return }
        switch resolveAction(defaults: defaults) {
        case .minimize: window.performMiniaturize(nil)
        case .zoom: window.performZoom(nil)
        case .none: break
        }
    }
}
