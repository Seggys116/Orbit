import Foundation
import XCTest

// MARK: - Recorded provider

private final class RecordingProvider: @unchecked Sendable {
    private(set) var requests: [AssistRequest] = []
    private(set) var pageTextCallCount = 0

    var reply: String = "recorded answer"
    var failure: AssistError?
    var page: PageTextExtract?

    var sink: AssistSink {
        AssistSink(
            generate: { [self] request in
                requests.append(request)
                if let failure { throw failure }
                return reply
            },
            pageText: { [self] in
                pageTextCallCount += 1
                return page
            }
        )
    }
}

@MainActor
final class AssistRuntimeAskOnPageTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "AssistRuntimeAskOnPageTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        super.tearDown()
    }

    private func makeExtract(text: String, total: Int) -> PageTextExtract {
        PageTextExtract(title: "Oaxacan Food", url: "https://example.com/oaxaca", text: text, totalCharacters: total)
    }

    func test_askOnPage_withTheFeatureOff_refusesAndNeverCallsTheProvider() async {
        AssistSettings.isAskOnPageEnabled = false
        let provider = RecordingProvider()
        provider.page = makeExtract(text: "page body", total: 9)

        do {
            _ = try await AssistRuntime().askOnPage(question: "what are chapulines?", sink: provider.sink)
            XCTFail("A switched-off feature must refuse")
        } catch {
            XCTAssertEqual(error as? AssistError, .featureDisabled("Ask on Page"))
        }
        XCTAssertTrue(provider.requests.isEmpty, "Nothing may leave the machine for a switched-off feature")
    }

    func test_askOnPage_withNoReadableText_refusesAndNeverCallsTheProvider() async {
        AssistSettings.isAskOnPageEnabled = true
        let provider = RecordingProvider()
        provider.page = nil

        do {
            _ = try await AssistRuntime().askOnPage(question: "anything", sink: provider.sink)
            XCTFail("No page text means no request")
        } catch {
            XCTAssertEqual(error as? AssistError, .noPageText)
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func test_askOnPage_sendsExactlyTheTitleTheURLThePageTextAndTheQuestion() async throws {
        AssistSettings.isAskOnPageEnabled = true
        let provider = RecordingProvider()
        provider.page = makeExtract(text: "Chapulines are toasted grasshoppers.", total: 36)

        _ = try await AssistRuntime().askOnPage(question: "what are chapulines?", sink: provider.sink)

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.user.contains("Oaxacan Food"))
        XCTAssertTrue(request.user.contains("https://example.com/oaxaca"))
        XCTAssertTrue(request.user.contains("Chapulines are toasted grasshoppers."))
        XCTAssertTrue(request.user.contains("what are chapulines?"))
    }

    func test_askOnPage_returnsTheProvidersAnswerVerbatim() async throws {
        AssistSettings.isAskOnPageEnabled = true
        let provider = RecordingProvider()
        provider.page = makeExtract(text: "body", total: 4)
        provider.reply = "They are toasted grasshoppers."

        let answer = try await AssistRuntime().askOnPage(question: "q", sink: provider.sink)
        XCTAssertEqual(answer.text, "They are toasted grasshoppers.")
        XCTAssertEqual(answer.question, "q")
    }

    func test_askOnPage_carriesTheTruncationNoticeOnlyWhenThePageWasActuallyCut() async throws {
        AssistSettings.isAskOnPageEnabled = true
        let provider = RecordingProvider()

        provider.page = makeExtract(text: String(repeating: "a", count: 80), total: 100)
        let truncated = try await AssistRuntime().askOnPage(question: "q", sink: provider.sink)
        XCTAssertEqual(truncated.truncationNotice, "This page was long, so I read the first 80%.")

        provider.page = makeExtract(text: String(repeating: "a", count: 100), total: 100)
        let whole = try await AssistRuntime().askOnPage(question: "q", sink: provider.sink)
        XCTAssertNil(whole.truncationNotice, "A page that fitted must not claim it was cut")
    }

    func test_askOnPage_propagatesAProviderFailureRatherThanReturningAnAnswer() async {
        AssistSettings.isAskOnPageEnabled = true
        let provider = RecordingProvider()
        provider.page = makeExtract(text: "body", total: 4)
        provider.failure = .http(status: 401, body: "bad key")

        do {
            _ = try await AssistRuntime().askOnPage(question: "q", sink: provider.sink)
            XCTFail("A failing provider must not resolve to an answer")
        } catch {
            XCTAssertEqual(error as? AssistError, .http(status: 401, body: "bad key"))
        }
    }
}

@MainActor
final class AssistRuntimeTidyTabTitleTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "AssistRuntimeTidyTitleTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        super.tearDown()
    }

    func test_tidiedTabTitle_withTheFeatureOff_refuses() async {
        AssistSettings.isTidyTabTitlesEnabled = false
        let provider = RecordingProvider()
        do {
            _ = try await AssistRuntime().tidiedTabTitle(
                rawTitle: String(repeating: "long title ", count: 8),
                url: URL(string: "https://example.com")!,
                sink: provider.sink
            )
            XCTFail("A switched-off feature must refuse")
        } catch {
            XCTAssertEqual(error as? AssistError, .featureDisabled("Tidy Tab Titles"))
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func test_tidiedTabTitle_leavesAShortTitleAloneWithoutSpendingARequest() async throws {
        AssistSettings.isTidyTabTitlesEnabled = true
        let provider = RecordingProvider()
        let result = try await AssistRuntime().tidiedTabTitle(
            rawTitle: "Short",
            url: URL(string: "https://example.com")!,
            sink: provider.sink
        )
        XCTAssertNil(result)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func test_tidiedTabTitle_sendsTheTitleAndURLButNotAnyPageBody() async throws {
        AssistSettings.isTidyTabTitlesEnabled = true
        let provider = RecordingProvider()
        provider.page = PageTextExtract(title: "t", url: "u", text: "SECRET PAGE BODY", totalCharacters: 16)
        provider.reply = "Short one"

        _ = try await AssistRuntime().tidiedTabTitle(
            rawTitle: "An Extremely Long Page Title About Something | Example Site",
            url: URL(string: "https://example.com/a")!,
            sink: provider.sink
        )

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.user.contains("An Extremely Long Page Title"))
        XCTAssertTrue(request.user.contains("https://example.com/a"))
        XCTAssertFalse(request.user.contains("SECRET PAGE BODY"), "Tidy Tab Titles must not send the page body")
        XCTAssertEqual(provider.pageTextCallCount, 0, "It must not even read the page")
    }

    func test_acceptTidiedTitle_rejectsAnythingNotShorterThanTheOriginal() {
        let original = "A Reasonably Long Original Title Here"
        XCTAssertNil(AssistRuntime.acceptTidiedTitle(original, original: original))
        XCTAssertNil(AssistRuntime.acceptTidiedTitle(original + " and more", original: original))
        XCTAssertEqual(AssistRuntime.acceptTidiedTitle("Short Title", original: original), "Short Title")
    }

    func test_acceptTidiedTitle_stripsQuotesAndTakesOnlyTheFirstLine() {
        let original = "A Reasonably Long Original Title Here"
        XCTAssertEqual(AssistRuntime.acceptTidiedTitle("\"Quoted\"", original: original), "Quoted")
        XCTAssertEqual(AssistRuntime.acceptTidiedTitle("First\nSecond line", original: original), "First")
    }

    func test_acceptTidiedTitle_rejectsAModelThatAnsweredWithASentence() {
        let original = String(repeating: "x", count: 200)
        let sentence = "Sure, here is a shorter version of that tab title for you"
        XCTAssertNil(
            AssistRuntime.acceptTidiedTitle(sentence, original: original),
            "A nine-word answer is prose, not a tab title"
        )
    }

    func test_acceptTidiedTitle_rejectsAnEmptyAnswer() {
        XCTAssertNil(AssistRuntime.acceptTidiedTitle("   \n ", original: "A long original title here"))
    }
}

@MainActor
final class AssistRuntimeTidyDownloadTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "AssistRuntimeTidyDownloadTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        super.tearDown()
    }

    func test_filenameLooksOpaque_isTrueForTheUUIDArcsOwnScreenshotShows() {
        XCTAssertTrue(AssistRuntime.filenameLooksOpaque("6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf"))
    }

    func test_filenameLooksOpaque_isTrueForGenericAndNumericNames() {
        for name in ["download.pdf", "document (3).docx", "untitled.png", "20240414123055.jpg", "IMG_4021.HEIC"] {
            XCTAssertTrue(AssistRuntime.filenameLooksOpaque(name), "\(name) says nothing about its contents")
        }
    }

    func test_filenameLooksOpaque_isFalseForANameThatAlreadyMeansSomething() {
        for name in ["Q3 Budget Review.xlsx", "AeroMexico Flight Confirmation.pdf", "annual-report-2024.pdf"] {
            XCTAssertFalse(AssistRuntime.filenameLooksOpaque(name), "\(name) is already meaningful and must be left alone")
        }
    }

    func test_tidiedDownloadName_leavesAMeaningfulNameAloneWithoutSpendingARequest() async throws {
        AssistSettings.isTidyDownloadsEnabled = true
        let provider = RecordingProvider()
        let result = try await AssistRuntime().tidiedDownloadName(
            originalFileName: "Q3 Budget Review.xlsx",
            sourceURL: URL(string: "https://example.com/f")!,
            pageTitle: "Finance",
            sink: provider.sink
        )
        XCTAssertNil(result)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func test_tidiedDownloadName_keepsTheOriginalExtension() async throws {
        AssistSettings.isTidyDownloadsEnabled = true
        let provider = RecordingProvider()
        provider.reply = "AeroMexico Flight Confirmation, April 14"

        let result = try await AssistRuntime().tidiedDownloadName(
            originalFileName: "6774fe08-5cd3-4b6e-9623-8cbc791eede6.pdf",
            sourceURL: URL(string: "https://mail.google.com/x")!,
            pageTitle: "Your April 14 AeroMexico flight",
            sink: provider.sink
        )
        XCTAssertEqual(result, "AeroMexico Flight Confirmation, April 14.pdf")
    }

    func test_tidiedDownloadName_neverSendsTheFileItself_onlyItsNameSourceAndPageTitle() async throws {
        AssistSettings.isTidyDownloadsEnabled = true
        let provider = RecordingProvider()
        provider.reply = "Something"
        _ = try await AssistRuntime().tidiedDownloadName(
            originalFileName: "deadbeefdeadbeefdeadbeef.pdf",
            sourceURL: URL(string: "https://mail.google.com/attachment")!,
            pageTitle: "Inbox message",
            sink: provider.sink
        )
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.user.contains("deadbeefdeadbeefdeadbeef"))
        XCTAssertTrue(request.user.contains("https://mail.google.com/attachment"))
        XCTAssertTrue(request.user.contains("Inbox message"))
        XCTAssertEqual(provider.pageTextCallCount, 0)
    }

    func test_acceptTidiedFileName_doesNotDoubleTheExtension() {
        XCTAssertEqual(AssistRuntime.acceptTidiedFileName("Invoice March.pdf", extension: "pdf"), "Invoice March.pdf")
    }

    func test_acceptTidiedFileName_removesPathSeparatorsAndIllegalCharacters() {
        let cleaned = AssistRuntime.acceptTidiedFileName("Report: Q1/Q2 <draft>?", extension: "pdf")
        XCTAssertEqual(cleaned, "Report - Q1-Q2 draft.pdf")
        XCTAssertFalse(cleaned!.contains("/"))
    }

    func test_acceptTidiedFileName_rejectsAnEmptyOrAbsurdlyLongAnswer() {
        XCTAssertNil(AssistRuntime.acceptTidiedFileName("   ", extension: "pdf"))
        XCTAssertNil(AssistRuntime.acceptTidiedFileName(String(repeating: "x", count: 200), extension: "pdf"))
    }
}
