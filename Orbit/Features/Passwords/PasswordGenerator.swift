import Foundation
import Security

/// Strong random passwords. Every character comes from the system's secure random source, and indexes are drawn by rejection sampling so no character is likelier than another.
nonisolated struct PasswordGenerator: Sendable {

    static let uppercaseLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lowercaseLetters = Array("abcdefghijklmnopqrstuvwxyz")
    static let digits = Array("0123456789")
    /// No quotes, backslash, angle brackets, space or hyphen, so the password survives form fields and never looks like a group separator.
    static let symbols = Array("!@#$%^&*_+=?")
    /// Characters that are easy to mistake for another in some typefaces.
    static let lookAlikes: Set<Character> = ["0", "O", "o", "1", "l", "I"]

    static let maximumLength = 128

    struct Options: Equatable, Sendable {
        /// Number of password characters, not counting group separators.
        var length: Int = 20
        var includeUppercase = true
        var includeLowercase = true
        var includeDigits = true
        var includeSymbols = true
        /// Leaves out 0 O o 1 l I.
        var avoidLookAlikes = false
        /// Splits the password into groups with a hyphen between them, such as xxxxxx-xxxxxx-xxxxxx.
        var grouped = false
        var groupSize = 6

        init() {}

        /// Letters and digits in three groups of six, the shape Safari suggests.
        static var safariLike: Options {
            var options = Options()
            options.length = 18
            options.includeSymbols = false
            options.grouped = true
            options.groupSize = 6
            return options
        }

        /// What `generate` actually uses: at least one class enabled (lower case when none is) and a length that fits one character from each enabled class.
        var normalized: Options {
            var options = self
            if !(options.includeUppercase || options.includeLowercase || options.includeDigits || options.includeSymbols) {
                options.includeLowercase = true
            }
            let classCount = [options.includeUppercase, options.includeLowercase, options.includeDigits, options.includeSymbols]
                .filter { $0 }.count
            options.length = min(max(options.length, classCount), PasswordGenerator.maximumLength)
            options.groupSize = max(options.groupSize, 1)
            return options
        }
    }

    private let randomBytes: @Sendable (Int) -> [UInt8]

    /// `randomBytes` returns exactly the requested number of bytes. Tests replace it to exercise rejection sampling.
    init(randomBytes: @escaping @Sendable (Int) -> [UInt8] = PasswordGenerator.secureRandomBytes) {
        self.randomBytes = randomBytes
    }

    static let secure = PasswordGenerator()

    func generate(_ requested: Options = Options()) -> String {
        let options = requested.normalized
        var classes: [[Character]] = []
        if options.includeUppercase { classes.append(Self.uppercaseLetters) }
        if options.includeLowercase { classes.append(Self.lowercaseLetters) }
        if options.includeDigits { classes.append(Self.digits) }
        if options.includeSymbols { classes.append(Self.symbols) }
        if options.avoidLookAlikes {
            classes = classes.map { $0.filter { !Self.lookAlikes.contains($0) } }
        }
        let pool = classes.flatMap { $0 }

        var characters = classes.map { $0[randomIndex(below: $0.count)] }
        while characters.count < options.length {
            characters.append(pool[randomIndex(below: pool.count)])
        }
        shuffle(&characters)

        guard options.grouped else { return String(characters) }
        return stride(from: 0, to: characters.count, by: options.groupSize)
            .map { String(characters[$0..<min($0 + options.groupSize, characters.count)]) }
            .joined(separator: "-")
    }

    /// Uniform in 0..<bound by discarding draws from the uneven tail of the 32-bit range.
    func randomIndex(below bound: Int) -> Int {
        precondition(bound > 0 && bound <= Int(UInt32.max), "bound out of range")
        let range = UInt64(1) << 32
        let limit = range - range % UInt64(bound)
        while true {
            let bytes = randomBytes(4)
            precondition(bytes.count == 4, "random source returned the wrong number of bytes")
            let draw = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if draw < limit { return Int(draw % UInt64(bound)) }
        }
    }

    private func shuffle(_ characters: inout [Character]) {
        guard characters.count > 1 else { return }
        for index in stride(from: characters.count - 1, to: 0, by: -1) {
            characters.swapAt(index, randomIndex(below: index + 1))
        }
    }

    static func secureRandomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess { return bytes }
        // SystemRandomNumberGenerator is also the system's secure source; this only runs if Security refuses.
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
