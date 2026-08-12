//  Deliberately does not decode a Profile this process just encoded: writes a real state.json,
//  strips the new keys off disk, asserts they're gone, then reloads through the real StateStore.load().

import XCTest

@MainActor
final class SearchEngineBackCompatDecodingTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-SearchEngineBackCompat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private static let newProfileKeys = ["searchEngine", "includesSearchSuggestions"]

    // MARK: - Bare Profile decoding

    private static let legacyProfileJSON = """
    {
      "id": "1F2E3D4C-5B6A-4798-8877-665544332211",
      "name": "Personal",
      "symbolName": "person.crop.circle",
      "tint": { "red": 0.45, "green": 0.42, "blue": 0.95, "alpha": 1 },
      "isPersistent": true,
      "createdAt": 726000000
    }
    """

    func test_profileWrittenWithoutASearchEngine_stillDecodes() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(Self.legacyProfileJSON.utf8))

        XCTAssertEqual(profile.name, "Personal", "the fields that were always there must survive untouched")
        XCTAssertTrue(profile.isPersistent)
        XCTAssertEqual(profile.symbolName, "person.crop.circle")
    }

    func test_absentSearchEngine_defaultsToTheShippedFallback() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(Self.legacyProfileJSON.utf8))

        XCTAssertEqual(profile.searchEngine, .fallback)
        XCTAssertEqual(
            profile.searchEngine, .google,
            "every hardcoded search URL this change replaced was a Google one, so an untouched Profile must still be Google"
        )
        XCTAssertTrue(
            profile.includesSearchSuggestions,
            "suggestions were unconditionally fetched before this field existed; absent must mean on, not off"
        )
    }

    func test_minimalProfile_decodesWithWorkingDefaults() throws {
        let json = """
        { "id": "1F2E3D4C-5B6A-4798-8877-665544332211", "name": "Minimal" }
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.name, "Minimal")
        XCTAssertEqual(profile.searchEngine, .fallback)
        XCTAssertTrue(profile.includesSearchSuggestions)
        XCTAssertTrue(profile.isPersistent, "a Profile with no recorded persistence flag is a persistent Profile")
    }

    func test_unrecognisedSearchEngineValue_fallsBackInsteadOfThrowing() throws {
        let json = """
        {
          "id": "1F2E3D4C-5B6A-4798-8877-665544332211",
          "name": "Future",
          "searchEngine": "someEngineFromALaterBuild"
        }
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.searchEngine, .fallback)
        XCTAssertEqual(profile.name, "Future", "the rest of the Profile must survive an unknown engine value")
    }

    // MARK: - state.json, through the real load path

    func test_stateJSONWithoutTheNewProfileFields_stillLoads() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        var profile = Profile(name: "Personal")
        profile.searchEngine = .duckDuckGo
        profile.includesSearchSuggestions = false
        let space = Space(name: "Work", profileID: profile.id)
        let tab = Tab(spaceID: space.id, url: URL(string: "https://news.ycombinator.com/")!)

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [tab.id: tab]
        document.activeSpaceID = space.id
        try store.saveNow(document)

        let stateURL = scratchDirectory.appendingPathComponent("state.json", isDirectory: false)
        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: stateURL)) as? [String: Any]
        )
        var rawProfiles = try XCTUnwrap(raw["profiles"] as? [[String: Any]])
        XCTAssertEqual(rawProfiles.count, 1, "the writer must have persisted the Profile, or the strip below is a no-op")
        for index in rawProfiles.indices {
            for key in Self.newProfileKeys { rawProfiles[index].removeValue(forKey: key) }
        }
        raw["profiles"] = rawProfiles
        try JSONSerialization.data(withJSONObject: raw).write(to: stateURL, options: .atomic)

        let strippedText = try String(contentsOf: stateURL, encoding: .utf8)
        for key in Self.newProfileKeys {
            XCTAssertFalse(
                strippedText.contains("\"\(key)\""),
                "\(key) is still in the fixture — this test would pass without proving anything"
            )
        }

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(
            reloaded.profiles.count, 1,
            """
            A state.json written before Profile.searchEngine existed failed to \
            load. Every field added to `Profile` must be read with \
            `decodeIfPresent` and a default — see the file header.
            """
        )
        XCTAssertEqual(reloaded.spaces.count, 1, "the rest of the document must come back too, not just the Profiles")
        XCTAssertEqual(reloaded.tabs.count, 1)

        let reloadedProfile = try XCTUnwrap(reloaded.profiles.first)
        XCTAssertEqual(reloadedProfile.name, "Personal")
        XCTAssertEqual(reloadedProfile.id, profile.id)
        XCTAssertEqual(reloadedProfile.searchEngine, .fallback, "an absent engine reads as the shipped fallback")
        XCTAssertTrue(reloadedProfile.includesSearchSuggestions)
    }

    func test_stateJSONWithTheNewProfileFields_roundTrips() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        var profile = Profile(name: "Work")
        profile.searchEngine = .ecosia
        profile.includesSearchSuggestions = false

        var document = OrbitState()
        document.profiles = [profile]
        try store.saveNow(document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let reloadedProfile = try XCTUnwrap(reloaded.profiles.first)

        XCTAssertEqual(reloadedProfile.searchEngine, .ecosia)
        XCTAssertFalse(reloadedProfile.includesSearchSuggestions)
    }

    // MARK: - The engine has to actually resolve a query

    func test_everyEngineProducesADistinctCorrectlyEncodedSearchURL() throws {
        let query = "swift concurrency & actors"
        var seen: Set<String> = []

        for engine in SearchEngine.allCases {
            let url = try XCTUnwrap(engine.searchURL(for: query), "\(engine) produced no URL for a plain query")
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNotNil(url.host)
            XCTAssertFalse(
                url.absoluteString.contains("%s"),
                "\(engine)'s template placeholder survived into the resolved URL"
            )
            XCTAssertTrue(
                seen.insert(url.absoluteString).inserted,
                "\(engine) produced a URL another engine already produced — the popup would be decorative"
            )

            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = components.queryItems ?? []
            XCTAssertTrue(
                queryItems.contains { $0.value == query },
                "\(engine) did not round-trip the query text intact; got \(queryItems)"
            )
        }
    }

    func test_suggestionEndpointsAreDistinctPerEngine() throws {
        var seen: Set<String> = []
        for engine in SearchEngine.allCases {
            let url = try XCTUnwrap(engine.suggestionsURL(for: "orbit"))
            XCTAssertFalse(url.absoluteString.contains("%s"))
            XCTAssertTrue(
                seen.insert(url.absoluteString).inserted,
                "\(engine) shares a suggestion endpoint with another engine"
            )
        }
    }
}
