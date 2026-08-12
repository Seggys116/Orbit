import XCTest

final class ContentBlockingCosmeticCacheTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRuleSet(_ text: String, listID: String = "TestList") -> ContentBlockerRuleSet {
        var set = ContentBlockerRuleSet()
        set.add(listText: text, listID: listID)
        return set
    }

    private func makeBlocker(_ text: String) -> ContentBlocker {
        let blocker = ContentBlocker()
        blocker.setRuleSet(makeRuleSet(text))
        blocker.isEnabled = true
        return blocker
    }

    private func freshAnswer(_ text: String, forDocumentURL url: String) -> [String] {
        makeRuleSet(text).cosmeticSelectors(forDocumentURL: url)
    }

    // MARK: - Generic document

    private static let genericRulesText: String = (0..<20).map { "###generic-ad-\($0)" }.joined(separator: "\n")

    func testCachedSelectorsMatchAnIndependentlyComputedAnswerForAGenericDocument() {
        let set = makeRuleSet(Self.genericRulesText)
        let doc = "https://news.example/article"

        let first = set.cosmeticSelectors(forDocumentURL: doc)
        let second = set.cosmeticSelectors(forDocumentURL: doc)
        let third = set.cosmeticSelectors(forDocumentURL: doc)

        let expected = Set((0..<20).map { "#generic-ad-\($0)" })
        XCTAssertEqual(Set(first), expected)
        XCTAssertEqual(first, second, "a cache hit must return exactly what the first (uncached) call returned")
        XCTAssertEqual(first, third)

        let independent = freshAnswer(Self.genericRulesText, forDocumentURL: doc)
        XCTAssertEqual(Set(second), Set(independent),
                       "the cached answer must be byte-identical (as a set) to an independently computed one")
    }

    func testCachedStyleSheetMatchesAnIndependentlyComputedAnswerForAGenericDocument() {
        let blocker = makeBlocker(Self.genericRulesText)
        let doc = "https://news.example/article"

        let first = blocker.cosmeticStyleSheet(forDocumentURL: doc)
        let second = blocker.cosmeticStyleSheet(forDocumentURL: doc)
        XCTAssertEqual(first, second, "a cache hit must return the exact same CSS string as the first call")
        XCTAssertFalse(first.isEmpty)
        for i in 0..<20 {
            XCTAssertTrue(first.contains("#generic-ad-\(i)"), "missing selector #generic-ad-\(i) in cached CSS")
        }

        let independentBlocker = makeBlocker(Self.genericRulesText)
        let independent = independentBlocker.cosmeticStyleSheet(forDocumentURL: doc)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, independent,
                       "an independently built rule set for the same text must produce the identical CSS string")
    }

    // MARK: - Domain-specific document

    private static let domainSpecificRulesText = """
    ###generic-ad
    example.com###example-only-ad
    other.example###other-only-ad
    """

    func testCachedSelectorsMatchAnIndependentlyComputedAnswerForADomainSpecificDocument() {
        let set = makeRuleSet(Self.domainSpecificRulesText)

        let exampleFirst = set.cosmeticSelectors(forHost: "example.com")
        let exampleSecond = set.cosmeticSelectors(forHost: "example.com")
        XCTAssertEqual(Set(exampleFirst), ["#generic-ad", "#example-only-ad"])
        XCTAssertEqual(exampleFirst, exampleSecond, "repeat queries for the same host must agree")

        let otherFirst = set.cosmeticSelectors(forHost: "other.example")
        let otherSecond = set.cosmeticSelectors(forHost: "other.example")
        XCTAssertEqual(Set(otherFirst), ["#generic-ad", "#other-only-ad"])
        XCTAssertEqual(otherFirst, otherSecond)

        XCTAssertEqual(set.cosmeticSelectors(forHost: "example.com"), exampleFirst)

        let independentExample = freshAnswer(Self.domainSpecificRulesText, forDocumentURL: "https://example.com/")
        let independentOther = freshAnswer(Self.domainSpecificRulesText, forDocumentURL: "https://other.example/")
        XCTAssertEqual(Set(exampleSecond), Set(independentExample))
        XCTAssertEqual(Set(otherSecond), Set(independentOther))
    }

    // MARK: - $generichide exemption

    private static let generichideRulesText = """
    ###generic-ad
    youtube.com###yt-only-ad
    @@||www.youtube.com^$generichide
    """

    func testGenerichideExemptionIsRecomputedEveryCallAndNeverPollutesTheGenericCache() {
        let set = makeRuleSet(Self.generichideRulesText)

        let exemptedFirst = set.cosmeticSelectors(forHost: "www.youtube.com")
        XCTAssertEqual(exemptedFirst, ["#yt-only-ad"],
                       "generichide must withhold the generic selector and keep the host-scoped one")

        let ordinary = set.cosmeticSelectors(forHost: "elsewhere.example")
        XCTAssertEqual(Set(ordinary), ["#generic-ad"])

        let exemptedSecond = set.cosmeticSelectors(forHost: "www.youtube.com")
        XCTAssertEqual(exemptedSecond, ["#yt-only-ad"])

        XCTAssertEqual(Set(set.cosmeticSelectors(forHost: "elsewhere.example")), Set(ordinary))

        let independentExempted = freshAnswer(
            Self.generichideRulesText, forDocumentURL: "https://www.youtube.com/watch"
        )
        XCTAssertEqual(Set(exemptedSecond), Set(independentExempted))
    }

    func testElemhideAndSpecifichideAreAlsoRecomputedEveryCallRatherThanCached() {
        let set = makeRuleSet("""
        ###generic-ad
        example.com###local-ad
        example.org###local-ad
        @@||example.com^$elemhide
        @@||example.org^$specifichide
        """)

        XCTAssertEqual(set.cosmeticSelectors(forHost: "example.com"), [])
        XCTAssertEqual(set.cosmeticSelectors(forHost: "example.com"), [], "repeat call must stay empty")

        XCTAssertEqual(set.cosmeticSelectors(forHost: "example.org"), ["#generic-ad"])
        XCTAssertEqual(set.cosmeticSelectors(forHost: "example.org"), ["#generic-ad"], "repeat call must stay stable")

        XCTAssertEqual(Set(set.cosmeticSelectors(forHost: "elsewhere.example")), ["#generic-ad"])
    }

    // MARK: - Invalidation on rebuild

    func testRuleSetRebuildInvalidatesTheCosmeticCacheRatherThanLeakingStaleSelectors() {
        let blocker = ContentBlocker()
        blocker.isEnabled = true

        let ruleSetV1 = makeRuleSet("###ad-v1")
        blocker.setRuleSet(ruleSetV1)
        let host = "example.com"

        let cssV1 = blocker.cosmeticStyleSheet(forHost: host)
        XCTAssertTrue(cssV1.contains("#ad-v1"))
        XCTAssertFalse(cssV1.contains("#ad-v2"))
        _ = blocker.cosmeticStyleSheet(forHost: host)

        let ruleSetV2 = makeRuleSet("###ad-v2")
        blocker.setRuleSet(ruleSetV2)

        let cssV2 = blocker.cosmeticStyleSheet(forHost: host)
        XCTAssertTrue(cssV2.contains("#ad-v2"), "the rebuilt rule set's own selector must appear")
        XCTAssertFalse(cssV2.contains("#ad-v1"),
                       "a selector from the DISCARDED rule set must never survive a rebuild via a stale cache entry")

        XCTAssertEqual(blocker.cosmeticStyleSheet(forHost: host), cssV2)
    }

    func testTwoIndependentRuleSetInstancesNeverShareACosmeticCacheEntry() {
        let setA = makeRuleSet("###ad-a")
        let setB = makeRuleSet("###ad-b")
        let host = "shared-host.example"

        XCTAssertEqual(setA.cosmeticSelectors(forHost: host), ["#ad-a"])
        XCTAssertEqual(setB.cosmeticSelectors(forHost: host), ["#ad-b"])
        XCTAssertEqual(setA.cosmeticSelectors(forHost: host), ["#ad-a"])
    }

    // MARK: - Concurrency

    func testConcurrentReadsAcrossMultipleHostsAllReturnCorrectAnswers() {
        let set = makeRuleSet("""
        ###generic-ad
        example.com###example-only-ad
        other.example###other-only-ad
        @@||exempt.example^$generichide
        """)

        let hosts: [(host: String, expected: Set<String>)] = [
            ("example.com", ["#generic-ad", "#example-only-ad"]),
            ("other.example", ["#generic-ad", "#other-only-ad"]),
            ("plain.example", ["#generic-ad"]),
            ("exempt.example", []),
        ]

        let iterationCount = 400
        let mismatches = ManagedAtomicBox(0)
        DispatchQueue.concurrentPerform(iterations: iterationCount) { index in
            let entry = hosts[index % hosts.count]
            let actual = Set(set.cosmeticSelectors(forHost: entry.host))
            if actual != entry.expected {
                mismatches.increment()
            }
        }
        XCTAssertEqual(mismatches.value, 0, "every concurrent read must return the answer its host's rules specify")
    }
}

private final class ManagedAtomicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int

    init(_ value: Int) { storage = value }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
