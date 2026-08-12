import AppKit
import XCTest
@testable import Orbit

@MainActor
final class PageTopBandColorTests: XCTestCase {

    // MARK: - The decoder's contract

    func test_aPayloadWithNoDocumentKeyDecodesToNoDocumentColour() throws {
        let legacy = PageThemeColorScript.decode(["color": "#ff6600", "ready": true])
        let decoded = try XCTUnwrap(legacy)
        XCTAssertNotNil(decoded.color, "The chrome colour must still decode exactly as it did.")
        XCTAssertNil(decoded.documentColor, "An absent `document` key is 'unknown', which routes the consumer to its fallback.")
        XCTAssertTrue(decoded.isReady)
    }

    // MARK: - The constants the rule is built from

    func test_theBandConstantsKeepTheGuaranteesTheseTestsAssert() {
        XCTAssertGreaterThanOrEqual(
            PageThemeColorScript.bandMinimumDistinctRows, 2,
            "A colour that need only appear in one row can be a one-pixel line."
        )
        XCTAssertGreaterThan(
            PageThemeColorScript.bandSampleRows.count, PageThemeColorScript.bandMinimumDistinctRows,
            "There must be more rows than the floor requires, or every colour that clears the floor clears it trivially."
        )
        XCTAssertGreaterThan(
            PageThemeColorScript.bandDominance, 0.5,
            "Dominance below a majority would let the second-most-common colour win."
        )
        XCTAssertTrue(
            PageThemeColorScript.source.contains("__orbitTopBandColor"),
            "The shipping probe must actually call the band rule."
        )
        XCTAssertTrue(
            PageThemeColorScript.source.contains("elementsFromPoint"),
            "The band is read from the DOM. If this becomes a capture again, it brings the Screen Recording prompt back with it."
        )
        XCTAssertFalse(
            PageThemeColorScript.source.contains("capturePreview"),
            "Nothing here may reach for a screenshot."
        )
    }

    func test_theLiveObserverReReadsOnScroll() {
        let source = PageColorObserverScript.source(postExpression: "post(payload)")
        XCTAssertTrue(
            source.contains("'scroll'"),
            "The observer must subscribe to scroll, or the painted band goes stale the moment the page moves."
        )
        XCTAssertTrue(
            source.contains("passive: true"),
            "A scroll listener that is not passive can delay scrolling itself."
        )
        XCTAssertTrue(
            source.contains("capture: true"),
            "scroll does not bubble: without capture, a page that scrolls an inner container never reports."
        )
    }
}
