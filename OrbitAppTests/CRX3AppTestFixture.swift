import CryptoKit
import Foundation
import Security

// MARK: - Synthetic CRX construction shared with `CRX3VerifierTests`

/// A CRX3 container built entirely in-process with a real RSA keypair, assembled byte-for-byte the way CRX3Archive.parse(_:) expects to read it back.
enum CRX3AppTestFixture {
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
