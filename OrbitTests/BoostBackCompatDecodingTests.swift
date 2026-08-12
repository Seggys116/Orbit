import XCTest

@MainActor
final class BoostBackCompatDecodingTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-BoostBackCompat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private static let legacyBoostJSON = """
    {
      "id": "6B1B7C3E-4B7E-4E2E-9C8E-1D2A3B4C5D6E",
      "name": "Hacker News",
      "host": "news.ycombinator.com",
      "isEnabled": true,
      "zappedSelectors": ["#footer"],
      "customCSS": "body { max-width: 900px; }",
      "customJavaScript": "",
      "createdAt": 726000000,
      "updatedAt": 726000000
    }
    """

    // MARK: - boosts.json

    func test_boostWrittenWithoutTheVisualControls_stillDecodes() throws {
        let data = Data(Self.legacyBoostJSON.utf8)
        let boost = try JSONDecoder().decode(Boost.self, from: data)

        XCTAssertEqual(boost.name, "Hacker News", "the fields that were always there must survive untouched")
        XCTAssertEqual(boost.host, "news.ycombinator.com")
        XCTAssertEqual(boost.zappedSelectors, ["#footer"])
        XCTAssertEqual(boost.customCSS, "body { max-width: 900px; }")
        XCTAssertTrue(boost.isEnabled)
    }

    func test_absentVisualControls_defaultToLeavingThePageAlone() throws {
        let boost = try JSONDecoder().decode(Boost.self, from: Data(Self.legacyBoostJSON.utf8))

        XCTAssertFalse(boost.invertLightness)
        XCTAssertEqual(boost.contrast, 1.0, accuracy: 0.0001)
        XCTAssertEqual(boost.brightness, 1.0, accuracy: 0.0001)
        XCTAssertEqual(boost.saturation, 1.0, accuracy: 0.0001)
        XCTAssertEqual(boost.pageSizeScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(boost.textCase, .original)
        XCTAssertTrue(
            boost.hasDefaultVisualAdjustments,
            "an upgraded Boost must look, to the rest of the app, exactly like one that was never touched"
        )
    }

    func test_minimalBoost_decodesWithWorkingDefaults() throws {
        let json = """
        { "id": "6B1B7C3E-4B7E-4E2E-9C8E-1D2A3B4C5D6E", "name": "Minimal", "host": "example.com" }
        """
        let boost = try JSONDecoder().decode(Boost.self, from: Data(json.utf8))

        XCTAssertEqual(boost.host, "example.com")
        XCTAssertTrue(boost.isEnabled, "a Boost with no recorded enabled flag is an enabled Boost")
        XCTAssertTrue(boost.zappedSelectors.isEmpty)
        XCTAssertEqual(boost.customCSS, "")
        XCTAssertEqual(boost.textCase, .original)
    }

    // MARK: - state.json, through the real load path

    func test_stateJSONWithoutTheNewBoostFields_stillLoads() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let profile = Profile(name: "Personal")
        let space = Space(name: "Work", profileID: profile.id)
        let tab = Tab(spaceID: space.id, url: URL(string: "https://news.ycombinator.com/")!)
        let boost = Boost(
            name: "Hacker News",
            host: "news.ycombinator.com",
            zappedSelectors: ["#footer"],
            customCSS: "body { max-width: 900px; }"
        )
        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [tab.id: tab]
        document.boosts = [boost]
        document.activeSpaceID = space.id
        try store.saveNow(document)

        let stateURL = scratchDirectory.appendingPathComponent("state.json", isDirectory: false)
        let newKeys = ["invertLightness", "contrast", "brightness", "saturation", "pageSizeScale", "textCase"]
        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: stateURL)) as? [String: Any]
        )
        var rawBoosts = try XCTUnwrap(raw["boosts"] as? [[String: Any]])
        for index in rawBoosts.indices {
            for key in newKeys { rawBoosts[index].removeValue(forKey: key) }
        }
        raw["boosts"] = rawBoosts
        try JSONSerialization.data(withJSONObject: raw).write(to: stateURL, options: .atomic)

        let strippedText = try String(contentsOf: stateURL, encoding: .utf8)
        for key in newKeys {
            XCTAssertFalse(
                strippedText.contains("\"\(key)\""),
                "\(key) is still in the fixture — this test would pass without proving anything"
            )
        }

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(
            reloaded.boosts.count, 1,
            """
            A state.json written before the Boost visual controls existed \
            failed to load. Every field added to `Boost` must be read with \
            `decodeIfPresent` and a default — see the file header.
            """
        )
        XCTAssertEqual(reloaded.spaces.count, 1, "the rest of the document must come back too, not just the Boosts")
        XCTAssertEqual(reloaded.tabs.count, 1)
        XCTAssertEqual(reloaded.profiles.count, 1)

        let reloadedBoost = try XCTUnwrap(reloaded.boosts.first)
        XCTAssertEqual(reloadedBoost.host, "news.ycombinator.com")
        XCTAssertEqual(reloadedBoost.zappedSelectors, ["#footer"])
        XCTAssertEqual(reloadedBoost.customCSS, "body { max-width: 900px; }")
        XCTAssertTrue(reloadedBoost.hasDefaultVisualAdjustments)
    }

    func test_stateJSONWithTheNewBoostFields_roundTrips() throws {
        let store = StateStore(rootDirectory: scratchDirectory)
        var boost = Boost(name: "Hacker News", host: "news.ycombinator.com")
        boost.invertLightness = true
        boost.contrast = 1.4
        boost.pageSizeScale = 1.25
        boost.textCase = .uppercase

        var document = OrbitState()
        document.boosts = [boost]
        try store.saveNow(document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let reloadedBoost = try XCTUnwrap(reloaded.boosts.first)

        XCTAssertTrue(reloadedBoost.invertLightness)
        XCTAssertEqual(reloadedBoost.contrast, 1.4, accuracy: 0.0001)
        XCTAssertEqual(reloadedBoost.pageSizeScale, 1.25, accuracy: 0.0001)
        XCTAssertEqual(reloadedBoost.textCase, .uppercase)
    }

}
