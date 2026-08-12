import XCTest

final class ContentBlockingLowercaseFusionTests: XCTestCase {

    private func assertMatchesOriginal(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
        let fused = ContentBlockerRuleSet.lowercasedUTF8Bytes(of: string)
        let original = Array(string.lowercased().utf8)
        XCTAssertEqual(fused, original,
                       "lowercasedUTF8Bytes(of: \(string.debugDescription)) diverged from Array(string.lowercased().utf8)",
                       file: file, line: line)
    }

    func testFusedLowercaseMatchesTheOriginalTwoAllocationComputationForOrdinaryASCIIURLs() {
        assertMatchesOriginal("https://Ib.AdNxs.COM/UT/v3/Prebid?ID=ABC123")
        assertMatchesOriginal("https://www.EXAMPLE.com/Some/Path?Query=Value&Other=THING")
        assertMatchesOriginal("")
        assertMatchesOriginal("HTTPS://ALL-CAPS.EXAMPLE/PATH")
        assertMatchesOriginal("https://already-lowercase.example/path")
    }

    func testFusedLowercaseLeavesNonLetterASCIIBytesUntouched() {
        assertMatchesOriginal("https://example.com:8443/path;param=1?q=a+b&r=c%20d#frag")
        assertMatchesOriginal("[Z-brackets-and-backtick-`-adjacent-to-the-letter-range]")
    }

    func testFusedLowercaseFallsBackExactlyForNonASCIIInput() {
        assertMatchesOriginal("https://example.com/İstanbul/AdBanner")
        assertMatchesOriginal("https://müller-tracker.example/AD")
        assertMatchesOriginal("https://example.com/Ω-metrics/Ad")
        assertMatchesOriginal("https://example.com/AAAA/İ/BBBB/AD")
    }

    func testDecisionStillMatchesMixedCaseAndNonASCIIURLsAfterTheFusion() {
        var set = ContentBlockerRuleSet()
        set.add(listText: "||adnxs.com^\n||müller-tracker.example^\n", listID: "L")

        XCTAssertTrue(set.decision(
            forURL: "https://IB.ADNXS.COM/ut/v3/prebid",
            documentURL: "https://a.example/",
            resourceType: .script
        ).isBlocked, "an upper-case host must still match a lower-case rule")

        XCTAssertTrue(set.decision(
            forURL: "https://MÜLLER-tracker.example/ad",
            documentURL: "https://a.example/",
            resourceType: .script
        ).isBlocked, "a mixed-case NON-ASCII host must still match via the fallback path")
    }
}
