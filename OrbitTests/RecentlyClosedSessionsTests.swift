//  The BrowserStore half of chrome.sessions: the by-id restore, the closedAt stamp
//  getRecentlyClosed reports as Session.lastModified, and the change notification
//  sessions.onChanged rides on. Backed by a scratch StateStore, never the real one.

import XCTest

@MainActor
final class RecentlyClosedSessionsTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: BrowserStore!
    private var spaceID: SpaceID!
    private var observer: NSObjectProtocol?
    private var notifications = 0

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-RecentlyClosedSessions-\(UUID().uuidString)", isDirectory: true)
        store = BrowserStore(
            stateStore: StateStore(rootDirectory: scratchDirectory, maxBackups: 0),
            autoArchiveInterval: nil
        )
        spaceID = store.activeSpace!.id
    }

    override func tearDown() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        store = nil
        spaceID = nil
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func openAndClose(_ host: String) -> TabID {
        let id = store.openTab(url: URL(string: "https://\(host).example.com")!, in: spaceID)
        store.closeTab(id)
        return id
    }

    private var closedTabIDs: [TabID] { store.recentlyClosedRecords.map(\.tabID) }

    /// Counts only this store's posts; other suites' stores share the notification name.
    private func countNotifications() {
        observer = NotificationCenter.default.addObserver(
            forName: .orbitRecentlyClosedDidChange, object: store, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notifications += 1 }
        }
    }

    // MARK: - Restoring one named entry

    func test_reopenClosedTab_restoresTheNamedEntryAndLeavesTheRestInOrder() {
        let first = openAndClose("first")
        let second = openAndClose("second")
        let third = openAndClose("third")
        XCTAssertEqual(closedTabIDs, [first, second, third], "the list is append-ordered, oldest first")
        let activeBefore = store.activeTab(in: spaceID)?.id

        XCTAssertTrue(store.reopenClosedTab(first))

        XCTAssertEqual(
            store.tab(first)?.section, .today,
            "chrome.sessions.restore names one entry; restoring the newest instead would reopen the wrong page"
        )
        XCTAssertEqual(
            closedTabIDs, [second, third],
            "exactly the restored record leaves the list, and the survivors keep their order"
        )
        XCTAssertEqual(store.tab(second)?.section, .archived)
        XCTAssertEqual(store.tab(third)?.section, .archived)
        XCTAssertEqual(
            store.activeTab(in: spaceID)?.id, activeBefore,
            "selection is the caller's, so a window-scoped AppEnvironment can do it through its own scoping"
        )
    }

    func test_reopenClosedTab_withAnUnknownIdChangesNothing() {
        let closed = openAndClose("only")

        XCTAssertFalse(store.reopenClosedTab(UUID()))

        XCTAssertEqual(closedTabIDs, [closed], "an id naming no record must not consume some other record")
        XCTAssertEqual(store.tab(closed)?.section, .archived)
    }

    func test_reopenClosedTab_isNotRepeatable_forAnAlreadyRestoredEntry() {
        let closed = openAndClose("only")
        XCTAssertTrue(store.reopenClosedTab(closed))

        XCTAssertFalse(
            store.reopenClosedTab(closed),
            "the record is gone, so the second restore has nothing to restore and must say so"
        )
        XCTAssertTrue(closedTabIDs.isEmpty)
    }

    func test_reopenClosedTab_putsAPinnedRecordBackIntoPinnedWithItsOrigin() {
        let id = store.openTab(url: URL(string: "https://pinned.example.com/article")!, in: spaceID, section: .pinned)
        store.state.tabs[id]?.title = "The Article I Pinned"
        store.state.tabs[id]?.pinnedTitle = "The Article I Pinned"
        let originURL = store.tab(id)?.pinnedURL
        XCTAssertNotNil(originURL)
        store.state.tabs[id]?.url = URL(string: "https://pinned.example.com/section")!

        store.closeTab(id)
        XCTAssertEqual(store.tab(id)?.section, .today, "closeTab on a pinned tab unpins it")

        XCTAssertTrue(store.reopenClosedTab(id))

        XCTAssertEqual(
            store.tab(id)?.section, .pinned,
            "a pinned record restores its pin, exactly as reopenLastClosedTab's shared branch does"
        )
        XCTAssertEqual(
            store.tab(id)?.pinnedURL, originURL,
            "the pinned origin must survive a by-id restore, not be recaptured at whatever page the tab was on"
        )
        XCTAssertEqual(store.tab(id)?.pinnedTitle, "The Article I Pinned")
    }

    // MARK: - closedAt

    func test_closedAt_isStampedAtEveryPushSite() {
        let before = Date()
        let today = openAndClose("today")

        let pinned = store.openTab(url: URL(string: "https://pinned.example.com")!, in: spaceID, section: .pinned)
        store.closeTab(pinned)

        let bookmarked = store.openTab(url: URL(string: "https://bookmarked.example.com")!, in: spaceID, section: .pinned)
        store.removeBookmark(bookmarked)
        let after = Date()

        XCTAssertEqual(
            closedTabIDs, [today, pinned, bookmarked],
            "closeTab's Today branch, closeTab's pinned branch and removeBookmark are the three push sites"
        )
        for record in store.recentlyClosedRecords {
            XCTAssertGreaterThanOrEqual(
                record.closedAt, before,
                """
                closedAt is what getRecentlyClosed reports as Session.lastModified. An unset or \
                fabricated time here is a lie the extension API has no way to detect.
                """
            )
            XCTAssertLessThanOrEqual(record.closedAt, after)
        }
    }

    // MARK: - The change notification sessions.onChanged rides on

    func test_theChangeNotification_firesOnEveryRealMutationOfTheList() {
        countNotifications()

        let first = openAndClose("first")
        XCTAssertEqual(notifications, 1, "closing a tab pushes a record, which is a change")

        let second = openAndClose("second")
        XCTAssertEqual(notifications, 2)

        XCTAssertTrue(store.reopenClosedTab(first))
        XCTAssertEqual(notifications, 3, "a by-id restore removes a record, which is just as much a change")

        store.reopenLastClosedTab()
        XCTAssertEqual(notifications, 4, "reopenLastClosedTab pops the same list")
        XCTAssertEqual(store.tab(second)?.section, .today)
    }

    func test_theChangeNotification_firesFromTheBulkClearInBrowserStoreSpaces() {
        let otherSpace = store.createSpace(name: "Second", activate: false)
        let strandedTab = store.openTab(url: URL(string: "https://stranded.example.com")!, in: otherSpace)
        store.closeTab(strandedTab)
        countNotifications()

        store.deleteSpace(otherSpace)

        XCTAssertEqual(
            notifications, 1,
            "BrowserStore+Spaces drops the deleted Space's closed tabs; the didSet is what makes that fire"
        )
        XCTAssertTrue(closedTabIDs.isEmpty)
    }

    /// resetToFirstRun's own clear is covered in OrbitAppTests, where
    /// AppEnvironment+DataReset.swift is reachable; this is the bare removeAll it performs.
    func test_theChangeNotification_firesOnABulkRemoveAll() {
        _ = openAndClose("first")
        _ = openAndClose("second")
        countNotifications()

        store.recentlyClosedRecords.removeAll()

        XCTAssertEqual(notifications, 1, "emptying the list wholesale is a change like any other")
    }

    func test_theChangeNotification_staysQuietWhenTheListIsAssignedAnEqualValue() {
        _ = openAndClose("first")
        countNotifications()

        store.recentlyClosedRecords = store.recentlyClosedRecords

        XCTAssertEqual(
            notifications, 0,
            "a write that changes nothing must not wake every sessions.onChanged listener"
        )
    }

    // MARK: - MAX_SESSION_RESULTS

    func test_maxSessionResults_inTheSchemaMatchesOrbitsOwnCapacity() throws {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chromium/Embedder/common/api/sessions.json")
        let text = try String(contentsOf: schemaURL, encoding: .utf8)
        // Orbit's schemas open with a // licence/rationale block the JSON parser cannot read.
        let start = try XCTUnwrap(text.firstIndex(of: "["), "sessions.json has no JSON array in it")
        let data = try XCTUnwrap(String(text[start...]).data(using: .utf8))
        let namespaces = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            "sessions.json did not parse as a schema array"
        )
        let sessions = try XCTUnwrap(namespaces.first { $0["namespace"] as? String == "sessions" })

        let properties = try XCTUnwrap(sessions["properties"] as? [String: Any])
        let maxResults = try XCTUnwrap(properties["MAX_SESSION_RESULTS"] as? [String: Any])
        XCTAssertEqual(
            maxResults["value"] as? Int, store.recentlyClosedCapacity,
            """
            sessions.MAX_SESSION_RESULTS is the number extensions size their own lists by, and \
            recentlyClosedCapacity is the number Orbit actually keeps. Two copies that disagree \
            promise entries that were already dropped.
            """
        )

        let types = try XCTUnwrap(sessions["types"] as? [[String: Any]])
        let filter = try XCTUnwrap(types.first { $0["id"] as? String == "Filter" })
        let filterProperties = try XCTUnwrap(filter["properties"] as? [String: Any])
        let filterMax = try XCTUnwrap(filterProperties["maxResults"] as? [String: Any])
        XCTAssertEqual(
            filterMax["maximum"] as? Int, store.recentlyClosedCapacity,
            "Filter.maxResults' ceiling is the third copy of the same number and has to move with it"
        )
    }
}
