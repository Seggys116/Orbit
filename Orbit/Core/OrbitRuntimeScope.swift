import Foundation
import OSLog

/// Which copy of Orbit this process is. Everything that can reach real user data —
/// Application Support, preferences, engine profile, Keychain, iCloud — resolves through this.
enum OrbitRuntimeScope: String, Sendable {

    case production
    case development
    case test

    static let productionBundleIdentifier = "com.zak-noble-clarke.Orbit"

    static let overrideEnvironmentName = "ORBIT_DATA_SCOPE"

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "OrbitRuntimeScope")

    static let current: OrbitRuntimeScope = {
        let scope = resolve(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleURL: Bundle.main.bundleURL,
            environment: ProcessInfo.processInfo.environment
        )
        logger.log("""
        scope \(scope.rawValue, privacy: .public) — \
        bundle \(Bundle.main.bundleIdentifier ?? "<none>", privacy: .public) \
        at \(Bundle.main.bundleURL.path, privacy: .public)
        """)
        return scope
    }()

    var isProduction: Bool { self == .production }

    static func resolve(
        bundleIdentifier: String?,
        bundleURL: URL,
        environment: [String: String]
    ) -> OrbitRuntimeScope {
        // First and unconditional: no switch a test bundle can set may reach production.
        if environment["XCTestConfigurationFilePath"] != nil { return .test }
        if environment["ORBIT_SMOKE_PROBE"] == "1" { return .test }
        let isWebStoreProbe = environment["ORBIT_WEBSTORE_PROBE"] != nil
        let wantsRealProfile = isTrue(environment["ORBIT_PROBE_REAL_PROFILE"])
        if isWebStoreProbe, !wantsRealProfile { return .test }

        guard bundleIdentifier == productionBundleIdentifier else { return .development }

        switch environment[overrideEnvironmentName]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "production": return .production
        case "development", "dev": return .development
        case "test", "scratch": return .test
        default: break
        }

        if isWebStoreProbe { return .production }

        if isBuildProduct(bundleURL) || isLaunchedByXcode(environment) { return .development }
        return .production
    }

    static func isBuildProduct(_ bundleURL: URL) -> Bool {
        let components = bundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if components.contains("DerivedData") { return true }
        for (index, component) in components.enumerated()
        where component == "Build" && index + 1 < components.count && components[index + 1] == "Products" {
            return true
        }
        return false
    }

    // Only variables Xcode alone sets. DYLD_* and its __XPC_DYLD_* carriers are excluded on
    // purpose: launchd folds `launchctl setenv DYLD_LIBRARY_PATH` into every GUI launch, so
    // reading them would hide a real user's data behind an unrelated machine setting.
    private static let xcodeLaunchVariables = [
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
        "XCODE_VERSION_ACTUAL",
    ]

    static func isLaunchedByXcode(_ environment: [String: String]) -> Bool {
        xcodeLaunchVariables.contains { environment[$0]?.isEmpty == false }
    }

    /// An unset or empty variable means "not this run"; so does any value that is not a yes.
    private static func isTrue(_ raw: String?) -> Bool {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }
}
