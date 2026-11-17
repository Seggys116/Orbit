import XCTest
@testable import Orbit

/// The network log is always kept, but the table, counts and summary are only projected while the Network panel is on screen.
@MainActor
final class NetworkModelIdleTests: XCTestCase {

    private func makeModel(presented: Bool) -> (OrbitNetworkModel, PresentationFlag) {
        let flag = PresentationFlag(presented)
        let model = OrbitNetworkModel()
        model.presentationProbe = { flag.value }
        return (model, flag)
    }

    private final class PresentationFlag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private func record(_ id: String, _ url: String, start: Double? = nil) -> NetRecord {
        var rec = NetRecord(id: id)
        rec.url = url
        rec.startTime = start
        return rec
    }

    private func deliverTiming(_ model: OrbitNetworkModel, url: String, start: Double) {
        let entry: [String: Any] = ["k": "timing", "url": url, "st": start, "respEnd": start + 100, "dur": 100.0]
        model.receive(type: "net.batch", object: ["entries": [entry]], frame: OrbitInspectFrame(url: "", isMain: true))
    }

    private func waitForFlush() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }

    // MARK: - Presentation gating

    func testAHiddenPanelKeepsTheLogButDoesNotProjectTheTable() async throws {
        let (model, _) = makeModel(presented: false)
        for i in 0..<20 { model.nativeRequestSent(record("r\(i)", "https://example.com/\(i).js")) }
        try await waitForFlush()

        XCTAssertTrue(model.filteredRecords.isEmpty, "The table must not be rebuilt while the Network panel is hidden.")
        XCTAssertTrue(model.summary == NetSummary(), "The summary must not be rebuilt while the Network panel is hidden.")
        XCTAssertEqual(model.records.count, 20, "History made before the panel opens must still be kept and readable by other tools.")
    }

    func testOpeningThePanelShowsEverythingLoggedWhileItWasHidden() async throws {
        let (model, flag) = makeModel(presented: false)
        for i in 0..<20 { model.nativeRequestSent(record("r\(i)", "https://example.com/\(i).js")) }
        try await waitForFlush()
        XCTAssertTrue(model.filteredRecords.isEmpty)

        flag.value = true
        model.panelDidAppear(force: false)

        XCTAssertEqual(model.filteredRecords.count, 20)
        XCTAssertEqual(model.records.map(\.id), (0..<20).map { "r\($0)" })
    }

    func testAPresentedPanelProjectsNewRecordsWithoutBeingAsked() async throws {
        let (model, _) = makeModel(presented: true)
        model.nativeRequestSent(record("a", "https://example.com/a.js"))
        try await waitForFlush()

        XCTAssertEqual(model.filteredRecords.map(\.id), ["a"])
    }

    func testAPanelHiddenBeforeTheFrameFlushDoesNotProjectButCatchesUpOnAppear() async throws {
        let (model, flag) = makeModel(presented: true)
        model.nativeRequestSent(record("a", "https://example.com/a.js"))
        flag.value = false
        try await waitForFlush()
        XCTAssertTrue(model.filteredRecords.isEmpty)

        flag.value = true
        model.panelDidAppear(force: false)
        XCTAssertEqual(model.filteredRecords.map(\.id), ["a"])
    }

    func testRecordsReadWhileHiddenReflectLaterUpdates() async throws {
        let (model, _) = makeModel(presented: false)
        model.nativeRequestSent(record("a", "https://example.com/a.js"))
        XCTAssertEqual(model.records.first?.status, 0)

        model.nativeResponseReceived(
            id: "a", status: 200, statusText: "OK", headers: [], mimeType: "text/javascript",
            url: nil, fromCache: false, expectedBodySize: nil)

        XCTAssertEqual(model.records.first?.status, 200, "A tool reading the log while the panel is hidden must not see stale rows.")
    }

    func testAnExplicitFlushStillProjectsWhileHidden() async throws {
        let (model, _) = makeModel(presented: false)
        model.nativeRequestSent(record("a", "https://example.com/a.js"))
        model.flushIfDirty()

        XCTAssertEqual(model.filteredRecords.map(\.id), ["a"])
    }

    // MARK: - Timing index

    func testATimingEntryAttachesToTheRecordWithTheClosestStartTime() {
        let (model, _) = makeModel(presented: false)
        model.nativeRequestSent(record("early", "https://example.com/app.js", start: 10))
        model.nativeRequestSent(record("late", "https://example.com/app.js", start: 500))

        deliverTiming(model, url: "https://example.com/app.js", start: 490)

        XCTAssertNil(model.richRecord(id: "early")?.timingRaw)
        XCTAssertNotNil(model.richRecord(id: "late")?.timingRaw)
    }

    func testAnExactURLBeatsOneThatDiffersOnlyInTheQuery() {
        let (model, _) = makeModel(presented: false)
        model.nativeRequestSent(record("v1", "https://example.com/data.json?v=1", start: 100))
        model.nativeRequestSent(record("v2", "https://example.com/data.json?v=2", start: 900))

        deliverTiming(model, url: "https://example.com/data.json?v=2", start: 100)

        XCTAssertNotNil(model.richRecord(id: "v2")?.timingRaw)
        XCTAssertNil(model.richRecord(id: "v1")?.timingRaw)
    }

    func testAQueryOnlyDifferenceStillMatchesWhenNothingIsExact() {
        let (model, _) = makeModel(presented: false)
        model.nativeRequestSent(record("only", "https://example.com/data.json?v=1", start: 100))

        deliverTiming(model, url: "https://example.com/data.json?v=2", start: 100)

        XCTAssertNotNil(model.richRecord(id: "only")?.timingRaw)
    }

    func testARecordThatAlreadyHasTimingIsNotGivenAnotherEntry() {
        let (model, _) = makeModel(presented: false)
        model.nativeRequestSent(record("a", "https://example.com/a.js", start: 10))
        model.nativeRequestSent(record("b", "https://example.com/a.js", start: 20))

        deliverTiming(model, url: "https://example.com/a.js", start: 10)
        deliverTiming(model, url: "https://example.com/a.js", start: 20)

        XCTAssertEqual(model.richRecord(id: "a")?.timingRaw?.startTime, 10)
        XCTAssertEqual(model.richRecord(id: "b")?.timingRaw?.startTime, 20)
    }

    func testAnUnknownURLAttachesNowhere() {
        let (model, _) = makeModel(presented: false)
        model.nativeRequestSent(record("a", "https://example.com/a.js", start: 10))

        deliverTiming(model, url: "https://example.com/other.js", start: 10)

        XCTAssertNil(model.richRecord(id: "a")?.timingRaw)
    }

    func testTheIndexFollowsARecordWhoseURLChanges() {
        let (model, _) = makeModel(presented: false)
        model.nativeRequestSent(record("a", "https://example.com/old.js", start: 10))
        model.nativeResponseReceived(
            id: "a", status: 200, statusText: "OK", headers: [], mimeType: "text/javascript",
            url: "https://example.com/new.js", fromCache: false, expectedBodySize: nil)

        deliverTiming(model, url: "https://example.com/old.js", start: 10)
        XCTAssertNil(model.richRecord(id: "a")?.timingRaw, "The record no longer has the old URL.")

        deliverTiming(model, url: "https://example.com/new.js", start: 10)
        XCTAssertNotNil(model.richRecord(id: "a")?.timingRaw)
    }

    func testTheIndexForgetsRecordsTheLogHasEvicted() {
        let (model, _) = makeModel(presented: false)
        for i in 0..<5100 { model.nativeRequestSent(record("r\(i)", "https://example.com/\(i).js", start: Double(i))) }

        XCTAssertNil(model.richRecord(id: "r0"), "The oldest records fall out of the 5000-entry log.")
        deliverTiming(model, url: "https://example.com/0.js", start: 0)
        deliverTiming(model, url: "https://example.com/5099.js", start: 5099)

        XCTAssertNotNil(model.richRecord(id: "r5099")?.timingRaw)
        XCTAssertNil(model.richRecord(id: "r100")?.timingRaw)
    }
}
