import Foundation
import XCTest
@testable import Orbit

/// The bridge's own payload, driven against a scratch store with no engine and no window.
/// Lives here rather than in OrbitTests because OrbitChromiumSessionsBridge and
/// AppEnvironment+DataReset are only reachable through @testable import Orbit.
@MainActor
final class SessionsRecentlyClosedPayloadTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: BrowserStore!
    private var spaceID: SpaceID!
    private var notifications = 0

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-SessionsPayload-\(UUID().uuidString)", isDirectory: true)
        store = BrowserStore(
            stateStore: StateStore(rootDirectory: scratchDirectory, maxBackups: 0),
            autoArchiveInterval: nil
        )
        spaceID = store.activeSpace!.id
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        store = nil
        spaceID = nil
        scratchDirectory = nil
        super.tearDown()
    }

    private func openAndClose(_ host: String) -> TabID {
        let id = store.openTab(url: URL(string: "https://\(host).example.com")!, in: spaceID)
        store.closeTab(id)
        return id
    }

    private func sessionIDs(maxResults: Int32) throws -> [String] {
        let json = OrbitChromiumSessionsBridge.shared.recentlyClosedJSON(maxResults: maxResults, in: store)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let sessions = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return sessions.compactMap { $0["sessionId"] as? String }
    }

    func test_maxResultsZero_reportsNothingRatherThanEverything() throws {
        _ = openAndClose("first")
        _ = openAndClose("second")
        _ = openAndClose("third")

        XCTAssertEqual(
            try sessionIDs(maxResults: 0), [],
            """
            C++ substitutes MAX_SESSION_RESULTS when the filter is absent, so a 0 arriving here \
            is an extension explicitly asking for none. Treating it as "all" hands back the whole \
            list to a caller that asked for nothing.
            """
        )
    }

    func test_maxResultsOne_reportsOnlyTheMostRecentlyClosedTab() throws {
        _ = openAndClose("first")
        _ = openAndClose("second")
        let third = openAndClose("third")

        XCTAssertEqual(try sessionIDs(maxResults: 1), [third.uuidString])
    }

    /// An omitted filter reaches Swift as MAX_SESSION_RESULTS, never as a sentinel.
    func test_anOmittedFilter_reportsUpToTheCapacityNewestFirst() throws {
        var closed: [TabID] = []
        for index in 0..<(store.recentlyClosedCapacity + 3) {
            closed.append(openAndClose("host\(index)"))
        }

        let all = try sessionIDs(maxResults: Int32(store.recentlyClosedCapacity))

        XCTAssertEqual(all.count, store.recentlyClosedCapacity)
        XCTAssertEqual(
            all.first, closed.last?.uuidString,
            "the list is capped by dropping the oldest, so the newest close must still be at index 0"
        )
        XCTAssertFalse(
            all.contains(closed[0].uuidString),
            "the three closes past the capacity must have pushed the oldest out, not been silently kept"
        )
    }

    func test_resetToFirstRun_firesTheChangeNotificationSessionsOnChangedRidesOn() {
        _ = openAndClose("first")
        let observer = NotificationCenter.default.addObserver(
            forName: .orbitRecentlyClosedDidChange, object: store, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.resetToFirstRun()

        XCTAssertEqual(
            notifications, 1,
            "AppEnvironment+DataReset clears the whole list and has no bridge call of its own"
        )
        XCTAssertTrue(store.recentlyClosedRecords.isEmpty)
    }
}
