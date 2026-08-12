import XCTest

@MainActor
final class ArchivePolicyScopeBackCompatDecodingTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ArchivePolicyScope-\(UUID().uuidString)", isDirectory: true)
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
      "id": "30000000-0000-0000-0000-0000000000AA",
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
      "archivePolicy": "after30Days",
      "createdAt": 726000000
    }
    """

    func test_spaceWrittenWithThePerSpaceKey_stillDecodesAndKeepsTheValue() throws {
        let space = try JSONDecoder().decode(Space.self, from: Data(Self.legacySpaceJSON.utf8))

        XCTAssertEqual(
            space.legacyArchivePolicy, ArchivePolicy.after30Days.rawValue,
            "Space.legacyArchivePolicy must keep reading the on-disk key \"archivePolicy\" that existing documents were written with"
        )
        XCTAssertEqual(space.name, "Work", "the fields that were always there must survive the CodingKeys rewrite untouched")
        XCTAssertEqual(space.icon, "briefcase.fill")
        XCTAssertEqual(space.order, 2)
        XCTAssertFalse(space.iconIsEmoji)
    }

    func test_spaceWrittenWithoutAnyArchivePolicy_stillDecodes() throws {
        let json = """
        {
          "id": "30000000-0000-0000-0000-0000000000BB",
          "name": "Bare",
          "icon": "circle",
          "iconIsEmoji": false,
          "theme": { "style": "solid", "colors": [], "angle": 0, "grain": 0, "blur": 0,
                     "followsSystemAppearance": true, "prefersDarkContent": false },
          "profileID": "1F2E3D4C-5B6A-4798-8877-665544332211",
          "order": 0,
          "favorites": [],
          "pinned": [],
          "today": [],
          "createdAt": 726000000
        }
        """
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
        XCTAssertNil(space.legacyArchivePolicy)
        XCTAssertEqual(space.name, "Bare")
    }

    func test_spaceWithAnUnrecognisedArchivePolicy_stillDecodes() throws {
        let json = Self.legacySpaceJSON.replacingOccurrences(of: "after30Days", with: "afterOneFortnight")
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))

        XCTAssertEqual(space.name, "Work", "the rest of the Space must survive a cadence this build has never heard of")
        XCTAssertEqual(space.legacyArchivePolicy, "afterOneFortnight")
        XCTAssertNil(
            space.legacyArchivePolicy.flatMap(ArchivePolicy.init(rawValue:)),
            "an unknown cadence must resolve to no policy, so the migration leaves the Profile's own value alone"
        )
    }

    func test_profileWrittenWithoutAnArchivePolicy_defaultsToTwelveHours() throws {
        let json = """
        {
          "id": "1F2E3D4C-5B6A-4798-8877-665544332211",
          "name": "Personal",
          "symbolName": "person.crop.circle",
          "tint": { "red": 0.45, "green": 0.42, "blue": 0.95, "alpha": 1 },
          "isPersistent": true,
          "createdAt": 726000000
        }
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.archivePolicy, .after12Hours)
        XCTAssertEqual(profile.name, "Personal")
    }

    func test_profileWithAnUnrecognisedArchivePolicy_fallsBackInsteadOfThrowing() throws {
        let json = """
        {
          "id": "1F2E3D4C-5B6A-4798-8877-665544332211",
          "name": "Future",
          "archivePolicy": "afterOneFortnight"
        }
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.archivePolicy, .after12Hours)
        XCTAssertEqual(profile.name, "Future", "the rest of the Profile must survive an unknown cadence")
    }

    // MARK: - state.json, through the real load path

    func test_stateJSONInTheOldPerSpaceShape_stillLoadsWithEverythingIntact() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let profile = Profile(name: "Personal", archivePolicy: .after7Days)
        var space = Space(name: "Work", profileID: profile.id)
        space.legacyArchivePolicy = ArchivePolicy.after30Days.rawValue
        let tab = Tab(spaceID: space.id, url: URL(string: "https://news.ycombinator.com/")!)

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [tab.id: tab]
        document.activeSpaceID = space.id
        try store.saveNow(document)

        var raw = try rawDocument()
        var rawProfiles = try XCTUnwrap(raw["profiles"] as? [[String: Any]])
        XCTAssertEqual(rawProfiles.count, 1, "the writer must have persisted the Profile, or the strip below is a no-op")
        for index in rawProfiles.indices { rawProfiles[index].removeValue(forKey: "archivePolicy") }
        raw["profiles"] = rawProfiles
        try write(raw)

        let strippedProfiles = try XCTUnwrap(try rawDocument()["profiles"] as? [[String: Any]])
        XCTAssertNil(strippedProfiles[0]["archivePolicy"], "the Profile key is still there — this test would pass without proving anything")
        let strippedSpaces = try XCTUnwrap(try rawDocument()["spaces"] as? [[String: Any]])
        XCTAssertEqual(
            strippedSpaces[0]["archivePolicy"] as? String, ArchivePolicy.after30Days.rawValue,
            "the Space must be written with the legacy key \"archivePolicy\", or nothing about back-compatibility is being exercised"
        )

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(
            reloaded.profiles.count, 1,
            """
            A state.json written before Profile.archivePolicy existed failed to \
            load. Every field added to `Profile` must be read with \
            `decodeIfPresent` and a default — see the file header.
            """
        )
        XCTAssertEqual(reloaded.spaces.count, 1, "the rest of the document must come back too, not just the Profiles")
        XCTAssertEqual(reloaded.tabs.count, 1)

        let reloadedSpace = try XCTUnwrap(reloaded.spaces.first)
        XCTAssertEqual(reloadedSpace.id, space.id)
        XCTAssertEqual(reloadedSpace.name, "Work")
        XCTAssertEqual(
            reloadedSpace.legacyArchivePolicy, ArchivePolicy.after30Days.rawValue,
            "the chosen cadence must survive the round trip on disk, or BrowserStore's migration has nothing to lift"
        )
        XCTAssertEqual(reloaded.profiles[0].archivePolicy, .after12Hours, "an absent Profile cadence reads as the shipped default")
    }

    func test_stateJSONWrittenByThisBuild_roundTripsThePerProfileCadence() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let profile = Profile(name: "Work", archivePolicy: .never)
        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [Space(name: "Only", profileID: profile.id)]
        try store.saveNow(document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(try XCTUnwrap(reloaded.profiles.first).archivePolicy, .never)
        XCTAssertNil(
            try XCTUnwrap(reloaded.spaces.first).legacyArchivePolicy,
            "a Space written by this build must carry no cadence at all — one place holds the answer"
        )
    }

    func test_everyOtherSpaceFieldStillRoundTripsThroughTheHandWrittenCodingKeys() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let profile = Profile(name: "Personal")
        let tab = Tab(spaceID: SpaceID(), url: URL(string: "https://example.com/")!)
        var space = Space(
            name: "Everything",
            icon: "🚀",
            iconIsEmoji: true,
            theme: SpaceTheme(style: .linear, colors: [ThemeColor(red: 0.1, green: 0.2, blue: 0.3)], angle: 42, grain: 0.7),
            profileID: profile.id,
            order: 7,
            favorites: [Favorite(url: URL(string: "https://example.com/fav")!, title: "Fav")],
            today: [tab.id],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        space.isPinnedSectionCollapsed = true

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [tab.id: tab]
        try store.saveNow(document)

        let reloaded = try XCTUnwrap(try StateStore(rootDirectory: scratchDirectory).load().spaces.first)

        XCTAssertEqual(reloaded.id, space.id)
        XCTAssertEqual(reloaded.name, "Everything")
        XCTAssertEqual(reloaded.icon, "🚀")
        XCTAssertTrue(reloaded.iconIsEmoji)
        XCTAssertEqual(reloaded.theme.style, .linear)
        XCTAssertEqual(reloaded.theme.angle, 42, accuracy: 0.0001)
        XCTAssertEqual(reloaded.profileID, profile.id)
        XCTAssertEqual(reloaded.order, 7)
        XCTAssertEqual(reloaded.favorites.map(\.title), ["Fav"])
        XCTAssertEqual(reloaded.today, [tab.id])
        XCTAssertTrue(reloaded.isPinnedSectionCollapsed)
        XCTAssertEqual(reloaded.createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }
}
