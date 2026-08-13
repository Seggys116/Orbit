//  Runs before the engine starts. A site Orbit already has data for keeps it.

import Foundation
import OSLog

struct SiteDataInstallOutcome: Sendable, Hashable {
    var localStorageOriginsInstalled = 0
    var localStorageEntriesInstalled = 0
    var localStorageOriginsSkipped = 0
    var indexedDBOriginsInstalled = 0
    var indexedDBOriginsSkipped = 0
}

enum PendingSiteDataInstaller {

    static let maximumInstallAttempts = 3
    static let localStorageBackupName = "leveldb-before-import"

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "PendingSiteDataInstaller")

    /// `nil` when nothing was staged. A failing import is dropped after three attempts.
    @discardableResult
    static func installIfPending(stagingDirectory: URL, userDataDirectory: URL) -> SiteDataInstallOutcome? {
        let manager = FileManager.default
        let manifestURL = stagingDirectory.appendingPathComponent(ArcSiteDataStager.manifestName, isDirectory: false)
        guard let manifestData = try? Data(contentsOf: manifestURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var manifest = try? decoder.decode(PendingSiteDataManifest.self, from: manifestData),
              manifest.formatVersion == PendingSiteDataManifest.currentFormatVersion
        else {
            try? manager.removeItem(at: stagingDirectory)
            return nil
        }

        manifest.installAttempts += 1
        if manifest.installAttempts > maximumInstallAttempts {
            logger.error("dropping staged site data after \(maximumInstallAttempts, privacy: .public) failed attempts")
            try? manager.removeItem(at: stagingDirectory)
            return nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        var outcome = SiteDataInstallOutcome()
        do {
            try installLocalStorage(from: stagingDirectory, into: userDataDirectory, outcome: &outcome)
        } catch {
            logger.error("could not merge staged Local Storage: \(String(describing: error), privacy: .public)")
            return outcome
        }
        installIndexedDB(from: stagingDirectory, into: userDataDirectory, outcome: &outcome)

        try? manager.removeItem(at: stagingDirectory)
        logger.notice("""
        installed \(outcome.localStorageEntriesInstalled, privacy: .public) Local Storage entries for \
        \(outcome.localStorageOriginsInstalled, privacy: .public) sites \
        (\(outcome.localStorageOriginsSkipped, privacy: .public) already had data) and \
        \(outcome.indexedDBOriginsInstalled, privacy: .public) IndexedDB sites
        """)
        return outcome
    }

    // MARK: - Local Storage

    /// One database holds every origin, so the merge rewrites it whole and keeps a backup.
    private static func installLocalStorage(
        from staging: URL,
        into userDataDirectory: URL,
        outcome: inout SiteDataInstallOutcome
    ) throws {
        let manager = FileManager.default
        let entriesURL = staging.appendingPathComponent(ArcSiteDataStager.localStorageEntriesName, isDirectory: false)
        guard manager.fileExists(atPath: entriesURL.path) else { return }

        let container = userDataDirectory.appendingPathComponent("Local Storage", isDirectory: true)
        let destination = container.appendingPathComponent("leveldb", isDirectory: true)
        let merged = container.appendingPathComponent("leveldb-orbit-import", isDirectory: true)
        try manager.createDirectory(at: container, withIntermediateDirectories: true)
        if manager.fileExists(atPath: merged.path) { try manager.removeItem(at: merged) }

        let existing = manager.fileExists(atPath: destination.path)
            ? try LevelDBReader.readAll(directory: destination)
            : []
        var occupiedStorageKeys = Set(existing.compactMap { LocalStorageKey.storageKey(of: $0.key) })
        let hasVersion = existing.contains { $0.key == LocalStorageKey.versionKey }

        let writer = try LevelDBWriter(directory: merged)
        if !hasVersion {
            try writer.append(key: LocalStorageKey.versionKey, value: Data("1".utf8))
        }
        try writer.append(existing)

        var installedOrigins: Set<String> = []
        var skippedOrigins: Set<String> = []
        try ArcSiteDataStager.forEachStagedEntry(in: entriesURL) { key, value in
            guard let storageKey = LocalStorageKey.storageKey(of: key) else { return }
            guard !occupiedStorageKeys.contains(storageKey) else {
                skippedOrigins.insert(storageKey)
                return
            }
            try writer.append(key: key, value: value)
            installedOrigins.insert(storageKey)
            outcome.localStorageEntriesInstalled += 1
        }
        try writer.finish()

        occupiedStorageKeys.formUnion(installedOrigins)
        outcome.localStorageOriginsInstalled = installedOrigins.count
        outcome.localStorageOriginsSkipped = skippedOrigins.count

        if existing.isEmpty, !manager.fileExists(atPath: destination.path) {
            try manager.moveItem(at: merged, to: destination)
            return
        }
        let backup = container.appendingPathComponent(localStorageBackupName, isDirectory: true)
        if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
        if manager.fileExists(atPath: destination.path) { try manager.moveItem(at: destination, to: backup) }
        try manager.moveItem(at: merged, to: destination)
    }

    // MARK: - IndexedDB

    private static func installIndexedDB(
        from staging: URL,
        into userDataDirectory: URL,
        outcome: inout SiteDataInstallOutcome
    ) {
        let manager = FileManager.default
        let source = staging.appendingPathComponent(ArcSiteDataStager.indexedDBDirectoryName, isDirectory: true)
        guard let names = try? manager.contentsOfDirectory(atPath: source.path) else { return }
        let destination = userDataDirectory.appendingPathComponent("IndexedDB", isDirectory: true)
        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)

        let occupied = Set((try? manager.contentsOfDirectory(atPath: destination.path)) ?? [])
        for name in names.sorted() {
            let databaseName = name.replacingOccurrences(of: ".indexeddb.blob", with: ".indexeddb.leveldb")
            guard !occupied.contains(databaseName) else {
                if name.hasSuffix(".indexeddb.leveldb") { outcome.indexedDBOriginsSkipped += 1 }
                continue
            }
            do {
                try manager.moveItem(
                    at: source.appendingPathComponent(name, isDirectory: true),
                    to: destination.appendingPathComponent(name, isDirectory: true)
                )
                if name.hasSuffix(".indexeddb.leveldb") { outcome.indexedDBOriginsInstalled += 1 }
            } catch {
                logger.error("could not install IndexedDB directory \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
