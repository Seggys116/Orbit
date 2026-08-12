import CryptoKit
import Foundation
import Security
import XCTest

final class CRX3ArchiveTests: XCTestCase {

    // MARK: - Happy path

    // Regression: fixture and production code both once read signed_header_data off field 4
    // (actually verified_contents; real field is 10000), so this passed while real CRXs failed.
    func test_parsesAValidSyntheticCRX3ContainerWithSignedHeaderDataAtFieldTenThousand() throws {
        let built = try CRX3TestFixture.build()

        let archive = try CRX3Archive.parse(built.bytes)

        XCTAssertEqual(archive.rsaProofs.count, 1, "The fixture signs with exactly one RSA proof.")
        XCTAssertEqual(archive.ecdsaProofs.count, 0, "The fixture never adds an ECDSA proof.")
        XCTAssertEqual(archive.rsaProofs[0].publicKey, built.publicKeySPKI)
        XCTAssertEqual(archive.rsaProofs[0].signature, built.signature)
        XCTAssertEqual(archive.crxID, built.crxID)
        XCTAssertEqual(archive.zipPayload, built.zipPayload)
        XCTAssertEqual(
            archive.zipPayloadRange, built.zipPayloadRange,
            "The parser's own reported ZIP range must agree with where the fixture actually placed the ZIP bytes."
        )
        XCTAssertEqual(
            built.bytes.subdata(in: archive.zipPayloadRange), archive.zipPayload,
            "Slicing the original bytes by the reported range must reproduce zipPayload exactly."
        )
    }

    // MARK: - Truncated / invalid magic

    func test_rejectsAnEmptyFile() {
        XCTAssertThrowsError(try CRX3Archive.parse(Data())) { error in
            guard case CRX3Error.truncatedContainer(let available, let required) = error else {
                return XCTFail("Expected .truncatedContainer, got \(error).")
            }
            XCTAssertEqual(available, 0)
            XCTAssertEqual(required, 12)
        }
    }

    func test_rejectsAFileShorterThanTheFixedPreamble() {
        let data = Data([0x43, 0x72, 0x32, 0x34, 0x03, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            guard case CRX3Error.truncatedContainer = error else {
                return XCTFail("Expected .truncatedContainer, got \(error).")
            }
        }
    }

    func test_rejectsInvalidMagicBytes() {
        var data = Data([0x50, 0x4B, 0x03, 0x04]) // "PK\u{3}\u{4}" — an ordinary ZIP's own magic.
        data.append(uint32LE(3))
        data.append(uint32LE(0))
        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            XCTAssertEqual(error as? CRX3Error, .invalidMagic)
        }
    }

    // MARK: - CRX2 vs. unsupported version

    func test_rejectsCRX2VersionWithItsOwnDistinctError() {
        var data = Data([0x43, 0x72, 0x32, 0x34]) // "Cr24"
        data.append(uint32LE(2))
        data.append(uint32LE(0))
        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            XCTAssertEqual(error as? CRX3Error, .crx2Unsupported)
        }
    }

    func test_rejectsAFutureUnrecognizedVersion() {
        var data = Data([0x43, 0x72, 0x32, 0x34])
        data.append(uint32LE(99))
        data.append(uint32LE(0))
        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            XCTAssertEqual(error as? CRX3Error, .unsupportedVersion(99))
        }
    }

    // MARK: - `header_size` larger than the file

    func test_rejectsAHeaderSizeLargerThanTheFile() {
        var data = Data([0x43, 0x72, 0x32, 0x34])
        data.append(uint32LE(3))
        data.append(uint32LE(5_000_000))
        data.append(Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            guard case CRX3Error.headerSizeExceedsFile(let headerSize, let fileSize) = error else {
                return XCTFail("Expected .headerSizeExceedsFile, got \(error).")
            }
            XCTAssertEqual(headerSize, 5_000_000)
            XCTAssertEqual(fileSize, data.count)
        }
    }

    // header_size == UInt32.max is the value an attacker probing for integer overflow in a naive 12 + header_size computation would pick; parse(_:) must bound header_size against the remaining byte count instead.
    func test_rejectsTheMaximumUInt32HeaderSize() {
        var data = Data([0x43, 0x72, 0x32, 0x34])
        data.append(uint32LE(3))
        data.append(uint32LE(UInt32.max))
        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            guard case CRX3Error.headerSizeExceedsFile(let headerSize, _) = error else {
                return XCTFail("Expected .headerSizeExceedsFile, got \(error).")
            }
            XCTAssertEqual(headerSize, UInt32.max)
        }
    }

    // MARK: - `crx_id` shape

    func test_rejectsASignedHeaderDataWhoseCrxIDIsTheWrongLength() throws {
        let wrongLengthID = Data(repeating: 0xAB, count: 5)
        let signedHeaderData = lengthDelimitedField(1, wrongLengthID)
        let dummyProof = lengthDelimitedField(1, Data(repeating: 0x01, count: 8))
            + lengthDelimitedField(2, Data(repeating: 0x02, count: 8))
        let headerBytes = lengthDelimitedField(2, dummyProof) + lengthDelimitedField(10000, signedHeaderData)

        var data = Data([0x43, 0x72, 0x32, 0x34])
        data.append(uint32LE(3))
        data.append(uint32LE(UInt32(headerBytes.count)))
        data.append(headerBytes)

        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            XCTAssertEqual(error as? CRX3Error, .invalidCrxIDLength(5))
        }
    }

    func test_rejectsAHeaderWithNoSignedHeaderDataAtAll() throws {
        let dummyProof = lengthDelimitedField(1, Data(repeating: 0x01, count: 8))
            + lengthDelimitedField(2, Data(repeating: 0x02, count: 8))
        let headerBytes = lengthDelimitedField(2, dummyProof)

        var data = Data([0x43, 0x72, 0x32, 0x34])
        data.append(uint32LE(3))
        data.append(uint32LE(UInt32(headerBytes.count)))
        data.append(headerBytes)

        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            XCTAssertEqual(error as? CRX3Error, .missingSignedHeaderData)
        }
    }

    // Regression: parser once read signed_header_data off field 4 (verified_contents); a
    // header carrying only field 4 must throw, not treat its bytes as SignedData.
    func test_rejectsAHeaderCarryingOnlyVerifiedContentsFieldFourNotFieldTenThousand() throws {
        let verifiedContents = Data(repeating: 0x99, count: 32)
        let dummyProof = lengthDelimitedField(1, Data(repeating: 0x01, count: 8))
            + lengthDelimitedField(2, Data(repeating: 0x02, count: 8))
        let headerBytes = lengthDelimitedField(2, dummyProof) + lengthDelimitedField(4, verifiedContents)

        var data = Data([0x43, 0x72, 0x32, 0x34])
        data.append(uint32LE(3))
        data.append(uint32LE(UInt32(headerBytes.count)))
        data.append(headerBytes)

        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            XCTAssertEqual(error as? CRX3Error, .missingSignedHeaderData)
        }
    }

    // Mirrors the real field layout Google's Web Store serves: two sha256_with_rsa proofs, sha256_with_ecdsa, then signed_header_data at 10000, with a field-4 verified_contents blob also present -- the shape that exposed the field-4-vs-10000 bug.
    func test_parsesTheRealWebStoreFieldLayoutTwoRSAProofsOneECDSAThenSignedHeaderData() throws {
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var generationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &generationError) else {
            throw XCTSkip("Key generation unavailable in this environment: \(String(describing: generationError))")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            return XCTFail("SecKeyCopyPublicKey returned nil.")
        }
        var exportError: Unmanaged<CFError>?
        guard let pkcs1DER = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            return XCTFail("SecKeyCopyExternalRepresentation failed: \(String(describing: exportError))")
        }
        let spki = wrapAsSubjectPublicKeyInfo(pkcs1DER: pkcs1DER)
        let crxID = Data(SHA256.hash(data: spki).prefix(16))
        let signedHeaderData = lengthDelimitedField(1, crxID)

        var signedPayload = Data("CRX3 SignedData\u{0}".utf8)
        signedPayload.append(uint32LE(UInt32(signedHeaderData.count)))
        signedPayload.append(signedHeaderData)
        let zipPayload = Data("PK\u{3}\u{4} pretend ZIP bytes".utf8)
        signedPayload.append(zipPayload)

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, signedPayload as CFData, &signingError
        ) as Data? else {
            return XCTFail("SecKeyCreateSignature failed: \(String(describing: signingError))")
        }

        let rsaProof1 = lengthDelimitedField(1, spki) + lengthDelimitedField(2, signature)
        let rsaProof2 = lengthDelimitedField(1, Data(repeating: 0x07, count: 16))
            + lengthDelimitedField(2, Data(repeating: 0x08, count: 16))
        let ecdsaProof = lengthDelimitedField(1, Data(repeating: 0x09, count: 16))
            + lengthDelimitedField(2, Data(repeating: 0x0A, count: 16))
        let verifiedContents = Data(repeating: 0xCC, count: 18)

        let headerBytes = lengthDelimitedField(2, rsaProof1)
            + lengthDelimitedField(2, rsaProof2)
            + lengthDelimitedField(3, ecdsaProof)
            + lengthDelimitedField(4, verifiedContents)
            + lengthDelimitedField(10000, signedHeaderData)

        var data = Data([0x43, 0x72, 0x32, 0x34])
        data.append(uint32LE(3))
        data.append(uint32LE(UInt32(headerBytes.count)))
        data.append(headerBytes)
        data.append(zipPayload)

        let archive = try CRX3Archive.parse(data)

        XCTAssertEqual(archive.rsaProofs.count, 2, "Both sha256_with_rsa proofs must be read, in order.")
        XCTAssertEqual(archive.rsaProofs[0].publicKey, spki)
        XCTAssertEqual(archive.ecdsaProofs.count, 1)
        XCTAssertEqual(archive.crxID, crxID)
        XCTAssertEqual(archive.signedHeaderData, signedHeaderData)
        XCTAssertEqual(archive.zipPayload, zipPayload)
    }

    // MARK: - Adversarial input never crashes

    // Every prefix of a real, valid container fed straight to parse(_:): below the header's own end offset it must always throw, at or above it must always succeed with the correct prefix of the real payload (validating ZIP completeness is CRX3Verifier's job, not parse(_:)'s).
    func test_neverCrashesOnAnyTruncationOfAValidContainer() throws {
        let built = try CRX3TestFixture.build()
        let fullLength = built.bytes.count
        let headerEndOffset = built.zipPayloadRange.lowerBound

        for length in 0..<fullLength {
            let prefix = Data(built.bytes.prefix(length))
            do {
                let archive = try CRX3Archive.parse(prefix)
                XCTAssertGreaterThanOrEqual(
                    length, headerEndOffset,
                    "parse(_:) succeeded at truncated length \(length), which is shorter than the header itself (\(headerEndOffset)) — the header cannot have been fully present."
                )
                let expectedZipLength = length - headerEndOffset
                XCTAssertEqual(archive.zipPayload.count, expectedZipLength)
                XCTAssertEqual(archive.zipPayload, built.zipPayload.prefix(expectedZipLength))
            } catch {
                XCTAssertLessThan(
                    length, headerEndOffset,
                    "parse(_:) threw at truncated length \(length), which is at or past the header's own end (\(headerEndOffset)) — the header was fully present and this should have succeeded (with a truncated zipPayload)."
                )
            }
        }
    }

    // A header of all 0xFF bytes is a varint that never terminates; ProtobufFieldReader.readVarint() must bound itself to 10 groups so this cannot shift a UInt64 by more than 63 bits, which is a runtime trap, not a catchable error.
    func test_neverCrashesOnAMalformedVarintOfAllContinuationBytes() {
        let malformedHeader = Data(repeating: 0xFF, count: 64)
        var data = Data([0x43, 0x72, 0x32, 0x34])
        data.append(uint32LE(3))
        data.append(uint32LE(UInt32(malformedHeader.count)))
        data.append(malformedHeader)

        XCTAssertThrowsError(try CRX3Archive.parse(data)) { error in
            guard case CRX3Error.malformedProtobuf = error else {
                return XCTFail("Expected .malformedProtobuf, got \(error).")
            }
        }
    }
}

// MARK: - Synthetic CRX construction shared with `CRX3VerifierTests`

/// A CRX3 container built entirely in-process with a real RSA keypair, assembled byte-for-byte the way CRX3Archive.parse(_:) expects to read it back.
enum CRX3TestFixture {
    enum FixtureError: Error {
        case keyGenerationFailed(String)
        case exportFailed(String)
        case signingFailed(String)
    }

    // bytes alone is var so a caller can take &built.bytes to corrupt one
    // specific byte range in place, without reconstructing the whole struct.
    struct BuiltCRX {
        var bytes: Data
        let publicKeySPKI: Data
        let publicKeyBase64: String
        let crxID: Data
        let zipPayload: Data
        let signature: Data
        let zipPayloadRange: Range<Data.Index>
        let signatureRange: Range<Data.Index>
    }

    // crxIDOverride, when supplied, is signed over exactly as if it were correct, so the signature still validates and only the identity-binding check (SHA256(public_key) vs. the declared crx_id) fails.
    static func build(
        zipPayload: Data = Data("PK\u{3}\u{4} pretend ZIP bytes for CRX3 testing, not a real archive".utf8),
        crxIDOverride: Data? = nil
    ) throws -> BuiltCRX {
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var generationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &generationError) else {
            throw FixtureError.keyGenerationFailed(cfErrorDescription(generationError))
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw FixtureError.keyGenerationFailed("SecKeyCopyPublicKey returned nil.")
        }

        var exportError: Unmanaged<CFError>?
        // Security.framework's RSA "external representation" is bare PKCS#1, never an X.509 SubjectPublicKeyInfo; wrapAsSubjectPublicKeyInfo performs the same wrap Chrome performs, written independently of CRX3Verifier.swift's own unwrap.
        guard let pkcs1DER = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw FixtureError.exportFailed(cfErrorDescription(exportError))
        }
        let spki = wrapAsSubjectPublicKeyInfo(pkcs1DER: pkcs1DER)

        let realCRXID = Data(SHA256.hash(data: spki).prefix(16))
        let crxID = crxIDOverride ?? realCRXID
        let signedHeaderData = lengthDelimitedField(1, crxID)

        var signedPayload = Data("CRX3 SignedData\u{0}".utf8)
        signedPayload.append(uint32LE(UInt32(signedHeaderData.count)))
        signedPayload.append(signedHeaderData)
        signedPayload.append(zipPayload)

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, signedPayload as CFData, &signingError
        ) as Data? else {
            throw FixtureError.signingFailed(cfErrorDescription(signingError))
        }

        let proofBytes = lengthDelimitedField(1, spki) + lengthDelimitedField(2, signature)
        // signed_header_data is field 10000, not field 4 (verified_contents).
        let headerBytes = lengthDelimitedField(2, proofBytes) + lengthDelimitedField(10000, signedHeaderData)

        var bytes = Data([0x43, 0x72, 0x32, 0x34]) // "Cr24"
        bytes.append(uint32LE(3))
        bytes.append(uint32LE(UInt32(headerBytes.count)))
        bytes.append(headerBytes)
        let zipStart = bytes.count
        bytes.append(zipPayload)
        let zipPayloadRange = zipStart..<bytes.count

        // 256 bytes of RSA-2048 signature located back out by content match:
        // unambiguous in practice against the small, structured surrounding bytes.
        guard let signatureRange = bytes.range(of: signature) else {
            throw FixtureError.signingFailed("Could not locate the signature bytes in the assembled container for test bookkeeping.")
        }

        return BuiltCRX(
            bytes: bytes,
            publicKeySPKI: spki,
            publicKeyBase64: spki.base64EncodedString(),
            crxID: crxID,
            zipPayload: zipPayload,
            signature: signature,
            zipPayloadRange: zipPayloadRange,
            signatureRange: signatureRange
        )
    }

    private static func cfErrorDescription(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "Security.framework did not provide a reason." }
        return (error.takeRetainedValue() as Error).localizedDescription
    }
}

// MARK: - A minimal DER encoder, independent of `CRX3Verifier`'s decoder

/// Wraps a bare PKCS#1 RSAPublicKey DER blob in the X.509 SubjectPublicKeyInfo
/// structure Chrome actually writes into a CRX3 header's public_key field:
/// SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { 0x00, <pkcs1DER> } }.
func wrapAsSubjectPublicKeyInfo(pkcs1DER: Data) -> Data {
    let rsaEncryptionOID = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
    let oid = derTLV(tag: 0x06, content: rsaEncryptionOID)
    let null = derTLV(tag: 0x05, content: Data())
    let algorithmIdentifier = derTLV(tag: 0x30, content: oid + null)

    var bitStringContent = Data([0x00]) // zero unused bits — PKCS#1 DER is always byte-aligned.
    bitStringContent.append(pkcs1DER)
    let bitString = derTLV(tag: 0x03, content: bitStringContent)

    return derTLV(tag: 0x30, content: algorithmIdentifier + bitString)
}

func derTLV(tag: UInt8, content: Data) -> Data {
    var result = Data([tag])
    result.append(derLength(content.count))
    result.append(content)
    return result
}

func derLength(_ length: Int) -> Data {
    if length < 0x80 {
        return Data([UInt8(length)])
    }
    var magnitudeBytes: [UInt8] = []
    var remaining = length
    while remaining > 0 {
        magnitudeBytes.insert(UInt8(remaining & 0xFF), at: 0)
        remaining >>= 8
    }
    return Data([0x80 | UInt8(magnitudeBytes.count)] + magnitudeBytes)
}

// MARK: - A minimal protobuf encoder, independent of `ProtobufFieldReader`

// Base-128 varint encoding, least-significant group first: the mirror image
// of ProtobufFieldReader.readVarint() in CRX3Archive.swift, not shared with it.
func varintBytes(_ value: UInt64) -> Data {
    var remaining = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7F)
        remaining >>= 7
        if remaining != 0 {
            byte |= 0x80
        }
        bytes.append(byte)
    } while remaining != 0
    return Data(bytes)
}

func lengthDelimitedField(_ fieldNumber: Int, _ value: Data) -> Data {
    let tag = UInt64((fieldNumber << 3) | 0x2)
    var result = varintBytes(tag)
    result.append(varintBytes(UInt64(value.count)))
    result.append(value)
    return result
}

func uint32LE(_ value: UInt32) -> Data {
    var littleEndianValue = value.littleEndian
    return Data(bytes: &littleEndianValue, count: MemoryLayout<UInt32>.size)
}
