import XCTest

@MainActor
final class GitHubLiveFolderBackCompatDecodingTests: XCTestCase {

    private static let newSpaceKeys = ["githubLiveFolder"]

    private static let preExistingSpaceKeys: Set<String> = [
        "id", "name", "icon", "iconIsEmoji", "theme", "profileID", "order",
        "favorites", "pinned", "today", "createdAt",
        "pinnedSectionCollapsed", "ephemeral", "archivePolicy",
    ]

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-GitHubLiveFolderBackCompat-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixture

    private func makeDocument() -> (document: OrbitState, configuredSpaceID: SpaceID, bareSpaceID: SpaceID, tabID: TabID) {
        let profile = Profile(name: "Personal")
        var configured = Space(name: "Work", profileID: profile.id)

        let pinnedTab = Tab(
            spaceID: configured.id,
            section: .pinned,
            url: URL(string: "https://github.com/PebbleBird-co/FinalFinal-Chinese/pull/6")!,
            title: "Bump react, react-dom"
        )
        let folder = Folder(name: "Reading", children: [.tab(pinnedTab.id)])

        configured.pinned = [.folder(folder)]
        configured.githubLiveFolder = GitHubLiveFolderConfig(
            enabled: true,
            name: "My Pull Requests",
            icon: "🐙",
            iconIsEmoji: true,
            isExpanded: false,
            showsCreatedByMe: true,
            showsReviewRequests: false
        )

        let bare = Space(name: "Personal", profileID: profile.id, order: 1)

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [configured, bare]
        document.tabs = [pinnedTab.id: pinnedTab]
        document.activeSpaceID = configured.id
        return (document, configured.id, bare.id, pinnedTab.id)
    }

    // MARK: - state.json, through the real load path

    func test_stateJSONWithoutTheGithubLiveFolderKey_stillLoads() throws {
        let fixture = makeDocument()
        try StateStore(rootDirectory: scratchDirectory).saveNow(fixture.document)

        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: stateFileURL)) as? [String: Any]
        )
        var rawSpaces = try XCTUnwrap(raw["spaces"] as? [[String: Any]])
        XCTAssertEqual(rawSpaces.count, 2, "the writer must have persisted both Spaces, or the strip below is a no-op")
        var strippedSpaces = 0
        for index in rawSpaces.indices {
            for key in Self.newSpaceKeys { rawSpaces[index].removeValue(forKey: key) }
            strippedSpaces += 1
        }
        XCTAssertEqual(strippedSpaces, 2)
        raw["spaces"] = rawSpaces
        try JSONSerialization.data(withJSONObject: raw).write(to: stateFileURL, options: .atomic)

        let strippedText = try String(contentsOf: stateFileURL, encoding: .utf8)
        for key in Self.newSpaceKeys {
            XCTAssertFalse(
                strippedText.contains("\"\(key)\""),
                "\(key) is still in the fixture — this test would pass without proving anything"
            )
        }

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(
            reloaded.spaces.count, 2,
            """
            A state.json written before `Space.githubLiveFolder` existed failed to load. The \
            field must stay `Optional` so synthesized `Codable` reads it with `decodeIfPresent` \
            — see this file's header.
            """
        )
        XCTAssertEqual(reloaded.profiles.count, 1, "the rest of the document has to come back too")
        XCTAssertEqual(reloaded.tabs.count, 1)

        let configured = try XCTUnwrap(reloaded.spaces.first { $0.id == fixture.configuredSpaceID })
        XCTAssertNil(configured.githubLiveFolder, "an old document records no Live Folder, so there is none to read back")
        XCTAssertEqual(configured.name, "Work", "stripping the new key must not disturb the fields already there")

        XCTAssertEqual(configured.pinned.count, 1)
        guard case .folder(let folder) = configured.pinned[0] else {
            return XCTFail("The pinned folder must survive: `Folder` gained nothing, precisely so it would.")
        }
        XCTAssertEqual(folder.name, "Reading")
        XCTAssertEqual(folder.allTabIDs, [fixture.tabID])

        let defaults = configured.githubLiveFolder ?? GitHubLiveFolderConfig()
        XCTAssertFalse(defaults.isEnabled, "a Space that has never had a Live Folder must not acquire one by upgrading")
        XCTAssertEqual(defaults.displayName, "Pull Requests")
        XCTAssertTrue(defaults.includesCreatedByMe)
        XCTAssertTrue(defaults.includesReviewRequests)
        XCTAssertTrue(defaults.isExpandedOrDefault)
    }

    func test_stateJSONWithAGithubLiveFolder_roundTrips() throws {
        let fixture = makeDocument()
        try StateStore(rootDirectory: scratchDirectory).saveNow(fixture.document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let configured = try XCTUnwrap(reloaded.spaces.first { $0.id == fixture.configuredSpaceID })
        let config = try XCTUnwrap(configured.githubLiveFolder)

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.displayName, "My Pull Requests")
        XCTAssertEqual(config.icon, "🐙")
        XCTAssertTrue(config.isIconEmoji)
        XCTAssertFalse(config.isExpandedOrDefault)
        XCTAssertTrue(config.includesCreatedByMe)
        XCTAssertFalse(config.includesReviewRequests, "a filter the user turned off must stay off across a relaunch")

        let bare = try XCTUnwrap(reloaded.spaces.first { $0.id == fixture.bareSpaceID })
        XCTAssertNil(bare.githubLiveFolder, "a Space with no Live Folder must not gain one by round-tripping")
    }

    func test_noPullRequestOrFetchTimeEverReachesTheDisk() throws {
        let fixture = makeDocument()
        try StateStore(rootDirectory: scratchDirectory).saveNow(fixture.document)

        let text = try String(contentsOf: stateFileURL, encoding: .utf8)
        for forbidden in ["lastSuccessfulFetch", "pullRequests", "reviewRequests", "createdByMe", "ownerLogin", "reviewable_state"] {
            XCTAssertFalse(
                text.contains(forbidden),
                """
                `\(forbidden)` reached state.json. Persisting contents or a fetch timestamp is what \
                makes a Live Folder look live and never update — the exact failure this feature is \
                built to avoid. Only `GitHubLiveFolderConfig` may be written.
                """
            )
        }
    }

    func test_theStripListNamesEveryKeyThisBuildAddedToTheSpace() throws {
        var space = Space(
            name: "Everything",
            icon: "🚀",
            iconIsEmoji: true,
            profileID: ProfileID(),
            order: 3,
            isEphemeral: true,
            legacyArchivePolicy: ArchivePolicy.after30Days.rawValue
        )
        space.isPinnedSectionCollapsed = true
        space.githubLiveFolder = GitHubLiveFolderConfig(enabled: true)

        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(space)) as? [String: Any]
        )

        XCTAssertEqual(
            Set(encoded.keys).subtracting(Self.preExistingSpaceKeys),
            Set(Self.newSpaceKeys),
            """
            A persisted `Space` key exists that neither predates this work nor is in \
            `newSpaceKeys`. Add it — until you do, the stripped fixture in \
            `test_stateJSONWithoutTheGithubLiveFolderKey_stillLoads` still contains it, so that \
            test is decoding a document written by this build rather than by an older one and \
            proves nothing about upgrading.
            """
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
        space.legacyArchivePolicy = ArchivePolicy.after30Days.rawValue
        space.githubLiveFolder = GitHubLiveFolderConfig(enabled: true, name: "PRs")

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
        XCTAssertEqual(reloaded.legacyArchivePolicy, ArchivePolicy.after30Days.rawValue)
        XCTAssertEqual(reloaded.createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
        XCTAssertEqual(reloaded.githubLiveFolder?.displayName, "PRs")
    }

    // MARK: - The decoder itself

    func test_spaceWrittenWithoutTheGithubLiveFolderKey_stillDecodes() throws {
        let json = """
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
          "createdAt": 726000000
        }
        """
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))

        XCTAssertNil(space.githubLiveFolder)
        XCTAssertEqual(space.name, "Work", "the fields that were always there must survive untouched")
        XCTAssertEqual(space.order, 2)
    }

    func test_aGithubLiveFolderCarryingUnrecognisedContentStillDecodes() throws {
        let json = """
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
          "createdAt": 726000000,
          "githubLiveFolder": {
            "enabled": true,
            "name": "Pull Requests",
            "showsCreatedByMe": "sometimes",
            "sourceKind": "gitlab",
            "repositories": ["acme/widgets"]
          }
        }
        """
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))

        XCTAssertEqual(space.name, "Work", "the rest of the Space must survive content this build has never heard of")
        let config = try XCTUnwrap(space.githubLiveFolder)
        XCTAssertTrue(config.isEnabled, "the keys this build does understand must still be read")
        XCTAssertEqual(config.displayName, "Pull Requests")
        XCTAssertTrue(
            config.includesCreatedByMe,
            "a value of the wrong type must degrade to that field's default, not throw the document away"
        )
    }

    func test_anEmptyConfigDecodesToTheDocumentedDefaults() throws {
        let config = try JSONDecoder().decode(GitHubLiveFolderConfig.self, from: Data("{}".utf8))

        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.displayName, "Pull Requests", "Arc's own name for the folder, verbatim")
        XCTAssertNil(config.icon, "no icon means the octocat-badged folder glyph, which the sidebar draws")
        XCTAssertTrue(config.isExpandedOrDefault)
        XCTAssertTrue(config.includesCreatedByMe)
        XCTAssertTrue(config.includesReviewRequests)
    }

    func test_theConfigWritesOnlyTheFieldsThatWereActuallySet() throws {
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(GitHubLiveFolderConfig(enabled: true)))
                as? [String: Any]
        )
        XCTAssertEqual(Set(encoded.keys), ["enabled"])
    }

    func test_theConfigDeclaresNoEnumTypedStoredProperty() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Orbit/Features/GitHubLiveFolders/GitHubLiveFolderModels.swift"),
            encoding: .utf8
        )
        let declaration = try XCTUnwrap(
            source.range(of: "public struct GitHubLiveFolderConfig").map { String(source[$0.lowerBound...]) }
        )
        // Every stored property in the struct, up to the first computed one.
        for line in declaration.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public var "), trimmed.hasSuffix("?") else { continue }
            let type = trimmed.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            XCTAssertTrue(
                ["Bool?", "String?"].contains(type),
                """
                `\(trimmed)` stores a `\(type)`. Every stored property on GitHubLiveFolderConfig \
                must be an optional `Bool` or `String`: an enum-typed one throws on an \
                unrecognised value and takes the user's whole state.json with it.
                """
            )
        }
    }
}
