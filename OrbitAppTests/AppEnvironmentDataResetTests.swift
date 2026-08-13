import XCTest
@testable import Orbit

@MainActor
final class AppEnvironmentDataResetTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var suiteName = ""
    private var scratchDefaults: UserDefaults!
    private var scratchRoot: URL!
    private var originalTargets: DataResetTargets?

    override func setUp() async throws {
        try await super.setUp()

        suiteName = "AppEnvironmentDataResetTests-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: suiteName)
        AppEnvironment.defaults = scratchDefaults
        SiteZoomStore.defaults = scratchDefaults
        SyncPreferences.defaults = scratchDefaults

        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(suiteName, isDirectory: true)
        for directory in [faviconsDirectory, spaceIconsDirectory, extensionsDirectory, chromiumDirectory, syncDirectory, contentBlockingDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        originalTargets = DataResetTargets.override
        DataResetTargets.override = DataResetTargets(
            faviconCache: FaviconCache(diskDirectory: faviconsDirectory),
            spaceIconImages: SpaceIconImageStore(diskDirectory: spaceIconsDirectory),
            extensions: ExtensionStore(root: extensionsDirectory),
            contentBlocking: ContentBlockingController(
                store: FilterListStore(directory: contentBlockingDirectory),
                defaults: scratchDefaults
            ),
            chromiumProfileDirectory: chromiumDirectory,
            syncDirectory: syncDirectory,
            contentBlockingDirectory: contentBlockingDirectory
        )
    }

    override func tearDown() async throws {
        DataResetTargets.override = originalTargets
        AppEnvironment.defaults = OrbitDefaults.standard
        SiteZoomStore.defaults = OrbitDefaults.standard
        SyncPreferences.defaults = OrbitDefaults.standard
        scratchDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratchRoot)
        try await super.tearDown()
    }

    private var faviconsDirectory: URL { scratchRoot.appendingPathComponent("Favicons", isDirectory: true) }
    private var spaceIconsDirectory: URL { scratchRoot.appendingPathComponent("SpaceIcons", isDirectory: true) }
    private var extensionsDirectory: URL { scratchRoot.appendingPathComponent("Extensions", isDirectory: true) }
    private var chromiumDirectory: URL { scratchRoot.appendingPathComponent("Chromium", isDirectory: true) }
    private var syncDirectory: URL { scratchRoot.appendingPathComponent("Sync", isDirectory: true) }
    private var contentBlockingDirectory: URL { scratchRoot.appendingPathComponent("ContentBlocking", isDirectory: true) }

    // MARK: - Category metadata

    func testEveryCategoryDescribesItselfAndOnlyTheEngineOnesNeedARelaunch() {
        var ids: Set<String> = []
        for category in DataResetCategory.allCases {
            XCTAssertFalse(category.title.isEmpty, "\(category.rawValue) has no title for the Settings row.")
            XCTAssertFalse(category.detail.isEmpty, "\(category.rawValue) has no detail line, so the row cannot say what it removes.")
            XCTAssertTrue(ids.insert(category.id).inserted, "\(category.rawValue) shares an id with another category.")
        }
        XCTAssertEqual(
            Set(DataResetCategory.allCases.filter(\.requiresRelaunch)),
            [.cookiesAndLogins, .extensions, .siteSettings, .preferences],
            "Every category that reaches into the Chromium profile or the settings layer has to demand a relaunch."
        )
    }

    // MARK: - History

    func testHistoryCategoryEmptiesTheStoreAndTheInMemoryCache() async throws {
        let space = try XCTUnwrap(env.activeSpace)
        env.recordVisit(url: URL(string: "https://example.com/reset")!, title: "Reset", profileID: space.profileID, spaceID: space.id)
        try await waitUntil("a visit reaches the history cache") { !self.env.localHistoryCache.isEmpty }

        let outcome = await env.resetData([.history])

        XCTAssertEqual(outcome.clearedCategories, [.history])
        XCTAssertTrue(outcome.failedCategories.isEmpty)
        XCTAssertTrue(env.localHistoryCache.isEmpty, "The Command Bar reads localHistoryCache, so clearing sqlite alone leaves the history on screen.")
        let stillIndexed = await env.historyEntries(in: Date(timeIntervalSince1970: 0)...Date.distantFuture)
        XCTAssertTrue(stillIndexed.isEmpty, "The sqlite database still answers with the visits that were supposed to be gone.")
    }

    // MARK: - Downloads

    func testDownloadsCategoryDropsEveryRecordIncludingOnesClearListKeeps() async {
        let item = env.addDownload(
            sourceURL: URL(string: "https://example.com/big.zip")!,
            destinationURL: scratchRoot.appendingPathComponent("big.zip"),
            suggestedFileName: "big.zip",
            mimeType: "application/zip",
            totalBytes: 1024
        )
        env.updateDownload(id: item.id, progress: DownloadProgress(receivedBytes: 10, totalBytes: 1024, state: .inProgress))
        XCTAssertFalse(env.downloads.isEmpty)

        let outcome = await env.resetData([.downloads])

        XCTAssertEqual(outcome.clearedCategories, [.downloads])
        XCTAssertTrue(env.downloads.isEmpty, "An in-progress download survives clearList(); a data reset must take it too.")
        XCTAssertFalse(outcome.needsRelaunch)
    }

    // MARK: - Spaces and tabs

    func testSpacesAndTabsCategoryReturnsTheDocumentToItsFirstRunShape() async {
        env.state = OrbitState.demo
        XCTAssertGreaterThan(env.spaces.count, 1)

        let outcome = await env.resetData([.spacesAndTabs])

        XCTAssertEqual(outcome.clearedCategories, [.spacesAndTabs])
        XCTAssertEqual(env.spaces.count, 1, "A reset sidebar is the one Space bootstrapIfNeeded() seeds, not an empty document.")
        XCTAssertEqual(env.state.profiles.count, 1)
        XCTAssertEqual(env.state.tabs.count, 1)
        XCTAssertEqual(env.state.tabs.values.first?.url, BrowserStore.firstRunTabURL)
        XCTAssertNotNil(env.activeSpace)
        XCTAssertFalse(env.spaces[0].favorites.isEmpty, "First run seeds favourites; a reset that lands on an emptier document is not first-run state.")
    }

    // MARK: - Favourites

    func testFavouritesCategoryClearsFavouritesAndFoldersWithoutLosingSpacesOrTabs() async {
        env.state = OrbitState.demo
        let spaceCountBefore = env.spaces.count
        let tabCountBefore = env.state.tabs.count
        XCTAssertTrue(env.spaces.contains { !$0.favorites.isEmpty })
        XCTAssertTrue(env.spaces.contains { !$0.pinned.isEmpty })

        let outcome = await env.resetData([.favourites])

        XCTAssertEqual(outcome.clearedCategories, [.favourites])
        for space in env.spaces {
            XCTAssertTrue(space.favorites.isEmpty, "\(space.name) still has favourites.")
            XCTAssertTrue(space.pinned.isEmpty, "\(space.name) still has bookmarked rows or folders.")
        }
        XCTAssertEqual(env.spaces.count, spaceCountBefore, "Clearing favourites must not remove Spaces.")
        XCTAssertEqual(env.state.tabs.count, tabCountBefore, "Bookmarked tabs are archived, not deleted.")
    }

    // MARK: - Documents

    func testNotesEaselsAndBoostsCategoriesEmptyTheirOwnStores() async {
        env.noteStore.createNote(title: "Kept?")
        env.easelStore.createEasel(title: "Kept?")
        env.boostStore.createBoost(name: "Kept?", host: "example.com")

        let outcome = await env.resetData([.notes, .easels, .boosts])

        XCTAssertEqual(outcome.clearedCategories, [.notes, .easels, .boosts])
        XCTAssertTrue(env.noteStore.index.isEmpty)
        XCTAssertTrue(env.easelStore.index.isEmpty)
        XCTAssertTrue(env.boostStore.boosts.isEmpty)
    }

    // MARK: - Extensions

    func testExtensionsCategoryUninstallsEverythingAndDemandsARelaunch() async throws {
        let source = scratchRoot.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"name":"Reset Probe","version":"1.0","manifest_version":3}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        let store = env.dataResetTargets.extensions
        _ = try store.finalizeInstall(ExtensionStore.stageInstall(unpackedAt: source, root: store.root, publicKey: nil))
        XCTAssertEqual(store.installed().count, 1)

        let outcome = await env.resetData([.extensions])

        XCTAssertEqual(outcome.clearedCategories, [.extensions])
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertTrue(outcome.needsRelaunch, "Extensions are only read at browser start-up, so the caller has to be told.")
    }

    // MARK: - Cookies and logins

    func testCookiesAndLoginsCategoryRemovesCredentialAndStorageFilesFromEverySessionProfile() async throws {
        let sessionProfile = try makeProfile(named: "0A28A41D-CFBE-4FE5-B639-F252B8014652")
        let defaultProfile = try makeProfile(named: "Default")
        let keptRootFile = chromiumDirectory.appendingPathComponent("Local State")
        FileManager.default.createFile(atPath: keptRootFile.path, contents: Data("{}".utf8))

        let outcome = await env.resetData([.cookiesAndLogins])

        XCTAssertEqual(outcome.clearedCategories, [.cookiesAndLogins])
        XCTAssertTrue(outcome.failedCategories.isEmpty)
        XCTAssertTrue(outcome.needsRelaunch, "The browser process holds the profile files open, so the removal only sticks after a relaunch.")
        for profile in [sessionProfile, defaultProfile] {
            for entry in ChromiumProfileData.credentialAndStorageEntries + ["Cookies-journal", "Login Data-journal", "Web Data-wal"] {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: profile.appendingPathComponent(entry).path),
                    "\(profile.lastPathComponent)/\(entry) survived a Cookies and Logins reset."
                )
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: profile.appendingPathComponent("History").path),
                "Cookies and Logins took a file belonging to another category."
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path), "The profile directory itself must survive.")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptRootFile.path))
    }

    func testCookiesAndLoginsCategoryReportsFailureWhenAProfileFileCannotBeRemoved() async throws {
        let profile = try makeProfile(named: "Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: profile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path) }

        let outcome = await env.resetData([.cookiesAndLogins])

        XCTAssertEqual(outcome.failedCategories, [.cookiesAndLogins], "A locked profile file has to be reported, not silently skipped.")
        XCTAssertTrue(outcome.clearedCategories.isEmpty)
        XCTAssertFalse(outcome.needsRelaunch, "Nothing was cleared, so there is nothing for a relaunch to finish.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Login Data").path))
    }

    // MARK: - Site settings

    func testSiteSettingsCategoryClearsPerSiteContentSettingsAndLeavesTheRestOfPreferences() async throws {
        let profile = try makeProfile(named: "Default")
        try writePreferences(
            [
                "profile": [
                    "content_settings": [
                        "exceptions": [
                            "media_stream_camera": ["https://example.com,*": ["setting": 1]],
                            "notifications": ["https://example.com,*": ["setting": 1]],
                        ],
                        "pref_version": 1,
                    ],
                    "name": "Person 1",
                ],
                "extensions": ["settings": ["abc": ["state": 1]]],
            ],
            in: profile
        )

        let outcome = await env.resetData([.siteSettings])

        XCTAssertEqual(outcome.clearedCategories, [.siteSettings])
        XCTAssertTrue(outcome.needsRelaunch, "A running browser process rewrites Preferences on exit, so the clear only sticks after a relaunch.")
        let rewritten = try readPreferences(in: profile)
        let contentSettings = try XCTUnwrap((rewritten["profile"] as? [String: Any])?["content_settings"] as? [String: Any])
        XCTAssertNil(contentSettings["exceptions"], "Per-origin camera and notification grants survived a Site Settings reset.")
        XCTAssertNotNil(contentSettings["pref_version"], "Only the exceptions may go — the rest of content_settings is unrelated state.")
        XCTAssertEqual((rewritten["profile"] as? [String: Any])?["name"] as? String, "Person 1")
        XCTAssertNotNil(rewritten["extensions"], "Preferences carries state no reset category claims; it must not be deleted wholesale.")
    }

    func testSiteSettingsCategoryReportsFailureWhenPreferencesCannotBeRead() async throws {
        let profile = try makeProfile(named: "Default")
        try Data("not json".utf8).write(to: profile.appendingPathComponent(ChromiumProfileData.preferencesFileName))

        let outcome = await env.resetData([.siteSettings])

        XCTAssertEqual(outcome.failedCategories, [.siteSettings], "Unreadable Preferences means the permissions are still there.")
        XCTAssertTrue(outcome.clearedCategories.isEmpty)
    }

    func testSiteSettingsCategoryClearsPerSiteContentSettingsInEverySessionProfile() async throws {
        let profiles = try ["Default", "4D16A368-BC2C-4733-A15E-3B10EBCD0422"].map { try makeProfile(named: $0) }
        for profile in profiles {
            try writePreferences(["profile": ["content_settings": ["exceptions": ["geolocation": ["https://example.com,*": ["setting": 1]]]]]], in: profile)
        }

        let outcome = await env.resetData([.siteSettings])

        XCTAssertEqual(outcome.clearedCategories, [.siteSettings])
        for profile in profiles {
            let rewritten = try readPreferences(in: profile)
            let contentSettings = (rewritten["profile"] as? [String: Any])?["content_settings"] as? [String: Any]
            XCTAssertNil(contentSettings?["exceptions"], "\(profile.lastPathComponent) kept its per-origin permissions.")
        }
    }

    func testSiteSettingsCategoryClearsZoomSiteSearchesAndTheAdBlockAllowlist() async {
        SiteZoomStore.setZoomFactor(1.5, forHost: "example.com")
        env.siteSearchStore.createEngine(name: "Docs", shortcut: "docs", urlTemplate: "https://d.example.com?q=%s")
        let controller = env.dataResetTargets.contentBlocking
        await controller.setAllowlisted(true, for: URL(string: "https://allowed.example.com/page")!)
        XCTAssertFalse(controller.allowlistedHosts.isEmpty)

        let outcome = await env.resetData([.siteSettings])

        XCTAssertEqual(outcome.clearedCategories, [.siteSettings])
        XCTAssertTrue(SiteZoomStore.allZoomFactors().isEmpty)
        XCTAssertTrue(env.siteSearchStore.engines.isEmpty, "The seeded defaults count as site settings too.")
        XCTAssertTrue(controller.allowlistedHosts.isEmpty, "A host left allowlisted keeps the blocker off for that site forever.")
    }

    // MARK: - Preferences

    func testPreferencesCategoryClearsOrbitKeysButNeverTheOnboardingFlag() async {
        scratchDefaults.set(999.0, forKey: AppEnvironment.Keys.sidebarWidth)
        scratchDefaults.set(false, forKey: "contentBlocking.enabled")
        scratchDefaults.set("keep me", forKey: "NSSomeoneElsesKey")
        env.hasCompletedOnboarding = true

        let outcome = await env.resetData([.preferences])

        XCTAssertEqual(outcome.clearedCategories, [.preferences])
        XCTAssertTrue(outcome.needsRelaunch)
        XCTAssertNil(scratchDefaults.object(forKey: AppEnvironment.Keys.sidebarWidth))
        XCTAssertNil(scratchDefaults.object(forKey: "contentBlocking.enabled"))
        XCTAssertEqual(scratchDefaults.string(forKey: "NSSomeoneElsesKey"), "keep me", "Only Orbit's own preferences may be touched.")
        XCTAssertTrue(
            env.hasCompletedOnboarding,
            "Resetting preferences must not re-run onboarding — Restart Onboarding is a separate, deliberate action."
        )
    }

    // MARK: - Sync

    func testSyncCacheCategoryRemovesLocalFilesAndLeavesTheDirectoryInPlace() async {
        let cached = syncDirectory.appendingPathComponent("record-cache.json")
        FileManager.default.createFile(atPath: cached.path, contents: Data("{}".utf8))
        SyncPreferences.isEnabled = false

        let outcome = await env.resetData([.syncCache])

        XCTAssertEqual(outcome.clearedCategories, [.syncCache])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncDirectory.path), "The directory itself must survive; only its local contents go.")
        XCTAssertTrue(SyncPreferences.isEnabled, "SyncPreferences goes back to its default, which is on.")
    }

    // MARK: - Everything

    func testResetEverythingClearsEveryCategoryPlusTheProfileAndFilterListDirectories() async {
        let profileFile = chromiumDirectory.appendingPathComponent("Cookies")
        let filterListFile = contentBlockingDirectory.appendingPathComponent("index.json")
        FileManager.default.createFile(atPath: profileFile.path, contents: Data("cookies".utf8))
        FileManager.default.createFile(atPath: filterListFile.path, contents: Data("{}".utf8))
        env.noteStore.createNote(title: "Gone")

        let outcome = await env.resetEverything()

        XCTAssertEqual(outcome.failedCategories, [], "Reset Everything reported a category it could not clear.")
        XCTAssertEqual(outcome.clearedCategories, Set(DataResetCategory.allCases))
        XCTAssertTrue(outcome.needsRelaunch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileFile.path), "The Chromium profile directory still holds the user's browsing state.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: filterListFile.path))
        XCTAssertTrue(env.noteStore.index.isEmpty)
        XCTAssertEqual(env.spaces.count, 1)
    }

    func testResetDataOnlyTouchesTheCategoriesItWasAsked() async {
        env.noteStore.createNote(title: "Kept")
        env.boostStore.createBoost(name: "Kept", host: "example.com")

        let outcome = await env.resetData([.notes])

        XCTAssertEqual(outcome.clearedCategories, [.notes])
        XCTAssertTrue(env.noteStore.index.isEmpty)
        XCTAssertEqual(env.boostStore.boosts.count, 1, "A category that was not selected must be left completely alone.")
    }

    // MARK: - Helpers

    @discardableResult
    private func makeProfile(named name: String) throws -> URL {
        let profile = chromiumDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let files = ChromiumProfileData.credentialAndStorageEntries
            + ["Cookies-journal", "Login Data-journal", "Web Data-wal", "History"]
        for file in files {
            let url = profile.appendingPathComponent(file)
            if ["Local Storage", "Session Storage", "WebStorage", "IndexedDB", "Service Worker", "File System"].contains(file) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.appendingPathComponent("000003.log").path, contents: Data("leveldb".utf8))
            } else {
                FileManager.default.createFile(atPath: url.path, contents: Data(file.utf8))
            }
        }
        return profile
    }

    private func writePreferences(_ json: [String: Any], in profile: URL) throws {
        try JSONSerialization.data(withJSONObject: json)
            .write(to: profile.appendingPathComponent(ChromiumProfileData.preferencesFileName))
    }

    private func readPreferences(in profile: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: profile.appendingPathComponent(ChromiumProfileData.preferencesFileName))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description).")
    }
}

@MainActor
final class OnboardingRestartTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var suiteName = ""
    private var scratchDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "OnboardingRestartTests-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: suiteName)
        AppEnvironment.defaults = scratchDefaults
    }

    override func tearDown() async throws {
        AppEnvironment.defaults = OrbitDefaults.standard
        scratchDefaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testShowIfNeededNeverPresentsOnceOnboardingIsComplete() {
        env.hasCompletedOnboarding = true
        XCTAssertNil(
            OnboardingWindowController.showIfNeeded(on: env),
            "Onboarding is gated on the completion flag alone — nothing may force it back on screen."
        )
    }

    func testRestartLeavesTheFlagCompleteWhenThereIsNothingToPresent() {
        env.hasCompletedOnboarding = true

        OnboardingWindowController.restart(on: env)

        XCTAssertTrue(
            env.hasCompletedOnboarding,
            "A restart that could not present must put the flag back, or every later launch re-offers onboarding with no window."
        )
    }

    func testSkippingRemainingStepsStaysIdempotentAcrossRestarts() {
        env.hasCompletedOnboarding = false
        XCTAssertTrue(OnboardingWindowController.skipRemainingSteps(in: env))
        XCTAssertFalse(
            OnboardingWindowController.skipRemainingSteps(in: env),
            "A second close must not be read as a second skip, or Finish opens a browser window twice."
        )
    }
}
