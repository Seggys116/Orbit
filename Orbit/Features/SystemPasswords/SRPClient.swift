import CryptoKit
import Foundation

nonisolated struct SRPGroup: Sendable, Equatable {
    let prime: SRPBigUInt
    let generator: SRPBigUInt

    /// Values are padded to the byte length of the prime wherever SRP-6a pads them.
    var paddedLength: Int { (prime.bitWidth + 7) / 8 }

    /// RFC 5054, appendix A: the 3072-bit group, generator 5.
    static let rfc5054Group3072 = SRPGroup(
        prime: SRPBigUInt(hex: """
            FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1 29024E08
            8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD EF9519B3 CD3A431B
            302B0A6D F25F1437 4FE1356D 6D51C245 E485B576 625E7EC6 F44C42E9
            A637ED6B 0BFF5CB6 F406B7ED EE386BFB 5A899FA5 AE9F2411 7C4B1FE6
            49286651 ECE45B3D C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8
            FD24CF5F 83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
            670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B E39E772C
            180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9 DE2BCBF6 95581718
            3995497C EA956AE5 15D22618 98FA0510 15728E5A 8AAAC42D AD33170D
            04507A33 A85521AB DF1CBA64 ECFB8504 58DBEF0A 8AEA7157 5D060C7D
            B3970F85 A6E1E4C7 ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226
            1AD2EE6B F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
            BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31 43DB5BFC
            E0FD108E 4B82D120 A93AD2CA FFFFFFFF FFFFFFFF
            """)!,
        generator: SRPBigUInt(5)
    )
}

nonisolated enum SRPError: Error, Equatable {
    /// B is zero modulo N, which would let the server fix the shared secret.
    case invalidServerPublicKey
    /// u came out as zero.
    case invalidScrambler
    case emptySalt
}

/// The values one successful client proof yields. `sessionKey` is K; only its first 16 bytes key the channel.
nonisolated struct SRPClientProof: Sendable, Equatable {
    let clientProof: [UInt8]
    let expectedServerProof: [UInt8]
    let sessionKey: [UInt8]
}

/// The client half of SRP-6a with SHA-256 as Apple's password helper speaks it.
/// x = H(s | H(I ":" P)), k = H(N | PAD(g)), u = H(PAD(A) | PAD(B)), S = (B - k g^x)^(a + u x), K = H(S) over S's minimal bytes,
/// M = H(H(N) xor H(PAD(g)) | H(I) | s | A | B | K), HAMK = H(A | M | K), with A and B in their minimal bytes outside the padded hashes.
nonisolated struct SRPClient: Sendable {
    let group: SRPGroup
    let identity: String
    let privateKey: SRPBigUInt
    let publicKey: SRPBigUInt

    init(group: SRPGroup = .rfc5054Group3072, identity: String, privateKeyBytes: [UInt8]) {
        self.group = group
        self.identity = identity
        self.privateKey = SRPBigUInt(bigEndian: privateKeyBytes)
        self.publicKey = group.generator.power(privateKey, modulus: group.prime)
    }

    var publicKeyBytes: [UInt8] { publicKey.bytes }

    static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Array(hasher.finalize())
    }

    func multiplier() -> SRPBigUInt {
        SRPBigUInt(bigEndian: Self.hash(group.prime.bytes, group.generator.bytes(paddedTo: group.paddedLength)))
    }

    func scrambler(serverPublicKey: SRPBigUInt) -> SRPBigUInt {
        SRPBigUInt(bigEndian: Self.hash(
            publicKey.bytes(paddedTo: group.paddedLength),
            serverPublicKey.bytes(paddedTo: group.paddedLength)
        ))
    }

    static func privateExponent(identity: String, password: String, salt: [UInt8]) -> SRPBigUInt {
        let inner = hash(Array("\(identity):\(password)".utf8))
        return SRPBigUInt(bigEndian: hash(salt, inner))
    }

    func verifier(password: String, salt: [UInt8]) -> SRPBigUInt {
        group.generator.power(Self.privateExponent(identity: identity, password: password, salt: salt), modulus: group.prime)
    }

    /// The shared secret S before hashing.
    func premasterSecret(password: String, salt: [UInt8], serverPublicKey: SRPBigUInt) throws -> SRPBigUInt {
        let modulus = group.prime
        let reducedServerKey = serverPublicKey % modulus
        guard !reducedServerKey.isZero else { throw SRPError.invalidServerPublicKey }
        let u = scrambler(serverPublicKey: serverPublicKey)
        guard !u.isZero else { throw SRPError.invalidScrambler }
        let x = Self.privateExponent(identity: identity, password: password, salt: salt)
        let kv = (multiplier() * group.generator.power(x, modulus: modulus)) % modulus
        let base = reducedServerKey >= kv ? reducedServerKey - kv : reducedServerKey + modulus - kv
        return base.power(privateKey + u * x, modulus: modulus)
    }

    func proof(password: String, salt: [UInt8], serverPublicKeyBytes: [UInt8]) throws -> SRPClientProof {
        guard !salt.isEmpty else { throw SRPError.emptySalt }
        let serverPublicKey = SRPBigUInt(bigEndian: serverPublicKeyBytes)
        let secret = try premasterSecret(password: password, salt: salt, serverPublicKey: serverPublicKey)
        let sessionKey = Self.hash(secret.bytes)

        let primeHash = Self.hash(group.prime.bytes)
        let generatorHash = Self.hash(group.generator.bytes(paddedTo: group.paddedLength))
        let mixed = zip(primeHash, generatorHash).map { $0 ^ $1 }
        let clientProof = Self.hash(
            mixed,
            Self.hash(Array(identity.utf8)),
            salt,
            publicKey.bytes,
            serverPublicKey.bytes,
            sessionKey
        )
        let serverProof = Self.hash(publicKey.bytes, clientProof, sessionKey)
        return SRPClientProof(clientProof: clientProof, expectedServerProof: serverProof, sessionKey: sessionKey)
    }

    /// Compared in constant time.
    static func proofsMatch(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
