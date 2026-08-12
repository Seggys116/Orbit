import XCTest
#if canImport(SQLite3)
import SQLite3
#endif

final class ArcSettingsReaderTests: XCTestCase {

    private var profile: URL!

    override func setUp() {
        super.setUp()
        profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ArcSettings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let profile {
            try? FileManager.default.removeItem(at: profile)
        }
        profile = nil
        super.tearDown()
    }

    // MARK: - Zoom

    func testZoomLevelsAreConvertedOutOfChromiumsLogarithmicScale() throws {
        try writePreferences(Self.zoomPreferences)

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)
        let factors = Dictionary(uniqueKeysWithValues: settings.hostZoomLevels.map { ($0.host, $0.zoomFactor) })

        let zoomedIn = try XCTUnwrap(factors["theapplaunchpad.com"])
        XCTAssertEqual(
            zoomedIn,
            1.5,
            accuracy: 1e-9,
            "zoom_level 2.223901085741545 is Chromium's log-base-1.2 encoding of a 150% zoom."
        )

        let unzoomed = try XCTUnwrap(factors["unzoomed.example.com"])
        XCTAssertEqual(unzoomed, 1.0, accuracy: 1e-9, "zoom_level 0 is exactly 1.0x, not 0.")

        let zoomedOut = try XCTUnwrap(factors["sotonac.sharepoint.com"])
        XCTAssertLessThan(zoomedOut, 1.0, "A negative zoom_level is a zoom *out* and must produce a factor below 1.")
        XCTAssertEqual(zoomedOut, 0.8, accuracy: 1e-6, "zoom_level -1.2239010040114338 is an 80% zoom.")

        let tripled = try XCTUnwrap(factors["www.kongregate.com"])
        XCTAssertEqual(tripled, 3.0, accuracy: 1e-9, "zoom_level 6.025685102665476 is a 300% zoom.")
    }

    func testEveryStoragePartitionsZoomLevelsAreRead() throws {
        try writePreferences(Self.zoomPreferences)

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(
            settings.hostZoomLevels.map(\.host),
            [
                "app.example.com",
                "sotonac.sharepoint.com",
                "theapplaunchpad.com",
                "unzoomed.example.com",
                "www.kongregate.com",
            ],
            "per_host_zoom_levels is keyed by storage partition; every partition's hosts must be read."
        )

        let partitioned = try XCTUnwrap(settings.hostZoomLevels.first { $0.host == "app.example.com" })
        XCTAssertEqual(partitioned.zoomFactor, 1.5, accuracy: 1e-9)
    }

    // MARK: - Content settings

    func testContentSettingsMapAllowAndBlockOntoExplicitDecisions() throws {
        try writePreferences(Self.contentSettingsPreferences)

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(
            settings.sitePermissions,
            [
                ArcSitePermission(origin: URL(string: "https://cv.example.com:443")!, kind: .automaticDownloads, isAllowed: true),
                ArcSitePermission(origin: URL(string: "https://meet.google.com:443")!, kind: .camera, isAllowed: true),
                ArcSitePermission(origin: URL(string: "https://excalidraw.com:443")!, kind: .clipboardRead, isAllowed: true),
                ArcSitePermission(origin: URL(string: "https://chatgpt.com:443")!, kind: .durableStorage, isAllowed: true),
                ArcSitePermission(origin: URL(string: "http://localhost:3000")!, kind: .geolocation, isAllowed: true),
                ArcSitePermission(origin: URL(string: "https://cad.onshape.com:443")!, kind: .localNetwork, isAllowed: false),
                ArcSitePermission(origin: URL(string: "https://linear.app:443")!, kind: .localNetwork, isAllowed: true),
                ArcSitePermission(origin: URL(string: "https://meet.google.com:443")!, kind: .microphone, isAllowed: true),
                ArcSitePermission(origin: URL(string: "https://news.example.com:443")!, kind: .notifications, isAllowed: true),
                ArcSitePermission(origin: URL(string: "https://www.youtube.com:443")!, kind: .notifications, isAllowed: false),
            ],
            "Only Chromium settings 1 and 2 are decisions, and media_stream_mic/media_stream_camera/clipboard/"
                + "automatic_downloads/durable_storage/local_network/loopback_network must map onto their Orbit kinds."
        )
    }

    func testContentSettingsIgnoreTelemetryEntriesUnknownCategoriesAndPerEmbedderRules() throws {
        try writePreferences(Self.contentSettingsPreferences)

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)
        let origins = Set(settings.sitePermissions.map(\.origin.absoluteString))

        XCTAssertFalse(
            origins.contains("https://engagement.example.com:443"),
            "An entry whose `setting` is a dictionary is telemetry, not a decision, and must be ignored."
        )

        XCTAssertFalse(origins.contains("https://www.netflix.com:443"), "media_engagement is not a permission category.")

        XCTAssertFalse(origins.contains("https://undecided.example.com:443"), "setting 0 is \"not decided\", not \"allow\".")

        XCTAssertFalse(
            origins.contains("https://a.example.com:443"),
            "A rule with a non-* secondary pattern is per-embedder and must be skipped, not flattened."
        )

        XCTAssertFalse(origins.contains("[*.]wild.example.com"), "Wildcard host patterns have no single origin.")

        XCTAssertFalse(origins.contains("https://spam.example.com:443"), "Unmapped categories must be dropped entirely.")

        XCTAssertEqual(settings.sitePermissions.count, 10, "Exactly the ten expressible decisions, and nothing else.")
    }

    // MARK: - Scalar preferences

    func testDownloadDirectoryDoNotTrackAndLanguagesAreRead() throws {
        try writePreferences(Self.contentSettingsPreferences)

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(
            settings.downloadDirectory?.path,
            "/Users/example/Downloads",
            "The download directory is savefile.default_directory; selectfile.last_directory is an open panel's history."
        )
        XCTAssertEqual(settings.sendsDoNotTrack, false, "enable_do_not_track was present and false.")
        XCTAssertEqual(
            settings.preferredLanguages,
            ["en-GB", "en-US", "en"],
            "intl.selected_languages is a comma-separated string, not an array."
        )
    }

    // MARK: - Default search engine

    func testEmptySearchProviderGuidYieldsNoSearchEngineName() throws {
        try writePreferences(["default_search_provider": ["guid": ""]])
        try writeWebDataFixture()

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertNil(
            settings.searchEngineName,
            "An empty default_search_provider.guid means \"not determinable\" — never the first row, and never Google."
        )
    }

    func testNonEmptySearchProviderGuidResolvesShortNameFromWebData() throws {
        try writePreferences(["default_search_provider": ["guid": "485bf7d3-0215-45af-87dc-538868000092"]])
        try writeWebDataFixture()

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(
            settings.searchEngineName,
            "DuckDuckGo",
            "The GUID must be looked up in keywords.sync_guid, not assumed to be the first or the prepopulated row."
        )
    }

    func testSearchProviderGuidThatMatchesNoKeywordRowYieldsNil() throws {
        try writePreferences(["default_search_provider": ["guid": "00000000-0000-0000-0000-000000000000"]])
        try writeWebDataFixture()

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertNil(settings.searchEngineName, "A GUID that names no row is still \"not determinable\".")
    }

    // MARK: - Failure policy

    func testMissingPreferencesYieldsEmptySettingsAndDoesNotThrow() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Preferences").path))

        let settings = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(settings, ArcSettings(), "A profile with no Preferences file must read as empty settings, not fail.")
        XCTAssertNil(settings.searchEngineName)
        XCTAssertNil(settings.downloadDirectory)
        XCTAssertEqual(settings.hostZoomLevels, [])
        XCTAssertEqual(settings.sitePermissions, [])
        XCTAssertNil(settings.sendsDoNotTrack)
        XCTAssertEqual(settings.preferredLanguages, [])
    }

    func testMalformedPreferencesThrowsUnreadable() throws {
        try Data("{\"partition\": {\"per_host_zoom_".utf8)
            .write(to: profile.appendingPathComponent("Preferences", isDirectory: false))

        do {
            _ = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)
            XCTFail("A Preferences file that isn't JSON must throw .unreadable.")
        } catch let error as BrowserImportError {
            guard case .unreadable(let browser, let reason) = error else {
                return XCTFail("Expected .unreadable, got \(error).")
            }
            XCTAssertEqual(browser, .arc)
            XCTAssertFalse(reason.isEmpty, "The reason must say something the user can act on.")
        }
    }

    func testPreferencesWhoseRootIsNotAnObjectThrowsUnreadable() throws {
        try Data("[1, 2, 3]".utf8)
            .write(to: profile.appendingPathComponent("Preferences", isDirectory: false))

        do {
            _ = try ArcSettingsReader.read(profileDirectory: profile, browser: .arc)
            XCTFail("Valid JSON that isn't an object must still throw .unreadable.")
        } catch let error as BrowserImportError {
            guard case .unreadable = error else { return XCTFail("Expected .unreadable, got \(error).") }
        }
    }

    // MARK: - Extensions: i18n

    func testExtensionNamesAreResolvedFromLocalesMessagesJSON() throws {
        try writeExtension(
            identifier: Self.honeyID,
            versionDirectoryName: "19.4.0_0",
            manifest: [
                "name": "__MSG_Honey_Title__",
                "version": "19.4.0",
                "manifest_version": 3,
                "default_locale": "en",
            ],
            locales: [
                "en": ["Honey_Title": ["message": "Honey: Automated Coupons & Rewards"]],
                "de": ["Honey_Title": ["message": "Honey: Automatische Gutscheine"]],
            ]
        )

        try writeExtension(
            identifier: Self.iCloudPasswordsID,
            versionDirectoryName: "3.3.0_0",
            manifest: [
                "name": "__MSG_extName__",
                "version": "3.3.0",
                "manifest_version": 3,
                "default_locale": "en",
            ],
            locales: [:]
        )

        try writeExtension(
            identifier: Self.caseInsensitiveID,
            versionDirectoryName: "1.0.0_0",
            manifest: [
                "name": "__MSG_appName__",
                "version": "1.0.0",
                "manifest_version": 3,
                "default_locale": "en",
            ],
            locales: ["en": ["appname": ["message": "alpha Reader"]]]
        )

        let inventory = try ArcExtensionInventory.read(profileDirectory: profile, browser: .arc)
        let byID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.identifier, $0) })

        XCTAssertEqual(
            byID[Self.honeyID]?.name,
            "Honey: Automated Coupons & Rewards",
            "__MSG_Honey_Title__ resolves from _locales/en/messages.json via default_locale."
        )
        XCTAssertEqual(
            byID[Self.iCloudPasswordsID]?.name,
            "__MSG_extName__",
            "With no _locales bundle the raw placeholder is kept — inventing a name would produce a list the user can't check."
        )
        XCTAssertEqual(
            byID[Self.caseInsensitiveID]?.name,
            "alpha Reader",
            "__MSG_appName__ must match the `appname` key: Chrome's lookup is case-insensitive."
        )
    }

    func testExtensionsAreSortedByNameCaseInsensitively() throws {
        try writeExtension(
            identifier: Self.honeyID,
            versionDirectoryName: "1.0.0_0",
            manifest: ["name": "zeta Tools", "version": "1.0.0", "manifest_version": 3],
            locales: [:]
        )
        try writeExtension(
            identifier: Self.wappalyzerID,
            versionDirectoryName: "1.0.0_0",
            manifest: ["name": "alpha Tools", "version": "1.0.0", "manifest_version": 3],
            locales: [:]
        )
        try writeExtension(
            identifier: Self.caseInsensitiveID,
            versionDirectoryName: "1.0.0_0",
            manifest: ["name": "Beta Tools", "version": "1.0.0", "manifest_version": 3],
            locales: [:]
        )

        let inventory = try ArcExtensionInventory.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(inventory.map(\.name), ["alpha Tools", "Beta Tools", "zeta Tools"])
    }

    // MARK: - Extensions: manifests

    func testManifestV2HostPermissionsAreSplitOutOfPermissions() throws {
        try writeExtension(
            identifier: Self.honeyID,
            versionDirectoryName: "2.4.1_0",
            manifest: [
                "name": "Legacy Extension",
                "version": "2.4.1",
                "manifest_version": 2,
                "permissions": ["tabs", "<all_urls>", "https://example.com/*", "storage", "*://*.google.com/*"],
            ],
            locales: [:]
        )

        let entry = try XCTUnwrap(ArcExtensionInventory.read(profileDirectory: profile, browser: .arc).first)

        XCTAssertEqual(entry.manifestVersion, 2)
        XCTAssertEqual(entry.permissions, ["tabs", "storage"], "API permissions only.")
        XCTAssertEqual(
            entry.hostPermissions,
            ["<all_urls>", "https://example.com/*", "*://*.google.com/*"],
            "Entries containing :// and the <all_urls> token are host access, wherever the manifest put them."
        )
    }

    func testManifestV3HostPermissionsAndNonStringPermissionsAreHandled() throws {
        try writeExtension(
            identifier: Self.wappalyzerID,
            versionDirectoryName: "6.12.4_0",
            manifest: [
                "name": "Wappalyzer - Technology profiler",
                "version": "6.12.4",
                "manifest_version": 3,
                "permissions": ["cookies", ["storage": ["managed": true]] as [String: Any], "tabs"],
                "host_permissions": ["http://*/*", "https://*/*"],
            ],
            locales: [:]
        )

        let entry = try XCTUnwrap(ArcExtensionInventory.read(profileDirectory: profile, browser: .arc).first)

        XCTAssertEqual(entry.manifestVersion, 3)
        XCTAssertEqual(entry.permissions, ["cookies", "tabs"], "Only strings survive.")
        XCTAssertEqual(entry.hostPermissions, ["http://*/*", "https://*/*"])
        XCTAssertEqual(entry.version, "6.12.4")
        XCTAssertEqual(
            entry.webStoreURL,
            URL(string: "https://chromewebstore.google.com/detail/\(Self.wappalyzerID)")!
        )
    }

    func testAbsentManifestVersionDefaultsToTwo() throws {
        try writeExtension(
            identifier: Self.honeyID,
            versionDirectoryName: "0.1_0",
            manifest: ["name": "Ancient Extension", "version": "0.1"],
            locales: [:]
        )

        let entry = try XCTUnwrap(ArcExtensionInventory.read(profileDirectory: profile, browser: .arc).first)
        XCTAssertEqual(entry.manifestVersion, 2, "`manifest_version` predates MV2's mandate; 2 is the only value still true on disk.")
    }

    func testHighestVersionDirectoryWinsAndIsComparedNumerically() throws {
        try writeExtension(
            identifier: Self.honeyID,
            versionDirectoryName: "1.9.0_0",
            manifest: ["name": "Superseded", "version": "1.9.0", "manifest_version": 3, "permissions": ["tabs"]],
            locales: [:]
        )
        try writeExtension(
            identifier: Self.honeyID,
            versionDirectoryName: "1.10.0_0",
            manifest: ["name": "Current", "version": "1.10.0", "manifest_version": 3, "permissions": ["storage"]],
            locales: [:]
        )

        let inventory = try ArcExtensionInventory.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(inventory.count, 1, "Two version directories are one extension, not two.")
        let entry = try XCTUnwrap(inventory.first)
        XCTAssertEqual(entry.version, "1.10.0", "1.10.0 is newer than 1.9.0; a lexicographic compare says otherwise.")
        XCTAssertEqual(entry.name, "Current")
        XCTAssertEqual(entry.permissions, ["storage"], "The permissions must come from the same version as the name.")
        XCTAssertEqual(entry.directory.lastPathComponent, "1.10.0_0")
    }

    // MARK: - Extensions: state and absence

    func testIsEnabledIsNilWithoutSecurePreferencesAndFalseWhenStateIsZero() throws {
        try writeExtension(
            identifier: Self.honeyID,
            versionDirectoryName: "1.0.0_0",
            manifest: ["name": "Disabled Extension", "version": "1.0.0", "manifest_version": 3],
            locales: [:]
        )
        try writeExtension(
            identifier: Self.wappalyzerID,
            versionDirectoryName: "1.0.0_0",
            manifest: ["name": "Enabled Extension", "version": "1.0.0", "manifest_version": 3],
            locales: [:]
        )
        try writeExtension(
            identifier: Self.iCloudPasswordsID,
            versionDirectoryName: "1.0.0_0",
            manifest: ["name": "Unstated Extension", "version": "1.0.0", "manifest_version": 3],
            locales: [:]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Secure Preferences").path))
        for entry in try ArcExtensionInventory.read(profileDirectory: profile, browser: .arc) {
            XCTAssertNil(entry.isEnabled, "\(entry.name) reported a state with no Secure Preferences to read it from.")
        }

        try writeSecurePreferences([
            "extensions": [
                "settings": [
                    Self.honeyID: ["state": 0, "manifest": ["name": "Disabled Extension"]],
                    Self.wappalyzerID: ["state": 1, "manifest": ["name": "Enabled Extension"]],
                    Self.iCloudPasswordsID: ["manifest": ["name": "Unstated Extension"]],
                ],
            ],
        ])

        let inventory = try ArcExtensionInventory.read(profileDirectory: profile, browser: .arc)
        let byID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.identifier, $0) })

        let disabled = try XCTUnwrap(byID[Self.honeyID])
        XCTAssertEqual(disabled.isEnabled, false, "Extension::State 0 is DISABLED.")

        let enabled = try XCTUnwrap(byID[Self.wappalyzerID])
        XCTAssertEqual(enabled.isEnabled, true, "Extension::State 1 is ENABLED.")

        let unstated = try XCTUnwrap(byID[Self.iCloudPasswordsID])
        XCTAssertNil(unstated.isEnabled, "An entry with no `state` key must stay unknown, not default to enabled.")
    }

    func testMissingExtensionsDirectoryYieldsNoExtensions() throws {
        XCTAssertEqual(try ArcExtensionInventory.read(profileDirectory: profile, browser: .arc), [])
    }

    func testDirectoriesWithoutAReadableManifestAreSkippedRatherThanThrown() throws {
        let root = profile.appendingPathComponent("Extensions", isDirectory: true)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(Self.honeyID, isDirectory: true).appendingPathComponent("1.0.0_0", isDirectory: true),
            withIntermediateDirectories: true
        )
        let broken = root.appendingPathComponent(Self.iCloudPasswordsID, isDirectory: true)
            .appendingPathComponent("2.0.0_0", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{\"name\": ".utf8).write(to: broken.appendingPathComponent("manifest.json", isDirectory: false))

        let temp = root.appendingPathComponent("Temp", isDirectory: true).appendingPathComponent("scoped_dir_1", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": "Half-unpacked", "version": "1.0", "manifest_version": 3])
            .write(to: temp.appendingPathComponent("manifest.json", isDirectory: false))

        try writeExtension(
            identifier: Self.wappalyzerID,
            versionDirectoryName: "6.12.4_0",
            manifest: ["name": "Wappalyzer - Technology profiler", "version": "6.12.4", "manifest_version": 3],
            locales: [:]
        )

        let inventory = try ArcExtensionInventory.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(inventory.map(\.identifier), [Self.wappalyzerID])
    }

    // MARK: - Fixture identifiers

    private static let honeyID = "bmnlcjabgnpnenekpadlanbbkooimhnj"
    private static let wappalyzerID = "gppongmhjkpfnbhagpmjfkannfbllamg"
    private static let iCloudPasswordsID = "pejdijmoenmkgeppbflobdenhhabjlaj"
    private static let caseInsensitiveID = "abcdefghijklmnopabcdefghijklmnop"

    // MARK: - Preference fixtures

    private static let zoomPreferences: [String: Any] = [
        "partition": [
            "per_host_zoom_levels": [
                "x": [
                    "theapplaunchpad.com": ["zoom_level": 2.223901085741545, "last_modified": "13390831367549875"],
                    "sotonac.sharepoint.com": ["zoom_level": -1.2239010040114338, "last_modified": "13424111447124784"],
                    "www.kongregate.com": ["zoom_level": 6.025685102665476, "last_modified": "13392155774909905"],
                    "unzoomed.example.com": ["zoom_level": 0, "last_modified": "13392155774909906"],
                ],
                "isolated-app": [
                    "app.example.com": ["zoom_level": 2.223901085741545, "last_modified": "13392155774909907"],
                ],
            ],
        ],
    ]

    private static let contentSettingsPreferences: [String: Any] = [
        "savefile": ["default_directory": "/Users/example/Downloads"],
        "selectfile": ["last_directory": "/Users/example/Projects/orbit/public"],
        "intl": ["selected_languages": "en-GB,en-US,en"],
        "enable_do_not_track": false,
        "default_search_provider": ["guid": ""],
        "profile": [
            "content_settings": [
                "exceptions": [
                    "notifications": [
                        "https://www.youtube.com:443,*": ["setting": 2, "last_modified": "13390831367549875"],
                        "https://news.example.com:443,*": ["setting": 1, "last_modified": "13390831367549876"],
                        "https://engagement.example.com:443,*": [
                            "setting": [
                                "audiblePlaybacks": 2,
                                "hasHighScore": false,
                                "highScoreChanges": 0,
                                "lastMediaPlaybackTime": 1_690_000_000_000.0,
                                "mediaPlaybacks": 2,
                                "significantPlaybacks": 1,
                                "visits": 4,
                            ] as [String: Any],
                        ] as [String: Any],
                        "https://undecided.example.com:443,*": ["setting": 0],
                    ] as [String: Any],
                    "geolocation": [
                        "http://localhost:3000,*": ["setting": 1],
                        "https://a.example.com:443,https://b.example.com:443": ["setting": 1],
                        "[*.]wild.example.com,*": ["setting": 2],
                    ] as [String: Any],
                    "media_stream_camera": ["https://meet.google.com:443,*": ["setting": 1]] as [String: Any],
                    "media_stream_mic": ["https://meet.google.com:443,*": ["setting": 1]] as [String: Any],
                    "clipboard": ["https://excalidraw.com:443,*": ["setting": 1]] as [String: Any],
                    "automatic_downloads": ["https://cv.example.com:443,*": ["setting": 1]] as [String: Any],
                    "durable_storage": ["https://chatgpt.com:443,*": ["setting": 1]] as [String: Any],
                    "local_network": ["https://cad.onshape.com:443,*": ["setting": 2]] as [String: Any],
                    "loopback_network": [
                        "https://cad.onshape.com:443,*": ["setting": 1],
                        "https://linear.app:443,*": ["setting": 1],
                    ] as [String: Any],
                    "media_engagement": [
                        "https://www.netflix.com:443,*": [
                            "setting": ["visits": 91, "mediaPlaybacks": 60] as [String: Any],
                        ] as [String: Any],
                    ] as [String: Any],
                    "popups": ["https://spam.example.com:443,*": ["setting": 2]] as [String: Any],
                    "has_migrated_local_network_access": true,
                ] as [String: Any],
            ],
        ],
    ]

    // MARK: - Fixture writers

    private func writePreferences(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [])
            .write(to: profile.appendingPathComponent("Preferences", isDirectory: false))
    }

    private func writeSecurePreferences(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [])
            .write(to: profile.appendingPathComponent("Secure Preferences", isDirectory: false))
    }

    private func writeExtension(
        identifier: String,
        versionDirectoryName: String,
        manifest: [String: Any],
        locales: [String: [String: Any]]
    ) throws {
        let directory = profile
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(versionDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest, options: [])
            .write(to: directory.appendingPathComponent("manifest.json", isDirectory: false))

        for (locale, messages) in locales {
            let localeDirectory = directory
                .appendingPathComponent("_locales", isDirectory: true)
                .appendingPathComponent(locale, isDirectory: true)
            try FileManager.default.createDirectory(at: localeDirectory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: messages, options: [])
                .write(to: localeDirectory.appendingPathComponent("messages.json", isDirectory: false))
        }
    }

    private func writeWebDataFixture() throws {
        let handle = try openDatabase(at: profile.appendingPathComponent("Web Data", isDirectory: false))
        defer { sqlite3_close(handle) }

        try exec(handle, """
        CREATE TABLE keywords (
            id INTEGER PRIMARY KEY,
            short_name VARCHAR NOT NULL,
            keyword VARCHAR NOT NULL,
            favicon_url VARCHAR NOT NULL,
            url VARCHAR NOT NULL,
            safe_for_autoreplace INTEGER,
            date_created INTEGER DEFAULT 0,
            prepopulate_id INTEGER DEFAULT 0,
            sync_guid VARCHAR,
            is_active INTEGER DEFAULT 0
        );
        """)
        try exec(handle, """
        INSERT INTO keywords (id, short_name, keyword, favicon_url, url, prepopulate_id, sync_guid, is_active)
        VALUES (2, 'Google', 'google.com', '', 'https://www.google.com/search?q={searchTerms}', 1,
                '485bf7d3-0215-45af-87dc-538868000001', 0);
        INSERT INTO keywords (id, short_name, keyword, favicon_url, url, prepopulate_id, sync_guid, is_active)
        VALUES (3, 'Microsoft Bing', 'bing.com', '', 'https://www.bing.com/search?q={searchTerms}', 3,
                '485bf7d3-0215-45af-87dc-538868000003', 0);
        INSERT INTO keywords (id, short_name, keyword, favicon_url, url, prepopulate_id, sync_guid, is_active)
        VALUES (5, 'DuckDuckGo', 'duckduckgo.com', '', 'https://duckduckgo.com/?q={searchTerms}', 92,
                '485bf7d3-0215-45af-87dc-538868000092', 0);
        INSERT INTO keywords (id, short_name, keyword, favicon_url, url, prepopulate_id, sync_guid, is_active)
        VALUES (7, 'Perplexity', 'perplexity.ai', '', 'https://www.perplexity.ai/?q={searchTerms}', 0,
                '8cad4da9-0bd2-4a6a-9ec7-6da3b076c59c', 0);
        """)
    }

    // MARK: - SQLite fixture plumbing (system libsqlite3, same as production)

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "ArcSettingsReaderTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create the fixture database at \(url.path).",
            ])
        }
        return handle
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(domain: "ArcSettingsReaderTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Fixture SQL failed: \(message)",
            ])
        }
    }
}
