import WebKit
import XCTest
@testable import Orbit

@MainActor
final class AppEnvironmentDataResetTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var suiteName = ""
    private var scratchDefaults: UserDefaults!
    private var scratchRoot: URL!
    private var originalTargets: DataResetTargets?
    private var sessions: [any EngineSession] = []

    override func setUp() async throws {
        try await super.setUp()

        suiteName = "AppEnvironmentDataResetTests-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: suiteName)
        AppEnvironment.defaults = scratchDefaults
        SiteZoomStore.defaults = scratchDefaults
        SyncPreferences.defaults = scratchDefaults

        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(suiteName, isDirectory: true)
        for directory in [faviconsDirectory, spaceIconsDirectory, extensionsDirectory, contentSettingsDirectory, syncDirectory, contentBlockingDirectory] {
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
            contentSettingsDirectory: contentSettingsDirectory,
            syncDirectory: syncDirectory,
            contentBlockingDirectory: contentBlockingDirectory,
            engineSessions: { [unowned self] in self.sessions }
        )
    }

    override func tearDown() async throws {
        for session in sessions.compactMap({ $0 as? WebKitSession }) {
            try? await WKWebsiteDataStore.remove(forIdentifier: WebKitSession.dataStoreIdentifier(for: session.identifier))
        }
        sessions.removeAll()
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
    private var contentSettingsDirectory: URL { scratchRoot.appendingPathComponent("ContentSettings", isDirectory: true) }
    private var syncDirectory: URL { scratchRoot.appendingPathComponent("Sync", isDirectory: true) }
    private var contentBlockingDirectory: URL { scratchRoot.appendingPathComponent("ContentBlocking", isDirectory: true) }

    // MARK: - Category metadata

    func testEveryCategoryDescribesItselfAndOnlyTheOnesWebKitCannotClearLiveNeedARelaunch() {
        var ids: Set<String> = []
        for category in DataResetCategory.allCases {
            XCTAssertFalse(category.title.isEmpty, "\(category.rawValue) has no title for the Settings row.")
            XCTAssertFalse(category.detail.isEmpty, "\(category.rawValue) has no detail line, so the row cannot say what it removes.")
            XCTAssertTrue(ids.insert(category.id).inserted, "\(category.rawValue) shares an id with another category.")
        }
        XCTAssertEqual(
            Set(DataResetCategory.allCases.filter(\.requiresRelaunch)),
            [.extensions, .preferences],
            "Website data and site settings clear live through WebKit; only loaded extensions and already-read preferences need a relaunch."
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

    func testCookiesAndLoginsCategoryNeedsNoRelaunchAndSucceedsWithoutAnEngine() async {
        XCTAssertNil(env.engine, "Precondition: a demo environment has no engine to clear.")

        let outcome = await env.resetData([.cookiesAndLogins])

        XCTAssertEqual(outcome.clearedCategories, [.cookiesAndLogins])
        XCTAssertTrue(outcome.failedCategories.isEmpty)
        XCTAssertFalse(outcome.needsRelaunch, "WebKit removes website data from a running data store, so nothing waits on a relaunch.")
    }

    // MARK: - Site settings

    func testSiteSettingsCategoryClearsPersistedPerSiteDecisionsInEverySession() async throws {
        let first = makeSession(named: "reset-first")
        let second = makeSession(named: "reset-second")
        let origin = URL(string: "https://example.com/page")!
        first.setContentSetting(.allow, for: .camera, url: origin)
        second.setContentSetting(.block, for: .geolocation, url: origin)
        let firstFile = try XCTUnwrap(first.contentSettingsFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path), "Precondition: the decision was persisted.")
        let orphan = contentSettingsDirectory.appendingPathComponent("deleted-profile.json")
        FileManager.default.createFile(atPath: orphan.path, contents: Data("{}".utf8))

        let outcome = await env.resetData([.siteSettings])

        XCTAssertEqual(outcome.clearedCategories, [.siteSettings])
        XCTAssertFalse(outcome.needsRelaunch)
        XCTAssertEqual(first.contentSetting(.camera, for: origin), .ask, "A live session kept its camera grant.")
        XCTAssertEqual(second.contentSetting(.geolocation, for: origin), .ask)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "A session this process never created kept its stored decisions.")

        let reloaded = WebKitSession(
            identifier: first.identifier, persistent: true, storageURL: nil, settingsDirectory: contentSettingsDirectory
        )
        XCTAssertEqual(reloaded.contentSetting(.camera, for: origin), .ask, "The decision came back after a relaunch.")
    }

    func testSiteSettingsCategoryReportsFailureWhenStoredDecisionsCannotBeRemoved() async throws {
        let session = makeSession(named: "reset-locked")
        session.setContentSetting(.allow, for: .camera, url: URL(string: "https://example.com")!)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: contentSettingsDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: contentSettingsDirectory.path) }

        let outcome = await env.resetData([.siteSettings])

        XCTAssertEqual(outcome.failedCategories, [.siteSettings], "Decisions still on disk have to be reported, not skipped.")
        XCTAssertTrue(outcome.clearedCategories.isEmpty)
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

    func testResetEverythingClearsEveryCategoryPlusStoredDecisionsAndFilterLists() async {
        let session = makeSession(named: "reset-everything")
        let origin = URL(string: "https://example.com")!
        session.setContentSetting(.allow, for: .microphone, url: origin)
        let filterListFile = contentBlockingDirectory.appendingPathComponent("index.json")
        FileManager.default.createFile(atPath: filterListFile.path, contents: Data("{}".utf8))
        env.noteStore.createNote(title: "Gone")

        let outcome = await env.resetEverything()

        XCTAssertEqual(outcome.failedCategories, [], "Reset Everything reported a category it could not clear.")
        XCTAssertEqual(outcome.clearedCategories, Set(DataResetCategory.allCases))
        XCTAssertTrue(outcome.needsRelaunch)
        XCTAssertEqual(session.contentSetting(.microphone, for: origin), .ask)
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

    private func makeSession(named name: String) -> WebKitSession {
        let session = WebKitSession(
            identifier: "\(name)-\(UUID().uuidString)",
            persistent: true,
            storageURL: nil,
            settingsDirectory: contentSettingsDirectory
        )
        sessions.append(session)
        return session
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

    // env is AppEnvironment.demo, so the assertion above also holds via the isDemo launch gate.
    // These three separate the two gates and cover the reported defect.

    func testPresentIsGatedOnTheCompletionFlagAloneNotOnIsDemo() {
        env.hasCompletedOnboarding = true
        XCTAssertNil(
            OnboardingWindowController.present(on: env),
            "present must refuse once onboarding is complete, independently of isDemo."
        )
    }

    func testShowIfNeededStillRefusesToAutoOpenInTheDemoApp() {
        env.hasCompletedOnboarding = false
        defer { OnboardingWindowController.closeForTests() }
        XCTAssertTrue(env.isDemo, "test precondition: AppEnvironment.demo must be a demo environment")
        XCTAssertNil(
            OnboardingWindowController.showIfNeeded(on: env),
            "The Demo app must not open onboarding by itself on launch."
        )
    }

    func testRestartPresentsOnboardingEvenInTheDemoApp() {
        env.hasCompletedOnboarding = true
        defer { OnboardingWindowController.closeForTests() }

        OnboardingWindowController.restart(on: env)

        XCTAssertFalse(
            env.hasCompletedOnboarding,
            "Restart Onboarding is an explicit request: in the Demo app it silently did nothing, because restart went through showIfNeeded and hit the isDemo launch gate."
        )
        XCTAssertNotNil(
            OnboardingWindowController.presentedWindowForTests,
            "Restart Onboarding must actually put the flow on screen, in both the real app and Demo."
        )
    }

    // Was testRestartLeavesTheFlagCompleteWhenThereIsNothingToPresent, which only passed because
    // restart could not present in a demo environment — the defect itself. present is the only
    // thing that can still refuse, and refusing must never clear the flag.
    func testARefusedPresentNeverClearsTheCompletionFlag() {
        env.hasCompletedOnboarding = true

        XCTAssertNil(OnboardingWindowController.present(on: env))

        XCTAssertTrue(
            env.hasCompletedOnboarding,
            "A refused present must leave the flag complete, or every later launch re-offers onboarding with no window."
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
