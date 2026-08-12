import Foundation
import XCTest

// MARK: - Test doubles

private actor LinkPreviewFetchGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RecordedFetcher: @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var requestedURLs: [URL] = []
    var result: Result<LinkPreviewFetcher.LinkPreviewPageData, Error>
    var gate: LinkPreviewFetchGate?

    init(result: Result<LinkPreviewFetcher.LinkPreviewPageData, Error>) {
        self.result = result
    }

    var closure: @Sendable (URL) async throws -> LinkPreviewFetcher.LinkPreviewPageData {
        { [self] url in
            callCount += 1
            requestedURLs.append(url)
            if let gate { await gate.wait() }
            return try result.get()
        }
    }
}

private final class RecordedLinkSink: @unchecked Sendable {
    private(set) var generateCallCount = 0
    var reply = "SUMMARY: A recorded summary.\nITEM: place | Visit Somewhere | A short description sentence."
    var failure: AssistError?

    var sink: AssistSink {
        AssistSink(
            generate: { [self] _ in
                generateCallCount += 1
                if let failure { throw failure }
                return reply
            },
            pageText: { nil }
        )
    }
}

@MainActor
final class LinkPreviewControllerTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "LinkPreviewControllerTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
        AssistSettings.isFiveSecondPreviewsEnabled = true
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        super.tearDown()
    }

    private func makePageData(url: URL, text: String = "Oaxaca is known for Monte Alban and its markets.") -> LinkPreviewFetcher.LinkPreviewPageData {
        LinkPreviewFetcher.LinkPreviewPageData(
            sourceURL: url,
            imageURL: nil,
            title: "A Page",
            description: nil,
            pageText: PageTextExtract(title: "A Page", url: url.absoluteString, text: text, totalCharacters: text.count)
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Feature disabled (#8)

    func test_hoverChanged_withTheFeatureDisabled_neverCallsFetchOrTheSink() async {
        AssistSettings.isFiveSecondPreviewsEnabled = false
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let url = URL(string: "https://example.com/a")!
        let fetcher = RecordedFetcher(result: .success(makePageData(url: url)))
        let sink = RecordedLinkSink()

        controller.hoverChanged(
            url: url, shiftDown: true, at: .zero,
            isSessionPersistent: true,
            fetch: fetcher.closure, sink: sink.sink
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(fetcher.callCount, 0, "A switched-off feature must never fetch the hovered page")
        XCTAssertEqual(sink.generateCallCount, 0, "A switched-off feature must never call the provider")
    }

    // MARK: - Incognito (#7)

    func test_hoverChanged_withANonPersistentSession_neverCallsFetchOrTheSink() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let url = URL(string: "https://example.com/a")!
        let fetcher = RecordedFetcher(result: .success(makePageData(url: url)))
        let sink = RecordedLinkSink()

        controller.hoverChanged(
            url: url, shiftDown: true, at: .zero,
            isSessionPersistent: false,
            fetch: fetcher.closure, sink: sink.sink
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(fetcher.callCount, 0, "Nothing may leave an Incognito window — the fetch itself must never happen")
        XCTAssertEqual(sink.generateCallCount, 0, "Nothing may leave an Incognito window — the model call must never happen")
    }

    func test_hoverChanged_withANonPersistentSession_refusesEvenWithNoSinkAtAll() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let fetcher = RecordedFetcher(result: .success(makePageData(url: URL(string: "https://example.com/a")!)))

        controller.hoverChanged(
            url: URL(string: "https://example.com/a")!, shiftDown: true, at: .zero,
            isSessionPersistent: false,
            fetch: fetcher.closure, sink: nil
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(fetcher.callCount, 0)
    }

    // MARK: - Non-http(s) scheme

    func test_hoverChanged_refusesANonHTTPScheme() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let fetcher = RecordedFetcher(result: .success(makePageData(url: URL(string: "orbit://new-tab")!)))

        controller.hoverChanged(
            url: URL(string: "orbit://new-tab")!, shiftDown: true, at: .zero,
            isSessionPersistent: true,
            fetch: fetcher.closure, sink: RecordedLinkSink().sink
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(fetcher.callCount, 0)
    }

    // MARK: - Shift released mid-flight (#5)

    func test_shiftReleasedWhileAFetchIsInFlight_noCardIsEverShown() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let url = URL(string: "https://example.com/a")!
        let gate = LinkPreviewFetchGate()
        let fetcher = RecordedFetcher(result: .success(makePageData(url: url)))
        fetcher.gate = gate
        let sink = RecordedLinkSink()

        controller.hoverChanged(url: url, shiftDown: true, at: .zero, isSessionPersistent: true, fetch: fetcher.closure, sink: sink.sink)
        await waitUntil { fetcher.callCount >= 1 }
        XCTAssertEqual(controller.phase, .loading, "Test precondition: the fetch is genuinely in flight")

        controller.hoverChanged(url: url, shiftDown: false, at: .zero, isSessionPersistent: true, fetch: fetcher.closure, sink: sink.sink)
        XCTAssertEqual(controller.phase, .idle, "Releasing Shift must return to idle immediately")

        await gate.open()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.phase, .idle, "A fetch abandoned by releasing Shift must never land a card afterward")
        XCTAssertEqual(sink.generateCallCount, 0, "The abandoned fetch resolving must not go on to call the model either")
    }

    // MARK: - Hover moved to a different URL while in flight (#6)

    func test_hoverMovedToADifferentURLWhileTheFirstIsInFlight_theFirstsLateResultNeverBecomesTheVisibleCard() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0

        let urlA = URL(string: "https://example.com/a")!
        let urlB = URL(string: "https://example.com/b")!

        let gateA = LinkPreviewFetchGate()
        let fetcherA = RecordedFetcher(result: .success(makePageData(url: urlA, text: "Page A talks about Monte Alban and Oaxaca City.")))
        fetcherA.gate = gateA
        let sinkA = RecordedLinkSink()
        sinkA.reply = "SUMMARY: Summary for A.\nITEM: place | Visit Monte Alban | A ruin near Oaxaca City."

        let fetcherB = RecordedFetcher(result: .success(makePageData(url: urlB, text: "Page B talks about Mezcal tasting tours.")))
        let sinkB = RecordedLinkSink()
        sinkB.reply = "SUMMARY: Summary for B.\nITEM: food | Taste Mezcal | A guided tasting tour."

        controller.hoverChanged(url: urlA, shiftDown: true, at: .zero, isSessionPersistent: true, fetch: fetcherA.closure, sink: sinkA.sink)
        await waitUntil { fetcherA.callCount >= 1 }
        XCTAssertEqual(controller.phase, .loading, "Test precondition: A's fetch is genuinely in flight")

        controller.hoverChanged(url: urlB, shiftDown: true, at: .zero, isSessionPersistent: true, fetch: fetcherB.closure, sink: sinkB.sink)

        await waitUntil(timeout: 3) {
            if case .ready = controller.phase { return true }
            return false
        }
        guard case .ready(let readyPreview) = controller.phase else {
            return XCTFail("B should have resolved to a ready preview; phase is \(controller.phase)")
        }
        XCTAssertEqual(readyPreview.summary, "Summary for B.")

        await gateA.open()
        try? await Task.sleep(nanoseconds: 80_000_000)

        guard case .ready(let stillPreview) = controller.phase else {
            return XCTFail("Phase must still be .ready after A resolves late; got \(controller.phase)")
        }
        XCTAssertEqual(stillPreview.summary, "Summary for B.", "A's late result overwrote B's — the exact stale-card bug this test exists to catch")
        XCTAssertEqual(sinkA.generateCallCount, 0, "A's fetch resolving after being abandoned must not go on to call the model")
    }

    // MARK: - Same URL re-hovered while already showing

    func test_reHoveringTheSameURLWhileAlreadyShowing_doesNotRefetch() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let url = URL(string: "https://example.com/a")!
        let fetcher = RecordedFetcher(result: .success(makePageData(url: url)))
        let sink = RecordedLinkSink()

        controller.hoverChanged(url: url, shiftDown: true, at: .zero, isSessionPersistent: true, fetch: fetcher.closure, sink: sink.sink)
        await waitUntil(timeout: 3) {
            if case .ready = controller.phase { return true }
            return false
        }
        XCTAssertEqual(fetcher.callCount, 1)

        controller.hoverChanged(url: url, shiftDown: true, at: CGPoint(x: 5, y: 5), isSessionPersistent: true, fetch: fetcher.closure, sink: sink.sink)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fetcher.callCount, 1, "The same URL, already showing, must not spend a second fetch")
        XCTAssertEqual(sink.generateCallCount, 1)
    }

    // MARK: - The happy path, for completeness

    func test_hoverChanged_aFullSuccessfulRunReachesReadyWithTheParsedPreview() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let url = URL(string: "https://example.com/oaxaca")!
        let fetcher = RecordedFetcher(result: .success(makePageData(url: url, text: "Monte Alban is an archaeological site near Oaxaca City.")))
        let sink = RecordedLinkSink()
        sink.reply = "SUMMARY: A guide to Oaxaca.\nITEM: place | Visit Monte Alban | An archaeological site."

        controller.hoverChanged(url: url, shiftDown: true, at: CGPoint(x: 40, y: 60), isSessionPersistent: true, fetch: fetcher.closure, sink: sink.sink)
        await waitUntil(timeout: 3) {
            if case .ready = controller.phase { return true }
            return false
        }

        guard case .ready(let preview) = controller.phase else {
            return XCTFail("Expected .ready, got \(controller.phase)")
        }
        XCTAssertEqual(preview.summary, "A guide to Oaxaca.")
        XCTAssertEqual(preview.items.first?.lead, "Visit Monte Alban")
        XCTAssertEqual(controller.anchor, CGPoint(x: 40, y: 60))
        XCTAssertEqual(controller.previewedURL, url)
    }
}
