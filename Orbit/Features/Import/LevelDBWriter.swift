//  Writes a manifest plus one write-ahead log: the shape LevelDB recovers after a crash.

import Foundation

final class LevelDBWriter {

    private static let logFileNumber: UInt64 = 3
    private static let batchByteLimit = 1 << 20

    private let directory: URL
    private let log: LevelDBLogFileWriter
    private var batch: [UInt8] = []
    private var batchCount: UInt32 = 0
    private var nextSequence: UInt64 = 1
    private var didFinish = false

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = String(format: "%06llu.log", Self.logFileNumber)
        log = try LevelDBLogFileWriter(url: directory.appendingPathComponent(name, isDirectory: false))
        beginBatch()
    }

    func append(key: Data, value: Data) throws {
        batch.append(LevelDBFormat.ValueType.value.rawValue)
        Varint.appendLengthPrefixed(key, to: &batch)
        Varint.appendLengthPrefixed(value, to: &batch)
        batchCount += 1
        if batch.count >= Self.batchByteLimit { try flushBatch() }
    }

    func append(_ records: [LevelDBRecord]) throws {
        for record in records { try append(key: record.key, value: record.value) }
    }

    func finish() throws {
        guard !didFinish else { return }
        didFinish = true
        try flushBatch()
        try log.close()
        try writeManifest()
    }

    // MARK: - Batches

    private func beginBatch() {
        batch = [UInt8](repeating: 0, count: 12)
        batchCount = 0
    }

    private func flushBatch() throws {
        guard batchCount > 0 else { return }
        withUnsafeBytes(of: nextSequence.littleEndian) { bytes in
            for (index, byte) in bytes.enumerated() { batch[index] = byte }
        }
        withUnsafeBytes(of: batchCount.littleEndian) { bytes in
            for (index, byte) in bytes.enumerated() { batch[8 + index] = byte }
        }
        try log.addRecord(batch)
        nextSequence += UInt64(batchCount)
        beginBatch()
    }

    // MARK: - Manifest

    private func writeManifest() throws {
        var edit: [UInt8] = []
        Varint.append(1, to: &edit)
        Varint.appendLengthPrefixed(Data(LevelDBFormat.comparatorName.utf8), to: &edit)
        Varint.append(9, to: &edit)
        Varint.append(0, to: &edit)
        Varint.append(2, to: &edit)
        Varint.append(Self.logFileNumber, to: &edit)
        Varint.append(3, to: &edit)
        Varint.append(Self.logFileNumber + 1, to: &edit)
        Varint.append(4, to: &edit)
        Varint.append(nextSequence, to: &edit)

        let manifestName = "MANIFEST-000001"
        let manifest = try LevelDBLogFileWriter(url: directory.appendingPathComponent(manifestName, isDirectory: false))
        try manifest.addRecord(edit)
        try manifest.close()

        try Data("\(manifestName)\n".utf8).write(
            to: directory.appendingPathComponent("CURRENT", isDirectory: false),
            options: .atomic
        )
    }
}

/// The record framing LevelDB uses for its log and its manifest.
final class LevelDBLogFileWriter {

    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var blockOffset = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
    }

    func addRecord(_ payload: [UInt8]) throws {
        var start = 0
        var isFirst = true
        repeat {
            let leftover = LevelDBFormat.logBlockSize - blockOffset
            if leftover < LevelDBFormat.logHeaderLength {
                if leftover > 0 { write([UInt8](repeating: 0, count: leftover)) }
                blockOffset = 0
            }
            let available = LevelDBFormat.logBlockSize - blockOffset - LevelDBFormat.logHeaderLength
            let length = min(payload.count - start, available)
            let isLast = start + length == payload.count
            let type: LevelDBFormat.LogRecordType
            switch (isFirst, isLast) {
            case (true, true): type = .full
            case (true, false): type = .first
            case (false, true): type = .last
            case (false, false): type = .middle
            }
            emit(type, Array(payload[start..<(start + length)]))
            start += length
            isFirst = false
        } while start < payload.count
        if buffer.count >= 1 << 20 { try flush() }
    }

    func close() throws {
        try flush()
        try handle.close()
    }

    private func emit(_ type: LevelDBFormat.LogRecordType, _ fragment: [UInt8]) {
        var header = [UInt8]()
        header.reserveCapacity(LevelDBFormat.logHeaderLength)
        let crc = CRC32C.mask(CRC32C.checksum([type.rawValue] + fragment))
        withUnsafeBytes(of: crc.littleEndian) { header.append(contentsOf: $0) }
        header.append(UInt8(fragment.count & 0xff))
        header.append(UInt8((fragment.count >> 8) & 0xff))
        header.append(type.rawValue)
        write(header)
        write(fragment)
    }

    private func write(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        blockOffset = (blockOffset + bytes.count) % LevelDBFormat.logBlockSize
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
