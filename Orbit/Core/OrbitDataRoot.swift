//  Every store names its subdirectory here so a new store cannot land on the real profile.
//  Which root a process gets comes from OrbitRuntimeScope, read from the running process
//  rather than from a switch a test can set — such a switch once let a test environment
//  prune the real profile's Space icons.

import Foundation
import OSLog

struct OrbitDataRoot: Sendable, Equatable {

    let url: URL

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "OrbitDataRoot")

    static var productionBundleIdentifier: String { OrbitRuntimeScope.productionBundleIdentifier }

    /// Exactly `~/Library/Application Support/Orbit` — the directory the real
    /// browser has always used. Never construct one of these for a demo or a test.
    static var production: OrbitDataRoot {
        OrbitDataRoot(url: applicationSupportBase.appendingPathComponent("Orbit", isDirectory: true))
    }

    /// One stable directory per bundle, in a place no release reads.
    static func development(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> OrbitDataRoot {
        let url = developmentBase
            .appendingPathComponent(developmentName(for: bundleIdentifier), isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return OrbitDataRoot(url: url)
    }

    static var developmentBase: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitDev", isDirectory: true)
    }

    /// The last component of the bundle identifier, not the whole thing: Chromium puts sockets
    /// in its user data directory and `sun_path` is 104 bytes, which $TMPDIR already half spends.
    static func developmentName(for bundleIdentifier: String?) -> String {
        let identifier = bundleIdentifier ?? productionBundleIdentifier
        let last = identifier.split(separator: ".").last.map(String.init) ?? ""
        return last.isEmpty ? productionBundleIdentifier : last
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
        let root = make(for: OrbitRuntimeScope.current)
        logger.log("""
        scope \(OrbitRuntimeScope.current.rawValue, privacy: .public) — \
        stores default to \(root.url.path, privacy: .public)
        """)
        return root
    }()

    static func make(for scope: OrbitRuntimeScope) -> OrbitDataRoot {
        switch scope {
        case .production: return production
        case .development: return development()
        case .test: return scratch(label: "Process")
        }
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
    var pendingSiteData: URL { directory("PendingSiteData") }

    var downloadsFile: URL { directory("Downloads").appendingPathComponent("downloads.json", isDirectory: false) }
    var boostsFile: URL { directory("Boosts").appendingPathComponent("boosts.json", isDirectory: false) }
    var siteSearchFile: URL { directory("SiteSearch").appendingPathComponent("site-search.json", isDirectory: false) }
    var historyDatabase: URL { directory("History").appendingPathComponent("history.sqlite3", isDirectory: false) }

    private func directory(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: true)
    }
}
