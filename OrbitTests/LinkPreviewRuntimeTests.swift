import Foundation
import XCTest

// MARK: - Recorded provider

private final class RecordedLinkPreviewSink: @unchecked Sendable {
    private(set) var requests: [AssistRequest] = []
    var reply = "SUMMARY: A default reply.\nITEM: place | Visit Somewhere | A short description."
    var failure: AssistError?

    var sink: AssistSink {
        AssistSink(
            generate: { [self] request in
                requests.append(request)
                if let failure { throw failure }
                return reply
            },
            pageText: { nil }
        )
    }
}

@MainActor
// Whole suite excluded on GitHub-hosted runners: needs a real running app, not a headless VM.
final class LinkPreviewRuntimeTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "LinkPreviewRuntimeTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
    }

    override func tearDown() {
        AssistSettings.defaults = OrbitDefaults.standard
        suite = nil
        super.tearDown()
    }

    private func pageData(
        text: String = "Oaxaca is a city famous for Monte Alban and Mezcal tours.",
        total: Int? = nil,
        imageURL: URL? = URL(string: "https://example.com/hero.jpg"),
        title: String? = "Oaxaca Travel Guide"
    ) -> LinkPreviewFetcher.LinkPreviewPageData {
        LinkPreviewFetcher.LinkPreviewPageData(
            sourceURL: URL(string: "https://ourescapeclause.com/oaxaca")!,
            imageURL: imageURL,
            title: title,
            description: nil,
            pageText: PageTextExtract(title: title ?? "", url: "https://ourescapeclause.com/oaxaca", text: text, totalCharacters: total ?? text.count)
        )
    }

    // MARK: Refusals

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_linkPreview_withTheFeatureOff_refusesAndNeverCallsTheProvider

    func test_linkPreview_withTheFeatureOff_refusesAndNeverCallsTheProvider() async {
        AssistSettings.isFiveSecondPreviewsEnabled = false
        let provider = RecordedLinkPreviewSink()

        do {
            _ = try await AssistRuntime().linkPreview(sourceURL: pageData().sourceURL, pageData: pageData(), sink: provider.sink)
            XCTFail("A switched-off feature must refuse")
        } catch {
            XCTAssertEqual(error as? AssistError, .featureDisabled("5-Second Previews"))
        }
        XCTAssertTrue(provider.requests.isEmpty, "Nothing may leave the machine for a switched-off feature")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_linkPreview_withNoReadablePageText_throwsNoPageTextRatherThanSummarisingTheURLAlone

    func test_linkPreview_withNoReadablePageText_throwsNoPageTextRatherThanSummarisingTheURLAlone() async {
        AssistSettings.isFiveSecondPreviewsEnabled = true
        let provider = RecordedLinkPreviewSink()
        let empty = pageData(text: "   ")

        do {
            _ = try await AssistRuntime().linkPreview(sourceURL: empty.sourceURL, pageData: empty, sink: provider.sink)
            XCTFail("No page text means no request")
        } catch {
            XCTAssertEqual(error as? AssistError, .noPageText)
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_linkPreview_anEmptySummaryFailsTheWholePreview_ratherThanRenderingABlankCard

    func test_linkPreview_anEmptySummaryFailsTheWholePreview_ratherThanRenderingABlankCard() async {
        AssistSettings.isFiveSecondPreviewsEnabled = true
        let provider = RecordedLinkPreviewSink()
        provider.reply = "ITEM: place | Visit Somewhere | A short description."

        do {
            let data = pageData()
            _ = try await AssistRuntime().linkPreview(sourceURL: data.sourceURL, pageData: data, sink: provider.sink)
            XCTFail("A reply with no SUMMARY: line must not become a preview")
        } catch {
            XCTAssertEqual(error as? AssistError, .emptyCompletion)
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_linkPreview_propagatesAProviderFailure

    func test_linkPreview_propagatesAProviderFailure() async {
        AssistSettings.isFiveSecondPreviewsEnabled = true
        let provider = RecordedLinkPreviewSink()
        provider.failure = .http(status: 500, body: "boom")

        do {
            let data = pageData()
            _ = try await AssistRuntime().linkPreview(sourceURL: data.sourceURL, pageData: data, sink: provider.sink)
            XCTFail("A failing provider must not resolve to a preview")
        } catch {
            XCTAssertEqual(error as? AssistError, .http(status: 500, body: "boom"))
        }
    }

    // MARK: What it sends

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_linkPreview_sendsThePageTitleURLAndText_neverTheImageURL

    func test_linkPreview_sendsThePageTitleURLAndText_neverTheImageURL() async throws {
        AssistSettings.isFiveSecondPreviewsEnabled = true
        let provider = RecordedLinkPreviewSink()
        let data = pageData(text: "Monte Alban is an ancient Zapotec archaeological site.", imageURL: URL(string: "https://example.com/should-not-be-sent.jpg"))

        _ = try await AssistRuntime().linkPreview(sourceURL: data.sourceURL, pageData: data, sink: provider.sink)

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.user.contains("Oaxaca Travel Guide"))
        XCTAssertTrue(request.user.contains("https://ourescapeclause.com/oaxaca"))
        XCTAssertTrue(request.user.contains("Monte Alban is an ancient Zapotec archaeological site."))
        XCTAssertFalse(
            request.user.contains("should-not-be-sent.jpg"),
            "The photo URL is placed on the card directly from the fetch — it must never be described to the model"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_linkPreview_carriesThePageDatasTruncationNoticeOntoTheCard

    func test_linkPreview_carriesThePageDatasTruncationNoticeOntoTheCard() async throws {
        AssistSettings.isFiveSecondPreviewsEnabled = true
        let provider = RecordedLinkPreviewSink()
        let cutText = String(repeating: "a", count: 80)
        let data = pageData(text: cutText, total: 100)

        let preview = try await AssistRuntime().linkPreview(sourceURL: data.sourceURL, pageData: data, sink: provider.sink)
        XCTAssertEqual(preview.truncationNotice, "This page was long, so I read the first 80%.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_linkPreview_carriesTheFetchedImageURLThroughUntouched

    func test_linkPreview_carriesTheFetchedImageURLThroughUntouched() async throws {
        AssistSettings.isFiveSecondPreviewsEnabled = true
        let provider = RecordedLinkPreviewSink()
        let imageURL = URL(string: "https://example.com/oaxaca-hero.jpg")!
        let data = pageData(imageURL: imageURL)

        let preview = try await AssistRuntime().linkPreview(sourceURL: data.sourceURL, pageData: data, sink: provider.sink)
        XCTAssertEqual(preview.imageURL, imageURL)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_linkPreview_usesTheSourceURLsHostAsSourceHost

    func test_linkPreview_usesTheSourceURLsHostAsSourceHost() async throws {
        AssistSettings.isFiveSecondPreviewsEnabled = true
        let provider = RecordedLinkPreviewSink()
        let data = pageData()

        let preview = try await AssistRuntime().linkPreview(sourceURL: data.sourceURL, pageData: data, sink: provider.sink)
        XCTAssertEqual(preview.sourceHost, "ourescapeclause.com")
    }
}

// MARK: - Reply parsing

final class LinkPreviewReplyParsingTests: XCTestCase {

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parseLinkPreviewReply_readsTheSummaryAndEveryItem

    func test_parseLinkPreviewReply_readsTheSummaryAndEveryItem() {
        let raw = """
        SUMMARY: Delicious food, colorful streets, ruins, and festivals make Oaxaca a must-visit destination.
        ITEM: place | Visit Monte Alban | Explore the abandoned city of Monte Alban.
        ITEM: travel | Wander through Oaxaca City | Stroll through the center and the Zocalo.
        ITEM: food | Taste Mezcal | Take a Mezcal tour and try different varieties.
        """
        let parsed = AssistRuntime.parseLinkPreviewReply(raw)
        XCTAssertEqual(parsed.summary, "Delicious food, colorful streets, ruins, and festivals make Oaxaca a must-visit destination.")
        XCTAssertEqual(parsed.items.count, 3)
        XCTAssertEqual(parsed.items[0].lead, "Visit Monte Alban")
        XCTAssertEqual(parsed.items[0].detail, "Explore the abandoned city of Monte Alban.")
        XCTAssertEqual(parsed.items[0].symbolName, AssistRuntime.linkPreviewGlyphs["place"])
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parseLinkPreviewReply_toleratesNoItemLinesAtAll

    func test_parseLinkPreviewReply_toleratesNoItemLinesAtAll() {
        let parsed = AssistRuntime.parseLinkPreviewReply("SUMMARY: Just a summary, nothing else.")
        XCTAssertEqual(parsed.summary, "Just a summary, nothing else.")
        XCTAssertTrue(parsed.items.isEmpty)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parseLinkPreviewReply_dropsAnItemLineMissingAField

    func test_parseLinkPreviewReply_dropsAnItemLineMissingAField() {
        let raw = """
        SUMMARY: A page.
        ITEM: place | Visit Somewhere
        ITEM: food | Taste Something | A real detail sentence.
        """
        let parsed = AssistRuntime.parseLinkPreviewReply(raw)
        XCTAssertEqual(parsed.items.count, 1, "A two-field ITEM line is malformed and must be dropped, not rendered with a blank field")
        XCTAssertEqual(parsed.items[0].lead, "Taste Something")
    }

    // MARK: Glyph allow-list

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parseLinkPreviewReply_mapsARecognisedGlyphKeyToItsSFSymbol

    func test_parseLinkPreviewReply_mapsARecognisedGlyphKeyToItsSFSymbol() {
        let parsed = AssistRuntime.parseLinkPreviewReply("SUMMARY: s\nITEM: money | Budget Tip | Bring cash.")
        XCTAssertEqual(parsed.items.first?.symbolName, "dollarsign.circle")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parseLinkPreviewReply_anUnrecognisedGlyphKeyFallsBackToTheNeutralGlyph_neverReachesSwiftUIAsRawText

    func test_parseLinkPreviewReply_anUnrecognisedGlyphKeyFallsBackToTheNeutralGlyph_neverReachesSwiftUIAsRawText() {
        let raw = "SUMMARY: s\nITEM: chart.bar.xaxis | Suspicious Lead | A detail sentence right here."
        let parsed = AssistRuntime.parseLinkPreviewReply(raw)
        XCTAssertEqual(
            parsed.items.first?.symbolName,
            AssistRuntime.linkPreviewNeutralGlyph,
            "A glyph key outside the fixed allow-list must never become the SF Symbol name handed to Image(systemName:)"
        )
        XCTAssertFalse(AssistRuntime.linkPreviewGlyphs.values.contains("chart.bar.xaxis"))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parseLinkPreviewReply_anEmptyOrGarbledGlyphKeyAlsoFallsBackToNeutral

    func test_parseLinkPreviewReply_anEmptyOrGarbledGlyphKeyAlsoFallsBackToNeutral() {
        let raw = "SUMMARY: s\nITEM:  | Lead Phrase | A detail sentence right here."
        let parsed = AssistRuntime.parseLinkPreviewReply(raw)
        XCTAssertEqual(parsed.items.first?.symbolName, AssistRuntime.linkPreviewNeutralGlyph)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_everyAllowListedGlyphIsGrey_lineArt_shortList

    func test_everyAllowListedGlyphIsGrey_lineArt_shortList() {
        XCTAssertTrue((8...12).contains(AssistRuntime.linkPreviewGlyphs.count))
        for (key, symbol) in AssistRuntime.linkPreviewGlyphs {
            XCTAssertFalse(key.isEmpty)
            XCTAssertFalse(symbol.isEmpty)
            XCTAssertFalse(symbol.contains(" "), "\(symbol) is not a plausible SF Symbol name")
        }
    }
}

// MARK: - The honesty check

final class LinkPreviewGroundedItemsTests: XCTestCase {

    private let pageText = """
    Oaxaca is famous for its markets and its food scene. Visitors often start at Monte Alban, \
    an ancient archaeological site above the city, then wander through the historic Zocalo in \
    Oaxaca City itself. Many tours include a stop to taste Mezcal at a family-run palenque.
    """

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_groundedItems_keepsAnItemWhoseLeadPhraseIsOnThePage

    func test_groundedItems_keepsAnItemWhoseLeadPhraseIsOnThePage() {
        let items = [AssistRuntime.LinkPreview.Item(symbolName: "star", lead: "Visit Monte Alban", detail: "An ancient site.")]
        let grounded = AssistRuntime.groundedItems(items, in: pageText)
        XCTAssertEqual(grounded, items, "Monte Alban is genuinely on the page and must be kept")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_groundedItems_dropsAnItemWhoseLeadPhraseIsNotOnThePage

    func test_groundedItems_dropsAnItemWhoseLeadPhraseIsNotOnThePage() {
        let items = [AssistRuntime.LinkPreview.Item(symbolName: "place", lead: "Explore Hierve el Agua", detail: "Petrified waterfalls nearby.")]
        let grounded = AssistRuntime.groundedItems(items, in: pageText)
        XCTAssertTrue(
            grounded.isEmpty,
            "An invented location that never appears in the fetched page text must never reach the card"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_groundedItems_keepsGroundedAndDropsUngroundedFromTheSameBatch

    func test_groundedItems_keepsGroundedAndDropsUngroundedFromTheSameBatch() {
        let grounded = AssistRuntime.LinkPreview.Item(symbolName: "food", lead: "Taste Mezcal", detail: "At a family-run palenque.")
        let invented = AssistRuntime.LinkPreview.Item(symbolName: "place", lead: "Climb Pyramid of the Sun", detail: "A famous nearby ruin.")
        let result = AssistRuntime.groundedItems([grounded, invented], in: pageText)
        XCTAssertEqual(result, [grounded])
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_groundedItems_aLeadPhraseOfOnlyShortOrStopWordsCannotGroundItself

    func test_groundedItems_aLeadPhraseOfOnlyShortOrStopWordsCannotGroundItself() {
        let items = [AssistRuntime.LinkPreview.Item(symbolName: "star", lead: "See This Here", detail: "Something or other.")]
        XCTAssertTrue(AssistRuntime.groundedItems(items, in: pageText).isEmpty)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_groundedItems_ignoresCaseAndCurlyPunctuationDifferences

    func test_groundedItems_ignoresCaseAndCurlyPunctuationDifferences() {
        let curlyPage = "The chef\u{2019}s tour visits MONTE ALBAN before lunch."
        let items = [AssistRuntime.LinkPreview.Item(symbolName: "food", lead: "Visit Monte Alban", detail: "A guided tour.")]
        XCTAssertEqual(AssistRuntime.groundedItems(items, in: curlyPage), items)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_groundedItems_dropsEveryItemWhenNoneAreGrounded_leavingTheSummaryToStandAlone

    func test_groundedItems_dropsEveryItemWhenNoneAreGrounded_leavingTheSummaryToStandAlone() {
        let items = [
            AssistRuntime.LinkPreview.Item(symbolName: "place", lead: "Visit Chichen Itza", detail: "A different city."),
            AssistRuntime.LinkPreview.Item(symbolName: "food", lead: "Try Ceviche Tacos", detail: "Not mentioned here."),
        ]
        XCTAssertTrue(AssistRuntime.groundedItems(items, in: pageText).isEmpty)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_groundedItems_withEmptyPageTextGroundsNothing

    func test_groundedItems_withEmptyPageTextGroundsNothing() {
        let items = [AssistRuntime.LinkPreview.Item(symbolName: "place", lead: "Visit Monte Alban", detail: "d")]
        XCTAssertTrue(AssistRuntime.groundedItems(items, in: "").isEmpty)
    }
}
