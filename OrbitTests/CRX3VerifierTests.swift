import CryptoKit
import Foundation
import Security
import XCTest

final class CRX3VerifierTests: XCTestCase {

    // MARK: - Happy path

    func test_validContainerWithSignedHeaderDataAtFieldTenThousandVerifies() throws {
        let built = try CRX3TestFixture.build()

        let result = try CRX3Verifier.verify(built.bytes)

        XCTAssertEqual(result.publicKeySPKI, built.publicKeySPKI)
        XCTAssertEqual(result.publicKeyBase64, built.publicKeyBase64)
        XCTAssertEqual(result.crxID, built.crxID)
        XCTAssertEqual(result.zipPayload, built.zipPayload)
    }

    func test_verifyArchiveAndVerifyDataAgree() throws {
        let built = try CRX3TestFixture.build()
        let archive = try CRX3Archive.parse(built.bytes)

        let fromArchive = try CRX3Verifier.verify(archive: archive)
        let fromBytes = try CRX3Verifier.verify(built.bytes)

        XCTAssertEqual(fromArchive, fromBytes)
    }

    // MARK: - Tampering after signing

    func test_flippedBitInZipPayloadFailsVerification() throws {
        var built = try CRX3TestFixture.build()
        try flipOneBit(in: &built.bytes, at: built.zipPayloadRange.lowerBound)

        XCTAssertThrowsError(try CRX3Verifier.verify(built.bytes)) { error in
            XCTAssertEqual(
                error as? CRX3Error, .signatureVerificationFailed,
                "Corrupting the ZIP payload must be caught as a signature mismatch, since the payload is part of what was signed."
            )
        }
    }

    func test_flippedBitInSignatureFailsVerification() throws {
        var built = try CRX3TestFixture.build()
        try flipOneBit(in: &built.bytes, at: built.signatureRange.lowerBound)

        XCTAssertThrowsError(try CRX3Verifier.verify(built.bytes)) { error in
            XCTAssertEqual(error as? CRX3Error, .signatureVerificationFailed)
        }
    }

    // MARK: - Identity binding

    func test_crxIDNotMatchingTheKeyIsRejected() throws {
        let wrongCRXID = Data(repeating: 0xEE, count: 16)
        let built = try CRX3TestFixture.build(crxIDOverride: wrongCRXID)

        let realID = Data(SHA256.hash(data: built.publicKeySPKI).prefix(16))
        XCTAssertNotEqual(built.crxID, realID, "The fixture's override must actually disagree with the key's real hash.")

        XCTAssertThrowsError(try CRX3Verifier.verify(built.bytes)) { error in
            XCTAssertEqual(error as? CRX3Error, .crxIDMismatch)
        }
    }

    // MARK: - No RSA proofs at all

    func test_containerWithNoRSAProofsIsRejected() throws {
        let crxID = Data(repeating: 0x11, count: 16)
        let signedHeaderData = lengthDelimitedField(1, crxID)
        let headerBytes = lengthDelimitedField(10000, signedHeaderData)

        var bytes = Data([0x43, 0x72, 0x32, 0x34])
        bytes.append(uint32LE(3))
        bytes.append(uint32LE(UInt32(headerBytes.count)))
        bytes.append(headerBytes)

        XCTAssertThrowsError(try CRX3Verifier.verify(bytes)) { error in
            XCTAssertEqual(error as? CRX3Error, .noRSAProofs)
        }
    }

    // MARK: - Multiple proofs: aggregate failure reporting

    func test_multipleFailingProofsAggregateIntoOneError() throws {
        let firstBuilt = try CRX3TestFixture.build()
        var tamperedBytes = firstBuilt.bytes
        try flipOneBit(in: &tamperedBytes, at: firstBuilt.signatureRange.lowerBound)
        let brokenArchive1 = try CRX3Archive.parse(tamperedBytes)

        let wrongCRXID = Data(repeating: 0xAA, count: 16)
        let secondBuilt = try CRX3TestFixture.build(crxIDOverride: wrongCRXID)
        let brokenArchive2 = try CRX3Archive.parse(secondBuilt.bytes)

        let combinedArchive = CRX3Archive(
            rsaProofs: brokenArchive1.rsaProofs + brokenArchive2.rsaProofs,
            ecdsaProofs: [],
            signedHeaderData: brokenArchive1.signedHeaderData,
            crxID: brokenArchive1.crxID,
            zipPayload: brokenArchive1.zipPayload,
            zipPayloadRange: brokenArchive1.zipPayloadRange
        )

        XCTAssertThrowsError(try CRX3Verifier.verify(archive: combinedArchive)) { error in
            guard case CRX3Error.noValidRSAProof(let reasons) = error else {
                return XCTFail("Expected .noValidRSAProof, got \(error).")
            }
            XCTAssertEqual(reasons.count, 2, "Both attempted proofs' failures must be represented.")
        }
    }

    // MARK: - `signedPayload(for:)` shape

    func test_signedPayloadHasTheExactDocumentedByteLayout() throws {
        let built = try CRX3TestFixture.build()
        let archive = try CRX3Archive.parse(built.bytes)

        let payload = try CRX3Verifier.signedPayload(for: archive)

        let prefix = Data("CRX3 SignedData\u{0}".utf8)
        XCTAssertEqual(prefix.count, 16, "The literal itself must be exactly 16 bytes, trailing NUL included.")
        XCTAssertEqual(payload.prefix(16), prefix)

        // Byte-by-byte, not an unaligned load: subdata(in:)'s offset isn't guaranteed 4-byte aligned.
        let lengthBytes = payload.subdata(in: payload.index(payload.startIndex, offsetBy: 16)..<payload.index(payload.startIndex, offsetBy: 20))
        let declaredLength = lengthBytes.enumerated().reduce(UInt32(0)) { partial, element in
            partial | (UInt32(element.element) << (8 * element.offset))
        }
        XCTAssertEqual(Int(declaredLength), archive.signedHeaderData.count)

        let signedHeaderStart = payload.index(payload.startIndex, offsetBy: 20)
        let signedHeaderEnd = payload.index(signedHeaderStart, offsetBy: archive.signedHeaderData.count)
        XCTAssertEqual(payload.subdata(in: signedHeaderStart..<signedHeaderEnd), archive.signedHeaderData)
        XCTAssertEqual(payload.subdata(in: signedHeaderEnd..<payload.endIndex), archive.zipPayload)
    }

    // MARK: - The base64 public key round-trips to a real Web Store id

    func test_publicKeyBase64RoundTripsThroughChromeExtensionIDToAValidID() throws {
        let built = try CRX3TestFixture.build()

        let result = try CRX3Verifier.verify(built.bytes)

        let id = try XCTUnwrap(
            ChromeExtensionID.id(fromPublicKeyBase64: result.publicKeyBase64),
            "A verified extension's own public key must always be valid base64 that ChromeExtensionID can derive an id from."
        )
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(ChromeExtensionID.isValid(id), "The derived id must satisfy ChromeExtensionID's own validity check.")

        XCTAssertEqual(id, ChromeExtensionID.id(fromPublicKeyBase64: result.publicKeyBase64))
    }

    // MARK: - Helpers

    private func flipOneBit(in data: inout Data, at offset: Int) throws {
        let index = data.index(data.startIndex, offsetBy: offset)
        data[index] ^= 0x01
    }
}
