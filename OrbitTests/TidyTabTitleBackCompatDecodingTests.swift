import XCTest

@MainActor
final class TidyTabTitleBackCompatDecodingTests: XCTestCase {

    private static let newTabKeys = ["tidiedTitle"]

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-TidyTabTitleBackCompat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Fixture

    private func makeDocument() -> (document: OrbitState, pinnedTabID: TabID, todayTabID: TabID) {
        let profile = Profile(name: "Personal")
        var space = Space(name: "Work", profileID: profile.id)

        let pinned = Tab(
            spaceID: space.id,
            section: .pinned,
            url: URL(string: "https://www.airbnb.com/experiences/12345")!,
            title: "Mezcal and Mole with a Local Chef in Oaxaca City | Airbnb Experiences",
            pinnedURL: URL(string: "https://www.airbnb.com/experiences/12345")!,
            pinnedTitle: "Mezcal and Mole with a Local Chef in Oaxaca City | Airbnb Experiences",
            tidiedTitle: "Mezcal and Mole"
        )
        let today = Tab(spaceID: space.id, url: URL(string: "https://example.com/scratch")!, title: "Scratch")

        space.pinned = [.tab(pinned.id)]
        space.today = [today.id]

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [pinned.id: pinned, today.id: today]
        document.activeSpaceID = space.id
        return (document, pinned.id, today.id)
    }

    // MARK: - state.json, through the real load path

    func test_stateJSONWithoutTheTidiedTitleKey_stillLoads() throws {
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
            A state.json written before `Tab.tidiedTitle` existed failed to load. The field must \
            stay `Optional` so synthesized `Codable` reads it with `decodeIfPresent` — see this \
            file's header.
            """
        )
        XCTAssertEqual(reloaded.spaces.count, 1, "The rest of the document has to come back too, not just the tabs.")
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.spaces.first?.pinned.flatMap(\.allTabIDs), [fixture.pinnedTabID], "The pinned tree must survive.")

        let reloadedPinned = try XCTUnwrap(reloaded.tabs[fixture.pinnedTabID])
        XCTAssertNil(reloadedPinned.tidiedTitle, "An old document records no tidied title, so there is none to read back.")
        XCTAssertEqual(
            reloadedPinned.displayTitle,
            "Mezcal and Mole with a Local Chef in Oaxaca City | Airbnb Experiences",
            "With no tidied title the row must fall back to the page's real title, not to an empty string."
        )
        XCTAssertEqual(
            reloadedPinned.pinnedTitle,
            "Mezcal and Mole with a Local Chef in Oaxaca City | Airbnb Experiences",
            "Stripping the new key must not disturb the fields that were already there."
        )
    }

    func test_stateJSONWithATidiedTitle_roundTrips() throws {
        let fixture = makeDocument()
        try StateStore(rootDirectory: scratchDirectory).saveNow(fixture.document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let reloadedPinned = try XCTUnwrap(reloaded.tabs[fixture.pinnedTabID])

        XCTAssertEqual(reloadedPinned.tidiedTitle, "Mezcal and Mole")
        XCTAssertEqual(reloadedPinned.displayTitle, "Mezcal and Mole", "The sidebar shows the tidied title after a relaunch.")

        let reloadedToday = try XCTUnwrap(reloaded.tabs[fixture.todayTabID])
        XCTAssertNil(reloadedToday.tidiedTitle, "A tab that was never tidied must not gain a tidied title by round-tripping.")
    }

    // MARK: - The decoder itself

    func test_tabWrittenWithoutTheTidiedTitleKey_stillDecodes() throws {
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
        XCTAssertNil(tab.tidiedTitle)
        XCTAssertEqual(tab.displayTitle, "World News")
    }

    // MARK: - Title precedence

    func test_aUsersOwnRenameBeatsTheTidiedTitle() {
        var tab = Tab(spaceID: UUID(), url: URL(string: "https://example.com")!, title: "The Real Page Title")
        tab.tidiedTitle = "Machine Written"
        XCTAssertEqual(tab.displayTitle, "Machine Written")

        tab.customTitle = "What I Called It"
        XCTAssertEqual(tab.displayTitle, "What I Called It")
    }

    func test_clearingTheTidiedTitleRestoresTheRealOne() {
        var tab = Tab(spaceID: UUID(), url: URL(string: "https://example.com")!, title: "The Real Page Title")
        tab.tidiedTitle = "Machine Written"
        tab.tidiedTitle = nil
        XCTAssertEqual(tab.displayTitle, "The Real Page Title")
    }
}
