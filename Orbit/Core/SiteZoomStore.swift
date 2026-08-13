import Foundation

@MainActor
enum SiteZoomStore {

    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    static let defaultsKey = "OrbitSiteZoomLevels.v1"

    static let defaultZoomFactor: Double = 1.0

    // Restricted to scheme, not "has a host": orbit://note/<uuid> parses host
    // "note", which would otherwise collapse every note onto one zoom entry.
    private static let zoomableSchemes: Set<String> = ["http", "https"]

    static func hostKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), zoomableSchemes.contains(scheme) else { return nil }
        guard let host = url.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    static func zoomFactor(forHost host: String) -> Double? {
        storedLevels()[host.lowercased()]
    }

    static func setZoomFactor(_ factor: Double, forHost host: String) {
        let key = host.lowercased()
        guard !key.isEmpty else { return }
        var levels = storedLevels()
        if factor == defaultZoomFactor {
            guard levels.removeValue(forKey: key) != nil else { return }
        } else {
            let clamped = min(max(factor, ZoomStep.p25.rawValue), ZoomStep.p500.rawValue)
            guard levels[key] != clamped else { return }
            levels[key] = clamped
        }
        defaults.set(levels, forKey: defaultsKey)
    }

    static func allZoomFactors() -> [String: Double] {
        storedLevels()
    }

    static func removeAll() {
        defaults.removeObject(forKey: defaultsKey)
    }

    // A malformed payload reads as empty rather than trapping.
    private static func storedLevels() -> [String: Double] {
        guard let raw = defaults.dictionary(forKey: defaultsKey) else { return [:] }
        return raw.compactMapValues { $0 as? Double }
    }
}
