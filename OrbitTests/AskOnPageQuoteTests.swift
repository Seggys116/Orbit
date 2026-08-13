// A model will cheerfully produce a plausible quotation not in the page.
// AssistRuntime.verifiedQuote exists to catch that.

import Foundation
import XCTest

@MainActor
final class AskOnPageQuoteVerificationTests: XCTestCase {

    private let page = """
    The Ransom. Haiti's founders declared independence in 1804. Decades later, \
    under the guns of a French fleet, Haiti agreed to pay reparations to the very \
    people who had enslaved them. We found that Haitians paid about $560 million \
    in today's dollars. Tallying Haiti's losses, he presented a bill: $21,685,135,571.48.
    """

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aQuotationThatIsActuallyInThePageIsKept

    func test_aQuotationThatIsActuallyInThePageIsKept() {
        let quote = "We found that Haitians paid about $560 million in today's dollars."
        XCTAssertEqual(AssistRuntime.verifiedQuote(quote, in: page), quote)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aPlausibleInventionIsRejected

    func test_aPlausibleInventionIsRejected() {
        let invented = "We found that Haitians paid about $600 million in today's dollars."
        XCTAssertNil(
            AssistRuntime.verifiedQuote(invented, in: page),
            "An invented quotation must never reach the panel — it would be rendered as a verbatim quote from the page"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aParaphraseIsRejectedEvenThoughItIsTrue

    func test_aParaphraseIsRejectedEvenThoughItIsTrue() {
        let paraphrase = "Haitians paid roughly 560 million dollars in modern money."
        XCTAssertNil(AssistRuntime.verifiedQuote(paraphrase, in: page))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_curlyQuotesAndDashesDoNotCauseAFalseRejection

    func test_curlyQuotesAndDashesDoNotCauseAFalseRejection() {
        let page = "Haiti\u{2019}s founders \u{2014} in 1804 \u{2014} declared independence."
        let quote = "Haiti's founders - in 1804 - declared independence."
        XCTAssertEqual(AssistRuntime.verifiedQuote(quote, in: page), quote)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_differingWhitespaceDoesNotCauseAFalseRejection

    func test_differingWhitespaceDoesNotCauseAFalseRejection() {
        let page = "We found that\n   Haitians paid   about $560 million."
        let quote = "We found that Haitians paid about $560 million."
        XCTAssertEqual(AssistRuntime.verifiedQuote(quote, in: page), quote)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aFragmentTooShortToBeEvidenceIsRejected

    func test_aFragmentTooShortToBeEvidenceIsRejected() {
        XCTAssertNil(AssistRuntime.verifiedQuote("Haiti", in: page), "A single word matches by accident and proves nothing")
        XCTAssertNil(AssistRuntime.verifiedQuote("The Ransom", in: page))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noQuoteAtAllIsNotAnError

    func test_noQuoteAtAllIsNotAnError() {
        XCTAssertNil(AssistRuntime.verifiedQuote(nil, in: page))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theReturnedStringIsTheOneThatWasChecked

    func test_theReturnedStringIsTheOneThatWasChecked() {
        let quote = "We found that Haitians paid about $560 million in today's dollars."
        let spacedPage = page.replacingOccurrences(of: "We found", with: "We   found")
        XCTAssertEqual(AssistRuntime.verifiedQuote(quote, in: spacedPage), quote)
    }
}

@MainActor
final class AskOnPageReplyParsingTests: XCTestCase {

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_splitsTheLabelledTwoLineReply

    func test_splitsTheLabelledTwoLineReply() {
        let raw = """
        QUOTE: We found that Haitians paid about $560 million in today's dollars.
        ANSWER: So, Haitians paid about $560 million to France and French investors.
        """
        let split = AssistRuntime.splitQuoteAndAnswer(raw)
        XCTAssertEqual(split.quote, "We found that Haitians paid about $560 million in today's dollars.")
        XCTAssertEqual(split.answer, "So, Haitians paid about $560 million to France and French investors.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_NONEMeansThereIsNoQuote

    func test_NONEMeansThereIsNoQuote() {
        let split = AssistRuntime.splitQuoteAndAnswer("QUOTE: NONE\nANSWER: The page does not say.")
        XCTAssertNil(split.quote)
        XCTAssertEqual(split.answer, "The page does not say.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_stripsSurroundingQuotationMarksFromTheQuoteLine

    func test_stripsSurroundingQuotationMarksFromTheQuoteLine() {
        let split = AssistRuntime.splitQuoteAndAnswer("QUOTE: \"a quoted passage here\"\nANSWER: yes")
        XCTAssertEqual(split.quote, "a quoted passage here")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aMultiLineAnswerIsKeptWhole

    func test_aMultiLineAnswerIsKeptWhole() {
        let raw = """
        QUOTE: NONE
        ANSWER: First sentence.
        Second sentence.
        """
        XCTAssertEqual(AssistRuntime.splitQuoteAndAnswer(raw).answer, "First sentence.\nSecond sentence.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anUnlabelledReplyBecomesTheAnswerWithNoQuote

    func test_anUnlabelledReplyBecomesTheAnswerWithNoQuote() {
        let split = AssistRuntime.splitQuoteAndAnswer("The model just answered in prose.")
        XCTAssertNil(split.quote)
        XCTAssertEqual(split.answer, "The model just answered in prose.")
    }
}

@MainActor
final class AskOnPageControllerTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "AskOnPageControllerTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
        AssistSettings.isAskOnPageEnabled = true
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        super.tearDown()
    }

    private func sink(reply: String, page: PageTextExtract?) -> AssistSink {
        AssistSink(generate: { _ in reply }, pageText: { page })
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aSuccessfulAskAppendsAnExchangeAndReturnsToIdle

    func test_aSuccessfulAskAppendsAnExchangeAndReturnsToIdle() async {
        let controller = AskOnPageController()
        let page = PageTextExtract(title: "t", url: "u", text: "Haitians paid about $560 million in today's dollars.", totalCharacters: 52)
        await controller.ask(
            question: "how much did haiti pay to france",
            sink: sink(reply: "QUOTE: Haitians paid about $560 million in today's dollars.\nANSWER: About $560 million.", page: page)
        )

        XCTAssertEqual(controller.exchanges.count, 1)
        XCTAssertEqual(controller.exchanges.first?.question, "how much did haiti pay to france")
        XCTAssertEqual(controller.exchanges.first?.answer, "About $560 million.")
        XCTAssertEqual(controller.exchanges.first?.quote, "Haitians paid about $560 million in today's dollars.")
        XCTAssertEqual(controller.phase, .idle)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anInventedQuoteIsDroppedButTheAnswerIsStillShown

    func test_anInventedQuoteIsDroppedButTheAnswerIsStillShown() async {
        let controller = AskOnPageController()
        let page = PageTextExtract(title: "t", url: "u", text: "Haitians paid about $560 million in today's dollars.", totalCharacters: 52)
        await controller.ask(
            question: "q",
            sink: sink(reply: "QUOTE: Haitians paid about nine hundred million dollars.\nANSWER: About $560 million.", page: page)
        )

        XCTAssertEqual(controller.exchanges.first?.answer, "About $560 million.")
        XCTAssertNil(controller.exchanges.first?.quote, "A quote that is not in the page must not be rendered as one")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_withNoProviderTheRefusalIsShownAndNoExchangeIsRecorded

    func test_withNoProviderTheRefusalIsShownAndNoExchangeIsRecorded() async {
        let controller = AskOnPageController()
        await controller.ask(question: "q", sink: nil)

        XCTAssertTrue(controller.exchanges.isEmpty)
        XCTAssertEqual(controller.phase, .failed(AssistError.notConfigured.localizedDescription))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anIncognitoTabIsRefusedBeforeAnySinkIsConsulted

    func test_anIncognitoTabIsRefusedBeforeAnySinkIsConsulted() async {
        let controller = AskOnPageController()
        var generateCalls = 0
        let watchful = AssistSink(
            generate: { _ in generateCalls += 1; return "should never happen" },
            pageText: { PageTextExtract(title: "", url: "", text: "body", totalCharacters: 4) }
        )

        await controller.ask(question: "q", sink: watchful, incognito: true)

        XCTAssertEqual(generateCalls, 0, "Nothing may leave an incognito window")
        XCTAssertTrue(controller.exchanges.isEmpty)
        XCTAssertEqual(controller.phase, .failed(AssistError.incognito.localizedDescription))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aProviderFailureSurfacesItsMessageRatherThanAnAnswer

    func test_aProviderFailureSurfacesItsMessageRatherThanAnAnswer() async {
        let controller = AskOnPageController()
        let failing = AssistSink(
            generate: { _ in throw AssistError.http(status: 401, body: "invalid key") },
            pageText: { PageTextExtract(title: "", url: "", text: "body", totalCharacters: 4) }
        )
        await controller.ask(question: "q", sink: failing)

        XCTAssertTrue(controller.exchanges.isEmpty)
        guard case .failed(let message) = controller.phase else {
            return XCTFail("Expected a visible failure, got \(controller.phase)")
        }
        XCTAssertTrue(message.contains("401"))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_switchingTabUnderAnOpenPanelClearsTheConversation

    func test_switchingTabUnderAnOpenPanelClearsTheConversation() async {
        let controller = AskOnPageController()
        let tabA = UUID()
        controller.present(tabID: tabA)
        await controller.ask(
            question: "q",
            sink: sink(reply: "QUOTE: NONE\nANSWER: an answer", page: PageTextExtract(title: "", url: "", text: "b", totalCharacters: 1))
        )
        XCTAssertEqual(controller.exchanges.count, 1)

        controller.tabDidChange(to: UUID())

        XCTAssertFalse(controller.isPresented, "An answer about one page must never stay on screen over another")
        XCTAssertTrue(controller.exchanges.isEmpty)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_presentingTheSameTabAgainKeepsTheConversation

    func test_presentingTheSameTabAgainKeepsTheConversation() async {
        let controller = AskOnPageController()
        let tab = UUID()
        controller.present(tabID: tab)
        await controller.ask(
            question: "q",
            sink: sink(reply: "QUOTE: NONE\nANSWER: an answer", page: PageTextExtract(title: "", url: "", text: "b", totalCharacters: 1))
        )
        controller.present(tabID: tab)
        XCTAssertEqual(controller.exchanges.count, 1, "Re-opening the panel on the same tab must not discard the thread")
    }
}
