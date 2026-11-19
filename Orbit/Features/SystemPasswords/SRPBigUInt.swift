import Foundation

/// An arbitrary-precision unsigned integer, just enough for SRP: add, subtract, multiply, divide, modular power and big-endian bytes.
/// Limbs are 32 bits, least significant first, with no zero limb at the top, so equal values have equal limbs.
nonisolated struct SRPBigUInt: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {

    private(set) var limbs: [UInt32]

    init() {
        limbs = []
    }

    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init<Bytes: Sequence>(bigEndian bytes: Bytes) where Bytes.Element == UInt8 {
        let array = Array(bytes)
        var limbs = [UInt32](repeating: 0, count: (array.count + 3) / 4)
        for (offset, byte) in array.reversed().enumerated() {
            limbs[offset / 4] |= UInt32(byte) << (8 * UInt32(offset % 4))
        }
        self.init(limbs: limbs)
    }

    /// Hex digits, optionally with a 0x prefix and with any whitespace ignored. Nil for any other character.
    init?(hex text: String) {
        var digits = text.filter { !$0.isWhitespace }
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits.removeFirst(2) }
        guard !digits.isEmpty else { return nil }
        var nibbles: [UInt8] = []
        nibbles.reserveCapacity(digits.count)
        for character in digits {
            guard let value = character.hexDigitValue else { return nil }
            nibbles.append(UInt8(value))
        }
        if nibbles.count % 2 == 1 { nibbles.insert(0, at: 0) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(nibbles.count / 2)
        for index in stride(from: 0, to: nibbles.count, by: 2) {
            bytes.append(nibbles[index] << 4 | nibbles[index + 1])
        }
        self.init(bigEndian: bytes)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 32 - top.leadingZeroBitCount
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return limbs[limb] >> UInt32(index % 32) & 1 == 1
    }

    var uint64Value: UInt64? {
        guard limbs.count <= 2 else { return nil }
        let low = limbs.first.map(UInt64.init) ?? 0
        let high = limbs.count == 2 ? UInt64(limbs[1]) : 0
        return high << 32 | low
    }

    /// Big-endian with no leading zero bytes; empty for zero.
    var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            out.append(UInt8(truncatingIfNeeded: limb >> 24))
            out.append(UInt8(truncatingIfNeeded: limb >> 16))
            out.append(UInt8(truncatingIfNeeded: limb >> 8))
            out.append(UInt8(truncatingIfNeeded: limb))
        }
        if let first = out.firstIndex(where: { $0 != 0 }) {
            out.removeFirst(first)
        } else {
            out.removeAll()
        }
        return out
    }

    /// Big-endian, left-padded with zeros to `length` bytes. A value wider than `length` keeps all its bytes.
    func bytes(paddedTo length: Int) -> [UInt8] {
        let minimal = bytes
        guard minimal.count < length else { return minimal }
        return [UInt8](repeating: 0, count: length - minimal.count) + minimal
    }

    var hexString: String {
        let minimal = bytes
        guard !minimal.isEmpty else { return "0" }
        return minimal.map { String(format: "%02x", $0) }.joined()
    }

    var description: String { "0x" + hexString }

    // MARK: - Comparison

    static func < (lhs: SRPBigUInt, rhs: SRPBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    // MARK: - Arithmetic

    static func + (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var result = [UInt32](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let left = index < lhs.limbs.count ? UInt64(lhs.limbs[index]) : 0
            let right = index < rhs.limbs.count ? UInt64(rhs.limbs[index]) : 0
            let sum = left + right + carry
            result[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        result[count] = UInt32(carry)
        return SRPBigUInt(limbs: result)
    }

    /// `lhs` must not be less than `rhs`.
    static func - (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        precondition(lhs >= rhs, "SRPBigUInt subtraction would go below zero")
        var result = lhs.limbs
        var borrow: UInt64 = 0
        for index in 0..<result.count {
            let right = (index < rhs.limbs.count ? UInt64(rhs.limbs[index]) : 0) + borrow
            let left = UInt64(result[index])
            if left >= right {
                result[index] = UInt32(left - right)
                borrow = 0
            } else {
                result[index] = UInt32((left + (1 << 32)) - right)
                borrow = 1
            }
        }
        return SRPBigUInt(limbs: result)
    }

    static func * (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        guard !lhs.isZero, !rhs.isZero else { return SRPBigUInt() }
        let leftCount = lhs.limbs.count
        let rightCount = rhs.limbs.count
        var result = [UInt32](repeating: 0, count: leftCount + rightCount)
        lhs.limbs.withUnsafeBufferPointer { left in
            rhs.limbs.withUnsafeBufferPointer { right in
                result.withUnsafeMutableBufferPointer { out in
                    for i in 0..<leftCount {
                        let multiplier = UInt64(left[i])
                        if multiplier == 0 { continue }
                        var carry: UInt64 = 0
                        for j in 0..<rightCount {
                            let product = multiplier * UInt64(right[j]) + UInt64(out[i + j]) + carry
                            out[i + j] = UInt32(truncatingIfNeeded: product)
                            carry = product >> 32
                        }
                        out[i + rightCount] = UInt32(carry)
                    }
                }
            }
        }
        return SRPBigUInt(limbs: result)
    }

    static func % (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    static func / (lhs: SRPBigUInt, rhs: SRPBigUInt) -> SRPBigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).quotient
    }

    /// Long division (Knuth, The Art of Computer Programming vol. 2, 4.3.1, Algorithm D). `divisor` must not be zero.
    func quotientAndRemainder(dividingBy divisor: SRPBigUInt) -> (quotient: SRPBigUInt, remainder: SRPBigUInt) {
        precondition(!divisor.isZero, "SRPBigUInt division by zero")
        if self < divisor { return (SRPBigUInt(), self) }

        if divisor.limbs.count == 1 {
            let single = UInt64(divisor.limbs[0])
            var quotient = [UInt32](repeating: 0, count: limbs.count)
            var remainder: UInt64 = 0
            for index in stride(from: limbs.count - 1, through: 0, by: -1) {
                let current = remainder << 32 | UInt64(limbs[index])
                quotient[index] = UInt32(current / single)
                remainder = current % single
            }
            return (SRPBigUInt(limbs: quotient), SRPBigUInt(remainder))
        }

        let n = divisor.limbs.count
        let m = limbs.count - n
        let shift = UInt32(divisor.limbs[n - 1].leadingZeroBitCount)

        // Normalised so the divisor's top limb has its high bit set; Swift's shifts give zero for a shift by 32.
        var v = [UInt32](repeating: 0, count: n)
        for index in stride(from: n - 1, to: 0, by: -1) {
            v[index] = divisor.limbs[index] << shift | divisor.limbs[index - 1] >> (32 - shift)
        }
        v[0] = divisor.limbs[0] << shift

        var u = [UInt32](repeating: 0, count: limbs.count + 1)
        u[limbs.count] = limbs[limbs.count - 1] >> (32 - shift)
        for index in stride(from: limbs.count - 1, to: 0, by: -1) {
            u[index] = limbs[index] << shift | limbs[index - 1] >> (32 - shift)
        }
        u[0] = limbs[0] << shift

        var quotient = [UInt32](repeating: 0, count: m + 1)
        let base: UInt64 = 1 << 32
        let top = UInt64(v[n - 1])
        let next = UInt64(v[n - 2])

        v.withUnsafeBufferPointer { v in
            u.withUnsafeMutableBufferPointer { u in
                for j in stride(from: m, through: 0, by: -1) {
                    let numerator = UInt64(u[j + n]) << 32 | UInt64(u[j + n - 1])
                    var estimate = numerator / top
                    var remainder = numerator % top
                    while estimate >= base || estimate * next > (remainder << 32 | UInt64(u[j + n - 2])) {
                        estimate -= 1
                        remainder += top
                        if remainder >= base { break }
                    }

                    var borrow: Int64 = 0
                    for i in 0..<n {
                        let product = estimate * UInt64(v[i])
                        let difference = Int64(u[i + j]) - borrow - Int64(product & 0xFFFF_FFFF)
                        u[i + j] = UInt32(truncatingIfNeeded: difference)
                        borrow = Int64(product >> 32) - (difference >> 32)
                    }
                    let last = Int64(u[j + n]) - borrow
                    u[j + n] = UInt32(truncatingIfNeeded: last)

                    if last < 0 {
                        estimate -= 1
                        var carry: UInt64 = 0
                        for i in 0..<n {
                            let sum = UInt64(u[i + j]) + UInt64(v[i]) + carry
                            u[i + j] = UInt32(truncatingIfNeeded: sum)
                            carry = sum >> 32
                        }
                        u[j + n] = u[j + n] &+ UInt32(truncatingIfNeeded: carry)
                    }
                    quotient[j] = UInt32(truncatingIfNeeded: estimate)
                }
            }
        }

        var remainder = [UInt32](repeating: 0, count: n)
        for index in 0..<(n - 1) {
            remainder[index] = u[index] >> shift | u[index + 1] << (32 - shift)
        }
        remainder[n - 1] = u[n - 1] >> shift
        return (SRPBigUInt(limbs: quotient), SRPBigUInt(limbs: remainder))
    }

    /// `self` to the power `exponent`, modulo `modulus` (left-to-right square and multiply). `modulus` must not be zero.
    func power(_ exponent: SRPBigUInt, modulus: SRPBigUInt) -> SRPBigUInt {
        precondition(!modulus.isZero, "SRPBigUInt modulus of zero")
        if modulus == SRPBigUInt(1) { return SRPBigUInt() }
        let base = self % modulus
        var result = SRPBigUInt(1)
        let width = exponent.bitWidth
        guard width > 0 else { return result }
        for index in stride(from: width - 1, through: 0, by: -1) {
            result = (result * result) % modulus
            if exponent.bit(index) {
                result = (result * base) % modulus
            }
        }
        return result
    }
}
