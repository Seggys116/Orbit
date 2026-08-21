//  Reads a LevelDB directory without opening it, so nothing is locked.

import Foundation

struct LevelDBRecord: Sendable, Hashable {
    var key: Data
    var value: Data
}

enum LevelDBReadError: Error, LocalizedError {
    case unreadable(String, reason: String)
    case malformed(String)
    case unsupportedCompression(UInt8)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name, let reason): return "Couldn't read \(name): \(reason)"
        case .malformed(let name): return "\(name) is not a LevelDB file Orbit understands."
        case .unsupportedCompression(let raw): return "This database uses compression Orbit can't read (type \(raw))."
        }
    }
}

enum LevelDBReader {

    struct Manifest {
        var logNumbers: Set<UInt64> = []
        var liveFileNumbers: Set<UInt64> = []
        var lastSequence: UInt64 = 0
    }

    private struct Versioned {
        var sequence: UInt64
        var value: Data?
    }

    /// Newest sequence wins, deletions dropped.
    static func readAll(directory: URL) throws -> [LevelDBRecord] {
        var latest: [Data: Versioned] = [:]
        try forEachEntry(directory: directory) { key, value, sequence in
            if let existing = latest[key], existing.sequence > sequence { return }
            latest[key] = Versioned(sequence: sequence, value: value)
        }
        return latest.compactMap { key, versioned in
            versioned.value.map { LevelDBRecord(key: key, value: $0) }
        }
        .sorted { $0.key.lexicographicallyPrecedes($1.key) }
    }

    /// Every stored entry, superseded versions and deletions (`nil`) included.
    static func forEachEntry(
        directory: URL,
        _ body: (Data, Data?, UInt64) throws -> Void
    ) throws {
        let manifest = try? readManifest(directory: directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

        var tables = names.filter { $0.hasSuffix(".ldb") || $0.hasSuffix(".sst") }
        if let live = manifest?.liveFileNumbers, !live.isEmpty {
            tables = tables.filter { name in fileNumber(name).map(live.contains) ?? true }
        }

        for name in tables.sorted() {
            try readTable(at: directory.appendingPathComponent(name, isDirectory: false), body)
        }
        for name in names.filter({ $0.hasSuffix(".log") }).sorted() {
            try readLog(at: directory.appendingPathComponent(name, isDirectory: false), body)
        }
    }

    static func fileNumber(_ name: String) -> UInt64? {
        UInt64(name.prefix(while: { $0.isNumber }))
    }

    // MARK: - Manifest

    static func readManifest(directory: URL) throws -> Manifest {
        let currentURL = directory.appendingPathComponent("CURRENT", isDirectory: false)
        guard let current = try? String(contentsOf: currentURL, encoding: .utf8) else {
            throw LevelDBReadError.unreadable("CURRENT", reason: "missing")
        }
        let name = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, isValidManifestName(name) else { throw LevelDBReadError.malformed("CURRENT") }

        var manifest = Manifest()
        let data = try mapped(directory.appendingPathComponent(name, isDirectory: false))
        data.withUnsafeBytes { buffer in
            forEachLogPayload(in: buffer) { payload in
                applyVersionEdit(payload, to: &manifest)
            }
        }
        return manifest
    }

    private static func isValidManifestName(_ name: String) -> Bool {
        guard !name.contains("/"), !name.contains("\\") else { return false }
        guard name != ".", name != ".." else { return false }
        return !name.hasPrefix("~")
    }

    private static func applyVersionEdit(_ payload: UnsafeRawBufferPointer, to manifest: inout Manifest) {
        var cursor = RawCursor(payload)
        while !cursor.isAtEnd {
            guard let tag = cursor.varint32() else { return }
            switch tag {
            case 1:
                guard cursor.lengthPrefixedRange() != nil else { return }
            case 2, 9:
                guard let number = cursor.varint() else { return }
                if number > 0 { manifest.logNumbers.insert(number) }
            case 3:
                guard cursor.varint() != nil else { return }
            case 4:
                guard let sequence = cursor.varint() else { return }
                manifest.lastSequence = max(manifest.lastSequence, sequence)
            case 5:
                guard cursor.varint32() != nil, cursor.lengthPrefixedRange() != nil else { return }
            case 6:
                guard cursor.varint32() != nil, let number = cursor.varint() else { return }
                manifest.liveFileNumbers.remove(number)
            case 7:
                guard cursor.varint32() != nil,
                      let number = cursor.varint(),
                      cursor.varint() != nil,
                      cursor.lengthPrefixedRange() != nil,
                      cursor.lengthPrefixedRange() != nil
                else { return }
                manifest.liveFileNumbers.insert(number)
            default:
                return
            }
        }
    }

    // MARK: - Tables

    static func readTable(at url: URL, _ body: (Data, Data?, UInt64) throws -> Void) throws {
        let data = try mapped(url)
        guard data.count >= LevelDBFormat.footerLength else { return }
        try data.withUnsafeBytes { buffer in
            var footer = RawCursor(buffer, offset: buffer.count - LevelDBFormat.footerLength)
            guard let metaindex = blockHandle(&footer), let index = blockHandle(&footer) else {
                throw LevelDBReadError.malformed(url.lastPathComponent)
            }
            _ = metaindex

            let indexBlock = try block(at: index, in: buffer, name: url.lastPathComponent)
            var handles: [(offset: Int, size: Int)] = []
            try forEachBlockEntry(indexBlock) { _, value in
                value.withUnsafeBufferPointer { pointer in
                    var cursor = RawCursor(UnsafeRawBufferPointer(pointer))
                    if let handle = blockHandle(&cursor) { handles.append(handle) }
                }
            }

            for handle in handles {
                let dataBlock = try block(at: handle, in: buffer, name: url.lastPathComponent)
                try forEachBlockEntry(dataBlock) { key, value in
                    guard key.count >= 8 else { return }
                    let trailer = key.suffix(8).withUnsafeBufferPointer { pointer in
                        UnsafeRawBufferPointer(pointer).loadUnaligned(as: UInt64.self).littleEndian
                    }
                    let userKey = Data(key.prefix(key.count - 8))
                    let isValue = LevelDBFormat.ValueType(rawValue: UInt8(trailer & 0xff)) == .value
                    try body(userKey, isValue ? Data(value) : nil, trailer >> 8)
                }
            }
        }
    }

    private static func blockHandle(_ cursor: inout RawCursor) -> (offset: Int, size: Int)? {
        guard let offset = cursor.varint(), let size = cursor.varint(),
              offset <= UInt64(Int.max), size <= UInt64(Int.max)
        else { return nil }
        return (Int(offset), Int(size))
    }

    private static func block(
        at handle: (offset: Int, size: Int),
        in buffer: UnsafeRawBufferPointer,
        name: String
    ) throws -> [UInt8] {
        let end = handle.offset + handle.size
        guard handle.offset >= 0, end + LevelDBFormat.blockTrailerLength <= buffer.count else {
            throw LevelDBReadError.malformed(name)
        }
        switch LevelDBFormat.Compression(rawValue: buffer[end]) {
        case .uncompressed:
            return [UInt8](buffer[handle.offset..<end])
        case .snappy:
            guard let decompressed = Snappy.decompress(buffer, range: handle.offset..<end) else {
                throw LevelDBReadError.malformed(name)
            }
            return decompressed
        case .zstd, .none:
            throw LevelDBReadError.unsupportedCompression(buffer[end])
        }
    }

    private static func forEachBlockEntry(
        _ block: [UInt8],
        _ body: ([UInt8], ArraySlice<UInt8>) throws -> Void
    ) throws {
        guard block.count >= 4 else { return }
        try block.withUnsafeBufferPointer { pointer in
            let buffer = UnsafeRawBufferPointer(pointer)
            let restartCount = Int(buffer.loadUnaligned(fromByteOffset: buffer.count - 4, as: UInt32.self).littleEndian)
            let entriesEnd = buffer.count - 4 - restartCount * 4
            guard entriesEnd >= 0 else { return }

            var cursor = RawCursor(buffer, end: entriesEnd)
            var key: [UInt8] = []
            while !cursor.isAtEnd {
                guard let shared = cursor.varint32(),
                      let unshared = cursor.varint32(),
                      let valueLength = cursor.varint32(),
                      shared <= key.count,
                      let keyRange = cursor.range(unshared),
                      let valueRange = cursor.range(valueLength)
                else { return }
                key.removeLast(key.count - shared)
                key.append(contentsOf: buffer[keyRange])
                try body(key, block[valueRange])
            }
        }
    }

    // MARK: - Logs

    static func readLog(at url: URL, _ body: (Data, Data?, UInt64) throws -> Void) throws {
        let data = try mapped(url)
        try data.withUnsafeBytes { buffer in
            try forEachLogPayload(in: buffer) { payload in
                try readWriteBatch(payload, body)
            }
        }
    }

    private static func readWriteBatch(
        _ payload: UnsafeRawBufferPointer,
        _ body: (Data, Data?, UInt64) throws -> Void
    ) throws {
        var cursor = RawCursor(payload)
        guard let sequence = cursor.uint64(), let count = cursor.uint32() else { return }
        var index: UInt64 = 0
        while index < UInt64(count), !cursor.isAtEnd {
            guard let tag = cursor.byte() else { return }
            switch LevelDBFormat.ValueType(rawValue: tag) {
            case .value:
                guard let keyRange = cursor.lengthPrefixedRange(),
                      let valueRange = cursor.lengthPrefixedRange()
                else { return }
                try body(cursor.data(keyRange), cursor.data(valueRange), sequence &+ index)
            case .deletion:
                guard let keyRange = cursor.lengthPrefixedRange() else { return }
                try body(cursor.data(keyRange), nil, sequence &+ index)
            case nil:
                return
            }
            index += 1
        }
    }

    /// A partial record at the tail is an ordinary live database, so it ends the walk.
    static func forEachLogPayload(
        in buffer: UnsafeRawBufferPointer,
        _ body: (UnsafeRawBufferPointer) throws -> Void
    ) rethrows {
        var offset = 0
        var pending: [UInt8] = []
        var pendingActive = false

        while offset + LevelDBFormat.logHeaderLength <= buffer.count {
            let blockRemaining = LevelDBFormat.logBlockSize - (offset % LevelDBFormat.logBlockSize)
            if blockRemaining < LevelDBFormat.logHeaderLength {
                offset += blockRemaining
                continue
            }

            var cursor = RawCursor(buffer, offset: offset)
            guard cursor.uint32() != nil,
                  let low = cursor.byte(), let high = cursor.byte(),
                  let rawType = cursor.byte()
            else { return }
            let length = Int(low) | (Int(high) << 8)
            guard cursor.offset + length <= buffer.count else { return }
            let payload = cursor.offset..<(cursor.offset + length)
            offset = cursor.offset + length

            switch LevelDBFormat.LogRecordType(rawValue: rawType) {
            case .full:
                try body(UnsafeRawBufferPointer(rebasing: buffer[payload]))
            case .first:
                pending = [UInt8](buffer[payload])
                pendingActive = true
            case .middle:
                guard pendingActive else { continue }
                pending.append(contentsOf: buffer[payload])
            case .last:
                guard pendingActive else { continue }
                pending.append(contentsOf: buffer[payload])
                pendingActive = false
                try pending.withUnsafeBufferPointer { pointer in
                    try body(UnsafeRawBufferPointer(pointer))
                }
                pending = []
            case .zero, nil:
                continue
            }
        }
    }

    private static func mapped(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LevelDBReadError.unreadable(url.lastPathComponent, reason: error.localizedDescription)
        }
    }
}
