//  Chrome's publicKey is DER SPKI, not the bare PKCS#1 SecKeyCreateWithData wants;
//  unwrapRSAPublicKeyDER peels it. Only sha256_with_rsa proofs are verified.

import CryptoKit
import Foundation
import Security

nonisolated public enum CRX3Verifier {

    public struct VerifiedExtension: Equatable, Sendable {
        public let publicKeySPKI: Data
        public let publicKeyBase64: String
        public let crxID: Data
        public let zipPayload: Data

        public init(publicKeySPKI: Data, publicKeyBase64: String, crxID: Data, zipPayload: Data) {
            self.publicKeySPKI = publicKeySPKI
            self.publicKeyBase64 = publicKeyBase64
            self.crxID = crxID
            self.zipPayload = zipPayload
        }
    }

    // MARK: - Entry points

    public static func verify(_ data: Data) throws -> VerifiedExtension {
        let archive = try CRX3Archive.parse(data)
        return try verify(archive: archive)
    }

    public static func verify(archive: CRX3Archive) throws -> VerifiedExtension {
        guard !archive.rsaProofs.isEmpty else {
            throw CRX3Error.noRSAProofs
        }

        let payload = try signedPayload(for: archive)

        var failures: [CRX3Error] = []
        for proof in archive.rsaProofs {
            do {
                try verifySignature(of: proof, against: payload)
                try verifyIdentityBinding(of: proof, declaredCRXID: archive.crxID)
                return VerifiedExtension(
                    publicKeySPKI: proof.publicKey,
                    publicKeyBase64: proof.publicKey.base64EncodedString(),
                    crxID: archive.crxID,
                    zipPayload: archive.zipPayload
                )
            } catch let error as CRX3Error {
                failures.append(error)
            }
        }

        if failures.count == 1, let onlyFailure = failures.first {
            throw onlyFailure
        }
        throw CRX3Error.noValidRSAProof(reasons: failures.map { $0.errorDescription ?? "unknown error" })
    }

    // MARK: - The signed payload

    // "CRX3 SignedData\0" (with the trailing NUL) + little-endian uint32
    // length of signedHeaderData + signedHeaderData + zipPayload.
    static func signedPayload(for archive: CRX3Archive) throws -> Data {
        guard let signedHeaderDataLength = UInt32(exactly: archive.signedHeaderData.count) else {
            throw CRX3Error.signedHeaderDataTooLarge(archive.signedHeaderData.count)
        }

        var payload = Data("CRX3 SignedData\u{0}".utf8)
        var lengthLittleEndian = signedHeaderDataLength.littleEndian
        withUnsafeBytes(of: &lengthLittleEndian) { payload.append(contentsOf: $0) }
        payload.append(archive.signedHeaderData)
        payload.append(archive.zipPayload)
        return payload
    }

    // MARK: - Per-proof verification

    private static func verifySignature(of proof: CRX3Archive.AsymmetricKeyProof, against payload: Data) throws {
        let rsaPublicKeyDER = try SubjectPublicKeyInfo.unwrapRSAPublicKeyDER(fromSPKI: proof.publicKey)
        let secKey = try makeRSASecKey(fromPKCS1DER: rsaPublicKeyDER)

        var verifyError: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            payload as CFData,
            proof.signature as CFData,
            &verifyError
        )
        guard verified else {
            throw CRX3Error.signatureVerificationFailed
        }
    }

    // Must run after, not instead of, signature verification: checked alone
    // this would accept any container whose author can compute a SHA-256.
    private static func verifyIdentityBinding(of proof: CRX3Archive.AsymmetricKeyProof, declaredCRXID: Data) throws {
        let digest = SHA256.hash(data: proof.publicKey)
        let derivedID = Data(digest.prefix(16))
        guard derivedID == declaredCRXID else {
            throw CRX3Error.crxIDMismatch
        }
    }

    private static func makeRSASecKey(fromPKCS1DER der: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var creationError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &creationError) else {
            let reason = creationError.map { ($0.takeRetainedValue() as Error).localizedDescription }
                ?? "Security.framework did not provide a reason."
            throw CRX3Error.secKeyCreationFailed(reason)
        }
        return secKey
    }
}

// MARK: - `SubjectPublicKeyInfo` unwrapping

private enum SubjectPublicKeyInfo {

    private static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    static func unwrapRSAPublicKeyDER(fromSPKI spki: Data) throws -> Data {
        var topLevelIndex = spki.startIndex
        let outerSequence = try DER.readTLV(spki, at: &topLevelIndex)
        guard outerSequence.tag == DER.Tag.sequence else {
            throw CRX3Error.invalidPublicKeyDER("Expected an outer SEQUENCE (SubjectPublicKeyInfo).")
        }
        guard topLevelIndex == spki.endIndex else {
            throw CRX3Error.invalidPublicKeyDER("Unexpected trailing bytes after the outer SEQUENCE.")
        }

        var outerContentIndex = outerSequence.content.startIndex
        let algorithmIdentifier = try DER.readTLV(outerSequence.content, at: &outerContentIndex)
        guard algorithmIdentifier.tag == DER.Tag.sequence else {
            throw CRX3Error.invalidPublicKeyDER("Expected an AlgorithmIdentifier SEQUENCE.")
        }

        var algorithmContentIndex = algorithmIdentifier.content.startIndex
        let algorithmOID = try DER.readTLV(algorithmIdentifier.content, at: &algorithmContentIndex)
        guard algorithmOID.tag == DER.Tag.objectIdentifier else {
            throw CRX3Error.invalidPublicKeyDER("Expected an algorithm OBJECT IDENTIFIER.")
        }
        guard [UInt8](algorithmOID.content) == rsaEncryptionOID else {
            throw CRX3Error.unsupportedKeyAlgorithm(hexDescription(algorithmOID.content))
        }

        guard algorithmContentIndex < algorithmIdentifier.content.endIndex else {
            throw CRX3Error.invalidPublicKeyDER("AlgorithmIdentifier is missing its NULL parameters field.")
        }
        let parameters = try DER.readTLV(algorithmIdentifier.content, at: &algorithmContentIndex)
        guard parameters.tag == DER.Tag.null, parameters.content.isEmpty else {
            throw CRX3Error.invalidPublicKeyDER("Expected a NULL parameters field after the rsaEncryption OID.")
        }
        guard algorithmContentIndex == algorithmIdentifier.content.endIndex else {
            throw CRX3Error.invalidPublicKeyDER("Unexpected trailing bytes inside AlgorithmIdentifier.")
        }

        let subjectPublicKey = try DER.readTLV(outerSequence.content, at: &outerContentIndex)
        guard subjectPublicKey.tag == DER.Tag.bitString else {
            throw CRX3Error.invalidPublicKeyDER("Expected a BIT STRING carrying the RSAPublicKey.")
        }
        guard outerContentIndex == outerSequence.content.endIndex else {
            throw CRX3Error.invalidPublicKeyDER("Unexpected trailing bytes after the BIT STRING.")
        }

        // Must be exactly 0 (byte-aligned); treating a non-zero count as 0
        // would silently hand SecKeyCreateWithData a corrupted key.
        guard let unusedBitsCount = subjectPublicKey.content.first else {
            throw CRX3Error.invalidPublicKeyDER("The BIT STRING carrying RSAPublicKey is empty.")
        }
        guard unusedBitsCount == 0 else {
            throw CRX3Error.invalidPublicKeyDER("The BIT STRING's unused-bits count is \(unusedBitsCount), not 0; RSAPublicKey must be byte-aligned.")
        }

        return subjectPublicKey.content.dropFirst()
    }

    private static func hexDescription(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - A strict, minimal DER reader

private enum DER {
    enum Tag {
        static let sequence: UInt8 = 0x30
        static let objectIdentifier: UInt8 = 0x06
        static let null: UInt8 = 0x05
        static let bitString: UInt8 = 0x03
    }

    struct TLV {
        let tag: UInt8
        let content: Data
    }

    static func readTLV(_ data: Data, at index: inout Data.Index) throws -> TLV {
        guard index < data.endIndex else {
            throw CRX3Error.invalidPublicKeyDER("Unexpected end of DER data while reading a tag.")
        }
        let tag = data[index]
        index = data.index(after: index)

        guard index < data.endIndex else {
            throw CRX3Error.invalidPublicKeyDER("Unexpected end of DER data while reading a length.")
        }
        let firstLengthByte = data[index]
        index = data.index(after: index)

        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            // 0x80 alone is BER's indefinite-form length; DER never uses it.
            guard lengthByteCount > 0, lengthByteCount <= 4 else {
                throw CRX3Error.invalidPublicKeyDER("DER length uses an indefinite or implausibly large long-form encoding.")
            }
            guard data.distance(from: index, to: data.endIndex) >= lengthByteCount else {
                throw CRX3Error.invalidPublicKeyDER("DER length's long-form byte count runs past the end of the data.")
            }
            var value: UInt64 = 0
            for _ in 0..<lengthByteCount {
                value = (value << 8) | UInt64(data[index])
                index = data.index(after: index)
            }
            guard let intValue = Int(exactly: value) else {
                throw CRX3Error.invalidPublicKeyDER("DER length is too large to be a real key's field length.")
            }
            length = intValue
        }

        guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else {
            throw CRX3Error.invalidPublicKeyDER("DER content length runs past the end of the data.")
        }
        let contentEnd = data.index(index, offsetBy: length)
        let content = data.subdata(in: index..<contentEnd)
        index = contentEnd
        return TLV(tag: tag, content: content)
    }
}
