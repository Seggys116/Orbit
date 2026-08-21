import Foundation

// MARK: - Cache

nonisolated enum CompiledFilterListCache {

    // Bump when the binary layout, or the shape of the types it serialises, changes.
    static let formatVersion: UInt32 = 2

    private static let magic: [UInt8] = Array("OCB1".utf8)

    static func encode(_ output: FilterListParser.Output, contentHash: String) -> Data {
        var writer = BinaryWriter()
        writer.writeRaw(magic)
        writer.writeUInt32(formatVersion)
        writer.writeString(contentHash)

        writer.writeUInt32(UInt32(clamping: output.stats.linesRead))
        writer.writeUInt32(UInt32(clamping: output.stats.blockingRules))
        writer.writeUInt32(UInt32(clamping: output.stats.exceptionRules))
        writer.writeUInt32(UInt32(clamping: output.stats.redirectRules))
        writer.writeUInt32(UInt32(clamping: output.stats.unblockRules))
        writer.writeUInt32(UInt32(clamping: output.stats.cosmeticRules))
        writer.writeUInt32(UInt32(clamping: output.stats.cosmeticExceptionRules))
        writer.writeUInt32(UInt32(clamping: output.stats.unsupportedRules))
        writer.writeUInt32(UInt32(clamping: output.stats.invalidRegexRules))

        writer.writeUInt32(UInt32(clamping: output.network.count))
        for rule in output.network { Self.encode(rule, into: &writer) }

        writer.writeUInt32(UInt32(clamping: output.cosmetic.count))
        for rule in output.cosmetic { Self.encode(rule, into: &writer) }

        return Data(writer.bytes)
    }

    static func decode(_ data: Data, expectedContentHash: String, listID: String) -> FilterListParser.Output? {
        var reader = BinaryReader(data)
        do {
            let storedMagic = try reader.readRaw(magic.count)
            guard storedMagic == magic else { return nil }

            let version = try reader.readUInt32()
            guard version == formatVersion else { return nil }

            let storedHash = try reader.readString()
            guard storedHash == expectedContentHash else { return nil }

            var output = FilterListParser.Output()
            var stats = ContentBlockingCompileStats()
            stats.linesRead = Int(try reader.readUInt32())
            stats.blockingRules = Int(try reader.readUInt32())
            stats.exceptionRules = Int(try reader.readUInt32())
            stats.redirectRules = Int(try reader.readUInt32())
            stats.unblockRules = Int(try reader.readUInt32())
            stats.cosmeticRules = Int(try reader.readUInt32())
            stats.cosmeticExceptionRules = Int(try reader.readUInt32())
            stats.unsupportedRules = Int(try reader.readUInt32())
            stats.invalidRegexRules = Int(try reader.readUInt32())
            output.stats = stats

            let networkCount = Int(try reader.readUInt32())
            output.network.reserveCapacity(networkCount)
            for _ in 0..<networkCount {
                output.network.append(try Self.decodeNetworkRule(from: &reader, listID: listID))
            }

            let cosmeticCount = Int(try reader.readUInt32())
            output.cosmetic.reserveCapacity(cosmeticCount)
            for _ in 0..<cosmeticCount {
                output.cosmetic.append(try Self.decodeCosmeticRule(from: &reader))
            }

            guard reader.isAtEnd else { return nil }

            return output
        } catch {
            return nil
        }
    }

    // MARK: - Network rule

    // Field order must match decodeNetworkRule exactly; matchCase must precede
    // the body since .regex needs it to reconstruct case-sensitivity.
    private static func encode(_ rule: NetworkFilterRule, into writer: inout BinaryWriter) {
        writer.writeUInt8(rule.anchor.rawValue)
        writer.writeBool(rule.anchoredRight)
        writer.writeBool(rule.isException)
        writer.writeBool(rule.isImportant)
        writer.writeBool(rule.matchCase)
        writer.writeUInt32(UInt32(clamping: rule.resourceTypes.rawValue))
        switch rule.thirdParty {
        case nil: writer.writeUInt8(0)
        case .some(true): writer.writeUInt8(1)
        case .some(false): writer.writeUInt8(2)
        }
        writer.writeStringArray(rule.includedDomains)
        writer.writeStringArray(rule.excludedDomains)
        if let redirect = rule.redirect {
            writer.writeUInt8(1)
            writer.writeString(redirect.token)
            writer.writeUInt32(UInt32(bitPattern: Int32(clamping: redirect.priority)))
            writer.writeBool(redirect.isRuleOnly)
            writer.writeBool(redirect.isNone)
        } else {
            writer.writeUInt8(0)
        }
        writer.writeUInt32(UInt32(clamping: rule.unblockModifiers.rawValue))
        if let token = rule.token {
            writer.writeUInt8(1)
            writer.writeUInt64(token)
        } else {
            writer.writeUInt8(0)
        }
        writer.writeString(rule.source)

        switch rule.body {
        case .segments(let segments):
            writer.writeUInt8(0)
            writer.writeUInt32(UInt32(clamping: segments.count))
            for segment in segments { writer.writeBytes(segment) }
        case .regex(let regex):
            writer.writeUInt8(1)
            writer.writeString(regex.pattern)
        }
    }

    private static func decodeNetworkRule(from reader: inout BinaryReader, listID: String) throws -> NetworkFilterRule {
        guard let anchor = NetworkFilterRule.Anchor(rawValue: try reader.readUInt8()) else {
            throw BinaryReader.DecodeError.malformed
        }
        let anchoredRight = try reader.readBool()
        let isException = try reader.readBool()
        let isImportant = try reader.readBool()
        let matchCase = try reader.readBool()
        let resourceTypes = ContentBlockingResourceTypeSet(rawValue: Int(try reader.readUInt32()))
        let thirdPartyTag = try reader.readUInt8()
        let thirdParty: Bool?
        switch thirdPartyTag {
        case 0: thirdParty = nil
        case 1: thirdParty = true
        case 2: thirdParty = false
        default: throw BinaryReader.DecodeError.malformed
        }
        let includedDomains = try reader.readStringArray()
        let excludedDomains = try reader.readStringArray()
        var redirect: RedirectDirective?
        if try reader.readBool() {
            let token = try reader.readString()
            let priority = Int(Int32(bitPattern: try reader.readUInt32()))
            let isRuleOnly = try reader.readBool()
            let isNone = try reader.readBool()
            redirect = RedirectDirective(
                token: token,
                priority: priority,
                isRuleOnly: isRuleOnly,
                isNone: isNone
            )
        }
        let unblockModifiers = UnblockModifiers(rawValue: Int(try reader.readUInt32()))
        let hasToken = try reader.readBool()
        let token: UInt64? = hasToken ? try reader.readUInt64() : nil
        let source = try reader.readString()

        let bodyTag = try reader.readUInt8()
        let body: NetworkFilterRule.Body
        switch bodyTag {
        case 0:
            let count = Int(try reader.readUInt32())
            var segments: [[UInt8]] = []
            segments.reserveCapacity(count)
            for _ in 0..<count { segments.append(try reader.readBytes()) }
            body = .segments(segments)
        case 1:
            let pattern = try reader.readString()
            guard FilterRegexBounds.isSafe(pattern) else { throw BinaryReader.DecodeError.malformed }
            var options: NSRegularExpression.Options = []
            if !matchCase { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                throw BinaryReader.DecodeError.malformed
            }
            body = .regex(regex)
        default:
            throw BinaryReader.DecodeError.malformed
        }

        return NetworkFilterRule(
            body: body,
            anchor: anchor,
            anchoredRight: anchoredRight,
            isException: isException,
            isImportant: isImportant,
            matchCase: matchCase,
            resourceTypes: resourceTypes,
            thirdParty: thirdParty,
            includedDomains: includedDomains,
            excludedDomains: excludedDomains,
            redirect: redirect,
            unblockModifiers: unblockModifiers,
            token: token,
            source: source,
            listID: listID
        )
    }

    // MARK: - Cosmetic rule

    private static func encode(_ rule: CosmeticFilterRule, into writer: inout BinaryWriter) {
        writer.writeString(rule.selector)
        writer.writeStringArray(rule.includedDomains)
        writer.writeStringArray(rule.excludedDomains)
        writer.writeBool(rule.isException)
    }

    private static func decodeCosmeticRule(from reader: inout BinaryReader) throws -> CosmeticFilterRule {
        let selector = try reader.readString()
        let includedDomains = try reader.readStringArray()
        let excludedDomains = try reader.readStringArray()
        let isException = try reader.readBool()
        return CosmeticFilterRule(
            selector: selector,
            includedDomains: includedDomains,
            excludedDomains: excludedDomains,
            isException: isException
        )
    }
}

// MARK: - Binary writer

private struct BinaryWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeRaw(_ raw: [UInt8]) { bytes.append(contentsOf: raw) }

    mutating func writeUInt8(_ value: UInt8) { bytes.append(value) }

    mutating func writeBool(_ value: Bool) { writeUInt8(value ? 1 : 0) }

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    mutating func writeUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func writeBytes(_ raw: [UInt8]) {
        writeUInt32(UInt32(clamping: raw.count))
        writeRaw(raw)
    }

    mutating func writeString(_ string: String) {
        writeBytes(Array(string.utf8))
    }

    mutating func writeStringArray(_ strings: [String]) {
        writeUInt32(UInt32(clamping: strings.count))
        for string in strings { writeString(string) }
    }
}

// MARK: - Binary reader

private struct BinaryReader {
    enum DecodeError: Error { case truncated, malformed }

    private let bytes: [UInt8]
    private var cursor: Int = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var isAtEnd: Bool { cursor == bytes.count }

    mutating func readRaw(_ count: Int) throws -> [UInt8] {
        guard count >= 0, cursor + count <= bytes.count else { throw DecodeError.truncated }
        let slice = Array(bytes[cursor..<(cursor + count)])
        cursor += count
        return slice
    }

    mutating func readUInt8() throws -> UInt8 {
        guard cursor < bytes.count else { throw DecodeError.truncated }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readUInt32() throws -> UInt32 {
        let raw = try readRaw(4)
        return UInt32(raw[0]) | (UInt32(raw[1]) << 8) | (UInt32(raw[2]) << 16) | (UInt32(raw[3]) << 24)
    }

    mutating func readUInt64() throws -> UInt64 {
        let raw = try readRaw(8)
        var value: UInt64 = 0
        for index in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(raw[index])
        }
        return value
    }

    mutating func readBytes() throws -> [UInt8] {
        let count = Int(try readUInt32())
        return try readRaw(count)
    }

    mutating func readString() throws -> String {
        let raw = try readBytes()
        guard let string = String(bytes: raw, encoding: .utf8) else { throw DecodeError.malformed }
        return string
    }

    mutating func readStringArray() throws -> [String] {
        let count = Int(try readUInt32())
        guard count >= 0 else { throw DecodeError.malformed }
        var result: [String] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try readString()) }
        return result
    }
}
