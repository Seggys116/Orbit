import Foundation
import OSLog

private let extensionStateLogger = Logger(subsystem: "com.orbit.browser", category: "WebKitExtensionStateStore")

/// What Orbit remembers about each extension across relaunches: the version it last ran
/// (for onInstalled's reason), optional permissions and hosts the user granted, and the
/// original regexFilter of any dynamic declarativeNetRequest rule Orbit had to rewrite.
struct WebKitExtensionState: Codable, Equatable {
    var lastSeenVersion: String?
    var grantedOptionalPermissions: [String] = []
    var grantedOptionalOrigins: [String] = []
    var dynamicRegexFilters: [String: String] = [:]
}

@MainActor
final class WebKitExtensionStateStore {
    private let directory: URL?
    private var cache: [String: WebKitExtensionState] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// `nil` keeps state in memory only, for an engine with no profile of its own.
    init(directory: URL?) {
        self.directory = directory
    }

    func state(for extensionID: String) -> WebKitExtensionState {
        if let cached = cache[extensionID] { return cached }
        var loaded = WebKitExtensionState()
        if let file = file(for: extensionID),
           let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode(WebKitExtensionState.self, from: data) {
            loaded = decoded
        }
        cache[extensionID] = loaded
        return loaded
    }

    func update(_ extensionID: String, _ change: (inout WebKitExtensionState) -> Void) {
        var current = state(for: extensionID)
        let before = current
        change(&current)
        guard current != before else { return }
        cache[extensionID] = current
        persist(current, for: extensionID)
    }

    /// An uninstall forgets everything, so a reinstall is a fresh install again.
    func remove(_ extensionID: String) {
        cache[extensionID] = nil
        guard let file = file(for: extensionID) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    private func persist(_ state: WebKitExtensionState, for extensionID: String) {
        guard let file = file(for: extensionID) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: file, options: .atomic)
        } catch {
            extensionStateLogger.error("Could not save state for extension \(extensionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func file(for extensionID: String) -> URL? {
        guard let directory, !extensionID.isEmpty, !extensionID.contains("/"), !extensionID.contains("..") else { return nil }
        return directory.appendingPathComponent("\(extensionID).json")
    }
}
