import XCTest

/// Hands out scripted draws one after another, then zeros, so a test can force rejection sampling down a known path.
nonisolated final class ScriptedByteSource: @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [[UInt8]]
    private(set) var requests = 0

    init(_ draws: [[UInt8]]) {
        scripted = draws
    }

    func next(_ count: Int) -> [UInt8] {
        lock.withLock {
            requests += 1
            if scripted.isEmpty { return [UInt8](repeating: 0, count: count) }
            return scripted.removeFirst()
        }
    }
}

final class PasswordGeneratorTests: XCTestCase {

    private let generator = PasswordGenerator()

    private func isUpper(_ c: Character) -> Bool { PasswordGenerator.uppercaseLetters.contains(c) }
    private func isLower(_ c: Character) -> Bool { PasswordGenerator.lowercaseLetters.contains(c) }
    private func isDigit(_ c: Character) -> Bool { PasswordGenerator.digits.contains(c) }
    private func isSymbol(_ c: Character) -> Bool { PasswordGenerator.symbols.contains(c) }

    // MARK: - Defaults

    func testTheDefaultIsTwentyCharactersWithEveryClass() {
        for _ in 0..<500 {
            let password = generator.generate()
            XCTAssertEqual(password.count, 20, password)
            XCTAssertTrue(password.contains(where: isUpper), password)
            XCTAssertTrue(password.contains(where: isLower), password)
            XCTAssertTrue(password.contains(where: isDigit), password)
            XCTAssertTrue(password.contains(where: isSymbol), password)
            XCTAssertTrue(password.allSatisfy { isUpper($0) || isLower($0) || isDigit($0) || isSymbol($0) }, password)
        }
    }

    func testTheSharedInstanceUsesTheSystemRandomSource() {
        let password = PasswordGenerator.secure.generate()
        XCTAssertEqual(password.count, 20)
        XCTAssertEqual(PasswordGenerator.secureRandomBytes(4).count, 4)
        let draws = Set((0..<64).map { _ in PasswordGenerator.secureRandomBytes(8) })
        XCTAssertGreaterThan(draws.count, 60)
    }

    // MARK: - Length

    func testLengthIsHonoured() {
        for length in [4, 8, 12, 20, 32, 64, 128] {
            var options = PasswordGenerator.Options()
            options.length = length
            XCTAssertEqual(generator.generate(options).count, length)
        }
    }

    func testLengthIsRaisedToFitOneCharacterOfEachEnabledClass() {
        var options = PasswordGenerator.Options()
        options.length = 1
        let password = generator.generate(options)
        XCTAssertEqual(password.count, 4)
        XCTAssertTrue(password.contains(where: isUpper) && password.contains(where: isLower))
        XCTAssertTrue(password.contains(where: isDigit) && password.contains(where: isSymbol))

        options.includeSymbols = false
        options.includeDigits = false
        options.length = 0
        XCTAssertEqual(generator.generate(options).count, 2)
    }

    func testLengthIsCappedAtTheMaximum() {
        var options = PasswordGenerator.Options()
        options.length = 10_000
        XCTAssertEqual(generator.generate(options).count, PasswordGenerator.maximumLength)
    }

    // MARK: - Classes

    func testEachClassGuaranteeHoldsEvenAtTheShortestLength() {
        var options = PasswordGenerator.Options()
        options.length = 4
        for _ in 0..<500 {
            let password = generator.generate(options)
            XCTAssertEqual(password.filter(isUpper).count, 1, password)
            XCTAssertEqual(password.filter(isLower).count, 1, password)
            XCTAssertEqual(password.filter(isDigit).count, 1, password)
            XCTAssertEqual(password.filter(isSymbol).count, 1, password)
        }
    }

    func testDisabledClassesNeverAppear() {
        var options = PasswordGenerator.Options()
        options.includeSymbols = false
        for _ in 0..<300 {
            let password = generator.generate(options)
            XCTAssertFalse(password.contains(where: isSymbol), password)
            XCTAssertTrue(password.contains(where: isUpper) && password.contains(where: isLower) && password.contains(where: isDigit), password)
        }

        options = PasswordGenerator.Options()
        options.includeUppercase = false
        options.includeLowercase = false
        options.includeSymbols = false
        for _ in 0..<100 {
            XCTAssertTrue(generator.generate(options).allSatisfy(isDigit))
        }
    }

    func testWithNoClassEnabledItFallsBackToLowercaseLetters() {
        var options = PasswordGenerator.Options()
        options.includeUppercase = false
        options.includeLowercase = false
        options.includeDigits = false
        options.includeSymbols = false
        let password = generator.generate(options)
        XCTAssertEqual(password.count, 20)
        XCTAssertTrue(password.allSatisfy(isLower), password)
    }

    func testTheSymbolSetHasNothingThatBreaksAFormFieldOrAGroupSeparator() {
        let unsafe: Set<Character> = ["\"", "'", "\\", "`", "<", ">", " ", "-", "/", ";", ":", ",", "."]
        XCTAssertTrue(PasswordGenerator.symbols.allSatisfy { !unsafe.contains($0) })
        XCTAssertEqual(Set(PasswordGenerator.symbols).count, PasswordGenerator.symbols.count)
    }

    // MARK: - Look-alikes

    func testLookAlikesAreLeftOutWhenAskedAndEveryClassIsStillPresent() {
        var options = PasswordGenerator.Options()
        options.avoidLookAlikes = true
        let forbidden: Set<Character> = ["0", "O", "o", "1", "l", "I"]
        for _ in 0..<1000 {
            let password = generator.generate(options)
            XCTAssertTrue(password.allSatisfy { !forbidden.contains($0) }, password)
            XCTAssertTrue(password.contains(where: isUpper) && password.contains(where: isLower), password)
            XCTAssertTrue(password.contains(where: isDigit) && password.contains(where: isSymbol), password)
        }
    }

    func testLookAlikesDoAppearWhenNotAskedToAvoidThem() {
        let forbidden: Set<Character> = ["0", "O", "o", "1", "l", "I"]
        let found = (0..<500).contains { _ in generator.generate().contains { forbidden.contains($0) } }
        XCTAssertTrue(found)
    }

    // MARK: - Grouped

    func testTheSafariLikeFormatIsThreeGroupsOfSix() throws {
        let pattern = try NSRegularExpression(pattern: "^[A-Za-z0-9]{6}-[A-Za-z0-9]{6}-[A-Za-z0-9]{6}$")
        for _ in 0..<500 {
            let password = generator.generate(.safariLike)
            XCTAssertEqual(password.count, 20, password)
            XCTAssertNotNil(pattern.firstMatch(in: password, range: NSRange(password.startIndex..., in: password)), password)
            XCTAssertTrue(password.contains(where: isUpper), password)
            XCTAssertTrue(password.contains(where: isLower), password)
            XCTAssertTrue(password.contains(where: isDigit), password)
        }
    }

    func testGroupingSplitsTheCharactersAndLeavesAShorterLastGroup() {
        var options = PasswordGenerator.Options()
        options.grouped = true
        options.includeSymbols = false
        options.length = 20
        let groups = generator.generate(options).split(separator: "-")
        XCTAssertEqual(groups.map(\.count), [6, 6, 6, 2])

        options.groupSize = 4
        options.length = 16
        XCTAssertEqual(generator.generate(options).split(separator: "-").map(\.count), [4, 4, 4, 4])
    }

    func testAGroupSizeBelowOneIsTreatedAsOne() {
        var options = PasswordGenerator.Options()
        options.grouped = true
        options.groupSize = 0
        options.length = 5
        XCTAssertEqual(generator.generate(options).filter { $0 == "-" }.count, 4)
    }

    func testAnUngroupedPasswordHasNoSeparator() {
        for _ in 0..<200 {
            XCTAssertFalse(generator.generate().contains("-"))
        }
    }

    // MARK: - Randomness

    func testManyPasswordsAreAllDistinct() {
        let passwords = Set((0..<2000).map { _ in generator.generate() })
        XCTAssertEqual(passwords.count, 2000)
        let grouped = Set((0..<2000).map { _ in generator.generate(.safariLike) })
        XCTAssertEqual(grouped.count, 2000)
    }

    func testTheGuaranteedCharactersLandInEveryPositionEvenly() {
        var options = PasswordGenerator.Options()
        options.length = 4
        var digitAtPosition = [Int](repeating: 0, count: 4)
        let runs = 4000
        for _ in 0..<runs {
            let characters = Array(generator.generate(options))
            for (index, character) in characters.enumerated() where isDigit(character) {
                digitAtPosition[index] += 1
            }
        }
        // Each position should see the digit a quarter of the time; 800...1200 is about seven standard deviations either side.
        for count in digitAtPosition {
            XCTAssertTrue((800...1200).contains(count), "\(digitAtPosition)")
        }
    }

    func testCharactersOfOneClassAreDrawnEvenly() {
        var options = PasswordGenerator.Options()
        options.includeUppercase = false
        options.includeLowercase = false
        options.includeSymbols = false
        options.length = 100
        var counts = [Character: Int]()
        for _ in 0..<600 {
            for character in generator.generate(options) { counts[character, default: 0] += 1 }
        }
        XCTAssertEqual(counts.count, 10)
        // 60000 draws over ten digits is 6000 each; 5400...6600 is about eight standard deviations.
        for (character, count) in counts {
            XCTAssertTrue((5400...6600).contains(count), "\(character): \(count)")
        }
    }

    // MARK: - Rejection sampling

    func testADrawFromTheUnevenTailOfTheRangeIsRejected() {
        // 2^32 mod 10 is 6, so draws of 4294967290 and above would favour the low digits.
        let source = ScriptedByteSource([[0xFF, 0xFF, 0xFF, 0xFA], [0xFF, 0xFF, 0xFF, 0xFF], [0xFF, 0xFF, 0xFF, 0xF9]])
        let scripted = PasswordGenerator(randomBytes: { source.next($0) })
        XCTAssertEqual(scripted.randomIndex(below: 10), 9)
        XCTAssertEqual(source.requests, 3)
    }

    func testADrawJustBelowTheLimitIsAccepted() {
        let source = ScriptedByteSource([[0xFF, 0xFF, 0xFF, 0xF9]])
        XCTAssertEqual(PasswordGenerator(randomBytes: { source.next($0) }).randomIndex(below: 10), 9)
        XCTAssertEqual(source.requests, 1)
    }

    func testABoundThatDividesTheRangeEvenlyNeverRejects() {
        let source = ScriptedByteSource([[0xFF, 0xFF, 0xFF, 0xFF]])
        XCTAssertEqual(PasswordGenerator(randomBytes: { source.next($0) }).randomIndex(below: 256), 255)
        XCTAssertEqual(source.requests, 1)
    }

    func testABoundOfOneAlwaysGivesZero() {
        let scripted = PasswordGenerator(randomBytes: { _ in [0xDE, 0xAD, 0xBE, 0xEF] })
        XCTAssertEqual(scripted.randomIndex(below: 1), 0)
    }

    func testThreeDoesNotWrapAroundOnTheTopDraw() {
        // 2^32 mod 3 is 1, so only 4294967295 is rejected.
        let source = ScriptedByteSource([[0xFF, 0xFF, 0xFF, 0xFF], [0xFF, 0xFF, 0xFF, 0xFE]])
        XCTAssertEqual(PasswordGenerator(randomBytes: { source.next($0) }).randomIndex(below: 3), Int(UInt32.max - 1) % 3)
        XCTAssertEqual(source.requests, 2)
    }

    func testAnAllZeroSourceStillYieldsEveryClass() {
        let source = ScriptedByteSource([])
        let password = PasswordGenerator(randomBytes: { source.next($0) }).generate()
        XCTAssertEqual(password.count, 20)
        XCTAssertTrue(password.contains(where: isUpper) && password.contains(where: isLower))
        XCTAssertTrue(password.contains(where: isDigit) && password.contains(where: isSymbol))
    }

    func testEveryCharacterComesFromTheRandomSource() {
        let source = ScriptedByteSource([])
        _ = PasswordGenerator(randomBytes: { source.next($0) }).generate()
        // One draw per class, one per filler character and one per shuffle step.
        XCTAssertEqual(source.requests, 4 + 16 + 19)
    }
}
