import CryptoKit
import XCTest

// The arbitrary-precision arithmetic and the SRP-6a client behind pairing with Apple's password helper
// (Orbit/Features/SystemPasswords/SRPBigUInt.swift, SRPClient.swift). Expected values come from UInt64 arithmetic
// written here, never from the type under test.

nonisolated struct SRPTestRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

nonisolated enum SRPReference {
    static func mulmod(_ a: UInt64, _ b: UInt64, _ m: UInt64) -> UInt64 {
        let product = (a % m).multipliedFullWidth(by: b % m)
        return m.dividingFullWidth((high: product.high, low: product.low)).remainder
    }

    static func addmod(_ a: UInt64, _ b: UInt64, _ m: UInt64) -> UInt64 {
        let (sum, overflow) = (a % m).addingReportingOverflow(b % m)
        precondition(!overflow)
        return sum % m
    }

    static func powmod(_ base: UInt64, _ exponent: UInt64, _ m: UInt64) -> UInt64 {
        var result: UInt64 = 1 % m
        var square = base % m
        var remaining = exponent
        while remaining > 0 {
            if remaining & 1 == 1 { result = mulmod(result, square, m) }
            square = mulmod(square, square, m)
            remaining >>= 1
        }
        return result
    }

    /// A big-endian byte string as a number, reduced modulo `m`.
    static func reduce(_ bytes: [UInt8], _ m: UInt64) -> UInt64 {
        bytes.reduce(UInt64(0)) { addmod(mulmod($0, 256, m), UInt64($1), m) }
    }

    static func minimalBytes(_ value: UInt64) -> [UInt8] {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        while bytes.first == 0 { bytes.removeFirst() }
        return bytes
    }

    static func paddedBytes(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    static func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Array(hasher.finalize())
    }

    static func limbs(of value: UInt64) -> [UInt32] {
        [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
    }
}

final class SRPBigUIntTests: XCTestCase {

    private var random = SRPTestRandom(state: 0x5EED_0F_0B17)

    private func big(_ value: UInt64) -> SRPBigUInt { SRPBigUInt(value) }

    func testSmallValuesWorkedByHand() {
        XCTAssertEqual(big(5).power(big(3), modulus: big(23)), big(10), "5^3 = 125 = 5 * 23 + 10")
        XCTAssertEqual(big(2).power(big(10), modulus: big(1_000_000)), big(1024))
        XCTAssertEqual(big(4).power(big(13), modulus: big(497)), big(445))
        XCTAssertEqual(big(7).power(big(0), modulus: big(13)), big(1))
        XCTAssertEqual(big(7).power(big(5), modulus: big(1)), big(0))
        XCTAssertEqual(big(0xFFFF_FFFF) + big(1), SRPBigUInt(limbs: [0, 1]), "a carry into a second limb")
        XCTAssertEqual(SRPBigUInt(limbs: [0, 1]) - big(1), big(0xFFFF_FFFF), "a borrow out of the second limb")
        XCTAssertEqual(big(1 << 32) * big(1 << 32), SRPBigUInt(limbs: [0, 0, 1]))
        XCTAssertEqual(big(100) / big(7), big(14))
        XCTAssertEqual(big(100) % big(7), big(2))
        XCTAssertTrue(SRPBigUInt().isZero)
        XCTAssertEqual(SRPBigUInt(limbs: [5, 0, 0]).limbs, [5], "zero limbs at the top are dropped")
    }

    func testBytesAndHexRoundTrip() {
        let value = SRPBigUInt(hex: "0x01 0203 0405")
        XCTAssertEqual(value?.bytes, [1, 2, 3, 4, 5])
        XCTAssertEqual(value?.hexString, "0102030405")
        XCTAssertEqual(value?.bytes(paddedTo: 8), [0, 0, 0, 1, 2, 3, 4, 5])
        XCTAssertEqual(SRPBigUInt(bigEndian: [0, 0, 0xAB]).bytes, [0xAB], "leading zero bytes are not part of the value")
        XCTAssertEqual(SRPBigUInt(bigEndian: [UInt8]()).bytes, [])
        XCTAssertEqual(SRPBigUInt(hex: "abc"), big(0xABC), "an odd number of digits")
        XCTAssertNil(SRPBigUInt(hex: "12g4"))
        XCTAssertNil(SRPBigUInt(hex: ""))
        for _ in 0..<200 {
            let value = random.next()
            XCTAssertEqual(SRPBigUInt(bigEndian: SRPReference.paddedBytes(value)).uint64Value, value)
            XCTAssertEqual(big(value).bytes, SRPReference.minimalBytes(value))
            XCTAssertEqual(big(value).bitWidth, 64 - value.leadingZeroBitCount)
        }
    }

    func testArithmeticAgreesWithUInt64() {
        for _ in 0..<2000 {
            let a = random.next()
            let b = random.next()
            let (low, high) = (min(a, b), max(a, b))

            let (sum, carry) = a.addingReportingOverflow(b)
            XCTAssertEqual(big(a) + big(b), SRPBigUInt(limbs: SRPReference.limbs(of: sum) + [carry ? 1 : 0]))
            XCTAssertEqual((big(high) - big(low)).uint64Value, high - low)

            let product = a.multipliedFullWidth(by: b)
            XCTAssertEqual(big(a) * big(b), SRPBigUInt(limbs: SRPReference.limbs(of: product.low) + SRPReference.limbs(of: product.high)))

            let divisor = max(b, 1)
            XCTAssertEqual((big(a) / big(divisor)).uint64Value, a / divisor)
            XCTAssertEqual((big(a) % big(divisor)).uint64Value, a % divisor)
            XCTAssertTrue((big(a) < big(b)) == (a < b))
        }
    }

    func testAOneHundredTwentyEightBitDividendAgreesWithFullWidthDivision() {
        for _ in 0..<2000 {
            let divisor = random.next() | 1 << 40
            let high = random.next() % divisor
            let low = random.next()
            let dividend = SRPBigUInt(limbs: SRPReference.limbs(of: low) + SRPReference.limbs(of: high))
            let expected = divisor.dividingFullWidth((high: high, low: low))
            let (quotient, remainder) = dividend.quotientAndRemainder(dividingBy: big(divisor))
            XCTAssertEqual(quotient.uint64Value, expected.quotient)
            XCTAssertEqual(remainder.uint64Value, expected.remainder)
        }
    }

    func testModularPowerAgreesWithUInt64() {
        for _ in 0..<300 {
            let modulus = random.next() % (1 << 61) | 2
            let base = random.next()
            let exponent = random.next()
            XCTAssertEqual(
                big(base).power(big(exponent), modulus: big(modulus)).uint64Value,
                SRPReference.powmod(base, exponent, modulus),
                "\(base)^\(exponent) mod \(modulus)"
            )
        }
    }

    private func randomBig(limbs count: Int) -> SRPBigUInt {
        SRPBigUInt(limbs: (0..<count).map { _ in UInt32(truncatingIfNeeded: random.next()) } + [UInt32(truncatingIfNeeded: random.next()) | 1])
    }

    func testDivisionOfWideNumbersReassembles() {
        for _ in 0..<200 {
            let divisor = randomBig(limbs: Int(random.next() % 40) + 1)
            let quotient = randomBig(limbs: Int(random.next() % 40))
            let remainder = randomBig(limbs: Int(random.next() % 60)) % divisor
            let dividend = quotient * divisor + remainder
            let result = dividend.quotientAndRemainder(dividingBy: divisor)
            XCTAssertEqual(result.quotient, quotient)
            XCTAssertEqual(result.remainder, remainder)
            XCTAssertLessThan(result.remainder, divisor)
        }
    }

    func testDivisionHitsTheRareCorrectionStep() {
        // A divisor of all-ones limbs and a dividend just under a multiple of it drive the quotient estimate too high.
        let divisor = SRPBigUInt(limbs: [0xFFFF_FFFF, 0xFFFF_FFFF, 0x8000_0000])
        for multiplier: UInt64 in [1, 2, 0xFFFF_FFFF, 0x1_0000_0001] {
            let dividend = divisor * big(multiplier) - big(1)
            let result = dividend.quotientAndRemainder(dividingBy: divisor)
            XCTAssertEqual(result.quotient, big(multiplier - 1))
            XCTAssertEqual(result.remainder, divisor - big(1))
        }
    }

    func testTheRFC5054PrimeHasItsKnownShape() {
        let prime = SRPGroup.rfc5054Group3072.prime
        XCTAssertEqual(prime.bitWidth, 3072)
        XCTAssertEqual(SRPGroup.rfc5054Group3072.paddedLength, 384)
        XCTAssertEqual(Array(prime.limbs.prefix(2)), [0xFFFF_FFFF, 0xFFFF_FFFF], "the low 64 bits are all ones")
        XCTAssertEqual(Array(prime.limbs.suffix(2)), [0xFFFF_FFFF, 0xFFFF_FFFF], "the high 64 bits are all ones")
        XCTAssertEqual(SRPGroup.rfc5054Group3072.generator, big(5))
    }

    func testTheRFC5054PrimePassesAFermatTest() {
        // A single mistyped digit would make it composite; 2^(N-1) mod N is then not 1 with overwhelming likelihood.
        let prime = SRPGroup.rfc5054Group3072.prime
        XCTAssertEqual(big(2).power(prime - big(1), modulus: prime), big(1))
    }
}

final class SRPClientTests: XCTestCase {

    private var random = SRPTestRandom(state: 0xA11CE)

    private func randomBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: random.next()) }
    }

    /// The Mersenne prime 2^61 - 1. Small enough that every SRP quantity can be worked out with UInt64 arithmetic,
    /// exponents reduced modulo N - 1 by Fermat's little theorem.
    private let smallPrime: UInt64 = (1 << 61) - 1
    private let smallGenerator: UInt64 = 3
    private var smallGroup: SRPGroup { SRPGroup(prime: SRPBigUInt(smallPrime), generator: SRPBigUInt(smallGenerator)) }

    func testEveryQuantityMatchesAnIndependentSmallGroupComputation() throws {
        let n = smallPrime
        let order = n - 1
        let g = smallGenerator
        let identity = "AQIDBAUGBwgJCgsMDQ4PEA=="
        let pin = "482913"
        let salt = randomBytes(16)
        let privateKey = randomBytes(32)
        let client = SRPClient(group: smallGroup, identity: identity, privateKeyBytes: privateKey)

        let a = SRPReference.reduce(privateKey, order)
        let publicKey = SRPReference.powmod(g, a, n)
        XCTAssertEqual(client.publicKey.uint64Value, publicKey)

        let x = SRPReference.reduce(SRPReference.sha256(salt, SRPReference.sha256(Array("\(identity):\(pin)".utf8))), order)
        let verifier = SRPReference.powmod(g, x, n)
        XCTAssertEqual(client.verifier(password: pin, salt: salt).uint64Value, verifier)

        let k = SRPReference.reduce(SRPReference.sha256(SRPReference.minimalBytes(n), SRPReference.paddedBytes(g)), n)
        XCTAssertEqual((client.multiplier() % SRPBigUInt(n)).uint64Value, k)

        let b = random.next() % order
        let serverPublicKey = SRPReference.addmod(SRPReference.mulmod(k, verifier, n), SRPReference.powmod(g, b, n), n)

        let uHash = SRPReference.sha256(SRPReference.paddedBytes(publicKey), SRPReference.paddedBytes(serverPublicKey))
        let u = SRPReference.reduce(uHash, order)
        let exponent = SRPReference.addmod(a, SRPReference.mulmod(u, x, order), order)
        let base = SRPReference.addmod(serverPublicKey, n - SRPReference.mulmod(k, verifier, n), n)
        let secret = SRPReference.powmod(base, exponent, n)

        // The server's side of the same secret: (A v^u)^b.
        let serverSecret = SRPReference.powmod(SRPReference.mulmod(publicKey, SRPReference.powmod(verifier, u, n), n), b, n)
        XCTAssertEqual(secret, serverSecret, "the reference arithmetic itself must agree with the server's view")

        let computed = try client.premasterSecret(password: pin, salt: salt, serverPublicKey: SRPBigUInt(serverPublicKey))
        XCTAssertEqual(computed.uint64Value, secret)

        let sessionKey = SRPReference.sha256(SRPReference.minimalBytes(secret))
        let mixed = zip(SRPReference.sha256(SRPReference.minimalBytes(n)), SRPReference.sha256(SRPReference.paddedBytes(g))).map { $0 ^ $1 }
        let expectedProof = SRPReference.sha256(
            mixed,
            SRPReference.sha256(Array(identity.utf8)),
            salt,
            SRPReference.minimalBytes(publicKey),
            SRPReference.minimalBytes(serverPublicKey),
            sessionKey
        )
        let expectedServerProof = SRPReference.sha256(SRPReference.minimalBytes(publicKey), expectedProof, sessionKey)

        let proof = try client.proof(password: pin, salt: salt, serverPublicKeyBytes: SRPReference.minimalBytes(serverPublicKey))
        XCTAssertEqual(proof.sessionKey, sessionKey)
        XCTAssertEqual(proof.clientProof, expectedProof)
        XCTAssertEqual(proof.expectedServerProof, expectedServerProof)
    }

    func testLeadingZeroBytesOfBDoNotChangeTheProof() throws {
        let client = SRPClient(group: smallGroup, identity: "tid", privateKeyBytes: randomBytes(32))
        let salt = randomBytes(16)
        let serverPublicKey = SRPReference.powmod(smallGenerator, 12345, smallPrime)
        let minimal = try client.proof(password: "000000", salt: salt, serverPublicKeyBytes: SRPReference.minimalBytes(serverPublicKey))
        let padded = try client.proof(password: "000000", salt: salt, serverPublicKeyBytes: [0, 0, 0] + SRPReference.minimalBytes(serverPublicKey))
        XCTAssertEqual(minimal, padded)
    }

    func testAServerKeyThatIsZeroModuloNIsRefused() {
        let client = SRPClient(group: smallGroup, identity: "tid", privateKeyBytes: randomBytes(32))
        XCTAssertThrowsError(try client.proof(password: "1", salt: [1], serverPublicKeyBytes: [0])) { error in
            XCTAssertEqual(error as? SRPError, .invalidServerPublicKey)
        }
        XCTAssertThrowsError(try client.proof(password: "1", salt: [1], serverPublicKeyBytes: SRPReference.minimalBytes(smallPrime))) { error in
            XCTAssertEqual(error as? SRPError, .invalidServerPublicKey)
        }
        XCTAssertThrowsError(try client.proof(password: "1", salt: [], serverPublicKeyBytes: [7])) { error in
            XCTAssertEqual(error as? SRPError, .emptySalt)
        }
    }

    /// The whole exchange in the real 3072-bit group, against a server written here: both sides reach the same K, the server accepts
    /// the client's M, and the client accepts the server's HAMK. A wrong PIN gives a proof the server rejects.
    func testTheClientAndAServerInThe3072BitGroupAgree() throws {
        let group = SRPGroup.rfc5054Group3072
        let prime = group.prime
        let identity = SystemPasswordsMessages.newTransactionID(encoding: .base64, bytes: randomBytes(16))
        let pin = "730154"
        let salt = randomBytes(16)
        let client = SRPClient(group: group, identity: identity, privateKeyBytes: randomBytes(32))

        func hash(_ parts: [UInt8]...) -> [UInt8] {
            var hasher = SHA256()
            for part in parts { hasher.update(data: part) }
            return Array(hasher.finalize())
        }
        let x = SRPBigUInt(bigEndian: hash(salt, hash(Array("\(identity):\(pin)".utf8))))
        let verifier = group.generator.power(x, modulus: prime)
        let k = SRPBigUInt(bigEndian: hash(prime.bytes, group.generator.bytes(paddedTo: 384)))
        let b = SRPBigUInt(bigEndian: randomBytes(32))
        let serverPublicKey = (k * verifier + group.generator.power(b, modulus: prime)) % prime

        let u = SRPBigUInt(bigEndian: hash(client.publicKey.bytes(paddedTo: 384), serverPublicKey.bytes(paddedTo: 384)))
        let serverSecret = ((client.publicKey * verifier.power(u, modulus: prime)) % prime).power(b, modulus: prime)
        let serverKey = hash(serverSecret.bytes)
        let mixed = zip(hash(prime.bytes), hash(group.generator.bytes(paddedTo: 384))).map { $0 ^ $1 }
        let serverExpectsM = hash(mixed, hash(Array(identity.utf8)), salt, client.publicKey.bytes, serverPublicKey.bytes, serverKey)

        let proof = try client.proof(password: pin, salt: salt, serverPublicKeyBytes: serverPublicKey.bytes)
        XCTAssertEqual(proof.sessionKey, serverKey)
        XCTAssertTrue(SRPClient.proofsMatch(proof.clientProof, serverExpectsM))
        let serverHAMK = hash(client.publicKey.bytes, serverExpectsM, serverKey)
        XCTAssertTrue(SRPClient.proofsMatch(serverHAMK, proof.expectedServerProof))

        let wrong = try client.proof(password: "730155", salt: salt, serverPublicKeyBytes: serverPublicKey.bytes)
        XCTAssertFalse(SRPClient.proofsMatch(wrong.clientProof, serverExpectsM))
    }

    func testProofComparisonNeedsEqualLengthAndBytes() {
        XCTAssertTrue(SRPClient.proofsMatch([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(SRPClient.proofsMatch([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(SRPClient.proofsMatch([1, 2, 3], [1, 2]))
    }
}
