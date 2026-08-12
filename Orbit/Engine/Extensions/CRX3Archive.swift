import Foundation

nonisolated public struct CRX3Archive {

    public struct AsymmetricKeyProof: Equatable {
        // DER-encoded X.509 SubjectPublicKeyInfo, not a bare PKCS#1 RSAPublicKey.
        public let publicKey: Data
        public let signature: Data

        public init(publicKey: Data, signature: Data) {
            self.publicKey = publicKey
            self.signature = signature
        }
    }

    public let rsaProofs: [AsymmetricKeyProof]
    // Parsed but never cryptographically checked; see CRX3Verifier.
    public let ecdsaProofs: [AsymmetricKeyProof]

    // Kept raw, not decoded: CRX3Verifier needs these exact bytes for its signed payload.
    public let signedHeaderData: Data

    public let crxID: Data
    public let zipPayload: Data
    public let zipPayloadRange: Range<Int>

    public init(
        rsaProofs: [AsymmetricKeyProof],
        ecdsaProofs: [AsymmetricKeyProof],
        signedHeaderData: Data,
        crxID: Data,
        zipPayload: Data,
        zipPayloadRange: Range<Int>
    ) {
        self.rsaProofs = rsaProofs
        self.ecdsaProofs = ecdsaProofs
        self.signedHeaderData = signedHeaderData
        self.crxID = crxID
        self.zipPayload = zipPayload
        self.zipPayloadRange = zipPayloadRange
    }

    // MARK: - Parsing

    private static let magic: [UInt8] = [0x43, 0x72, 0x32, 0x34]
    private static let fixedPreambleSize = 12

    // Parses shape only; call CRX3Verifier before trusting the result.
    public static func parse(_ data: Data) throws -> CRX3Archive {
        guard data.count >= fixedPreambleSize else {
            throw CRX3Error.truncatedContainer(available: data.count, required: fixedPreambleSize)
        }

        let magicEnd = data.index(data.startIndex, offsetBy: 4)
        let magicBytes = [UInt8](data.subdata(in: data.startIndex..<magicEnd))
        guard magicBytes == magic else {
            throw CRX3Error.invalidMagic
        }

        let version = try readUInt32LE(data, at: data.index(data.startIndex, offsetBy: 4))
        guard version != 2 else {
            throw CRX3Error.crx2Unsupported
        }
        guard version == 3 else {
            throw CRX3Error.unsupportedVersion(version)
        }

        let headerSize = try readUInt32LE(data, at: data.index(data.startIndex, offsetBy: 8))

        guard let headerSizeInt = Int(exactly: headerSize) else {
            throw CRX3Error.headerSizeExceedsFile(headerSize: headerSize, fileSize: data.count)
        }
        let remainingAfterPreamble = data.count - fixedPreambleSize
        guard headerSizeInt <= remainingAfterPreamble else {
            throw CRX3Error.headerSizeExceedsFile(headerSize: headerSize, fileSize: data.count)
        }

        let headerStart = data.index(data.startIndex, offsetBy: fixedPreambleSize)
        let headerEnd = data.index(headerStart, offsetBy: headerSizeInt)
        let headerBytes = data.subdata(in: headerStart..<headerEnd)

        let header = try parseCrxFileHeader(headerBytes)
        guard let signedHeaderData = header.signedHeaderData else {
            throw CRX3Error.missingSignedHeaderData
        }

        let signedData = try parseSignedData(signedHeaderData)
        guard signedData.crxID.count == 16 else {
            throw CRX3Error.invalidCrxIDLength(signedData.crxID.count)
        }

        let zipPayload = data.subdata(in: headerEnd..<data.endIndex)
        let zipStartOffset = data.distance(from: data.startIndex, to: headerEnd)
        let zipEndOffset = data.distance(from: data.startIndex, to: data.endIndex)

        return CRX3Archive(
            rsaProofs: header.rsaProofs,
            ecdsaProofs: header.ecdsaProofs,
            signedHeaderData: signedHeaderData,
            crxID: signedData.crxID,
            zipPayload: zipPayload,
            zipPayloadRange: zipStartOffset..<zipEndOffset
        )
    }

    private static func readUInt32LE(_ data: Data, at index: Data.Index) throws -> UInt32 {
        var value: UInt32 = 0
        var cursor = index
        for byteIndex in 0..<4 {
            guard cursor < data.endIndex else {
                throw CRX3Error.truncatedContainer(available: data.count, required: fixedPreambleSize)
            }
            value |= UInt32(data[cursor]) << (8 * byteIndex)
            cursor = data.index(after: cursor)
        }
        return value
    }

    // MARK: - `CrxFileHeader` / `AsymmetricKeyProof` / `SignedData`

    private struct RawCrxFileHeader {
        var rsaProofs: [AsymmetricKeyProof] = []
        var ecdsaProofs: [AsymmetricKeyProof] = []
        var signedHeaderData: Data?
    }

    // field 2 = sha256_with_rsa, field 3 = sha256_with_ecdsa, field 10000 = signed_header_data.
    private static func parseCrxFileHeader(_ data: Data) throws -> RawCrxFileHeader {
        var reader = ProtobufFieldReader(data)
        var result = RawCrxFileHeader()
        while let field = try reader.nextField() {
            switch field.number {
            case 2:
                guard case .lengthDelimited(let bytes) = field.value else {
                    throw CRX3Error.malformedProtobuf("CrxFileHeader field 2 (sha256_with_rsa) was not length-delimited.")
                }
                result.rsaProofs.append(try parseAsymmetricKeyProof(bytes))
            case 3:
                guard case .lengthDelimited(let bytes) = field.value else {
                    throw CRX3Error.malformedProtobuf("CrxFileHeader field 3 (sha256_with_ecdsa) was not length-delimited.")
                }
                result.ecdsaProofs.append(try parseAsymmetricKeyProof(bytes))
            case 10000:
                guard case .lengthDelimited(let bytes) = field.value else {
                    throw CRX3Error.malformedProtobuf("CrxFileHeader field 10000 (signed_header_data) was not length-delimited.")
                }
                result.signedHeaderData = bytes
            default:
                break
            }
        }
        return result
    }

    private static func parseAsymmetricKeyProof(_ data: Data) throws -> AsymmetricKeyProof {
        var reader = ProtobufFieldReader(data)
        var publicKey: Data?
        var signature: Data?
        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                guard case .lengthDelimited(let bytes) = field.value else {
                    throw CRX3Error.malformedProtobuf("AsymmetricKeyProof field 1 (public_key) was not length-delimited.")
                }
                publicKey = bytes
            case 2:
                guard case .lengthDelimited(let bytes) = field.value else {
                    throw CRX3Error.malformedProtobuf("AsymmetricKeyProof field 2 (signature) was not length-delimited.")
                }
                signature = bytes
            default:
                break
            }
        }
        guard let publicKey, let signature else {
            throw CRX3Error.malformedProtobuf("AsymmetricKeyProof is missing public_key or signature.")
        }
        return AsymmetricKeyProof(publicKey: publicKey, signature: signature)
    }

    private struct RawSignedData {
        var crxID: Data = Data()
    }

    // SignedData field 1 = crx_id (16 bytes when present).
    private static func parseSignedData(_ data: Data) throws -> RawSignedData {
        var reader = ProtobufFieldReader(data)
        var result = RawSignedData()
        while let field = try reader.nextField() {
            if field.number == 1, case .lengthDelimited(let bytes) = field.value {
                result.crxID = bytes
            }
        }
        return result
    }
}

// MARK: - Minimal protobuf wire-format reader

private struct ProtobufField {
    enum Value {
        case varint(UInt64)
        case lengthDelimited(Data)
    }
    let number: Int
    let value: Value
}

// Only varint and length-delimited wire types: CRX3's three messages never
// use anything else, so any other wire type is a hard parse failure.
private struct ProtobufFieldReader {
    private let data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func nextField() throws -> ProtobufField? {
        guard offset < data.endIndex else { return nil }

        let tag = try readVarint()
        let fieldNumber = Int(tag >> 3)
        let wireType = tag & 0x7

        switch wireType {
        case 0:
            let value = try readVarint()
            return ProtobufField(number: fieldNumber, value: .varint(value))
        case 2:
            let length = try readVarint()
            guard let lengthInt = Int(exactly: length) else {
                throw CRX3Error.malformedProtobuf("A length-delimited field declared a length that does not fit in memory.")
            }
            guard data.distance(from: offset, to: data.endIndex) >= lengthInt else {
                throw CRX3Error.malformedProtobuf("A length-delimited field's declared length runs past the end of the message.")
            }
            let fieldEnd = data.index(offset, offsetBy: lengthInt)
            let bytes = data.subdata(in: offset..<fieldEnd)
            offset = fieldEnd
            return ProtobufField(number: fieldNumber, value: .lengthDelimited(bytes))
        default:
            throw CRX3Error.malformedProtobuf("Field \(fieldNumber) used wire type \(wireType), which none of CRX3's messages use.")
        }
    }

    // shift < 64 must be checked before each shift, not after: Swift traps
    // on a shift >= 64 rather than wrapping it.
    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.endIndex else {
                throw CRX3Error.malformedProtobuf("A varint was truncated before its terminating byte.")
            }
            let byte = data[offset]
            offset = data.index(after: offset)

            guard shift < 64 else {
                throw CRX3Error.malformedProtobuf("A varint used more continuation bytes than a 64-bit value can need.")
            }
            result |= UInt64(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
    }
}

// MARK: - Errors

nonisolated public enum CRX3Error: LocalizedError, Equatable {
    case truncatedContainer(available: Int, required: Int)
    case invalidMagic
    case crx2Unsupported
    case unsupportedVersion(UInt32)
    case headerSizeExceedsFile(headerSize: UInt32, fileSize: Int)
    case malformedProtobuf(String)
    case missingSignedHeaderData
    case invalidCrxIDLength(Int)
    case signedHeaderDataTooLarge(Int)
    case noRSAProofs
    case invalidPublicKeyDER(String)
    case unsupportedKeyAlgorithm(String)
    case secKeyCreationFailed(String)
    case signatureVerificationFailed
    case crxIDMismatch
    case noValidRSAProof(reasons: [String])

    public var errorDescription: String? {
        switch self {
        case .truncatedContainer(let available, let required):
            return "This file is only \(available) byte(s) long, but a CRX3 container needs at least \(required) for its fixed header."
        case .invalidMagic:
            return "This file does not start with the CRX magic bytes \"Cr24\" and is not a Chrome extension package."
        case .crx2Unsupported:
            return "This file is a CRX2 package. The Chrome Web Store no longer serves CRX2, and Orbit has no way to verify its authenticity."
        case .unsupportedVersion(let version):
            return "This file declares CRX version \(version), which Orbit does not know how to parse (only version 3 is supported)."
        case .headerSizeExceedsFile(let headerSize, let fileSize):
            return "This file's header claims to be \(headerSize) byte(s), which is larger than the \(fileSize)-byte file that contains it."
        case .malformedProtobuf(let reason):
            return "This file's CRX3 header is corrupted: \(reason)"
        case .missingSignedHeaderData:
            return "This file's CRX3 header has no signed_header_data, so there is nothing to verify its signature against."
        case .invalidCrxIDLength(let length):
            return "This file's declared crx_id is \(length) byte(s) long; a CRX3 crx_id must be exactly 16 bytes."
        case .signedHeaderDataTooLarge(let length):
            return "This file's signed_header_data is \(length) byte(s), too large to verify."
        case .noRSAProofs:
            return "This file's CRX3 header has no RSA signature. Orbit cannot verify its authenticity."
        case .invalidPublicKeyDER(let reason):
            return "This file's signing key is not a valid RSA public key: \(reason)"
        case .unsupportedKeyAlgorithm(let oid):
            return "This file's signing key declares algorithm OID \(oid), not RSA, and cannot be verified."
        case .secKeyCreationFailed(let reason):
            return "This file's signing key could not be loaded: \(reason)"
        case .signatureVerificationFailed:
            return "This file's signature does not match its contents. It may have been tampered with after it was signed."
        case .crxIDMismatch:
            return "This file's declared identity does not match its own signing key. It may have been repackaged under a different extension's identity."
        case .noValidRSAProof(let reasons):
            return "None of this file's \(reasons.count) RSA signature(s) could be verified: \(reasons.joined(separator: "; "))"
        }
    }
}
