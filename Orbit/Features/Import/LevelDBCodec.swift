//  Byte primitives for the LevelDB format Chromium stores site data in.

import Foundation

enum LevelDBFormat {
    static let tableMagic: UInt64 = 0xdb47_7524_8b80_fb57
    static let footerLength = 48
    static let blockTrailerLength = 5
    static let logBlockSize = 32768
    static let logHeaderLength = 7
    static let comparatorName = "leveldb.BytewiseComparator"

    enum Compression: UInt8 {
        case uncompressed = 0
        case snappy = 1
        case zstd = 2
    }

    enum LogRecordType: UInt8 {
        case zero = 0
        case full = 1
        case first = 2
        case middle = 3
        case last = 4
    }

    enum ValueType: UInt8 {
        case deletion = 0
        case value = 1
    }
}

struct RawCursor {
    let buffer: UnsafeRawBufferPointer
    var offset: Int
    let end: Int

    init(_ buffer: UnsafeRawBufferPointer, offset: Int = 0, end: Int? = nil) {
        self.buffer = buffer
        self.offset = offset
        self.end = end ?? buffer.count
    }

    var isAtEnd: Bool { offset >= end }
    var remaining: Int { max(0, end - offset) }

    mutating func byte() -> UInt8? {
        guard offset < end else { return nil }
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift <= 63 {
            guard let byte = byte() else { return nil }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func varint32() -> Int? {
        guard let value = varint(), value <= UInt64(Int32.max) else { return nil }
        return Int(value)
    }

    mutating func uint32() -> UInt32? {
        guard offset + 4 <= end else { return nil }
        defer { offset += 4 }
        return buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
    }

    mutating func uint64() -> UInt64? {
        guard offset + 8 <= end else { return nil }
        defer { offset += 8 }
        return buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
    }

    mutating func range(_ count: Int) -> Range<Int>? {
        guard count >= 0, offset + count <= end else { return nil }
        defer { offset += count }
        return offset..<(offset + count)
    }

    mutating func lengthPrefixedRange() -> Range<Int>? {
        guard let length = varint32() else { return nil }
        return range(length)
    }

    func data(_ range: Range<Int>) -> Data {
        Data(buffer[range])
    }
}

enum Varint {
    static func append(_ value: UInt64, to bytes: inout [UInt8]) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

    static func appendLengthPrefixed(_ payload: Data, to bytes: inout [UInt8]) {
        append(UInt64(payload.count), to: &bytes)
        bytes.append(contentsOf: payload)
    }
}

/// Castagnoli CRC, masked the way LevelDB masks it in a record header.
enum CRC32C {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0x82f6_3b78 : value >> 1
            }
            table[index] = value
        }
        return table
    }()

    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ 0xffff_ffff
    }

    static func mask(_ crc: UInt32) -> UInt32 {
        ((crc >> 15) | (crc << 17)) &+ 0xa282_ead8
    }
}

/// Decompressor only: nothing Orbit writes is compressed.
enum Snappy {

    static func decompress(_ buffer: UnsafeRawBufferPointer, range: Range<Int>) -> [UInt8]? {
        var cursor = RawCursor(buffer, offset: range.lowerBound, end: range.upperBound)
        guard let expected = cursor.varint(), expected <= 1 << 31 else { return nil }

        var output = [UInt8]()
        output.reserveCapacity(Int(expected))

        while !cursor.isAtEnd {
            guard let tag = cursor.byte() else { return nil }
            if tag & 0x03 == 0 {
                var length = Int(tag >> 2) + 1
                if length > 60 {
                    let extra = length - 60
                    guard extra <= 4 else { return nil }
                    var raw = 0
                    for shift in 0..<extra {
                        guard let byte = cursor.byte() else { return nil }
                        raw |= Int(byte) << (8 * shift)
                    }
                    length = raw + 1
                }
                guard let literal = cursor.range(length) else { return nil }
                output.append(contentsOf: buffer[literal])
                continue
            }

            let length: Int
            let offset: Int
            switch tag & 0x03 {
            case 1:
                guard let low = cursor.byte() else { return nil }
                length = 4 + Int((tag >> 2) & 0x07)
                offset = (Int(tag >> 5) << 8) | Int(low)
            case 2:
                guard let low = cursor.byte(), let high = cursor.byte() else { return nil }
                length = Int(tag >> 2) + 1
                offset = Int(low) | (Int(high) << 8)
            default:
                var raw = 0
                for shift in 0..<4 {
                    guard let byte = cursor.byte() else { return nil }
                    raw |= Int(byte) << (8 * shift)
                }
                length = Int(tag >> 2) + 1
                offset = raw
            }

            guard offset > 0, offset <= output.count else { return nil }
            var source = output.count - offset
            for _ in 0..<length {
                output.append(output[source])
                source += 1
            }
        }

        guard output.count == Int(expected) else { return nil }
        return output
    }
}
