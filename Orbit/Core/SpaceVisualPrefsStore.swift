import Foundation

@MainActor
@Observable
final class SpaceVisualPrefsStore {
    static let shared = SpaceVisualPrefsStore()

    private(set) var blurBySpace: [SpaceID: Double] = [:]
    private let defaultsKey = "OrbitSpaceBlurPrefs.v1"

    private init() { load() }

    func blur(for spaceID: SpaceID) -> Double { blurBySpace[spaceID] ?? 0 }

    func setBlur(_ value: Double, for spaceID: SpaceID) {
        blurBySpace[spaceID] = max(0, min(1, value))
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        var result: [SpaceID: Double] = [:]
        for (key, value) in decoded {
            guard let id = UUID(uuidString: key) else { continue }
            result[id] = value
        }
        blurBySpace = result
    }

    private func persist() {
        var encodable: [String: Double] = [:]
        for (id, value) in blurBySpace { encodable[id.uuidString] = value }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
