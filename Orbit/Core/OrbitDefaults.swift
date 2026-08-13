import Foundation
import OSLog

/// Where every Orbit setting is read and written. Only the installed browser gets
/// `UserDefaults.standard`. A named suite excludes the app's own domain from its search list
/// in both directions, so a scoped run can neither read nor overwrite the real preferences.
public enum OrbitDefaults {

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "OrbitDefaults")

    /// Per bundle, like the development data root: the demo and an Xcode-run Orbit are two
    /// different browsers and must not write each other's settings.
    static func developmentSuiteName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        OrbitRuntimeScope.productionBundleIdentifier
            + ".development-" + OrbitDataRoot.developmentName(for: bundleIdentifier)
    }

    /// The pid is what lets a later run tell an abandoned suite from a live process's.
    static let testSuitePrefix = OrbitRuntimeScope.productionBundleIdentifier + ".test-"

    public static let standard: UserDefaults = {
        if OrbitRuntimeScope.current == .test { removeAbandonedTestSuites() }
        return make(for: OrbitRuntimeScope.current)
    }()

    static func make(for scope: OrbitRuntimeScope) -> UserDefaults {
        switch scope {
        case .production:
            return .standard
        case .development:
            return open(suiteNamed: developmentSuiteName())
        case .test:
            let name = "\(testSuitePrefix)\(getpid())-\(UUID().uuidString)"
            let defaults = open(suiteNamed: name)
            defaults.removePersistentDomain(forName: name)
            return defaults
        }
    }

    /// Never falls back to `.standard`: that fallback is the user's real preferences.
    private static func open(suiteNamed name: String) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: name) else {
            logger.fault("could not open the preferences suite \(name, privacy: .public)")
            fatalError("could not open the preferences suite \(name)")
        }
        return defaults
    }

    static var preferencesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// Removes only suites this type created whose owning process is gone.
    static func removeAbandonedTestSuites(in directory: URL = preferencesDirectory) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".plist") {
            let suite = String(name.dropLast(".plist".count))
            guard let owner = ownerProcessID(ofSuiteNamed: suite), !OrbitProcessLiveness.isAlive(owner) else { continue }
            let file = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            // cfprefsd can write the domain back out after the removal; flush before unlinking.
            CFPreferencesAppSynchronize(suite as CFString)
            try? fileManager.removeItem(at: file)
        }
    }

    static func ownerProcessID(ofSuiteNamed suite: String) -> pid_t? {
        guard suite.hasPrefix(testSuitePrefix) else { return nil }
        let fields = suite.dropFirst(testSuitePrefix.count).split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false
        )
        guard fields.count == 2,
              let owner = pid_t(fields[0]), owner > 0,
              UUID(uuidString: String(fields[1])) != nil
        else { return nil }
        return owner
    }
}
