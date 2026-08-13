//  The engine holds its databases open for its whole life, so an import can only stage.

import Foundation
import OSLog

struct PendingSiteDataManifest: Codable, Sendable, Hashable {
    var formatVersion: Int
    var source: String
    var stagedAt: Date
    var localStorageOrigins: [String]
    var localStorageEntries: Int
    var indexedDBDirectories: [String]
    var installAttempts: Int

    static let currentFormatVersion = 1
}

struct SiteDataStagingSummary: Sendable, Hashable {
    var localStorageOrigins = 0
    var localStorageEntries = 0
    var indexedDBOrigins = 0
    var bytesStaged: Int64 = 0

    var isEmpty: Bool { localStorageOrigins == 0 && indexedDBOrigins == 0 }
}

enum ArcSiteDataError: Error, LocalizedError {
    case noSiteData(String)

    var errorDescription: String? {
        switch self {
        case .noSiteData(let path): return "There is no site data at \(path)."
        }
    }
}

/// Storage keys as Chromium serialises them into the Local Storage database.
enum LocalStorageKey {
    static let versionKey = Data("VERSION".utf8)
    static let metaPrefixes = ["METAACCESS:", "META:"]

    /// An origin, or an origin pair (`https://a/^0https://b`) for partitioned data.
    static func storageKey(of key: Data) -> String? {
        let bytes = [UInt8](key)
        if bytes.first == UInt8(ascii: "_") {
            guard let terminator = bytes.firstIndex(of: 0), terminator > 1 else { return nil }
            return String(decoding: bytes[1..<terminator], as: UTF8.self)
        }
        for prefix in metaPrefixes {
            let marker = [UInt8](prefix.utf8)
            guard bytes.count > marker.count, Array(bytes.prefix(marker.count)) == marker else { continue }
            return String(decoding: bytes.dropFirst(marker.count), as: UTF8.self)
        }
        return nil
    }

    /// Extension, DevTools and WebUI keys belong to Arc's surfaces, not to sites.
    static func isWebOrigin(_ storageKey: String) -> Bool {
        storageKey.hasPrefix("https://") || storageKey.hasPrefix("http://")
    }
}

enum ArcSiteDataStager {

    static let manifestName = "manifest.json"
    static let localStorageEntriesName = "LocalStorage.entries"
    static let indexedDBDirectoryName = "IndexedDB"
    static let entriesMagic = Data("OBSD0001".utf8)

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "ArcSiteDataStager")

    /// Replaces anything an earlier import staged.
    static func stage(profileDirectory: URL, into staging: URL) throws -> SiteDataStagingSummary {
        let manager = FileManager.default
        let localStorage = profileDirectory.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
        let indexedDB = profileDirectory.appendingPathComponent("IndexedDB", isDirectory: true)
        guard manager.fileExists(atPath: localStorage.path) || manager.fileExists(atPath: indexedDB.path) else {
            throw ArcSiteDataError.noSiteData(profileDirectory.path)
        }

        if manager.fileExists(atPath: staging.path) {
            try manager.removeItem(at: staging)
        }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var summary = SiteDataStagingSummary()
        var origins: Set<String> = []
        if manager.fileExists(atPath: localStorage.path) {
            let records = try LevelDBReader.readAll(directory: localStorage)
            let importable = records.filter { record in
                guard let key = LocalStorageKey.storageKey(of: record.key) else { return false }
                guard LocalStorageKey.isWebOrigin(key) else { return false }
                origins.insert(key)
                return true
            }
            summary.localStorageEntries = importable.count
            summary.localStorageOrigins = origins.count
            try writeEntries(importable, to: staging.appendingPathComponent(localStorageEntriesName, isDirectory: false))
        }

        let copiedIndexedDB = try stageIndexedDB(from: indexedDB, into: staging)
        summary.indexedDBOrigins = copiedIndexedDB.filter { $0.hasSuffix(".indexeddb.leveldb") }.count

        let manifest = PendingSiteDataManifest(
            formatVersion: PendingSiteDataManifest.currentFormatVersion,
            source: "arc",
            stagedAt: Date(),
            localStorageOrigins: origins.sorted(),
            localStorageEntries: summary.localStorageEntries,
            indexedDBDirectories: copiedIndexedDB,
            installAttempts: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName, isDirectory: false), options: .atomic)

        summary.bytesStaged = directorySize(staging)
        logger.notice("""
        staged \(summary.localStorageEntries, privacy: .public) Local Storage entries from \
        \(summary.localStorageOrigins, privacy: .public) sites and \
        \(summary.indexedDBOrigins, privacy: .public) IndexedDB sites
        """)
        return summary
    }

    /// IndexedDB keeps one directory per origin already, so each is copied whole.
    private static func stageIndexedDB(from source: URL, into staging: URL) throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return [] }
        let destination = staging.appendingPathComponent(indexedDBDirectoryName, isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        var copied: [String] = []
        for name in (try? manager.contentsOfDirectory(atPath: source.path))?.sorted() ?? [] {
            guard name.hasSuffix(".indexeddb.leveldb") || name.hasSuffix(".indexeddb.blob") else { continue }
            guard name.hasPrefix("https_") || name.hasPrefix("http_") else { continue }
            do {
                try manager.copyItem(
                    at: source.appendingPathComponent(name, isDirectory: true),
                    to: destination.appendingPathComponent(name, isDirectory: true)
                )
                copied.append(name)
            } catch {
                logger.error("could not stage IndexedDB directory \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return copied
    }

    // MARK: - Entries file

    static func writeEntries(_ records: [LevelDBRecord], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var buffer = [UInt8](entriesMagic)
        for record in records {
            Varint.appendLengthPrefixed(record.key, to: &buffer)
            Varint.appendLengthPrefixed(record.value, to: &buffer)
            if buffer.count >= 1 << 22 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
    }

    static func forEachStagedEntry(in url: URL, _ body: (Data, Data) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= entriesMagic.count, data.prefix(entriesMagic.count) == entriesMagic else {
            throw LevelDBReadError.malformed(url.lastPathComponent)
        }
        try data.withUnsafeBytes { buffer in
            var cursor = RawCursor(buffer, offset: entriesMagic.count)
            while !cursor.isAtEnd {
                guard let keyRange = cursor.lengthPrefixedRange(),
                      let valueRange = cursor.lengthPrefixedRange()
                else { return }
                try body(cursor.data(keyRange), cursor.data(valueRange))
            }
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
