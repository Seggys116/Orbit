//  The interesting test does not decode a document this process just
//  encoded. It writes through StateStore.saveNow, strips the new key back
//  off the file on disk, and only then reloads through StateStore.load().

import XCTest

@MainActor
final class TidyTabsBackCompatDecodingTests: XCTestCase {

    private static let newTabKeys = ["tidyGroup"]

    private static let preExistingTabKeys: Set<String> = [
        "id", "spaceID", "section", "url", "title", "customTitle", "faviconURL",
        "lastAccessedAt", "createdAt", "archivedAt", "isUnloaded", "isMuted",
        "zoomFactor", "splitGroupID", "splitIndex", "pinnedURL", "pinnedTitle",
        "tidiedTitle",
    ]

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-TidyTabsBackCompat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Fixture

    private func makeDocument() -> (document: OrbitState, groupedIDs: [TabID], ungroupedID: TabID) {
        let profile = Profile(name: "Personal")
        var space = Space(name: "Work", profileID: profile.id)

        let first = Tab(
            spaceID: space.id,
            url: URL(string: "https://www.lonelyplanet.com/mexico/oaxaca")!,
            title: "Best time to visit Oaxaca",
            tidyGroup: "Oaxaca Trip"
        )
        let second = Tab(
            spaceID: space.id,
            url: URL(string: "https://www.airbnb.com/experiences/9021")!,
            title: "Mezcal tasting tour",
            tidyGroup: "Oaxaca Trip"
        )
        let loose = Tab(spaceID: space.id, url: URL(string: "https://example.com/scratch")!, title: "Scratch")

        space.today = [loose.id, first.id, second.id]

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [first.id: first, second.id: second, loose.id: loose]
        document.activeSpaceID = space.id
        return (document, [first.id, second.id], loose.id)
    }

    // MARK: - state.json, through the real load path

    func test_stateJSONWithoutTheTidyGroupKey_stillLoads() throws {
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
        XCTAssertEqual(strippedTabObjects, 3, "The fixture should have written all three tabs — otherwise the strip is a no-op.")
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
            reloaded.tabs.count, 3,
            """
            A state.json written before `Tab.tidyGroup` existed failed to load. The field must \
            stay `Optional` so synthesized `Codable` reads it with `decodeIfPresent` — see this \
            file's header.
            """
        )
        XCTAssertEqual(reloaded.spaces.count, 1, "The rest of the document has to come back too, not just the tabs.")
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(
            reloaded.spaces.first?.today,
            fixture.document.spaces.first?.today,
            "Today's order is what a header's position is read from, so it must survive untouched."
        )

        for id in fixture.groupedIDs {
            XCTAssertNil(
                try XCTUnwrap(reloaded.tabs[id]).tidyGroup,
                "An old document records no headers, so there are none to read back."
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(reloaded.tabs[fixture.groupedIDs[0]]).title,
            "Best time to visit Oaxaca",
            "Stripping the new key must not disturb the fields that were already there."
        )
    }

    func test_stateJSONWithTidyGroups_roundTrips() throws {
        let fixture = makeDocument()
        try StateStore(rootDirectory: scratchDirectory).saveNow(fixture.document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        for id in fixture.groupedIDs {
            XCTAssertEqual(try XCTUnwrap(reloaded.tabs[id]).tidyGroup, "Oaxaca Trip")
        }
        XCTAssertNil(
            try XCTUnwrap(reloaded.tabs[fixture.ungroupedID]).tidyGroup,
            "A tab that was never grouped must not gain a header by round-tripping."
        )
    }

    // MARK: - The decoder itself

    func test_tabWrittenWithoutTheTidyGroupKey_stillDecodes() throws {
        let json = """
        {
          "id": "1D40B4F0-2C42-4A2E-9E51-3A2E2A9D5C11",
          "spaceID": "5E5A5C7B-1E2F-4B3C-8D9E-0A1B2C3D4E5F",
          "section": "today",
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

        XCTAssertEqual(tab.section, .today, "The fields that were always there must survive untouched.")
        XCTAssertNil(tab.tidyGroup)
        XCTAssertEqual(tab.displayTitle, "World News")
    }

    func test_theStripListNamesEveryKeyThisBuildAddedToTheOldFormat() throws {
        let tab = Tab(
            spaceID: UUID(),
            section: .today,
            url: URL(string: "https://example.com")!,
            title: "Title",
            customTitle: "Custom",
            faviconURL: URL(string: "https://example.com/favicon.ico")!,
            archivedAt: Date(),
            zoomFactor: 1.5,
            splitGroupID: UUID(),
            splitIndex: 1,
            pinnedURL: URL(string: "https://example.com")!,
            pinnedTitle: "Title",
            tidiedTitle: "Short",
            tidyGroup: "Oaxaca Trip"
        )
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(tab)) as? [String: Any]
        )

        XCTAssertEqual(
            Set(encoded.keys).subtracting(Self.preExistingTabKeys),
            Set(Self.newTabKeys),
            """
            A persisted `Tab` key exists that neither predates this work nor is in \
            `newTabKeys`. Add it to `newTabKeys` — until you do, the stripped fixture in \
            `test_stateJSONWithoutTheTidyGroupKey_stillLoads` still contains it, so that \
            test is decoding a document written by this build rather than by an older one \
            and proves nothing about upgrading.
            """
        )
    }

    func test_aHeaderDoesNotAffectTheRowsOwnTitle() {
        var tab = Tab(spaceID: UUID(), url: URL(string: "https://example.com")!, title: "The Real Page Title")
        tab.tidyGroup = "Some Group"
        XCTAssertEqual(tab.displayTitle, "The Real Page Title")
    }
}
