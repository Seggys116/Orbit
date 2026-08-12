import XCTest

@MainActor
final class SpaceIconBackCompatDecodingTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-SpaceIconBackCompat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private var stateFileURL: URL {
        scratchDirectory.appendingPathComponent("state.json", isDirectory: false)
    }

    private func rawDocument() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: stateFileURL)) as? [String: Any])
    }

    private func write(_ raw: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: raw).write(to: stateFileURL, options: .atomic)
    }

    // MARK: - The old on-disk shape, decoded directly

    private static let legacySpaceJSON = """
    {
      "id": "40000000-0000-0000-0000-0000000000AA",
      "name": "Work",
      "icon": "briefcase.fill",
      "iconIsEmoji": false,
      "theme": { "style": "solid", "colors": [], "angle": 0, "grain": 0, "blur": 0,
                 "followsSystemAppearance": true, "prefersDarkContent": false },
      "profileID": "1F2E3D4C-5B6A-4798-8877-665544332211",
      "order": 2,
      "favorites": [],
      "pinned": [],
      "today": [],
      "createdAt": 726000000
    }
    """

    func test_spaceWrittenBeforeIconKindExisted_stillDecodes() throws {
        let space = try JSONDecoder().decode(Space.self, from: Data(Self.legacySpaceJSON.utf8))

        XCTAssertEqual(space.name, "Work", "the fields that were always there must survive the new optional fields being added")
        XCTAssertEqual(space.icon, "briefcase.fill")
        XCTAssertFalse(space.iconIsEmoji)
        XCTAssertNil(space.iconKind, "a document that never had this key must decode it as absent, not as some default case")
        XCTAssertNil(space.iconImageID)
    }

    func test_spaceWrittenBeforeIconKindExisted_resolvesTheLegacySymbol() throws {
        let space = try JSONDecoder().decode(Space.self, from: Data(Self.legacySpaceJSON.utf8))
        XCTAssertEqual(space.resolvedIcon, .symbol("briefcase.fill"))
    }

    func test_spaceWrittenBeforeIconKindExisted_emoji_resolvesTheLegacyEmoji() throws {
        let json = Self.legacySpaceJSON
            .replacingOccurrences(of: "\"icon\": \"briefcase.fill\"", with: "\"icon\": \"🚀\"")
            .replacingOccurrences(of: "\"iconIsEmoji\": false", with: "\"iconIsEmoji\": true")
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
        XCTAssertEqual(space.resolvedIcon, .emoji("🚀"))
    }

    // This throw is expected, not a bug: Space.iconKind's decodeIfPresent throws on a present but unrecognised value rather than treating it as absent, so what actually protects an upgrading user is StateStore's document-level SchemaMigration/backup-chain fallback, not this decode succeeding.
    func test_spaceWithAnUnrecognisedIconKind_stillDecodesTheRestOfTheSpace() throws {
        let json = Self.legacySpaceJSON.replacingOccurrences(
            of: "\"iconIsEmoji\": false,",
            with: "\"iconIsEmoji\": false, \"iconKind\": \"holographic\","
        )
        XCTAssertThrowsError(try JSONDecoder().decode(Space.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("expected DecodingError.dataCorrupted for an unrecognised iconKind, got \(error)")
                return
            }
        }
    }

    // MARK: - The dot fallback

    func test_setIconToNone_resolvesToTheDot() {
        var space = Space(name: "Reading", profileID: ProfileID())
        space.setIconToNone()
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.none)
        XCTAssertEqual(space.iconKind, SpaceIconKind.none)
        XCTAssertNil(space.iconImageID, "the dot never carries a stale image id")
    }

    func test_apply_none_isEquivalentToSetIconToNone() {
        var space = Space(name: "Reading", profileID: ProfileID())
        space.apply(SpaceIcon.none)
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.none)
    }

    func test_settingASymbolAfterTheDot_winsOverTheDot() {
        var space = Space(name: "Reading", profileID: ProfileID())
        space.setIconToNone()
        space.setIcon(symbol: "book")
        XCTAssertEqual(space.resolvedIcon, .symbol("book"))
    }

    func test_dotAfterAnImage_clearsTheImageID() {
        var space = Space(name: "Reading", profileID: ProfileID())
        let imageID = SpaceIconImageID()
        space.setIcon(imageID: imageID)
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.image(imageID))

        space.setIconToNone()
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.none)
        XCTAssertNil(space.iconImageID)
    }

    func test_imageKindWithNoImageID_fallsBackToTheDotRatherThanTheStaleSymbolString() throws {
        let json = Self.legacySpaceJSON.replacingOccurrences(
            of: "\"iconIsEmoji\": false,",
            with: "\"iconIsEmoji\": false, \"iconKind\": \"image\","
        )
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
        XCTAssertEqual(space.iconKind, .image)
        XCTAssertNil(space.iconImageID)
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.none, "iconKind == .image with no id must never resolve to drawing icon=\"briefcase.fill\" as though it were the chosen symbol")
    }

    // MARK: - state.json, through the real load path

    func test_stateJSONInTheOldShape_stillLoadsWithEverythingIntact() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let profile = Profile(name: "Personal")
        var space = Space(name: "Work", icon: "briefcase.fill", iconIsEmoji: false, profileID: profile.id)
        space.setIcon(symbol: "briefcase.fill")
        let tab = Tab(spaceID: space.id, url: URL(string: "https://news.ycombinator.com/")!)

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [tab.id: tab]
        document.activeSpaceID = space.id
        try store.saveNow(document)

        var raw = try rawDocument()
        var rawSpaces = try XCTUnwrap(raw["spaces"] as? [[String: Any]])
        XCTAssertEqual(rawSpaces.count, 1, "the writer must have persisted the Space, or the strip below is a no-op")
        XCTAssertNotNil(rawSpaces[0]["iconKind"], "the Space must be written with iconKind by this build, or the strip proves nothing")
        rawSpaces[0].removeValue(forKey: "iconKind")
        rawSpaces[0].removeValue(forKey: "iconImageID")
        raw["spaces"] = rawSpaces
        try write(raw)

        let strippedSpaces = try XCTUnwrap(try rawDocument()["spaces"] as? [[String: Any]])
        XCTAssertNil(strippedSpaces[0]["iconKind"], "iconKind is still on disk — this test would pass without proving anything")
        XCTAssertNil(strippedSpaces[0]["iconImageID"])
        XCTAssertNotNil(strippedSpaces[0]["icon"], "the legacy fields must still be there, or this isn't really the old shape")

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(
            reloaded.spaces.count, 1,
            """
            A state.json written before Space.iconKind existed failed to \
            load. iconKind/iconImageID must be read with decodeIfPresent \
            and default to nil — see this file's header.
            """
        )
        XCTAssertEqual(reloaded.profiles.count, 1, "the rest of the document must come back too, not just the Space")
        XCTAssertEqual(reloaded.tabs.count, 1)

        let reloadedSpace = try XCTUnwrap(reloaded.spaces.first)
        XCTAssertEqual(reloadedSpace.id, space.id)
        XCTAssertEqual(reloadedSpace.name, "Work")
        XCTAssertEqual(reloadedSpace.icon, "briefcase.fill")
        XCTAssertNil(reloadedSpace.iconKind, "a document written without the key must decode it as absent")
        XCTAssertEqual(reloadedSpace.resolvedIcon, .symbol("briefcase.fill"), "the Space must still resolve to a drawable icon via the legacy fallback")
    }

    func test_stateJSONWrittenByThisBuild_roundTripsTheDot() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let profile = Profile(name: "Personal")
        var space = Space(name: "Blank", icon: "circle.grid.2x2", iconIsEmoji: false, profileID: profile.id)
        space.setIconToNone()

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        try store.saveNow(document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let reloadedSpace = try XCTUnwrap(reloaded.spaces.first)
        XCTAssertEqual(reloadedSpace.iconKind, SpaceIconKind.none)
        XCTAssertEqual(reloadedSpace.resolvedIcon, SpaceIcon.none)
    }

    func test_stateJSONWrittenByThisBuild_roundTripsACustomImageIcon() throws {
        let store = StateStore(rootDirectory: scratchDirectory)
        let imageID = SpaceIconImageID()

        let profile = Profile(name: "Personal")
        var space = Space(name: "Custom", profileID: profile.id)
        space.setIcon(imageID: imageID)

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        try store.saveNow(document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let reloadedSpace = try XCTUnwrap(reloaded.spaces.first)
        XCTAssertEqual(reloadedSpace.iconKind, .image)
        XCTAssertEqual(reloadedSpace.iconImageID, imageID)
        XCTAssertEqual(reloadedSpace.resolvedIcon, SpaceIcon.image(imageID))
    }
}
