import Compression
import Foundation

nonisolated public enum ZipArchiveExtractor {

    // MARK: - Limits

    public struct Limits: Sendable, Equatable {
        public var maxTotalUncompressedBytes: Int
        public var maxEntryCount: Int
        public var maxCompressionRatio: Double

        public init(maxTotalUncompressedBytes: Int, maxEntryCount: Int, maxCompressionRatio: Double) {
            self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
            self.maxEntryCount = maxEntryCount
            self.maxCompressionRatio = maxCompressionRatio
        }

        // maxEntryCount is a CPU-cost bound, not the real DoS guard — maxTotalUncompressedBytes and
        // maxCompressionRatio already bound that; 10,000 was too low for real extensions (Wappalyzer's
        // real CRX ships 13,244 entries, mostly per-locale files).
        public static let `default` = Limits(
            maxTotalUncompressedBytes: 300 * 1024 * 1024,
            maxEntryCount: 50_000,
            maxCompressionRatio: 300
        )
    }

    // MARK: - Extraction

    public static func extract(
        _ data: Data,
        to destination: URL,
        limits: Limits = .default,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> [String] {
        let bytes = [UInt8](data)

        let eocdOffset = try locateEndOfCentralDirectory(in: bytes)
        try rejectIfZip64(bytes: bytes, eocdOffset: eocdOffset)

        let entryCount = try readUInt16(bytes, at: eocdOffset + 10)
        let centralDirectorySize = try readUInt32(bytes, at: eocdOffset + 12)
        let centralDirectoryOffset = try readUInt32(bytes, at: eocdOffset + 16)

        guard Int(entryCount) <= limits.maxEntryCount else {
            throw ZipArchiveError.entryCountLimitExceeded(limit: limits.maxEntryCount)
        }

        let entries = try parseCentralDirectory(
            bytes: bytes,
            offset: Int(centralDirectoryOffset),
            size: Int(centralDirectorySize),
            count: Int(entryCount)
        )

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Orbit-ZipExtract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        do {
            let extractedPaths = try extractEntries(entries, bytes: bytes, into: stagingRoot, limits: limits, onProgress: onProgress)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            } else {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            try moveStagingIntoPlace(from: stagingRoot, to: destination)

            return extractedPaths
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
    }

    // MARK: - Planning
    // Metadata-only checks run here, in entry order, before any byte is written,
    // since the size/ratio limits are order-dependent.

    private struct PlannedFile {
        let entryIndex: Int
        let name: String
        let destinationPath: String
        let dataRange: Range<Int>
        let compressionMethod: UInt16
        let uncompressedSize: Int
        let crc32: UInt32
    }

    private static func extractEntries(
        _ entries: [CDEntry],
        bytes: [UInt8],
        into stagingRoot: URL,
        limits: Limits,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> [String] {
        let rootPath = stagingRoot.standardizedFileURL.path
        let totalEntries = entries.count

        var extractedPaths: [String] = []
        extractedPaths.reserveCapacity(totalEntries)
        var planned: [PlannedFile] = []
        planned.reserveCapacity(totalEntries)
        var directoriesToCreate: [String] = []
        var seenDirectories: Set<String> = []
        var totalUncompressedBytes = 0

        for (index, entry) in entries.enumerated() {
            try validate(name: entry.fileName)
            try validateNotSymlink(entry)

            let destinationPath = try resolvedDestination(for: entry.fileName, rootPath: rootPath)

            if entry.isDirectory {
                // compressedSize isn't a meaningful check here: DEFLATE still produces a
                // nonzero-length stream for an empty directory (a real CRX ships this way).
                guard entry.uncompressedSize == 0 else {
                    throw ZipArchiveError.directoryEntryHasData(name: entry.fileName)
                }
                if seenDirectories.insert(destinationPath).inserted {
                    directoriesToCreate.append(destinationPath)
                }
                extractedPaths.append(entry.fileName)
                continue
            }

            guard entry.generalPurposeFlag & 0x1 == 0 else {
                throw ZipArchiveError.encryptedEntryNotSupported(name: entry.fileName)
            }
            guard entry.compressionMethod == 0 || entry.compressionMethod == 8 else {
                throw ZipArchiveError.unsupportedCompressionMethod(name: entry.fileName, method: entry.compressionMethod)
            }

            totalUncompressedBytes += Int(entry.uncompressedSize)
            guard totalUncompressedBytes <= limits.maxTotalUncompressedBytes else {
                throw ZipArchiveError.totalUncompressedSizeLimitExceeded(limit: limits.maxTotalUncompressedBytes)
            }
            try checkCompressionRatio(entry: entry, limits: limits)

            if entry.compressionMethod == 0, entry.compressedSize != entry.uncompressedSize {
                throw ZipArchiveError.declaredSizeMismatch(
                    name: entry.fileName,
                    declared: Int(entry.uncompressedSize),
                    actual: Int(entry.compressedSize)
                )
            }

            let dataRange = try locateLocalFileData(bytes: bytes, entry: entry)

            let parent = parentPath(of: destinationPath)
            if parent.count > rootPath.count, seenDirectories.insert(parent).inserted {
                directoriesToCreate.append(parent)
            }

            planned.append(PlannedFile(
                entryIndex: index,
                name: entry.fileName,
                destinationPath: destinationPath,
                dataRange: dataRange,
                compressionMethod: entry.compressionMethod,
                uncompressedSize: Int(entry.uncompressedSize),
                crc32: entry.crc32
            ))
            extractedPaths.append(entry.fileName)
        }

        // Sorted shortest-first so a parent is always made before its child,
        // and deduplicated above so a 13k-entry archive issues a few hundred
        // createDirectory calls rather than one per file.
        for path in directoriesToCreate.sorted(by: { $0.count < $1.count }) {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: nil
            )
        }

        let progress = ProgressCounter(total: totalEntries, onProgress: onProgress)
        progress.advance(by: totalEntries - planned.count)

        let failure = FirstFailure()
        bytes.withUnsafeBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: planned.count) { slot in
                guard !failure.hasFailed else { return }
                let file = planned[slot]
                do {
                    try writeEntry(file, source: buffer)
                } catch {
                    failure.record(error, at: file.entryIndex)
                }
                progress.advance(by: 1)
            }
        }
        if let error = failure.error { throw error }
        progress.flush()

        return extractedPaths
    }

    private static func writeEntry(_ file: PlannedFile, source: UnsafeBufferPointer<UInt8>) throws {
        guard let base = source.baseAddress else {
            throw ZipArchiveError.truncatedArchive("compressed data for \(file.name)")
        }
        let compressed = UnsafeBufferPointer(start: base + file.dataRange.lowerBound, count: file.dataRange.count)

        switch file.compressionMethod {
        case 0:
            guard compressed.count == file.uncompressedSize else {
                throw ZipArchiveError.declaredSizeMismatch(
                    name: file.name, declared: file.uncompressedSize, actual: compressed.count
                )
            }
            guard CRC32.checksum(compressed) == file.crc32 else {
                throw ZipArchiveError.crcMismatch(name: file.name)
            }
            try write(compressed, toPath: file.destinationPath, name: file.name)
        default:
            var output = [UInt8](unsafeUninitializedCapacity: max(file.uncompressedSize, 1)) { _, initialized in
                initialized = file.uncompressedSize
            }
            try output.withUnsafeMutableBufferPointer { destination in
                try inflate(compressed, into: destination, expectedSize: file.uncompressedSize, name: file.name)
                guard CRC32.checksum(UnsafeBufferPointer(destination)) == file.crc32 else {
                    throw ZipArchiveError.crcMismatch(name: file.name)
                }
                try write(UnsafeBufferPointer(destination), toPath: file.destinationPath, name: file.name)
            }
        }
    }

    // Deliberately not atomic: the whole staging directory moves into place once,
    // so per-entry atomicity buys nothing and measured 78% of the unpack.
    private static func write(_ contents: UnsafeBufferPointer<UInt8>, toPath path: String, name: String) throws {
        // O_NOFOLLOW as a third layer under validateNotSymlink and the
        // containment check: nothing may ever be written through a symlink,
        // whatever put one in the staging tree.
        let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644) }
        guard descriptor >= 0 else {
            throw ZipArchiveError.entryNotWritable(name: name, reason: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var written = 0
        while written < contents.count {
            guard let base = contents.baseAddress else { break }
            let result = Darwin.write(descriptor, base + written, contents.count - written)
            if result < 0 {
                if errno == EINTR { continue }
                throw ZipArchiveError.entryNotWritable(name: name, reason: String(cString: strerror(errno)))
            }
            if result == 0 { break }
            written += result
        }
        guard written == contents.count else {
            throw ZipArchiveError.entryNotWritable(name: name, reason: "wrote \(written) of \(contents.count) bytes")
        }
    }

    // MARK: - Concurrency helpers

    private final class FirstFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: (index: Int, error: Error)?
        private var failed = false

        var hasFailed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failed
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return recorded?.error
        }

        // Lowest entry index wins, so a parallel run reports the same entry a
        // serial one would have stopped at.
        func record(_ error: Error, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            failed = true
            if let existing = recorded, existing.index <= index { return }
            recorded = (index, error)
        }
    }

    // Reporting every entry pushed 13k hops onto the main actor, costing more
    // than the unpack itself; the counter stays exact, only reporting is bounded.
    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Int
        private let stride: Int
        private let onProgress: (@Sendable (Int, Int) -> Void)?
        private var completed = 0
        private var lastReported = -1

        init(total: Int, onProgress: (@Sendable (Int, Int) -> Void)?) {
            self.total = total
            self.stride = max(1, total / 100)
            self.onProgress = onProgress
        }

        func advance(by amount: Int) {
            guard let onProgress, amount > 0 else { return }
            lock.lock()
            completed += amount
            let shouldReport = completed / stride != lastReported / stride || completed == total
            let snapshot = completed
            if shouldReport { lastReported = completed }
            lock.unlock()
            if shouldReport { onProgress(snapshot, total) }
        }

        func flush() {
            guard let onProgress else { return }
            lock.lock()
            let snapshot = completed
            let alreadyReported = lastReported == completed
            lastReported = completed
            lock.unlock()
            if !alreadyReported { onProgress(snapshot, total) }
        }
    }

    private static func checkCompressionRatio(entry: CDEntry, limits: Limits) throws {
        guard entry.uncompressedSize > 0 else { return }
        guard entry.compressedSize > 0 else {
            throw ZipArchiveError.compressionRatioLimitExceeded(
                name: entry.fileName,
                ratio: .infinity,
                limit: limits.maxCompressionRatio
            )
        }
        let ratio = Double(entry.uncompressedSize) / Double(entry.compressedSize)
        guard ratio <= limits.maxCompressionRatio else {
            throw ZipArchiveError.compressionRatioLimitExceeded(
                name: entry.fileName,
                ratio: ratio,
                limit: limits.maxCompressionRatio
            )
        }
    }

    private static func moveStagingIntoPlace(from staging: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try FileManager.default.copyItem(at: staging, to: destination)
            try? FileManager.default.removeItem(at: staging)
        }
    }

    // MARK: - Central directory entry

    private struct CDEntry {
        let generalPurposeFlag: UInt16
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let externalAttributes: UInt32
        let localHeaderOffset: UInt32
        let fileName: String

        var isDirectory: Bool { fileName.hasSuffix("/") }
    }

    private static func parseCentralDirectory(
        bytes: [UInt8],
        offset: Int,
        size: Int,
        count: Int
    ) throws -> [CDEntry] {
        guard offset >= 0, size >= 0, offset + size <= bytes.count else {
            throw ZipArchiveError.truncatedArchive("central directory")
        }

        var entries: [CDEntry] = []
        entries.reserveCapacity(count)
        var cursor = offset
        let end = offset + size

        for _ in 0..<count {
            guard cursor + 46 <= end, cursor + 46 <= bytes.count else {
                throw ZipArchiveError.truncatedArchive("central directory entry header")
            }
            let signature = try readUInt32(bytes, at: cursor)
            guard signature == 0x02014b50 else {
                throw ZipArchiveError.centralDirectorySignatureMismatch(offset: cursor)
            }

            let generalPurposeFlag = try readUInt16(bytes, at: cursor + 8)
            let compressionMethod = try readUInt16(bytes, at: cursor + 10)
            let crc32 = try readUInt32(bytes, at: cursor + 16)
            let compressedSize = try readUInt32(bytes, at: cursor + 20)
            let uncompressedSize = try readUInt32(bytes, at: cursor + 24)
            let fileNameLength = Int(try readUInt16(bytes, at: cursor + 28))
            let extraFieldLength = Int(try readUInt16(bytes, at: cursor + 30))
            let fileCommentLength = Int(try readUInt16(bytes, at: cursor + 32))
            let externalAttributes = try readUInt32(bytes, at: cursor + 38)
            let localHeaderOffset = try readUInt32(bytes, at: cursor + 42)

            guard compressedSize != 0xFFFFFFFF,
                  uncompressedSize != 0xFFFFFFFF,
                  localHeaderOffset != 0xFFFFFFFF else {
                throw ZipArchiveError.zip64NotSupported
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd >= nameStart, nameEnd <= end, nameEnd <= bytes.count else {
                throw ZipArchiveError.truncatedArchive("central directory file name")
            }
            let nameBytes = Array(bytes[nameStart..<nameEnd])

            // Checked on the raw bytes: a Swift String can legally contain
            // an embedded NUL, which a post-decode check could miss.
            guard !nameBytes.contains(0) else {
                throw ZipArchiveError.fileNameContainsNulByte(rawByteCount: nameBytes.count)
            }
            guard let fileName = String(bytes: nameBytes, encoding: .utf8) else {
                throw ZipArchiveError.fileNameNotDecodable(rawByteCount: nameBytes.count)
            }
            guard !fileName.isEmpty else {
                throw ZipArchiveError.pathTraversalRejected(name: "(empty)")
            }

            let recordEnd = nameEnd + extraFieldLength + fileCommentLength
            guard recordEnd >= nameEnd, recordEnd <= end, recordEnd <= bytes.count else {
                throw ZipArchiveError.truncatedArchive("central directory extra/comment fields for \(fileName)")
            }

            entries.append(CDEntry(
                generalPurposeFlag: generalPurposeFlag,
                compressionMethod: compressionMethod,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                externalAttributes: externalAttributes,
                localHeaderOffset: localHeaderOffset,
                fileName: fileName
            ))

            cursor = recordEnd
        }

        return entries
    }

    // Must use the local header's own filename/extra-field lengths to locate the data offset; the central directory's copies are not guaranteed to match. Returns the range rather than a copy: copying every entry's compressed bytes out re-materialised the whole archive a second time.
    private static func locateLocalFileData(bytes: [UInt8], entry: CDEntry) throws -> Range<Int> {
        let localOffset = Int(entry.localHeaderOffset)
        guard localOffset >= 0, localOffset + 30 <= bytes.count else {
            throw ZipArchiveError.truncatedArchive("local header for \(entry.fileName)")
        }
        let signature = try readUInt32(bytes, at: localOffset)
        guard signature == 0x04034b50 else {
            throw ZipArchiveError.localHeaderSignatureMismatch(name: entry.fileName)
        }

        let localNameLength = Int(try readUInt16(bytes, at: localOffset + 26))
        let localExtraLength = Int(try readUInt16(bytes, at: localOffset + 28))
        let dataStart = localOffset + 30 + localNameLength + localExtraLength
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataStart >= localOffset, dataEnd >= dataStart, dataEnd <= bytes.count else {
            throw ZipArchiveError.truncatedArchive("compressed data for \(entry.fileName)")
        }

        return dataStart..<dataEnd
    }

    // MARK: - End of Central Directory

    private static func locateEndOfCentralDirectory(in bytes: [UInt8]) throws -> Int {
        let minimumSize = 22
        guard bytes.count >= minimumSize else {
            throw ZipArchiveError.notAZipArchive
        }

        let maxCommentLength = 65535
        let searchFloor = max(0, bytes.count - minimumSize - maxCommentLength)

        var cursor = bytes.count - minimumSize
        while cursor >= searchFloor {
            if bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4b, bytes[cursor + 2] == 0x05, bytes[cursor + 3] == 0x06 {
                let commentLength = Int(try readUInt16(bytes, at: cursor + 20))
                if cursor + minimumSize + commentLength == bytes.count {
                    return cursor
                }
            }
            cursor -= 1
        }

        throw ZipArchiveError.endOfCentralDirectoryNotFound
    }

    private static func rejectIfZip64(bytes: [UInt8], eocdOffset: Int) throws {
        let entryCountOnDisk = try readUInt16(bytes, at: eocdOffset + 8)
        let totalEntryCount = try readUInt16(bytes, at: eocdOffset + 10)
        let centralDirectorySize = try readUInt32(bytes, at: eocdOffset + 12)
        let centralDirectoryOffset = try readUInt32(bytes, at: eocdOffset + 16)

        if entryCountOnDisk == 0xFFFF || totalEntryCount == 0xFFFF
            || centralDirectorySize == 0xFFFFFFFF || centralDirectoryOffset == 0xFFFFFFFF {
            throw ZipArchiveError.zip64NotSupported
        }

        if eocdOffset >= 20 {
            let locatorOffset = eocdOffset - 20
            if let signature = try? readUInt32(bytes, at: locatorOffset), signature == 0x07064b50 {
                throw ZipArchiveError.zip64NotSupported
            }
        }
    }

    // MARK: - Name / path validation

    private static func validate(name: String) throws {
        guard !name.contains("\\") else {
            throw ZipArchiveError.fileNameContainsBackslash(name: name)
        }
        guard !name.hasPrefix("/") else {
            throw ZipArchiveError.absolutePathRejected(name: name)
        }

        let components = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { String($0) == ".." }) else {
            throw ZipArchiveError.pathTraversalRejected(name: name)
        }
    }

    private static func validateNotSymlink(_ entry: CDEntry) throws {
        let unixMode = entry.externalAttributes >> 16
        let fileTypeMask: UInt32 = 0xF000
        let symlinkType: UInt32 = 0xA000
        guard unixMode & fileTypeMask != symlinkType else {
            throw ZipArchiveError.symlinkRejected(name: entry.fileName)
        }
    }

    // Independent layer from validate(name:)'s `..` check; do not remove either.
    // Normalises lexically, not via URL.standardizedFileURL, which cost 43µs/entry.
    private static func resolvedDestination(for name: String, rootPath: String) throws -> String {
        var components: [Substring] = []
        for component in name.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != ".." else {
                throw ZipArchiveError.pathTraversalRejected(name: name)
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            throw ZipArchiveError.pathTraversalRejected(name: name)
        }
        let candidate = rootPath + "/" + components.joined(separator: "/")
        guard candidate == rootPath || candidate.hasPrefix(rootPath + "/") else {
            throw ZipArchiveError.pathTraversalRejected(name: name)
        }
        return candidate
    }

    private static func parentPath(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return path }
        return String(path[path.startIndex..<index])
    }

    // MARK: - Byte reading

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw ZipArchiveError.truncatedArchive("2-byte field at offset \(offset)")
        }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw ZipArchiveError.truncatedArchive("4-byte field at offset \(offset)")
        }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    // MARK: - Decompression

    // Do not switch COMPRESSION_ZLIB to a zlib-wrapping approach: it decodes raw DEFLATE, the correct method for ZIP's compression method 8, and a truncated output can still pass this size check, so the CRC-32 check in writeEntry must stay.
    private static func inflate(
        _ compressed: UnsafeBufferPointer<UInt8>,
        into destination: UnsafeMutableBufferPointer<UInt8>,
        expectedSize: Int,
        name: String
    ) throws {
        guard expectedSize > 0 else { return }
        guard !compressed.isEmpty, let sourceBase = compressed.baseAddress else {
            throw ZipArchiveError.declaredSizeMismatch(name: name, declared: expectedSize, actual: 0)
        }
        guard let destinationBase = destination.baseAddress else {
            throw ZipArchiveError.declaredSizeMismatch(name: name, declared: expectedSize, actual: 0)
        }

        let decodedCount = compression_decode_buffer(
            destinationBase, expectedSize, sourceBase, compressed.count, nil, COMPRESSION_ZLIB
        )
        guard decodedCount == expectedSize else {
            throw ZipArchiveError.declaredSizeMismatch(name: name, declared: expectedSize, actual: decodedCount)
        }
    }
}

// MARK: - CRC-32

private enum CRC32 {
    // Slice-by-8: eight tables, eight bytes folded per iteration. The
    // byte-at-a-time table this replaced ran over every uncompressed byte of
    // every entry.
    private static let tables: [[UInt32]] = {
        var tables = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 8)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            tables[0][index] = value
        }
        for index in 0..<256 {
            for slice in 1..<8 {
                let previous = tables[slice - 1][index]
                tables[slice][index] = (previous >> 8) ^ tables[0][Int(previous & 0xFF)]
            }
        }
        return tables
    }()

    static func checksum(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        guard let base = bytes.baseAddress else { return 0 }
        var crc: UInt32 = 0xFFFFFFFF
        return tables.withUnsafeBufferPointer { tableList in
            var offset = 0
            let count = bytes.count
            tableList[0].withUnsafeBufferPointer { t0 in
            tableList[1].withUnsafeBufferPointer { t1 in
            tableList[2].withUnsafeBufferPointer { t2 in
            tableList[3].withUnsafeBufferPointer { t3 in
            tableList[4].withUnsafeBufferPointer { t4 in
            tableList[5].withUnsafeBufferPointer { t5 in
            tableList[6].withUnsafeBufferPointer { t6 in
            tableList[7].withUnsafeBufferPointer { t7 in
                while offset + 8 <= count {
                    let word0 = crc
                        ^ UInt32(base[offset])
                        ^ (UInt32(base[offset + 1]) << 8)
                        ^ (UInt32(base[offset + 2]) << 16)
                        ^ (UInt32(base[offset + 3]) << 24)
                    crc = t7[Int(word0 & 0xFF)]
                        ^ t6[Int((word0 >> 8) & 0xFF)]
                        ^ t5[Int((word0 >> 16) & 0xFF)]
                        ^ t4[Int((word0 >> 24) & 0xFF)]
                        ^ t3[Int(base[offset + 4])]
                        ^ t2[Int(base[offset + 5])]
                        ^ t1[Int(base[offset + 6])]
                        ^ t0[Int(base[offset + 7])]
                    offset += 8
                }
                while offset < count {
                    crc = t0[Int((crc ^ UInt32(base[offset])) & 0xFF)] ^ (crc >> 8)
                    offset += 1
                }
            }}}}}}}}
            return crc ^ 0xFFFFFFFF
        }
    }
}

// MARK: - Errors

public enum ZipArchiveError: LocalizedError, Equatable {
    case notAZipArchive
    case endOfCentralDirectoryNotFound
    case zip64NotSupported
    case truncatedArchive(String)
    case centralDirectorySignatureMismatch(offset: Int)
    case localHeaderSignatureMismatch(name: String)
    case fileNameContainsNulByte(rawByteCount: Int)
    case fileNameNotDecodable(rawByteCount: Int)
    case fileNameContainsBackslash(name: String)
    case absolutePathRejected(name: String)
    case pathTraversalRejected(name: String)
    case symlinkRejected(name: String)
    case directoryEntryHasData(name: String)
    case encryptedEntryNotSupported(name: String)
    case unsupportedCompressionMethod(name: String, method: UInt16)
    case declaredSizeMismatch(name: String, declared: Int, actual: Int)
    case crcMismatch(name: String)
    case entryNotWritable(name: String, reason: String)
    case entryCountLimitExceeded(limit: Int)
    case totalUncompressedSizeLimitExceeded(limit: Int)
    case compressionRatioLimitExceeded(name: String, ratio: Double, limit: Double)

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "The data is too small to be a ZIP archive."
        case .endOfCentralDirectoryNotFound:
            return "No End Of Central Directory record was found; this is not a valid ZIP archive."
        case .zip64NotSupported:
            return "This archive requires ZIP64, which is not supported."
        case .truncatedArchive(let context):
            return "The archive is truncated or corrupt while reading \(context)."
        case .centralDirectorySignatureMismatch(let offset):
            return "The central directory is corrupt: no valid entry signature at offset \(offset)."
        case .localHeaderSignatureMismatch(let name):
            return "The local file header for \"\(name)\" is corrupt: no valid signature at its recorded offset."
        case .fileNameContainsNulByte(let rawByteCount):
            return "An entry's filename (\(rawByteCount) bytes) contains a NUL byte and was rejected."
        case .fileNameNotDecodable(let rawByteCount):
            return "An entry's filename (\(rawByteCount) bytes) is not valid UTF-8 and was rejected."
        case .fileNameContainsBackslash(let name):
            return "Entry \"\(name)\" contains a backslash, which is not a valid ZIP path separator, and was rejected."
        case .absolutePathRejected(let name):
            return "Entry \"\(name)\" is an absolute path and was rejected."
        case .pathTraversalRejected(let name):
            return "Entry \"\(name)\" would extract outside the destination directory and was rejected."
        case .symlinkRejected(let name):
            return "Entry \"\(name)\" is a symbolic link and was rejected."
        case .directoryEntryHasData(let name):
            return "Directory entry \"\(name)\" declares nonzero size, which is not valid, and was rejected."
        case .encryptedEntryNotSupported(let name):
            return "Entry \"\(name)\" is encrypted, which is not supported."
        case .unsupportedCompressionMethod(let name, let method):
            return "Entry \"\(name)\" uses unsupported compression method \(method) (only stored and deflate are supported)."
        case .declaredSizeMismatch(let name, let declared, let actual):
            return "Entry \"\(name)\" declared \(declared) uncompressed bytes but produced \(actual)."
        case .crcMismatch(let name):
            return "Entry \"\(name)\" failed its CRC-32 check; its extracted content does not match the archive."
        case .entryNotWritable(let name, let reason):
            return "Entry \"\(name)\" could not be written to the staging directory: \(reason)."
        case .entryCountLimitExceeded(let limit):
            return "The archive contains more than the maximum of \(limit) entries."
        case .totalUncompressedSizeLimitExceeded(let limit):
            return "The archive's total uncompressed size exceeds the maximum of \(limit) bytes."
        case .compressionRatioLimitExceeded(let name, let ratio, let limit):
            return "Entry \"\(name)\" has a compression ratio of \(ratio):1, which exceeds the maximum of \(limit):1 and looks like a decompression bomb."
        }
    }
}
