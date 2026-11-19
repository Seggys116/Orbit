import CryptoKit
import Foundation

/// Chrome native messaging framing: a 4-byte little-endian length, then that many bytes of UTF-8 JSON.
nonisolated enum NativeMessageFraming {

    static let maximumMessageLength = 8 * 1024 * 1024

    nonisolated enum Failure: Error, Equatable {
        case messageTooLarge(Int)
    }

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    /// Collects bytes as they arrive and hands back each complete message. A length past `maximumMessageLength` poisons the stream.
    nonisolated struct Decoder: Sendable {
        private var buffer = Data()

        init() {}

        var bufferedByteCount: Int { buffer.count }

        mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var messages: [Data] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 24
                guard length <= NativeMessageFraming.maximumMessageLength else {
                    buffer.removeAll()
                    throw Failure.messageTooLarge(length)
                }
                guard buffer.count >= 4 + length else { break }
                messages.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
                buffer = Data(buffer[(start + 4 + length)...])
            }
            return messages
        }
    }
}

/// How the helper spells binary values: base64 when its capabilities say so (always, on macOS), otherwise hex with an optional 0x prefix.
nonisolated enum SystemPasswordsBinaryEncoding: Sendable, Equatable {
    case base64
    case hex

    func encode(_ bytes: [UInt8], hexPrefix: Bool = true) -> String {
        switch self {
        case .base64:
            return Data(bytes).base64EncodedString()
        case .hex:
            let digits = bytes.map { String(format: "%02x", $0) }.joined()
            return hexPrefix ? "0x" + digits : digits
        }
    }

    func decode(_ text: String) -> [UInt8]? {
        switch self {
        case .base64:
            return Data(base64Encoded: text).map(Array.init)
        case .hex:
            var digits = Substring(text)
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2) }
            guard digits.count % 2 == 0 else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(digits.count / 2)
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
    }
}

/// JSON written in the key order given, which the helper's messages are built in.
nonisolated indirect enum WireJSON: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([WireJSON])
    case object([(String, WireJSON)])

    static func == (lhs: WireJSON, rhs: WireJSON) -> Bool { lhs.serialized == rhs.serialized }

    var serialized: String {
        switch self {
        case .string(let text): return Self.quoted(text)
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let items): return "[" + items.map(\.serialized).joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { Self.quoted($0.0) + ":" + $0.1.serialized }.joined(separator: ",") + "}"
        }
    }

    var data: Data { Data(serialized.utf8) }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// AES-128-GCM over the first 16 bytes of the SRP session key, with a 16-byte nonce and a 16-byte tag. The two directions lay out
/// SDATA differently: what Orbit sends is ciphertext, tag, nonce; what the helper sends is nonce, ciphertext, tag.
nonisolated struct SystemPasswordsCipher: Sendable {

    nonisolated enum Layout: Sendable {
        case clientToHelper
        case helperToClient
    }

    nonisolated enum Failure: Error, Equatable {
        case shortKey
        case shortMessage
        case authenticationFailed
    }

    static let nonceLength = 16
    static let tagLength = 16

    private let keyBytes: [UInt8]

    private var key: SymmetricKey { SymmetricKey(data: keyBytes) }

    init(sessionKey: [UInt8]) throws {
        guard sessionKey.count >= 16 else { throw Failure.shortKey }
        keyBytes = Array(sessionKey.prefix(16))
    }

    func seal(_ plaintext: Data, layout: Layout, nonce nonceBytes: [UInt8]? = nil) throws -> Data {
        let nonceData = Data(nonceBytes ?? Self.randomBytes(Self.nonceLength))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceData))
        switch layout {
        case .clientToHelper: return box.ciphertext + box.tag + nonceData
        case .helperToClient: return nonceData + box.ciphertext + box.tag
        }
    }

    func open(_ sdata: Data, layout: Layout) throws -> Data {
        let bytes = [UInt8](sdata)
        guard bytes.count >= Self.nonceLength + Self.tagLength else { throw Failure.shortMessage }
        let nonce: [UInt8]
        let ciphertext: [UInt8]
        let tag: [UInt8]
        switch layout {
        case .clientToHelper:
            let tagStart = bytes.count - Self.nonceLength - Self.tagLength
            ciphertext = Array(bytes[0..<tagStart])
            tag = Array(bytes[tagStart..<(tagStart + Self.tagLength)])
            nonce = Array(bytes[(bytes.count - Self.nonceLength)...])
        case .helperToClient:
            nonce = Array(bytes[0..<Self.nonceLength])
            ciphertext = Array(bytes[Self.nonceLength..<(bytes.count - Self.tagLength)])
            tag = Array(bytes[(bytes.count - Self.tagLength)...])
        }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(nonce)), ciphertext: Data(ciphertext), tag: Data(tag))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw Failure.authenticationFailed
        }
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
