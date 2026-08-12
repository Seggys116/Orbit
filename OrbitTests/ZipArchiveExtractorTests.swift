import XCTest

final class ZipArchiveExtractorTests: XCTestCase {

    private var createdPaths: [URL] = []

    override func tearDown() {
        for path in createdPaths {
            try? FileManager.default.removeItem(at: path)
        }
        createdPaths.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture directories

    private func makeDestination() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ZipExtractDestination-\(UUID().uuidString)", isDirectory: true)
        createdPaths.append(url)
        return url
    }

    private func makeSourceTree() throws -> (root: URL, topLevelEntries: [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ZipSourceTree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        createdPaths.append(root)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("subdir/subsubdir", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )

        try Data("root level manifest\n".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let repeatedContent = String(repeating: "Orbit extension asset content. ", count: 200)
        try Data(repeatedContent.utf8).write(to: root.appendingPathComponent("subdir/nested.txt"))
        try Data("deeply nested leaf file\n".utf8).write(to: root.appendingPathComponent("subdir/subsubdir/deep.txt"))
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x10, 0x20, 0x30]).write(to: root.appendingPathComponent("assets/icon.bin"))

        return (root, ["manifest.json", "subdir", "assets"])
    }

    private func zipDirectory(root: URL, entries: [String], stored: Bool = false) throws -> Data {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ZipFixture-\(UUID().uuidString).zip")
        createdPaths.append(archiveURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        var arguments = ["-r", "-q"]
        if stored {
            arguments.append("-0")
        }
        arguments.append(archiveURL.path)
        arguments.append(contentsOf: entries)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "/usr/bin/zip failed to build the test fixture archive.")

        return try Data(contentsOf: archiveURL)
    }

    private func collectFiles(under root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return result
        }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            result[relativePath] = try Data(contentsOf: url)
        }
        return result
    }

    // MARK: - Round trip

    func test_roundTrip_nestedDirectoryTree_defaultCompression() throws {
        let (sourceRoot, entries) = try makeSourceTree()
        let zipData = try zipDirectory(root: sourceRoot, entries: entries)
        let destination = makeDestination()

        let extracted = try ZipArchiveExtractor.extract(zipData, to: destination)

        XCTAssertFalse(extracted.isEmpty)
        let sourceFiles = try collectFiles(under: sourceRoot)
        let extractedFiles = try collectFiles(under: destination)
        XCTAssertEqual(extractedFiles, sourceFiles, "The extracted tree must be byte-for-byte identical to the original source tree.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("subdir/subsubdir/deep.txt").path),
            "A file nested two directories deep did not round-trip."
        )
    }

    func test_roundTrip_storedEntries_forcedViaZipDashZero() throws {
        let (sourceRoot, entries) = try makeSourceTree()
        let zipData = try zipDirectory(root: sourceRoot, entries: entries, stored: true)
        let destination = makeDestination()

        let extracted = try ZipArchiveExtractor.extract(zipData, to: destination)

        XCTAssertFalse(extracted.isEmpty)
        XCTAssertEqual(try collectFiles(under: destination), try collectFiles(under: sourceRoot))
    }

    func test_roundTrip_archiveWithTrailingComment_eocdScanFindsItPastTheComment() throws {
        let (sourceRoot, entries) = try makeSourceTree()
        let plainZipData = try zipDirectory(root: sourceRoot, entries: entries)
        let commentedZipData = appendComment(to: plainZipData, comment: "Orbit test fixture — not a real extension. 🧭")
        let destination = makeDestination()

        let extracted = try ZipArchiveExtractor.extract(commentedZipData, to: destination)

        XCTAssertFalse(extracted.isEmpty)
        XCTAssertEqual(try collectFiles(under: destination), try collectFiles(under: sourceRoot))
    }

    private func appendComment(to data: Data, comment: String) -> Data {
        var mutable = data
        let commentBytes = Array(comment.utf8)
        let lengthFieldOffset = mutable.count - 2
        mutable[lengthFieldOffset] = UInt8(commentBytes.count & 0xFF)
        mutable[lengthFieldOffset + 1] = UInt8((commentBytes.count >> 8) & 0xFF)
        mutable.append(contentsOf: commentBytes)
        return mutable
    }

    // MARK: - Empty archive

    func test_emptyArchive_extractsToAnEmptyExistingDirectory() throws {
        let zipData = buildZip(entries: [])
        let destination = makeDestination()

        let extracted = try ZipArchiveExtractor.extract(zipData, to: destination)

        XCTAssertEqual(extracted, [])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - Path traversal ("zip slip")

    func test_pathTraversalEntry_isRejected() throws {
        let maliciousName = "../../../../Library/LaunchAgents/x.plist"
        let zipData = buildZip(entries: [
            rawEntry(name: maliciousName, content: Array("evil".utf8))
        ])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .pathTraversalRejected(name: maliciousName))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "A rejected extraction must leave nothing at the destination.")
    }

    func test_pathTraversalEntry_withDotDotComponentInTheMiddle_isRejected() throws {
        let maliciousName = "innocuous/../../evil.txt"
        let zipData = buildZip(entries: [
            rawEntry(name: maliciousName, content: Array("evil".utf8))
        ])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .pathTraversalRejected(name: maliciousName))
        }
    }

    // MARK: - Absolute paths

    func test_absolutePathEntry_isRejected() throws {
        let maliciousName = "/etc/passwd"
        let zipData = buildZip(entries: [
            rawEntry(name: maliciousName, content: Array("evil".utf8))
        ])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .absolutePathRejected(name: maliciousName))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Backslash / NUL byte names

    func test_fileNameContainingBackslash_isRejected() throws {
        let maliciousName = "folder\\file.txt"
        let zipData = buildZip(entries: [
            rawEntry(name: maliciousName, content: Array("evil".utf8))
        ])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .fileNameContainsBackslash(name: maliciousName))
        }
    }

    func test_fileNameContainingNulByte_isRejected() throws {
        let maliciousName = "evil\0file.txt"
        let zipData = buildZip(entries: [
            rawEntry(name: maliciousName, content: Array("evil".utf8))
        ])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .fileNameContainsNulByte(rawByteCount: Array(maliciousName.utf8).count))
        }
    }

    // MARK: - Symlinks

    func test_symlinkEntry_isRejected() throws {
        let name = "evil-link"
        let content = Array("/etc/passwd".utf8)
        let symlinkExternalAttributes: UInt32 = (0xA1FF << 16)
        let zipData = buildZip(entries: [
            rawEntry(name: name, content: content, externalAttributes: symlinkExternalAttributes)
        ])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .symlinkRejected(name: name))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - CRC mismatch

    func test_crcMismatch_isRejected() throws {
        let name = "tampered.txt"
        let content = Array("this content does not match the declared crc".utf8)
        var entry = rawEntry(name: name, content: content)
        entry.crcOverride = 0x12345678
        let zipData = buildZip(entries: [entry])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .crcMismatch(name: name))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Declared vs actual size mismatch

    func test_declaredSizeMismatch_forStoredEntry_isRejected() throws {
        let name = "size-lie.txt"
        let content = Array("real content".utf8)
        var entry = rawEntry(name: name, content: content)
        entry.uncompressedSizeOverride = UInt32(content.count + 100)
        let zipData = buildZip(entries: [entry])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(
                error as? ZipArchiveError,
                .declaredSizeMismatch(name: name, declared: content.count + 100, actual: content.count)
            )
        }
    }

    // MARK: - Unsupported compression method

    func test_unsupportedCompressionMethod_isRejected() throws {
        let name = "weird.dat"
        var entry = rawEntry(name: name, content: Array("does not matter".utf8))
        entry.compressionMethod = 12 // BZIP2 — a real, but unsupported, ZIP method.
        let zipData = buildZip(entries: [entry])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .unsupportedCompressionMethod(name: name, method: 12))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Zip bomb limits

    func test_entryCountLimit_isEnforced() throws {
        let zipData = buildZip(entries: [
            rawEntry(name: "one.txt", content: Array("a".utf8)),
            rawEntry(name: "two.txt", content: Array("b".utf8)),
            rawEntry(name: "three.txt", content: Array("c".utf8))
        ])
        let destination = makeDestination()
        let limits = ZipArchiveExtractor.Limits(maxTotalUncompressedBytes: 1_000_000, maxEntryCount: 2, maxCompressionRatio: 1_000)

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination, limits: limits)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .entryCountLimitExceeded(limit: 2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // Real extensions with large locale/data sets exceed a low entry count long before they exceed
    // any real resource bound; Wappalyzer's real CRX ships 13,244 entries (see ExtensionInstallerTests'
    // large-CRX coverage). The default must accept that shape, not just a hand-picked small limit.
    func test_defaultLimits_acceptARealisticLargeEntryCount() throws {
        let entries = (0..<13_244).map { rawEntry(name: "file-\($0).json", content: []) }
        let zipData = buildZip(entries: entries)
        let destination = makeDestination()

        let extracted = try ZipArchiveExtractor.extract(zipData, to: destination)
        XCTAssertEqual(extracted.count, 13_244)
    }

    func test_totalUncompressedSizeLimit_isEnforced() throws {
        let content = [UInt8](repeating: 0x41, count: 1_000)
        let zipData = buildZip(entries: [rawEntry(name: "big.txt", content: content)])
        let destination = makeDestination()
        let limits = ZipArchiveExtractor.Limits(maxTotalUncompressedBytes: 500, maxEntryCount: 1_000, maxCompressionRatio: 1_000)

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination, limits: limits)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .totalUncompressedSizeLimitExceeded(limit: 500))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_compressionRatioLimit_isEnforced() throws {
        let name = "bomb.bin"
        var entry = rawEntry(name: name, content: Array("x".utf8))
        entry.compressionMethod = 8
        entry.uncompressedSizeOverride = 10_000
        let zipData = buildZip(entries: [entry])
        let destination = makeDestination()
        let limits = ZipArchiveExtractor.Limits(maxTotalUncompressedBytes: 1_000_000, maxEntryCount: 1_000, maxCompressionRatio: 100)

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination, limits: limits)) { error in
            guard case .compressionRatioLimitExceeded(let ratioName, let ratio, let limit) = error as? ZipArchiveError else {
                XCTFail("Expected .compressionRatioLimitExceeded, got \(String(describing: error))")
                return
            }
            XCTAssertEqual(ratioName, name)
            XCTAssertEqual(limit, 100)
            XCTAssertGreaterThan(ratio, 100)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Zip64 detection

    func test_zip64SentinelInEOCD_isRejected() throws {
        var zipData = buildZip(entries: [rawEntry(name: "a.txt", content: Array("a".utf8))])
        let eocdOffset = zipData.count - 22
        zipData[eocdOffset + 12] = 0xFF
        zipData[eocdOffset + 13] = 0xFF
        zipData[eocdOffset + 14] = 0xFF
        zipData[eocdOffset + 15] = 0xFF
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .zip64NotSupported)
        }
    }

    // MARK: - Directory entry with data

    func test_directoryEntryDeclaringNonzeroSize_isRejected() throws {
        let name = "not-really-a-dir/"
        var entry = rawEntry(name: name, content: Array("should not be here".utf8))
        entry.uncompressedSizeOverride = UInt32(entry.content.count)
        let zipData = buildZip(entries: [entry])
        let destination = makeDestination()

        XCTAssertThrowsError(try ZipArchiveExtractor.extract(zipData, to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .directoryEntryHasData(name: name))
        }
    }

    // A real Chrome Web Store CRX (Wappalyzer, gppongmhjkpfnbhagpmjfkannfbllamg) ships a "_locales/"
    // directory entry DEFLATEd rather than stored: zero uncompressed bytes, but a nonzero 2-byte
    // "empty block" deflate stream. compressedSize is meaningless for a directory and must not gate it.
    func test_directoryEntryWithDeflatedEmptyStream_isAccepted() throws {
        let name = "locales/"
        var entry = rawEntry(name: name, content: [0x03, 0x00]) // deflate's own empty-block encoding
        entry.compressionMethod = 8
        entry.uncompressedSizeOverride = 0
        let zipData = buildZip(entries: [entry])
        let destination = makeDestination()

        let extracted = try ZipArchiveExtractor.extract(zipData, to: destination)
        XCTAssertEqual(extracted, [name])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - Truncated input

    func test_truncatedInput_atSeveralOffsets_alwaysThrows_neverCrashes() throws {
        let (sourceRoot, entries) = try makeSourceTree()
        let fullZipData = try zipDirectory(root: sourceRoot, entries: entries)
        let count = fullZipData.count
        XCTAssertGreaterThan(count, 100, "Fixture sanity: the archive needs to be large enough for these offsets to be meaningful.")

        let offsets = [
            0,
            1,
            4,
            10,
            count / 2,
            count - 22,   // Exactly the start of a comment-less EOCD.
            count - 10,   // Inside the EOCD record.
            count - 2,    // Inside the EOCD's own comment-length field.
            count - 1,
        ]

        for offset in offsets {
            let truncated = fullZipData.prefix(offset)
            let destination = makeDestination()
            XCTAssertThrowsError(
                try ZipArchiveExtractor.extract(Data(truncated), to: destination),
                "Truncating to \(offset) of \(count) bytes must throw, not succeed."
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func test_zeroByteInput_throwsRatherThanCrashing() {
        let destination = makeDestination()
        XCTAssertThrowsError(try ZipArchiveExtractor.extract(Data(), to: destination)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .notAZipArchive)
        }
    }

    // MARK: - Unpacking cost
    //
    // Catches a return to per-entry atomic writes, per-entry URL standardisation, or serial
    // extraction — the causes that once made this take ~5.0s; it's ~1.1s now, budget set well above that.

    func test_unpackingARealisticExtensionSizedArchive_staysWithinItsBudget() throws {
        let budgetSeconds = 3.0

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ZipPerfTree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        createdPaths.append(root)

        var random = FixtureWordGenerator(seed: 0x0B17_5EED)
        var entryCount = 0

        try FileManager.default.createDirectory(at: root.appendingPathComponent("_locales"), withIntermediateDirectories: true)
        for locale in 0..<54 {
            let directory = root.appendingPathComponent("_locales/locale-\(locale)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(Self.wordSoup(bytes: 9_000, using: &random).utf8)
                .write(to: directory.appendingPathComponent("messages.json"))
            entryCount += 1
        }

        for group in 0..<64 {
            let directory = root.appendingPathComponent("technologies/group-\(group)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for shard in 0..<210 {
                try Data(Self.wordSoup(bytes: 400, using: &random).utf8)
                    .write(to: directory.appendingPathComponent("\(shard).json"))
                entryCount += 1
            }
        }

        let bundles = root.appendingPathComponent("js", isDirectory: true)
        try FileManager.default.createDirectory(at: bundles, withIntermediateDirectories: true)
        for (name, size) in [("content.js", 1_200_000), ("background.js", 2_400_000), ("vendor.js", 6_000_000)] {
            try Data(Self.wordSoup(bytes: size, using: &random).utf8).write(to: bundles.appendingPathComponent(name))
            entryCount += 1
        }

        XCTAssertGreaterThan(entryCount, 13_000, "The fixture stopped being the shape of a real large extension.")

        let zipData = try zipDirectory(root: root, entries: ["_locales", "technologies", "js"])

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let destination = makeDestination()
            let start = DispatchTime.now().uptimeNanoseconds
            let extracted = try ZipArchiveExtractor.extract(zipData, to: destination)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            XCTAssertGreaterThan(extracted.count, 13_000)
            best = min(best, elapsed)
            try? FileManager.default.removeItem(at: destination)
        }

        print(String(format: "ZipArchiveExtractor: %d entries unpacked in %.3fs (best of 3)", entryCount, best))
        XCTAssertLessThan(
            best, budgetSeconds,
            "Unpacking a realistic \(entryCount)-entry extension took \(best)s, over the \(budgetSeconds)s budget."
        )
    }

    private static func wordSoup(bytes: Int, using generator: inout FixtureWordGenerator) -> String {
        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu"]
        var result = ""
        result.reserveCapacity(bytes + 16)
        while result.utf8.count < bytes {
            result += words[Int(generator.next() % UInt64(words.count))]
            result += (generator.next() % 8 == 0) ? "\n" : " "
        }
        return result
    }

    // Deterministic, so a failure here is a real regression and not a fixture
    // that happened to compress differently this run. Named distinctly from
    // Orbit's own SeededGenerator: unrelated types, same tiny xorshift shape.
    private struct FixtureWordGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed | 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    // MARK: - Hand-built ("raw") ZIP fixtures

    private struct RawEntry {
        var name: String
        var content: [UInt8]
        var compressionMethod: UInt16 = 0
        var generalPurposeFlag: UInt16 = 0
        var externalAttributes: UInt32 = 0
        var crcOverride: UInt32?
        var uncompressedSizeOverride: UInt32?
    }

    private func rawEntry(
        name: String,
        content: [UInt8],
        compressionMethod: UInt16 = 0,
        externalAttributes: UInt32 = 0
    ) -> RawEntry {
        RawEntry(name: name, content: content, compressionMethod: compressionMethod, externalAttributes: externalAttributes)
    }

    private func buildZip(entries: [RawEntry]) -> Data {
        var data = Data()
        var centralDirectoryOffsets: [(entry: RawEntry, localOffset: UInt32, crc: UInt32)] = []

        for entry in entries {
            let localOffset = UInt32(data.count)
            let nameBytes = Array(entry.name.utf8)
            let crc = entry.crcOverride ?? crc32(entry.content)
            let compressedSize = UInt32(entry.content.count)
            let uncompressedSize = entry.uncompressedSizeOverride ?? UInt32(entry.content.count)

            data.append(contentsOf: leU32(0x04034b50))
            data.append(contentsOf: leU16(20))
            data.append(contentsOf: leU16(entry.generalPurposeFlag))
            data.append(contentsOf: leU16(entry.compressionMethod))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: leU32(crc))
            data.append(contentsOf: leU32(compressedSize))
            data.append(contentsOf: leU32(uncompressedSize))
            data.append(contentsOf: leU16(UInt16(nameBytes.count)))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: nameBytes)
            data.append(contentsOf: entry.content)

            centralDirectoryOffsets.append((entry, localOffset, crc))
        }

        let centralDirectoryStart = UInt32(data.count)
        for (entry, localOffset, crc) in centralDirectoryOffsets {
            let nameBytes = Array(entry.name.utf8)
            let compressedSize = UInt32(entry.content.count)
            let uncompressedSize = entry.uncompressedSizeOverride ?? UInt32(entry.content.count)

            data.append(contentsOf: leU32(0x02014b50))
            data.append(contentsOf: leU16(20))
            data.append(contentsOf: leU16(20))
            data.append(contentsOf: leU16(entry.generalPurposeFlag))
            data.append(contentsOf: leU16(entry.compressionMethod))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: leU32(crc))
            data.append(contentsOf: leU32(compressedSize))
            data.append(contentsOf: leU32(uncompressedSize))
            data.append(contentsOf: leU16(UInt16(nameBytes.count)))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: leU16(0))
            data.append(contentsOf: leU32(entry.externalAttributes))
            data.append(contentsOf: leU32(localOffset))
            data.append(contentsOf: nameBytes)
        }
        let centralDirectorySize = UInt32(data.count) - centralDirectoryStart

        data.append(contentsOf: leU32(0x06054b50))
        data.append(contentsOf: leU16(0))
        data.append(contentsOf: leU16(0))
        data.append(contentsOf: leU16(UInt16(entries.count)))
        data.append(contentsOf: leU16(UInt16(entries.count)))
        data.append(contentsOf: leU32(centralDirectorySize))
        data.append(contentsOf: leU32(centralDirectoryStart))
        data.append(contentsOf: leU16(0))

        return data
    }

    private func leU16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private func leU32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
