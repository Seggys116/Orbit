import Foundation

enum DebugFlags {

    // Delegate callbacks that would block on a modal or a human-resolved sheet must settle
    // themselves when this is true: an unattended run has nobody to click anything.
    static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // Drives the real Chromium browser, so a decision the engine genuinely blocks on must be
    // taken, not short-circuited — the suite plays the user, and must answer it or close the tab.
    static var isRunningUnderLiveEngine: Bool {
        ProcessInfo.processInfo.environment["ORBIT_LIVE_ENGINE"] != nil
    }

    // Launches the real, signed app bundle — indistinguishable from the browser the user runs.
    // Every decision reaching the real profile must read this: see OrbitDataRoot.isProductionBrowserProcess.
    static var isRunningSmokeProbe: Bool {
        ProcessInfo.processInfo.environment["ORBIT_SMOKE_PROBE"] == "1"
    }
}

// MARK: - UI diagnostic channels

enum DiagnosticChannel: String, CaseIterable {
    case toolbarColour

    case toolbarFrame

    case toolbarHitTest

    case toolbarViewTree

    case contentCard

    case webContentsAttachment

    case contentColumn

    // Also read by the C++ side through orbit_cef::diagnostics::SettingValue, so both
    // halves of the bridge appear in one log stream.
    case webStoreBridge

    // SidebarView's fault invariant assertions must never be gated behind a channel.

    var environmentName: String {
        "ORBIT_LOG_" + Self.screamingSnake(rawValue)
    }

    var preferenceKey: String {
        "OrbitLog" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var legacyEnvironmentNames: [String] {
        switch self {
        case .toolbarViewTree: return ["ORBIT_PROBE_TREE"]
        default: return []
        }
    }

    var isEnabled: Bool {
        if let fromEnvironment = DiagnosticChannel.environmentOverrides[self] {
            return fromEnvironment
        }
        if DiagnosticChannel.allChannelsPreferenceIsOn { return true }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }

    // MARK: Resolution

    private static let allChannelsEnvironmentName = "ORBIT_LOG_UI"
    private static let allChannelsPreferenceKey = "OrbitLogUI"

    private static var allChannelsPreferenceIsOn: Bool {
        UserDefaults.standard.bool(forKey: allChannelsPreferenceKey)
    }

    private static let environmentOverrides: [DiagnosticChannel: Bool] = {
        let environment = ProcessInfo.processInfo.environment
        let master = environment[allChannelsEnvironmentName].flatMap(booleanValue(of:))
        var resolved: [DiagnosticChannel: Bool] = [:]
        for channel in DiagnosticChannel.allCases {
            let names = [channel.environmentName] + channel.legacyEnvironmentNames
            if let own = names.lazy.compactMap({ environment[$0].flatMap(booleanValue(of:)) }).first {
                resolved[channel] = own
            } else if let master {
                resolved[channel] = master
            }
        }
        return resolved
    }()

    /// nil for an unset or empty variable — FOO= means "not this run".
    private static func booleanValue(of raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "": return nil
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    private static func screamingSnake(_ camelCase: String) -> String {
        var out = ""
        for character in camelCase {
            if character.isUppercase, !out.isEmpty { out.append("_") }
            out.append(character.uppercased())
        }
        return out
    }
}
