//  Every store names its subdirectory here so a new store cannot land on the
//  real profile. `.production` is reachable only from the real browser process.
//  The production/scratch decision is read from the running process, never from a
//  switch a test can set — such a switch once let a test environment prune the
//  real profile's Space icons.

import Foundation
import OSLog

struct OrbitDataRoot: Sendable, Equatable {

    let url: URL

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "OrbitDataRoot")

    static let productionBundleIdentifier = "com.zak-noble-clarke.Orbit"

    /// Exactly `~/Library/Application Support/Orbit` — the directory the real
    /// browser has always used. Never construct one of these for a demo or a test.
    static var production: OrbitDataRoot {
        OrbitDataRoot(url: applicationSupportBase.appendingPathComponent("Orbit", isDirectory: true))
    }

    static func scratch(label: String) -> OrbitDataRoot {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitData-\(label)-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return OrbitDataRoot(url: url)
    }

    /// What a store built with no explicit root gets. Resolved once per process.
    static let processDefault: OrbitDataRoot = {
        guard isProductionBrowserProcess else {
            let root = scratch(label: "Process")
            logger.log("""
            not the production browser process \
            (bundle \(Bundle.main.bundleIdentifier ?? "<none>", privacy: .public)) — \
            stores default to \(root.url.path, privacy: .public)
            """)
            return root
        }
        return production
    }()

    static var isProductionBrowserProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        // A probe is a throwaway diagnostic run of the real bundle, so it would otherwise resolve to
        // the real profile. Opt in with ORBIT_PROBE_REAL_PROFILE=1 for the one case that needs it,
        // verifying a Web Store install against the profile the user actually browses with.
        if environment["ORBIT_WEBSTORE_PROBE"] != nil, environment["ORBIT_PROBE_REAL_PROFILE"] == nil {
            return false
        }
        // No opt-in needed; nothing the smoke probe does touches the user's profile.
        // Read directly, not via DebugFlags: this file is recompiled into OrbitTests, which lacks it.
        if environment["ORBIT_SMOKE_PROBE"] == "1" { return false }
        return Bundle.main.bundleIdentifier == productionBundleIdentifier
    }

    var isProduction: Bool { url == OrbitDataRoot.production.url }

    static var applicationSupportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    // MARK: - Owned subdirectories

    var state: URL { directory("State") }
    var notes: URL { directory("Notes") }
    var easels: URL { directory("Easels") }
    var spaceIcons: URL { directory("SpaceIcons") }
    var favicons: URL { directory("Favicons") }
    var extensions: URL { directory("Extensions") }
    var contentBlocking: URL { directory("ContentBlocking") }
    var sync: URL { directory("Sync") }
    var chromiumProfile: URL { directory("Chromium") }

    var downloadsFile: URL { directory("Downloads").appendingPathComponent("downloads.json", isDirectory: false) }
    var boostsFile: URL { directory("Boosts").appendingPathComponent("boosts.json", isDirectory: false) }
    var siteSearchFile: URL { directory("SiteSearch").appendingPathComponent("site-search.json", isDirectory: false) }
    var historyDatabase: URL { directory("History").appendingPathComponent("history.sqlite3", isDirectory: false) }

    private func directory(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: true)
    }
}
