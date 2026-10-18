import CryptoKit
import Foundation
import OSLog
import WebKit

/// Maps a profile identifier to the UUID of its WKWebsiteDataStore.
/// The UUID is name-based (SHA-256 of a namespace and the scope-qualified profile id), so distinct profiles never share a store
/// and a test, smoke or development run never resolves to the production store even though it runs under the production bundle id.
/// Production keeps using the identifier an earlier release derived for a profile whose store already exists.
@MainActor
final class WebKitDataStoreIdentifiers {

    nonisolated static let namespace = UUID(uuidString: "5C1B0F4E-7D5A-4C0E-9A3E-2F6A8B7D1C33")!

    static let shared = WebKitDataStoreIdentifiers(
        scope: OrbitRuntimeScope.current,
        registryURL: OrbitRuntimeScope.current.isProduction
            ? OrbitDataRoot.processDefault.url.appendingPathComponent("WebsiteDataStoreIdentifiers.json", isDirectory: false)
            : nil,
        installedIdentifiers: { InstalledDataStores.current() }
    )

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "WebKitDataStoreIdentifiers")

    private struct Registry: Codable {
        var version = 1
        var identifiers: [String: UUID] = [:]
    }

    private let scope: OrbitRuntimeScope
    private let registryURL: URL?
    private let installedIdentifiers: () -> Set<UUID>?
    private var registry: Registry

    /// `registryURL` is only used in the production scope, the one that has earlier-release stores to keep reachable.
    init(scope: OrbitRuntimeScope, registryURL: URL?, installedIdentifiers: @escaping () -> Set<UUID>?) {
        self.scope = scope
        self.registryURL = scope.isProduction ? registryURL : nil
        self.installedIdentifiers = installedIdentifiers
        self.registry = Self.loadRegistry(from: self.registryURL)
    }

    func identifier(for profile: String) -> UUID {
        let derived = Self.derivedIdentifier(for: profile, scope: scope)
        guard scope.isProduction else { return derived }
        if let recorded = registry.identifiers[profile] { return recorded }

        let legacy = Self.legacyIdentifier(for: profile)
        // Without the installed set nothing can be decided, so nothing is recorded: the next launch decides with the facts.
        guard let installed = installedIdentifiers() else {
            Self.logger.error("installed data stores unknown; \(profile, privacy: .public) uses its derived identifier for now")
            return derived
        }
        var chosen = derived
        if legacy != derived,
           installed.contains(legacy), !installed.contains(derived),
           !registry.identifiers.values.contains(legacy) {
            chosen = legacy
            Self.logger.log("profile \(profile, privacy: .public) keeps the data store an earlier release created")
        }
        registry.identifiers[profile] = chosen
        save()
        return chosen
    }

    // MARK: - Derivation

    /// RFC 4122 version 5 layout over SHA-256: the first 16 bytes of the digest with the version and variant bits set.
    nonisolated static func derivedIdentifier(for profile: String, scope: OrbitRuntimeScope) -> UUID {
        var input = Data()
        withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
        input.append(Data("\(scope.rawValue):\(profile)".utf8))
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return uuid(from: bytes)
    }

    /// What earlier releases derived: the profile bytes XOR-folded into 16 bytes. Kept only to find stores they created.
    nonisolated static func legacyIdentifier(for profile: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in Array(profile.utf8).enumerated() {
            bytes[index % 16] ^= byte &+ UInt8(truncatingIfNeeded: index)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return uuid(from: bytes)
    }

    private nonisolated static func uuid(from bytes: [UInt8]) -> UUID {
        UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Persistence

    private static func loadRegistry(from url: URL?) -> Registry {
        guard let url, let data = try? Data(contentsOf: url) else { return Registry() }
        guard let decoded = try? JSONDecoder().decode(Registry.self, from: data) else {
            logger.error("ignoring unreadable data store registry at \(url.path, privacy: .public)")
            return Registry()
        }
        return decoded
    }

    private func save() {
        guard let registryURL else { return }
        do {
            try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(registry).write(to: registryURL, options: .atomic)
        } catch {
            Self.logger.error("could not write the data store registry: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The data stores WebKit already holds, read once per process. `preload()` at launch lets the first lookup find the answer waiting.
@MainActor
enum InstalledDataStores {

    private static var cached: Set<UUID>?
    private static var requested = false

    static func preload() {
        guard !requested else { return }
        requested = true
        // The data-store IO run loop is created with the first WKWebsiteDataStore.
        // Fetching identifiers before that dispatches onto a null run loop and
        // dies in os_unfair_lock (address 0x48) on WebsiteDataStoreIO.
        _ = WKWebsiteDataStore.default()
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { cached = Set(identifiers) }
            }
        }
    }

    // WebKit answers on the main queue, so a caller that cannot suspend serves the run loop until it does.
    static func current(timeout: TimeInterval = 10) -> Set<UUID>? {
        preload()
        let deadline = Date().addingTimeInterval(timeout)
        while cached == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return cached
    }
}
