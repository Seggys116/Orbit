import XCTest

// MARK: - Direct encode/decode

final class CompiledFilterListCacheEncodingTests: XCTestCase {

    // MARK: Round trip

    private static let sampleListText = """
    ! Title: CompiledFilterListCache sample
    ||adnxs.com^$third-party,script,image
    @@||adnxs.com/allow^$domain=example.com|~sub.example.com
    |https://exact-start.example/path|
    /example\\.com\\/track\\d+/$match-case
    example.com,~sub.example.com##.ad-banner
    example.com#@#.allowed-banner
    """

    func testNetworkAndCosmeticRulesSurviveARoundTrip() throws {
        let parsed = FilterListParser.parse(Self.sampleListText, listID: "SampleList")
        XCTAssertGreaterThan(parsed.network.count, 0, "fixture must actually produce network rules, or this test proves nothing")
        XCTAssertGreaterThan(parsed.cosmetic.count, 0, "fixture must actually produce cosmetic rules, or this test proves nothing")

        let encoded = CompiledFilterListCache.encode(parsed, contentHash: "sample-hash")
        let decoded = try XCTUnwrap(
            CompiledFilterListCache.decode(encoded, expectedContentHash: "sample-hash", listID: "SampleList")
        )

        XCTAssertEqual(decoded.network.count, parsed.network.count)
        XCTAssertEqual(decoded.cosmetic.count, parsed.cosmetic.count)
        XCTAssertEqual(decoded.stats, parsed.stats, "stats must round-trip exactly — they are what the UI is allowed to quote")

        var fromParse = ContentBlockerRuleSet()
        fromParse.add(parsed: parsed, listID: "SampleList")
        var fromCache = ContentBlockerRuleSet()
        fromCache.add(parsed: decoded, listID: "SampleList")

        let probes: [(url: String, document: String, type: ContentBlockingResourceType)] = [
            ("https://ib.adnxs.com/x", "https://a.example/", .script),
            ("https://ib.adnxs.com/allow", "https://example.com/", .script),
            ("https://exact-start.example/path", "https://a.example/", .document),
            ("https://exact-start.example/path/extra", "https://a.example/", .document),
            ("https://example.com/track42", "https://a.example/", .other),
        ]
        for probe in probes {
            let parseDecision = fromParse.decision(forURL: probe.url, documentURL: probe.document, resourceType: probe.type)
            let cacheDecision = fromCache.decision(forURL: probe.url, documentURL: probe.document, resourceType: probe.type)
            XCTAssertEqual(
                parseDecision, cacheDecision,
                "decision for \(probe.url) diverged between the freshly-parsed rule set and the cache round trip"
            )
        }

        for host in ["example.com", "sub.example.com", "other.example"] {
            XCTAssertEqual(
                fromParse.cosmeticSelectors(forHost: host),
                fromCache.cosmeticSelectors(forHost: host),
                "cosmetic selectors for \(host) diverged between the freshly-parsed rule set and the cache round trip"
            )
        }
    }

    func testTokenPresenceRoundTrips() throws {
        let text = """
        ||easylist-token-example.test^
        a*z
        """
        let parsed = FilterListParser.parse(text, listID: "TokenSample")
        XCTAssertEqual(parsed.network.count, 2)
        let withToken = parsed.network.first { $0.token != nil }
        let withoutToken = parsed.network.first { $0.token == nil }
        XCTAssertNotNil(withToken, "fixture must include a rule with a token")
        XCTAssertNotNil(withoutToken, "fixture must include a rule with no token")

        let decoded = try XCTUnwrap(CompiledFilterListCache.decode(
            CompiledFilterListCache.encode(parsed, contentHash: "h"),
            expectedContentHash: "h",
            listID: "TokenSample"
        ))
        XCTAssertEqual(decoded.network.map(\.token), parsed.network.map(\.token))
    }

    func testListIDIsStampedFromTheDecodeCallSiteNotStoredPerRule() throws {
        let parsed = FilterListParser.parse("||adnxs.com^\n", listID: "OriginalListID")
        let encoded = CompiledFilterListCache.encode(parsed, contentHash: "h")
        let decoded = try XCTUnwrap(
            CompiledFilterListCache.decode(encoded, expectedContentHash: "h", listID: "RestampedListID")
        )
        XCTAssertEqual(decoded.network.first?.listID, "RestampedListID")
    }

    // MARK: Rejection

    func testContentHashMismatchIsRejected() {
        let parsed = FilterListParser.parse("||adnxs.com^\n", listID: "L")
        let encoded = CompiledFilterListCache.encode(parsed, contentHash: "correct-hash")
        XCTAssertNil(CompiledFilterListCache.decode(encoded, expectedContentHash: "different-hash", listID: "L"))
        XCTAssertNotNil(CompiledFilterListCache.decode(encoded, expectedContentHash: "correct-hash", listID: "L"))
    }

    func testWrongMagicIsRejected() {
        let parsed = FilterListParser.parse("||adnxs.com^\n", listID: "L")
        var bytes = [UInt8](CompiledFilterListCache.encode(parsed, contentHash: "h"))
        bytes[0] = bytes[0] &+ 1
        XCTAssertNil(CompiledFilterListCache.decode(Data(bytes), expectedContentHash: "h", listID: "L"))
    }

    func testWrongFormatVersionIsRejected() {
        let parsed = FilterListParser.parse("||adnxs.com^\n", listID: "L")
        var bytes = [UInt8](CompiledFilterListCache.encode(parsed, contentHash: "h"))
        bytes[4] = bytes[4] &+ 1
        XCTAssertNil(CompiledFilterListCache.decode(Data(bytes), expectedContentHash: "h", listID: "L"))
    }

    func testTruncatedDataIsRejectedNotTrapped() {
        let parsed = FilterListParser.parse(Self.sampleListText, listID: "L")
        let full = CompiledFilterListCache.encode(parsed, contentHash: "h")
        for fraction in [0.0, 0.1, 0.5, 0.9, 0.99] {
            let cut = Int(Double(full.count) * fraction)
            let truncated = full.prefix(cut)
            XCTAssertNil(
                CompiledFilterListCache.decode(Data(truncated), expectedContentHash: "h", listID: "L"),
                "a cache truncated to \(Int(fraction * 100))% of its length must be rejected, not trapped or partially trusted"
            )
        }
    }

    func testTrailingGarbageAfterAllDeclaredRulesIsRejected() {
        let parsed = FilterListParser.parse("||adnxs.com^\n", listID: "L")
        var bytes = [UInt8](CompiledFilterListCache.encode(parsed, contentHash: "h"))
        bytes.append(contentsOf: [0xFF, 0xEE, 0xDD, 0xCC])
        XCTAssertNil(CompiledFilterListCache.decode(Data(bytes), expectedContentHash: "h", listID: "L"))
    }

    func testEmptyDataIsRejected() {
        XCTAssertNil(CompiledFilterListCache.decode(Data(), expectedContentHash: "h", listID: "L"))
    }
}

// MARK: - Integration through the controller

final class ContentBlockingCompiledCacheIntegrationTests: XCTestCase {

    private var createdDirectories: [URL] = []

    override func tearDown() {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories = []
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-CompiledCacheIntegration-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(url)
        return url
    }

    @discardableResult
    private func seedRawList(
        in directory: URL,
        listID: String = "EasyList",
        text: String,
        contentHash: String
    ) throws -> FilterListCacheEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent("\(listID).txt"), atomically: true, encoding: .utf8)
        let entry = FilterListCacheEntry(
            listID: listID,
            sourceURLs: [URL(string: "https://easylist.to/easylist/easylist.txt")!],
            declaredVersion: "1",
            declaredTitle: listID,
            expiresAfter: 4 * 86_400,
            fetchedAt: Date(),
            lastCheckedAt: Date(),
            etag: nil,
            lastModified: nil,
            byteCount: text.utf8.count,
            contentHash: contentHash
        )
        let data = try JSONEncoder.orbitContentBlocking.encode([listID: entry])
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        return entry
    }

    /// Seeds several lists into ONE shared index.json; seedRawList above
    /// writes a single-key index and would clobber a previous entry.
    private func seedRawLists(
        in directory: URL,
        _ lists: [(listID: String, text: String, contentHash: String)]
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [String: FilterListCacheEntry] = [:]
        for list in lists {
            try list.text.write(to: directory.appendingPathComponent("\(list.listID).txt"), atomically: true, encoding: .utf8)
            entries[list.listID] = FilterListCacheEntry(
                listID: list.listID,
                sourceURLs: [URL(string: "https://easylist.to/easylist/easylist.txt")!],
                declaredVersion: "1",
                declaredTitle: list.listID,
                expiresAfter: 4 * 86_400,
                fetchedAt: Date(),
                lastCheckedAt: Date(),
                etag: nil,
                lastModified: nil,
                byteCount: list.text.utf8.count,
                contentHash: list.contentHash
            )
        }
        let data = try JSONEncoder.orbitContentBlocking.encode(entries)
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    private func makeController(store: FilterListStore, listID: String = "EasyList") -> ContentBlockingController {
        let defaults = UserDefaults(suiteName: "OrbitTests.CompiledCacheIntegration.\(UUID().uuidString)")!
        defaults.set([listID], forKey: "contentBlocking.enabledLists")
        return ContentBlockingController(store: store, defaults: defaults)
    }

    private func makeController(store: FilterListStore, listIDs: [String]) -> ContentBlockingController {
        let defaults = UserDefaults(suiteName: "OrbitTests.CompiledCacheIntegration.\(UUID().uuidString)")!
        defaults.set(listIDs, forKey: "contentBlocking.enabledLists")
        return ContentBlockingController(store: store, defaults: defaults)
    }

    private static let realText = "||adnxs.com^\n"
    private static let differentText = """
    ||adnxs.com^
    ||doubleclick.net^
    ||googlesyndication.com^
    """

    // MARK: A valid, matching cache is actually used

    func testValidMatchingCacheIsUsed() async throws {
        let directory = makeTempDirectory()
        let entry = try seedRawList(in: directory, text: Self.realText, contentHash: "matching-hash")
        let store = FilterListStore(directory: directory)

        let parsed = FilterListParser.parse(Self.realText, listID: "EasyList")
        let validCache = CompiledFilterListCache.encode(parsed, contentHash: entry.contentHash)
        await store.storeCompiledCache(validCache, for: "EasyList")

        let controller = makeController(store: store)
        await controller.awaitInitialCacheLoad()

        XCTAssertEqual(controller.compiledRuleCount, 1)
        controller.blocker.isEnabled = true
        XCTAssertTrue(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked)
    }

    // MARK: Rejection, proven through the same entry point

    func testMismatchedContentHashCacheIsRejectedInFavorOfTheRealText() async throws {
        let directory = makeTempDirectory()
        let entry = try seedRawList(in: directory, text: Self.realText, contentHash: "real-content-hash")
        let store = FilterListStore(directory: directory)

        let wrongParsed = FilterListParser.parse(Self.differentText, listID: "EasyList")
        XCTAssertEqual(wrongParsed.network.count, 3, "fixture must actually produce a different rule count, or this test proves nothing")
        let staleCache = CompiledFilterListCache.encode(wrongParsed, contentHash: "stale-hash-from-a-previous-download")
        XCTAssertNotEqual("stale-hash-from-a-previous-download", entry.contentHash)
        await store.storeCompiledCache(staleCache, for: "EasyList")

        let controller = makeController(store: store)
        await controller.awaitInitialCacheLoad()

        XCTAssertEqual(
            controller.compiledRuleCount, 1,
            "a cache whose content hash does not match the real cached text must be rejected in favour of a real parse of that text — not the planted cache's 3 rules"
        )
        controller.blocker.isEnabled = true
        XCTAssertTrue(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "the real text's rule, not the stale cache's rules, must be the one actually live in the blocker")
        XCTAssertFalse(controller.blocker.decision(
            forURL: "https://x.doubleclick.net/y", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "a rule that exists ONLY in the rejected stale cache must not be live")
    }

    func testCorruptCacheBytesAreRejectedInFavorOfTheRealText() async throws {
        let directory = makeTempDirectory()
        _ = try seedRawList(in: directory, text: Self.realText, contentHash: "any-hash")
        let store = FilterListStore(directory: directory)

        await store.storeCompiledCache(Data([0x00, 0x01, 0x02, 0x03, 0x04]), for: "EasyList")

        let controller = makeController(store: store)
        await controller.awaitInitialCacheLoad()

        XCTAssertEqual(controller.compiledRuleCount, 1, "garbage cache bytes must fall back to a real parse, not crash or produce zero rules")
    }

    func testCacheFromAnIncompatibleFormatVersionIsRejectedInFavorOfTheRealText() async throws {
        let directory = makeTempDirectory()
        let entry = try seedRawList(in: directory, text: Self.realText, contentHash: "hash-for-version-test")
        let store = FilterListStore(directory: directory)

        let parsed = FilterListParser.parse(Self.realText, listID: "EasyList")
        var bytes = [UInt8](CompiledFilterListCache.encode(parsed, contentHash: entry.contentHash))
        // Corrupt the formatVersion field (the 4 bytes right after the fixed
        // 4-byte magic) so it no longer matches `CompiledFilterListCache.formatVersion`.
        bytes[4] = bytes[4] &+ 1
        await store.storeCompiledCache(Data(bytes), for: "EasyList")

        let controller = makeController(store: store)
        await controller.awaitInitialCacheLoad()

        XCTAssertEqual(controller.compiledRuleCount, 1)
    }

    func testMissingCompiledCacheFallsBackToTheRealText() async throws {
        let directory = makeTempDirectory()
        _ = try seedRawList(in: directory, text: Self.realText, contentHash: "hash-for-missing-test")
        let store = FilterListStore(directory: directory)
        // Deliberately no `storeCompiledCache` call.

        let controller = makeController(store: store)
        await controller.awaitInitialCacheLoad()

        XCTAssertEqual(controller.compiledRuleCount, 1)
    }

    // MARK: Concurrency must not narrow what "the cached compile has landed" means

    func testAllEnabledListsAreCompiledBeforeAwaitInitialCacheLoadReturnsEvenWhenParsedConcurrently() async throws {
        let directory = makeTempDirectory()
        try seedRawLists(in: directory, [
            (listID: "EasyList", text: Self.realText, contentHash: "el-hash"),
            (listID: "EasyPrivacy", text: Self.differentText, contentHash: "ep-hash"),
        ])
        let store = FilterListStore(directory: directory)
        // No compiled cache for either list: both must go through a real,
        // concurrent parse.

        let controller = makeController(store: store, listIDs: ["EasyList", "EasyPrivacy"])
        await controller.awaitInitialCacheLoad()

        XCTAssertEqual(
            controller.compiledRuleCount, 1 + 3,
            "both enabled lists must be fully compiled before awaitInitialCacheLoad() returns, not just whichever one finished first"
        )
        controller.blocker.isEnabled = true
        XCTAssertTrue(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "EasyList's rule must be live")
        XCTAssertTrue(controller.blocker.decision(
            forURL: "https://x.doubleclick.net/y", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "EasyPrivacy's rule must be live too, not just whichever list's parse happened to finish first")
    }

    // MARK: FilterListStore's own cache accessors

    func testStoreRoundTripsCompiledCacheBytes() async throws {
        let directory = makeTempDirectory()
        let store = FilterListStore(directory: directory)
        let initial = await store.compiledCacheData(for: "EasyList")
        XCTAssertNil(initial, "must start absent")

        let payload = Data([1, 2, 3, 4, 5])
        await store.storeCompiledCache(payload, for: "EasyList")
        let readBack = await store.compiledCacheData(for: "EasyList")
        XCTAssertEqual(readBack, payload)

        // Overwriting must replace, not append or leave the old bytes readable.
        let replacement = Data([9, 8, 7])
        await store.storeCompiledCache(replacement, for: "EasyList")
        let readBackAfterOverwrite = await store.compiledCacheData(for: "EasyList")
        XCTAssertEqual(readBackAfterOverwrite, replacement)
    }

    func testDiscardRemovesTheCompiledCacheToo() async throws {
        let directory = makeTempDirectory()
        _ = try seedRawList(in: directory, text: Self.realText, contentHash: "h")
        let store = FilterListStore(directory: directory)
        await store.storeCompiledCache(Data([1, 2, 3]), for: "EasyList")
        let beforeDiscard = await store.compiledCacheData(for: "EasyList")
        XCTAssertNotNil(beforeDiscard)

        await store.discard("EasyList")

        let textAfterDiscard = await store.cachedText(for: "EasyList")
        XCTAssertNil(textAfterDiscard, "discard must still remove the raw text")
        let cacheAfterDiscard = await store.compiledCacheData(for: "EasyList")
        XCTAssertNil(cacheAfterDiscard, "discard must remove the compiled cache")
    }
}
