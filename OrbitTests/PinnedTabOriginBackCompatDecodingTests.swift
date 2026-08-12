import XCTest

@MainActor
final class PinnedTabOriginBackCompatDecodingTests: XCTestCase {

    private static let newTabKeys = ["pinnedURL", "pinnedTitle"]

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-PinnedTabOriginBackCompat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Fixture

    private func makeDocument() -> (document: OrbitState, pinnedTabID: TabID, todayTabID: TabID, spaceID: SpaceID) {
        let profile = Profile(name: "Personal")
        var space = Space(name: "Work", profileID: profile.id)

        var pinned = Tab(
            spaceID: space.id,
            section: .pinned,
            url: URL(string: "https://www.nytimes.com/section/world")!,
            title: "World News",
            pinnedURL: URL(string: "https://www.nytimes.com/2024/02/22/some-article")!,
            pinnedTitle: "The Article I Pinned"
        )
        pinned.faviconURL = URL(string: "https://www.nytimes.com/favicon.ico")

        let today = Tab(spaceID: space.id, url: URL(string: "https://example.com/scratch")!, title: "Scratch")

        space.pinned = [.tab(pinned.id)]
        space.today = [today.id]

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [pinned.id: pinned, today.id: today]
        document.activeSpaceID = space.id
        return (document, pinned.id, today.id, space.id)
    }

    // MARK: - state.json, through the real load path

    func test_stateJSONWithoutThePinnedOriginKeys_stillLoads() throws {
        let fixture = makeDocument()
        try StateStore(rootDirectory: scratchDirectory).saveNow(fixture.document)

        let stateURL = scratchDirectory.appendingPathComponent("state.json", isDirectory: false)
        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: stateURL)) as? [String: Any]
        )
        var rawTabs = try XCTUnwrap(
            raw["tabs"] as? [Any],
            "Expected `tabs` to encode as the alternating [key, value, ...] array Swift uses for a non-String-keyed Dictionary."
        )
        var strippedTabObjects = 0
        for index in rawTabs.indices {
            guard var rawTab = rawTabs[index] as? [String: Any] else { continue }
            for newKey in Self.newTabKeys { rawTab.removeValue(forKey: newKey) }
            rawTabs[index] = rawTab
            strippedTabObjects += 1
        }
        XCTAssertEqual(strippedTabObjects, 2, "The fixture should have written both tabs — otherwise the strip is a no-op.")
        raw["tabs"] = rawTabs
        try JSONSerialization.data(withJSONObject: raw).write(to: stateURL, options: .atomic)

        let strippedText = try String(contentsOf: stateURL, encoding: .utf8)
        for key in Self.newTabKeys {
            XCTAssertFalse(
                strippedText.contains("\"\(key)\""),
                "\(key) is still in the fixture — this test would pass without proving anything"
            )
        }

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(
            reloaded.tabs.count, 2,
            """
            A state.json written before `Tab.pinnedURL`/`pinnedTitle` existed failed to load. \
            Both fields must stay `Optional` so synthesized `Codable` reads them with \
            `decodeIfPresent` — see this file's header.
            """
        )
        XCTAssertEqual(reloaded.spaces.count, 1, "The rest of the document has to come back too, not just the tabs.")
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.spaces.first?.pinned.flatMap(\.allTabIDs), [fixture.pinnedTabID], "The pinned tree must survive.")

        let reloadedPinned = try XCTUnwrap(reloaded.tabs[fixture.pinnedTabID])
        XCTAssertEqual(reloadedPinned.section, .pinned)
        XCTAssertEqual(reloadedPinned.url.absoluteString, "https://www.nytimes.com/section/world", "The tab's own URL is untouched by the strip.")
        XCTAssertNil(reloadedPinned.pinnedURL, "An old document records no origin, so there is none to read back.")
        XCTAssertNil(reloadedPinned.pinnedTitle)
        XCTAssertFalse(
            reloadedPinned.hasNavigatedAwayFromPinnedURL,
            "With no recorded origin there is nothing to have navigated away from, so no slash and no reset affordance."
        )
    }

    func test_stateJSONWithThePinnedOrigin_roundTrips() throws {
        let fixture = makeDocument()
        try StateStore(rootDirectory: scratchDirectory).saveNow(fixture.document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let reloadedPinned = try XCTUnwrap(reloaded.tabs[fixture.pinnedTabID])

        XCTAssertEqual(reloadedPinned.pinnedURL?.absoluteString, "https://www.nytimes.com/2024/02/22/some-article")
        XCTAssertEqual(reloadedPinned.pinnedTitle, "The Article I Pinned")
        XCTAssertTrue(
            reloadedPinned.hasNavigatedAwayFromPinnedURL,
            "The fixture was saved sitting on a different page than it was pinned at; that must survive a relaunch."
        )

        let reloadedToday = try XCTUnwrap(reloaded.tabs[fixture.todayTabID])
        XCTAssertNil(reloadedToday.pinnedURL, "A tab that was never pinned must not gain an origin by round-tripping.")
    }

    func test_reloadingDoesNotRevertAPinnedTabToItsOrigin() throws {
        let fixture = makeDocument()
        try StateStore(rootDirectory: scratchDirectory).saveNow(fixture.document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let reloadedPinned = try XCTUnwrap(reloaded.tabs[fixture.pinnedTabID])

        XCTAssertEqual(
            reloadedPinned.url.absoluteString,
            "https://www.nytimes.com/section/world",
            """
            Relaunch reverted a Pinned Tab to its pinned URL. Reversion is only ever an explicit \
            user action (favicon click, Command-click, or the "Edit Pinned Page" menu) — see \
            Orbit/Core/AppEnvironment+PinnedTabs.swift's header.
            """
        )
    }

    // MARK: - The decoder itself

    func test_tabWrittenWithoutThePinnedOriginKeys_stillDecodes() throws {
        let json = """
        {
          "id": "1D40B4F0-2C42-4A2E-9E51-3A2E2A9D5C11",
          "spaceID": "5E5A5C7B-1E2F-4B3C-8D9E-0A1B2C3D4E5F",
          "section": "pinned",
          "url": "https://www.nytimes.com/section/world",
          "title": "World News",
          "lastAccessedAt": 726000000,
          "createdAt": 726000000,
          "isUnloaded": false,
          "isMuted": false,
          "splitIndex": 0
        }
        """
        let tab = try JSONDecoder().decode(Tab.self, from: Data(json.utf8))

        XCTAssertEqual(tab.section, .pinned, "The fields that were always there must survive untouched.")
        XCTAssertEqual(tab.title, "World News")
        XCTAssertNil(tab.pinnedURL)
        XCTAssertNil(tab.pinnedTitle)
        XCTAssertFalse(tab.hasNavigatedAwayFromPinnedURL)
    }
}
