import Foundation

nonisolated enum FilterTokenizer {

    static let minimumTokenLength = 3

    @inline(__always)
    static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
    }

    @inline(__always)
    static func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    static func tokens(forURLBytes bytes: [UInt8]) -> [UInt64] {
        var result: [UInt64] = []
        result.reserveCapacity(16)
        var runStart = -1
        var index = 0
        let count = bytes.count
        while index <= count {
            let inRun = index < count && isTokenByte(bytes[index])
            if inRun {
                if runStart < 0 { runStart = index }
            } else if runStart >= 0 {
                if index - runStart >= minimumTokenLength {
                    result.append(hash(bytes[runStart..<index]))
                }
                runStart = -1
            }
            index += 1
        }
        return result
    }

    // A run must be delimited on both sides (anchor or non-alphanumeric byte) or the rule never fires.
    static func bestToken(forPattern pattern: String, leftAnchored: Bool, rightAnchored: Bool) -> UInt64? {
        let bytes = Array(pattern.utf8)
        guard !bytes.isEmpty else { return nil }

        var best: (start: Int, end: Int)?
        var runStart = -1
        var index = 0

        func consider(start: Int, end: Int) {
            let leftOK: Bool
            if start == 0 {
                leftOK = leftAnchored
            } else {
                let before = bytes[start - 1]
                leftOK = before != UInt8(ascii: "*")
            }
            guard leftOK else { return }
            let rightOK: Bool
            if end == bytes.count {
                rightOK = rightAnchored
            } else {
                let after = bytes[end]
                rightOK = after != UInt8(ascii: "*")
            }
            guard rightOK else { return }

            guard end - start >= minimumTokenLength else { return }
            if let current = best, current.end - current.start >= end - start { return }
            best = (start, end)
        }

        while index <= bytes.count {
            let inRun = index < bytes.count && isTokenByte(bytes[index])
            if inRun {
                if runStart < 0 { runStart = index }
            } else if runStart >= 0 {
                consider(start: runStart, end: index)
                runStart = -1
            }
            index += 1
        }

        guard let best else { return nil }
        return hash(bytes[best.start..<best.end])
    }
}
