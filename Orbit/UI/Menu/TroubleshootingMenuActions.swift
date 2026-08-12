import AppKit
import Foundation

@MainActor
enum TroubleshootingMenuActions {

    static func revealOrbitData(env: AppEnvironment) {
        NSWorkspace.shared.activateFileViewerSelecting([orbitDataDirectory(env: env)])
    }

    @discardableResult
    static func copyOrbitInfo(env: AppEnvironment) -> String {
        let report = orbitInfoReport(env: env)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        return report
    }

    static func orbitInfoReport(env: AppEnvironment) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let engineState = env.engine == nil ? "not running" : "running"
        return """
        Orbit \(version) (\(build))
        Engine: \(ChromiumBuild.engineDescription), \(engineState)
        System: \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)
        Data: \(orbitDataDirectory(env: env).path)
        """
    }

    // Reads env.store, not StateStore.defaultRootDirectory(): a demo or Incognito window has its own window-scoped document, and revealing the global default would open the real user's data folder from an app not using it.
    private static func orbitDataDirectory(env: AppEnvironment) -> URL {
        env.store.stateStore.rootDirectory
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown architecture"
        #endif
    }
}
