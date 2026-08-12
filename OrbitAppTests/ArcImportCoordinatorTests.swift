import CryptoKit
import Foundation
import Security
import XCTest
@testable import Orbit

@MainActor
final class ArcImportCoordinatorTests: XCTestCase {

    private var scratch: URL!
    private var home: URL!
    private var defaultsSuiteName: String!
    private var testDefaults: UserDefaults!
    private var extensionStore: ExtensionStore!
    private var savedZoomDefaults: UserDefaults!

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private let devSpaceID = UUID(uuidString: "B9E3E61E-D7F1-4517-B7F7-DFED52B80134")!
    private let japanSpaceID = UUID(uuidString: "768D7694-71D7-41BD-AD09-0A2C153493C0")!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ArcImport-\(UUID().uuidString)", isDirectory: true)
        home = scratch.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        defaultsSuiteName = "OrbitTests.ArcImport.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)
        extensionStore = ExtensionStore(root: scratch.appendingPathComponent("Extensions", isDirectory: true))

        savedZoomDefaults = SiteZoomStore.defaults
        SiteZoomStore.defaults = testDefaults
    }

    override func tearDown() async throws {
        SiteZoomStore.defaults = savedZoomDefaults
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        scratch = nil
        home = nil
        testDefaults = nil
        extensionStore = nil
        try await super.tearDown()
    }

    // MARK: - Spaces

    func testArcSpacesBecomeRealOrbitSpacesWithNamesIconsAndOrder() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        let before = env.store.spaces.count

        let summary = ArcImportCoordinator.apply(
            payload,
            env: env,
            defaults: testDefaults
        )

        XCTAssertEqual(summary.spacesCreated, 2)
        XCTAssertEqual(env.store.spaces.count, before + 2, "Import must add Spaces, never replace the user's own.")

        let imported = Array(env.store.spaces.suffix(2))
        XCTAssertEqual(imported.map(\.name), ["Dev", "Japan"], "Arc's own Space order must be preserved.")

        XCTAssertEqual(imported[0].icon, "👨🏻‍💻")
        XCTAssertTrue(imported[0].iconIsEmoji)
        XCTAssertGreaterThan(imported[0].icon.unicodeScalars.count, 1, "The skin-toned ZWJ emoji collapsed to one scalar.")

        XCTAssertFalse(imported[1].iconIsEmoji)
        XCTAssertEqual(imported[1].icon, "circle.grid.2x2")
    }

    func testAnExistingSpaceNameIsNeverMergedIntoAndGetsANumberedSuffix() throws {
        env.store.createSpace(name: "Dev", activate: false)
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)

        ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)

        let names = env.store.spaces.map(\.name)
        XCTAssertEqual(names.filter { $0 == "Dev" }.count, 1, "The user's own Dev Space must not have been reused.")
        XCTAssertTrue(names.contains("Dev 2"), "A colliding Arc Space must import as a numbered sibling. Got \(names).")
    }

    // MARK: - Pinned tree

    func testPinnedTreePreservesNestingAndArcsOwnChildOrder() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)

        let japan = try XCTUnwrap(env.store.spaces.first { $0.name == "Japan" })
        let nodes = env.store.pinnedNodes(in: japan.id)

        XCTAssertEqual(nodes.count, 2)

        guard case .tab(let firstTabID) = nodes[0] else { return XCTFail("Expected a tab first, got \(nodes[0]).") }
        XCTAssertEqual(env.store.tab(firstTabID)?.title, "Skyscanner")

        guard case .folder(let folder) = nodes[1] else { return XCTFail("Expected a folder second.") }
        XCTAssertEqual(folder.name, "Good Sleep")
        XCTAssertTrue(folder.isExpanded, "An import that arrived fully collapsed would look like it imported nothing.")
        XCTAssertEqual(folder.children.count, 2)

        guard case .tab(let hotelID) = folder.children[0] else { return XCTFail("Expected a tab inside Good Sleep.") }
        XCTAssertEqual(env.store.tab(hotelID)?.title, "Booking")

        guard case .folder(let nested) = folder.children[1] else { return XCTFail("Expected a nested folder.") }
        XCTAssertEqual(nested.name, "Cheap")
        XCTAssertEqual(nested.allTabIDs.count, 1, "Third-level nesting was flattened away.")
        XCTAssertEqual(env.store.tab(nested.allTabIDs[0])?.title, "Skiplagged")
    }

    func testPinnedTabsCarryArcsTimestampsAndPinnedURLNotDateNow() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)

        let japan = try XCTUnwrap(env.store.spaces.first { $0.name == "Japan" })
        let nodes = env.store.pinnedNodes(in: japan.id)
        guard case .tab(let tabID) = nodes[0] else { return XCTFail("Expected a tab.") }
        let tab = try XCTUnwrap(env.store.tab(tabID))

        XCTAssertEqual(tab.createdAt.timeIntervalSince1970, 1678307200, accuracy: 0.001)
        XCTAssertEqual(tab.lastAccessedAt.timeIntervalSince1970, 1678310800, accuracy: 0.001)

        XCTAssertEqual(tab.section, .pinned)
        XCTAssertEqual(tab.pinnedURL, tab.url, "A pinned tab must carry its pinned URL so Cmd-reset works from first launch.")
        XCTAssertTrue(tab.isUnloaded, "Importing thousands of tabs must not materialise thousands of web views.")
    }

    func testArcsRenameBecomesCustomTitleAndAnUnrenamedTabDoesNot() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)

        let dev = try XCTUnwrap(env.store.spaces.first { $0.name == "Dev" })
        let tabs = env.store.pinnedNodes(in: dev.id).flatMap(\.allTabIDs).compactMap { env.store.tab($0) }

        let renamed = try XCTUnwrap(tabs.first { $0.customTitle != nil })
        XCTAssertEqual(renamed.customTitle, "My Linear")
        XCTAssertEqual(renamed.title, "Linear", "The page's own title must survive alongside the user's rename.")

        let untouched = try XCTUnwrap(tabs.first { $0.title == "GitHub" })
        XCTAssertNil(untouched.customTitle, "An un-renamed Arc tab must not get a permanent user-set name.")
    }

    // MARK: - Today and Archive

    func testUnpinnedContainerBecomesTodayAndArchiveItemsLandInTheirSourceSpace() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON, archive: Self.archiveJSON)
        let summary = ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)

        let dev = try XCTUnwrap(env.store.spaces.first { $0.name == "Dev" })
        let today = env.store.todayTabs(in: dev.id)
        XCTAssertEqual(today.map(\.title), ["Gmail"], "Arc's unpinned container is Today.")
        XCTAssertEqual(summary.todayTabsImported, 1)

        let devArchive = env.store.archivedTabs(in: dev.id)
        XCTAssertEqual(devArchive.map(\.title), ["OVHcloud"])
        XCTAssertEqual(devArchive[0].section, .archived)

        let archived = try XCTUnwrap(devArchive.first?.archivedAt)
        XCTAssertEqual(archived.timeIntervalSince1970, 1780746558.198084, accuracy: 0.001)

        let japan = try XCTUnwrap(env.store.spaces.first { $0.name == "Japan" })
        XCTAssertEqual(
            env.store.archivedTabs(in: japan.id).map(\.title),
            ["Jalan"],
            "An archived tab did not land in the Space Arc archived it out of."
        )
        XCTAssertEqual(devArchive.map(\.title), ["OVHcloud"], "Japan's archived tab leaked into Dev.")
        XCTAssertEqual(summary.archivedTabsImported, 2)
    }

    // MARK: - Favourites

    func testTopAppsBecomeFavouritesOnceNotOncePerSpace() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        let existing = env.store.defaultProfile.map { profile in
            env.store.spaces.first { $0.profileID == profile.id }.map { env.store.favorites(for: $0.id).count } ?? 0
        } ?? 0

        let summary = ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)

        XCTAssertEqual(summary.favoritesImported, 2)

        let dev = try XCTUnwrap(env.store.spaces.first { $0.name == "Dev" })
        let favorites = env.store.favorites(for: dev.id)
        XCTAssertEqual(
            favorites.suffix(2).map(\.title),
            ["ChatGPT", "Claude"],
            "Arc's favourites must be appended in Arc's own order. Got \(favorites.map(\.title))."
        )
        XCTAssertEqual(favorites.count, existing + 2, "Import must add favourites, not replace the user's own.")

        let japan = try XCTUnwrap(env.store.spaces.first { $0.name == "Japan" })
        XCTAssertEqual(
            env.store.favorites(for: japan.id).count,
            favorites.count,
            "Favourites were added per Space and duplicated."
        )
        XCTAssertEqual(
            env.store.favorites(for: japan.id).filter { $0.title == "ChatGPT" }.count,
            1,
            "ChatGPT was imported more than once."
        )
    }

    // MARK: - Themes

    func testGradientThemeBecomesALinearSpaceThemeWithArcsColours() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)

        let dev = try XCTUnwrap(env.store.spaces.first { $0.name == "Dev" })
        XCTAssertEqual(dev.theme.style, .linear, "Two base colours is a two-stop gradient, not a mesh.")
        XCTAssertEqual(dev.theme.colors.count, 2)
        XCTAssertEqual(dev.theme.colors[0].red, 0.4003171324729919, accuracy: 1e-9)
        XCTAssertEqual(dev.theme.colors[0].green, 0.4041288197040558, accuracy: 1e-9)
        XCTAssertEqual(dev.theme.colors[0].blue, 0.537262499332428, accuracy: 1e-9)

        XCTAssertFalse(dev.theme.followsSystemAppearance)
        XCTAssertTrue(dev.theme.prefersDarkContent)
    }

    func testASpaceWithNoWindowThemeKeepsOrbitsDefaultPalette() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)

        let japan = try XCTUnwrap(env.store.spaces.first { $0.name == "Japan" })
        XCTAssertEqual(japan.theme.colors, SpaceTheme.defaultPalette, "A themeless Arc Space must not invent colours.")
    }

    // MARK: - Settings

    func testArcsAutoArchiveThresholdBecomesTheImportProfilesArchivePolicy() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        let preferences = ArcAppPreferences(autoArchiveThreshold: .thirtyDays)

        ArcImportCoordinator.apply(
            payload,
            appPreferences: preferences,
            env: env,
            defaults: testDefaults
        )

        let dev = try XCTUnwrap(env.store.spaces.first { $0.name == "Dev" })
        XCTAssertEqual(env.store.archivePolicy(forSpace: dev.id), .after30Days,
                       "A user who set 30 days in Arc must not be dropped to 12 hours.")
        XCTAssertNil(dev.legacyArchivePolicy,
                     "The import must write the Profile's field, never the retired per-Space carrier.")
    }

    func testNoThresholdLeavesOrbitsOwnDefaultRatherThanGuessing() {
        XCTAssertEqual(ArcImportCoordinator.archivePolicy(from: nil), .after12Hours)
        XCTAssertEqual(ArcImportCoordinator.archivePolicy(from: .never), .never)
        XCTAssertEqual(ArcImportCoordinator.archivePolicy(from: .sevenDays), .after7Days)
    }

    func testPerHostZoomIsWrittenThroughAndAHostAtOneIsNotCounted() throws {
        var payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        payload.settings = ArcSettings(hostZoomLevels: [
            ArcHostZoom(host: "theapplaunchpad.com", zoomFactor: 1.5),
            ArcHostZoom(host: "example.com", zoomFactor: 1.0),
        ])

        let summary = ArcImportCoordinator.apply(
            payload,
            env: env,
            defaults: testDefaults
        )

        XCTAssertEqual(summary.zoomLevelsImported, 1, "A host already at 1.0 carries no entry and must not be counted.")
        XCTAssertEqual(SiteZoomStore.zoomFactor(forHost: "theapplaunchpad.com") ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertNil(SiteZoomStore.zoomFactor(forHost: "example.com"))
    }

    func testLinkRoutingRulesBecomeRealRoutingRulesAndPointAtTheImportedSpace() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        let preferences = ArcAppPreferences(routingRules: [
            ArcRoutingRule(arcID: UUID(), match: .contains("meet.google.com"), destination: .mostRecentSpace),
            ArcRoutingRule(arcID: UUID(), match: .contains("linear.app"), destination: .space(devSpaceID)),
            ArcRoutingRule(arcID: UUID(), match: .startsWith("github.com"), destination: .mostRecentSpace),
        ])

        let summary = ArcImportCoordinator.apply(
            payload,
            appPreferences: preferences,
            env: env,
            defaults: testDefaults
        )

        XCTAssertEqual(summary.routingRulesImported, 2, "The startsWith rule must not have been approximated.")
        XCTAssertFalse(
            env.store.state.routingRules.contains { $0.pattern == "github.com" },
            "A prefix match was turned into a host rule, which changes which links it catches."
        )

        let rules = env.store.state.routingRules
        let meet = try XCTUnwrap(rules.first { $0.pattern == "meet.google.com" })
        XCTAssertEqual(meet.destination, .mostRecentSpace)

        let dev = try XCTUnwrap(env.store.spaces.first { $0.name == "Dev" })
        let linear = try XCTUnwrap(rules.first { $0.pattern == "linear.app" })
        XCTAssertEqual(linear.destination, .space(dev.id), "An Arc space destination must be remapped to the imported Space.")
    }

    func testSearchEngineMapsOnlyWhenOrbitActuallyHasThatEngine() {
        XCTAssertEqual(ArcImportCoordinator.searchEngine(named: "Google"), .google)
        XCTAssertEqual(ArcImportCoordinator.searchEngine(named: "DuckDuckGo"), .duckDuckGo)
        XCTAssertEqual(ArcImportCoordinator.searchEngine(named: "Ecosia"), .ecosia)
        XCTAssertEqual(ArcImportCoordinator.searchEngine(named: "Microsoft Bing"), .bing)
        XCTAssertNil(ArcImportCoordinator.searchEngine(named: "Perplexity"))
        XCTAssertNil(ArcImportCoordinator.searchEngine(named: nil))
    }

    func testPermissionKindsWithoutAnOrbitEquivalentMapToNilRatherThanSomethingElse() {
        XCTAssertEqual(ArcImportCoordinator.permissionKind(.notifications), .notifications)
        XCTAssertEqual(ArcImportCoordinator.permissionKind(.camera), .camera)
        XCTAssertEqual(ArcImportCoordinator.permissionKind(.microphone), .microphone)
        XCTAssertEqual(ArcImportCoordinator.permissionKind(.geolocation), .geolocation)
        XCTAssertEqual(ArcImportCoordinator.permissionKind(.clipboardRead), .clipboardRead)
        XCTAssertNil(ArcImportCoordinator.permissionKind(.automaticDownloads))
        XCTAssertNil(ArcImportCoordinator.permissionKind(.localNetwork))
        XCTAssertNil(ArcImportCoordinator.permissionKind(.durableStorage))
    }

    func testArcAppPreferencesLandInTheDefaultsOrbitActuallyReads() throws {
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        let preferences = ArcAppPreferences(
            showsToolbar: true,
            showsFullURLs: false,
            tidyTabsEnabled: false,
            instantLinksEnabled: true,
            sidebarWidth: 279
        )

        ArcImportCoordinator.apply(
            payload,
            appPreferences: preferences,
            env: env,
            defaults: testDefaults
        )

        XCTAssertTrue(testDefaults.bool(forKey: "OrbitToolbarVisible"))
        XCTAssertFalse(testDefaults.bool(forKey: "OrbitToolbarShowsFullURL"))
        XCTAssertFalse(testDefaults.bool(forKey: "OrbitAssistTidyTabsEnabled"))
        XCTAssertTrue(testDefaults.bool(forKey: "OrbitAssistInstantLinksEnabled"))
        XCTAssertEqual(testDefaults.double(forKey: "OrbitSidebarWidth"), 279, accuracy: 0.001)
    }

    // MARK: - Extensions
    // Drives ArcImportCoordinator.performImport end to end against a realistic
    // on-disk Arc profile, with only the network call stubbed.

    func testArcExtensionsInstallByDownloadingAndVerifyingFromTheWebStoreNotByCopyingArcsDiskDirectory() async throws {
        let webStore = try buildWebStoreCRX(name: "Wappalyzer", version: "2.0", markerFile: "from-web-store.marker")
        try writeArcExtension(
            identifier: webStore.id,
            version: "1.0",
            name: "Wappalyzer (Arc's stale disk copy)",
            permissions: ["storage"],
            hostPermissions: ["https://*/*"]
        )
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        XCTAssertEqual(payload.extensions.map(\.identifier), [webStore.id], "The fixture must be read by the real ArcExtensionInventory, not hand-built.")

        let installer = makeStubbedInstaller(store: extensionStore, handler: webStoreDownloadHandler(crxBytes: webStore.crxBytes))
        var summary = ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)
        await ArcImportCoordinator.installExtensions(payload.extensions, installer: installer, store: extensionStore, summary: &summary)

        XCTAssertEqual(summary.extensionsFound, 1)
        XCTAssertEqual(summary.extensionsInstalled, 1)
        XCTAssertEqual(summary.extensionsAlreadyInstalled, 0)
        XCTAssertTrue(summary.extensionsNeedingManualInstall.isEmpty)

        let installed = try XCTUnwrap(extensionStore.installed().first)
        XCTAssertEqual(installed.id, webStore.id)
        XCTAssertEqual(
            installed.version, "2.0",
            "The installed version must be the Web Store's (2.0), not Arc's on-disk copy (1.0) — proof the disk copy was never used."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installed.directory.appendingPathComponent("from-web-store.marker").path),
            "A file that only exists in the downloaded CRX must be present in what actually landed in ExtensionStore."
        )
    }

    func testAnExtensionNoLongerOnTheWebStoreIsNamedForManualInstallNotSilentlyDropped() async throws {
        let missingID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        try writeArcExtension(identifier: missingID, version: "1.0", name: "Delisted Extension")
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)

        let installer = makeStubbedInstaller(store: extensionStore) { _ in .respond(status: 404, headers: [:], body: Data()) }
        var summary = ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)
        await ArcImportCoordinator.installExtensions(payload.extensions, installer: installer, store: extensionStore, summary: &summary)

        XCTAssertEqual(summary.extensionsFound, 1)
        XCTAssertEqual(summary.extensionsInstalled, 0)
        XCTAssertEqual(summary.extensionsNeedingManualInstall, ["Delisted Extension"])
        XCTAssertTrue(extensionStore.installed().isEmpty)
    }

    func testACorruptArcExtensionDirectoryIsSkippedNotCrashedOn() async throws {
        let webStore = try buildWebStoreCRX(name: "Good Extension", version: "1.0")
        try writeArcExtension(identifier: webStore.id, version: "1.0", name: "Good Extension")

        // Same on-disk shape Arc leaves behind for a half-written install: an id directory
        // and a version directory, but no manifest.json inside it.
        let corruptID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        try FileManager.default.createDirectory(
            at: arcExtensionsDirectory().appendingPathComponent(corruptID).appendingPathComponent("1.0_0"),
            withIntermediateDirectories: true
        )

        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        XCTAssertEqual(payload.extensions.map(\.identifier), [webStore.id], "The corrupt directory must never reach the payload.")

        let installer = makeStubbedInstaller(store: extensionStore, handler: webStoreDownloadHandler(crxBytes: webStore.crxBytes))
        var summary = ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)
        await ArcImportCoordinator.installExtensions(payload.extensions, installer: installer, store: extensionStore, summary: &summary)

        XCTAssertEqual(summary.extensionsFound, 1, "The corrupt directory must be silently skipped, not counted or crashed on.")
        XCTAssertEqual(summary.extensionsInstalled, 1)
        XCTAssertEqual(extensionStore.installed().map(\.id), [webStore.id])
    }

    func testAnExtensionAlreadyInstalledInOrbitIsCountedNotReDownloadedOrOverwritten() async throws {
        let webStore = try buildWebStoreCRX(name: "Already Here", version: "1.0")
        let (existingSourceRoot, _) = try makeUnpackedSource(name: "Already Here", version: "9.9")
        // publicKey pins the install under the Web Store id directly, so this seeds exactly the
        // id collision the coordinator will see, without depending on a path-derived id.
        _ = try extensionStore.install(unpackedAt: existingSourceRoot, publicKey: webStore.publicKeyBase64)
        XCTAssertEqual(extensionStore.installed().map(\.id), [webStore.id])

        try writeArcExtension(identifier: webStore.id, version: "1.0", name: "Already Here")
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)

        var requestWasMade = false
        let installer = makeStubbedInstaller(store: extensionStore) { request in
            requestWasMade = true
            return .respond(status: 500, headers: [:], body: Data())
        }
        var summary = ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)
        await ArcImportCoordinator.installExtensions(payload.extensions, installer: installer, store: extensionStore, summary: &summary)

        XCTAssertFalse(requestWasMade, "An id already installed must be refused before any network request, per ExtensionInstaller.")
        XCTAssertEqual(summary.extensionsFound, 1)
        XCTAssertEqual(summary.extensionsInstalled, 0)
        XCTAssertEqual(summary.extensionsAlreadyInstalled, 1)
        XCTAssertTrue(summary.extensionsNeedingManualInstall.isEmpty, "Already-installed is not a failure and must not be reported as one.")
        XCTAssertEqual(extensionStore.installed().first?.version, "9.9", "The existing install must be untouched, not silently overwritten by the import.")
    }

    func testADisabledArcExtensionInstallsButStaysDisabledInOrbit() async throws {
        let webStore = try buildWebStoreCRX(name: "Muted Extension", version: "1.0")
        try writeArcExtension(identifier: webStore.id, version: "1.0", name: "Muted Extension")
        try writeArcExtensionSecurePreferences([webStore.id: 0])
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON)
        XCTAssertEqual(payload.extensions.first?.isEnabled, false, "Fixture check: this test means nothing if Arc's disabled state was not read.")

        let installer = makeStubbedInstaller(store: extensionStore, handler: webStoreDownloadHandler(crxBytes: webStore.crxBytes))
        var summary = ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)
        await ArcImportCoordinator.installExtensions(payload.extensions, installer: installer, store: extensionStore, summary: &summary)

        XCTAssertEqual(summary.extensionsInstalled, 1)
        XCTAssertEqual(extensionStore.installed().first?.isEnabled, false, "Arc's disabled state must carry over rather than defaulting to enabled.")
    }

    // MARK: - End to end

    func testReadingRealFixtureFilesFromDiskProducesTheSameImport() throws {
        try writeArcFixtures(sidebar: Self.twoSpaceSidebarJSON, archive: Self.archiveJSON)

        let reader = BrowserDataReader(homeDirectory: home)
        XCTAssertTrue(reader.availableBrowsers().contains(.arc), "Arc must be offered when its data is present.")

        let payload = try reader.readArc()
        let summary = ArcImportCoordinator.apply(
            payload,
            env: env,
            defaults: testDefaults
        )

        XCTAssertEqual(summary.spacesCreated, 2)
        XCTAssertEqual(summary.pinnedTabsImported, 5)
        XCTAssertEqual(summary.foldersCreated, 2, "Good Sleep and its nested Cheap.")
        XCTAssertEqual(summary.todayTabsImported, 1)
        XCTAssertEqual(summary.archivedTabsImported, 2)
        XCTAssertEqual(summary.totalTabsImported, 8)

        let pinnedInDocument = env.store.spaces.reduce(0) { $0 + env.store.pinnedNodes(in: $1.id).flatMap(\.allTabIDs).count }
        XCTAssertGreaterThanOrEqual(pinnedInDocument, 5)
    }

    // MARK: - Persistence

    func testAnImportedArcSpaceSurvivesARealSaveAndReload() throws {
        let store = StateStore(rootDirectory: scratch.appendingPathComponent("State", isDirectory: true))
        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON, archive: Self.archiveJSON)
        let preferences = ArcAppPreferences(
            autoArchiveThreshold: .thirtyDays,
            routingRules: [ArcRoutingRule(arcID: UUID(), match: .contains("meet.google.com"), destination: .mostRecentSpace)]
        )

        ArcImportCoordinator.apply(
            payload,
            appPreferences: preferences,
            env: env,
            defaults: testDefaults
        )
        _ = try store.saveNow(env.store.state)

        let reloaded = try store.load()

        let dev = try XCTUnwrap(reloaded.spaces.first { $0.name == "Dev" })
        XCTAssertEqual(dev.icon, "👨🏻‍💻")
        XCTAssertTrue(dev.iconIsEmoji)
        let devProfile = try XCTUnwrap(reloaded.profiles.first { $0.id == dev.profileID })
        XCTAssertEqual(devProfile.archivePolicy, .after30Days,
                       "The imported archive cadence must survive a real save/load round trip on the Profile.")
        XCTAssertEqual(dev.theme.style, .linear)
        XCTAssertEqual(dev.theme.colors.count, 2)
        XCTAssertFalse(dev.theme.followsSystemAppearance)
        XCTAssertTrue(dev.theme.prefersDarkContent)

        let japan = try XCTUnwrap(reloaded.spaces.first { $0.name == "Japan" })
        XCTAssertEqual(japan.pinned.flatMap(\.allTabIDs).count, 3, "Japan's pinned tree did not survive the round trip.")
        XCTAssertEqual(japan.pinned.count, 2, "The folder structure was flattened by persistence.")

        XCTAssertTrue(
            reloaded.routingRules.contains { $0.pattern == "meet.google.com" },
            "Arc's routing rule did not persist."
        )
        for space in [dev, japan] {
            for tabID in space.pinned.flatMap(\.allTabIDs) + space.today {
                XCTAssertNotNil(reloaded.tabs[tabID], "Imported tab \(tabID) was lost on save.")
            }
        }
    }

    func testAStateDocumentWithoutTheOptionalKeysThisImportWritesStillLoads() throws {
        let root = scratch.appendingPathComponent("BackCompatState", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = StateStore(rootDirectory: root)

        let payload = try readFixture(sidebar: Self.twoSpaceSidebarJSON, archive: Self.archiveJSON)
        ArcImportCoordinator.apply(payload, env: env, defaults: testDefaults)
        let url = try store.saveNow(env.store.state)

        var document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )

        let rawTabs = try XCTUnwrap(document["tabs"] as? [Any], "tabs was not a JSON array.")
        XCTAssertEqual(rawTabs.count % 2, 0, "A UUID-keyed dictionary must encode as alternating key/value pairs.")
        XCTAssertFalse(rawTabs.isEmpty, "The import wrote no tabs, so this test would prove nothing.")

        let optionalKeys = ["pinnedURL", "pinnedTitle", "archivedAt", "customTitle", "faviconURL", "zoomFactor"]

        var strippedTabs: [Any] = []
        var sawPinnedURL = false
        var sawArchivedAt = false
        for (index, element) in rawTabs.enumerated() {
            guard index % 2 == 1, var tab = element as? [String: Any] else {
                strippedTabs.append(element)
                continue
            }
            if tab["pinnedURL"] != nil { sawPinnedURL = true }
            if tab["archivedAt"] != nil { sawArchivedAt = true }
            for key in optionalKeys { tab.removeValue(forKey: key) }
            strippedTabs.append(tab)
        }

        XCTAssertTrue(sawPinnedURL, "The import wrote no pinnedURL at all, so this test would prove nothing.")
        XCTAssertTrue(sawArchivedAt, "The import wrote no archivedAt at all, so this test would prove nothing.")

        var spaces = try XCTUnwrap(document["spaces"] as? [[String: Any]])
        for index in spaces.indices {
            spaces[index].removeValue(forKey: "pinnedSectionCollapsed")
            spaces[index].removeValue(forKey: "ephemeral")
        }
        document["tabs"] = strippedTabs
        document["spaces"] = spaces
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url)

        let rewritten = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let rewrittenTabs = try XCTUnwrap(rewritten["tabs"] as? [Any])
        XCTAssertEqual(rewrittenTabs.count, rawTabs.count)
        for (index, element) in rewrittenTabs.enumerated() {
            guard index % 2 == 1, let tab = element as? [String: Any] else { continue }
            for key in optionalKeys {
                XCTAssertNil(tab[key], "\(key) was not actually stripped.")
            }
        }

        let reloaded = try store.load()

        XCTAssertEqual(reloaded.tabs.count, rawTabs.count / 2, "A document missing these optional keys failed to load.")
        XCTAssertEqual(reloaded.spaces.count, spaces.count)
        for tab in reloaded.tabs.values {
            XCTAssertNil(tab.pinnedURL, "A missing optional must default to nil, not fail the load.")
            XCTAssertNil(tab.archivedAt)
            XCTAssertNil(tab.customTitle)
        }
        for space in reloaded.spaces {
            XCTAssertFalse(space.isPinnedSectionCollapsed)
            XCTAssertFalse(space.isEphemeral)
        }

        let japan = try XCTUnwrap(reloaded.spaces.first { $0.name == "Japan" })
        XCTAssertEqual(japan.pinned.flatMap(\.allTabIDs).count, 3)
        XCTAssertEqual(japan.pinned.count, 2, "The folder structure did not survive.")
    }

    func testAnEmptyHomeDirectoryDoesNotOfferArc() {
        XCTAssertFalse(ImportableBrowser.arc.isPresent(homeDirectory: home))
        XCTAssertFalse(BrowserDataReader(homeDirectory: home).availableBrowsers().contains(.arc))
    }

    // MARK: - Fixtures

    private func readFixture(sidebar: String, archive: String? = nil) throws -> ArcImportPayload {
        try writeArcFixtures(sidebar: sidebar, archive: archive)
        return try ArcImportReader.read(homeDirectory: home)
    }

    private func writeArcFixtures(sidebar: String, archive: String? = nil) throws {
        let root = home.appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(sidebar.utf8).write(to: root.appendingPathComponent("StorableSidebar.json"))
        if let archive {
            try Data(archive.utf8).write(to: root.appendingPathComponent("StorableArchiveItems.json"))
        }
    }

    // Arc's real on-disk shape: Extensions/<id>/<version>_0/manifest.json under the Chromium
    // profile directory, read back by the real ArcExtensionInventory (not hand-built).
    private func arcExtensionsDirectory() -> URL {
        ArcImportReader.chromiumProfileDirectory(homeDirectory: home).appendingPathComponent("Extensions", isDirectory: true)
    }

    @discardableResult
    private func writeArcExtension(
        identifier: String,
        version: String,
        name: String,
        permissions: [String] = [],
        hostPermissions: [String] = []
    ) throws -> URL {
        let directory = arcExtensionsDirectory()
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("\(version)_0", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var manifest: [String: Any] = ["manifest_version": 3, "name": name, "version": version]
        if !permissions.isEmpty { manifest["permissions"] = permissions }
        if !hostPermissions.isEmpty { manifest["host_permissions"] = hostPermissions }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }

    private func writeArcExtensionSecurePreferences(_ states: [String: Int]) throws {
        let settings = states.mapValues { ["state": $0] }
        let object: [String: Any] = ["extensions": ["settings": settings]]
        try JSONSerialization.data(withJSONObject: object, options: [])
            .write(to: ArcImportReader.chromiumProfileDirectory(homeDirectory: home).appendingPathComponent("Secure Preferences"))
    }

    private static let twoSpaceSidebarJSON = """
    {
      "version": 1,
      "sidebar": { "containers": [
        { "global": {} },
        {
          "topAppsContainerIDs": [ { "default": true }, "C0000000-0000-0000-0000-0000000000FF" ],
          "spaces": [
            "B9E3E61E-D7F1-4517-B7F7-DFED52B80134",
            {
              "id": "B9E3E61E-D7F1-4517-B7F7-DFED52B80134",
              "title": "Dev",
              "profile": { "default": true },
              "containerIDs": ["pinned", "C0000000-0000-0000-0000-000000000001",
                               "unpinned", "C0000000-0000-0000-0000-000000000002"],
              "customInfo": {
                "iconType": { "emoji": 11036, "emoji_v2": "\\ud83d\\udc68\\ud83c\\udffb\\u200d\\ud83d\\udcbb" },
                "windowTheme": {
                  "background": { "single": { "_0": {
                    "contentOverBackgroundAppearance": "dark",
                    "isVibrant": true,
                    "style": { "color": { "_0": { "blendedGradient": { "_0": {
                      "baseColors": [
                        { "colorSpace": "extendedSRGB", "red": 0.4003171324729919, "green": 0.4041288197040558, "blue": 0.537262499332428, "alpha": 1 },
                        { "colorSpace": "extendedSRGB", "red": 0.4980021119117737, "green": 0.3971371650695801, "blue": 0.5361828207969666, "alpha": 1 }
                      ],
                      "overlayColors": [],
                      "modifiers": { "overlay": "grain", "noiseFactor": 0.5, "intensityFactor": 1 }
                    } } } } }
                  } } }
                }
              }
            },
            "768D7694-71D7-41BD-AD09-0A2C153493C0",
            {
              "id": "768D7694-71D7-41BD-AD09-0A2C153493C0",
              "title": "Japan",
              "profile": { "default": true },
              "containerIDs": ["pinned", "C0000000-0000-0000-0000-000000000003",
                               "unpinned", "C0000000-0000-0000-0000-000000000004"],
              "customInfo": {}
            }
          ],
          "items": [
            "C0000000-0000-0000-0000-000000000001",
            { "id": "C0000000-0000-0000-0000-000000000001", "parentID": null, "title": null,
              "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "B9E3E61E-D7F1-4517-B7F7-DFED52B80134" } } } },
              "childrenIds": ["70000000-0000-0000-0000-000000000001",
                              "70000000-0000-0000-0000-000000000002"] },

            "C0000000-0000-0000-0000-000000000002",
            { "id": "C0000000-0000-0000-0000-000000000002", "parentID": null, "title": null,
              "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "B9E3E61E-D7F1-4517-B7F7-DFED52B80134" } } } },
              "childrenIds": ["70000000-0000-0000-0000-000000000003"] },

            "C0000000-0000-0000-0000-000000000003",
            { "id": "C0000000-0000-0000-0000-000000000003", "parentID": null, "title": null,
              "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "768D7694-71D7-41BD-AD09-0A2C153493C0" } } } },
              "childrenIds": ["70000000-0000-0000-0000-000000000004",
                              "F0000000-0000-0000-0000-000000000001"] },

            "C0000000-0000-0000-0000-000000000004",
            { "id": "C0000000-0000-0000-0000-000000000004", "parentID": null, "title": null,
              "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "768D7694-71D7-41BD-AD09-0A2C153493C0" } } } },
              "childrenIds": [] },

            "C0000000-0000-0000-0000-0000000000FF",
            { "id": "C0000000-0000-0000-0000-0000000000FF", "parentID": null, "title": null,
              "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "itemContainer": { "containerType": { "topApps": { "_0": { "default": true } } } } },
              "childrenIds": ["A0000000-0000-0000-0000-000000000001",
                              "A0000000-0000-0000-0000-000000000002"] },

            "70000000-0000-0000-0000-000000000001",
            { "id": "70000000-0000-0000-0000-000000000001", "parentID": "C0000000-0000-0000-0000-000000000001",
              "title": "My Linear", "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "tab": { "savedURL": "https://linear.app/inbox", "savedTitle": "Linear",
                                 "savedMuteStatus": "allowAudio", "timeLastActiveAt": 700003600.0 } },
              "childrenIds": [] },

            "70000000-0000-0000-0000-000000000002",
            { "id": "70000000-0000-0000-0000-000000000002", "parentID": "C0000000-0000-0000-0000-000000000001",
              "title": null, "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "tab": { "savedURL": "https://github.com/", "savedTitle": "GitHub",
                                 "savedMuteStatus": "allowAudio" } },
              "childrenIds": [] },

            "70000000-0000-0000-0000-000000000003",
            { "id": "70000000-0000-0000-0000-000000000003", "parentID": "C0000000-0000-0000-0000-000000000002",
              "title": null, "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "tab": { "savedURL": "https://mail.google.com/", "savedTitle": "Gmail",
                                 "savedMuteStatus": "allowAudio" } },
              "childrenIds": [] },

            "70000000-0000-0000-0000-000000000004",
            { "id": "70000000-0000-0000-0000-000000000004", "parentID": "C0000000-0000-0000-0000-000000000003",
              "title": null, "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "tab": { "savedURL": "https://www.skyscanner.net/", "savedTitle": "Skyscanner",
                                 "savedMuteStatus": "allowAudio", "timeLastActiveAt": 700003600.0 } },
              "childrenIds": [] },

            "F0000000-0000-0000-0000-000000000001",
            { "id": "F0000000-0000-0000-0000-000000000001", "parentID": "C0000000-0000-0000-0000-000000000003",
              "title": "Good Sleep", "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "list": {} },
              "childrenIds": ["70000000-0000-0000-0000-000000000005",
                              "F0000000-0000-0000-0000-000000000002"] },

            "70000000-0000-0000-0000-000000000005",
            { "id": "70000000-0000-0000-0000-000000000005", "parentID": "F0000000-0000-0000-0000-000000000001",
              "title": null, "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "tab": { "savedURL": "https://www.booking.com/", "savedTitle": "Booking",
                                 "savedMuteStatus": "allowAudio" } },
              "childrenIds": [] },

            "F0000000-0000-0000-0000-000000000002",
            { "id": "F0000000-0000-0000-0000-000000000002", "parentID": "F0000000-0000-0000-0000-000000000001",
              "title": "Cheap", "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "list": {} },
              "childrenIds": ["70000000-0000-0000-0000-000000000006"] },

            "70000000-0000-0000-0000-000000000006",
            { "id": "70000000-0000-0000-0000-000000000006", "parentID": "F0000000-0000-0000-0000-000000000002",
              "title": null, "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "tab": { "savedURL": "https://skiplagged.com/", "savedTitle": "Skiplagged",
                                 "savedMuteStatus": "allowAudio" } },
              "childrenIds": [] },

            "A0000000-0000-0000-0000-000000000001",
            { "id": "A0000000-0000-0000-0000-000000000001", "parentID": "C0000000-0000-0000-0000-0000000000FF",
              "title": null, "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "tab": { "savedURL": "https://chatgpt.com/", "savedTitle": "ChatGPT",
                                 "savedMuteStatus": "allowAudio" } },
              "childrenIds": [] },

            "A0000000-0000-0000-0000-000000000002",
            { "id": "A0000000-0000-0000-0000-000000000002", "parentID": "C0000000-0000-0000-0000-0000000000FF",
              "title": null, "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
              "data": { "tab": { "savedURL": "https://claude.ai/new", "savedTitle": "Claude",
                                 "savedMuteStatus": "allowAudio" } },
              "childrenIds": [] }
          ]
        }
      ] }
    }
    """

    private static let archiveJSON = """
    {
      "version": 1,
      "items": [
        "94C6C5FC-D8A6-4B20-B3FD-D906472D844F",
        {
          "sidebarItem": {
            "id": "94C6C5FC-D8A6-4B20-B3FD-D906472D844F",
            "parentID": null, "title": null,
            "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
            "data": { "tab": { "savedURL": "https://www.ovhcloud.com/en-gb/bare-metal/prices/",
                               "savedTitle": "OVHcloud", "savedMuteStatus": "allowAudio" } },
            "childrenIds": []
          },
          "reason": "manual",
          "archivedAt": 802439358.198084,
          "source": { "space": { "_0": "B9E3E61E-D7F1-4517-B7F7-DFED52B80134" } }
        },
        "94C6C5FC-D8A6-4B20-B3FD-D906472D8450",
        {
          "sidebarItem": {
            "id": "94C6C5FC-D8A6-4B20-B3FD-D906472D8450",
            "parentID": null, "title": null,
            "createdAt": 700000000.0, "isUnread": false, "originatingDevice": "D",
            "data": { "tab": { "savedURL": "https://www.jalan.net/",
                               "savedTitle": "Jalan", "savedMuteStatus": "allowAudio" } },
            "childrenIds": []
          },
          "reason": "timeout",
          "archivedAt": 802439300.0,
          "source": { "space": { "_0": "768D7694-71D7-41BD-AD09-0A2C153493C0" } }
        }
      ]
    }
    """

    // MARK: - Chrome Web Store stub (mirrors OrbitTests/ExtensionInstallerTests.swift's harness)

    private static let downloadBlobURL = URL(string: "https://clients2.googleusercontent.com/crx/blobs/fixture.crx")!

    private func makeStubbedInstaller(
        store: ExtensionStore,
        handler: @escaping (URLRequest) -> ArcImportExtensionStubURLProtocol.Script
    ) -> ExtensionInstaller {
        ArcImportExtensionStubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArcImportExtensionStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return ExtensionInstaller(store: store, client: ChromeWebStoreClient(session: session, prodVersion: "151")) { _ in true }
    }

    private func webStoreDownloadHandler(crxBytes: Data) -> (URLRequest) -> ArcImportExtensionStubURLProtocol.Script {
        { request in
            guard let url = request.url else { return .respond(status: 400, headers: [:], body: Data()) }
            if url.host == Self.downloadBlobURL.host {
                return .respond(status: 200, headers: ["Content-Type": "application/x-chrome-extension"], body: crxBytes)
            }
            if url.query?.contains("response=redirect") == true {
                return .redirect(to: Self.downloadBlobURL)
            }
            return .respond(status: 404, headers: [:], body: Data())
        }
    }

    // An unpacked source tree, zipped, then signed into a real CRX3 container — the exact
    // shape ExtensionInstaller downloads, verifies and stages in production.
    private func buildWebStoreCRX(
        name: String,
        version: String,
        markerFile: String? = nil
    ) throws -> (crxBytes: Data, id: String, publicKeyBase64: String) {
        let (sourceRoot, entries) = try makeUnpackedSource(name: name, version: version, markerFile: markerFile)
        let zipData = try zipDirectory(root: sourceRoot, entries: entries)
        let built = try ArcImportCRXFixture.build(zipPayload: zipData)
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: built.publicKeyBase64))
        return (built.bytes, id, built.publicKeyBase64)
    }

    private func makeUnpackedSource(
        name: String,
        version: String,
        markerFile: String? = nil
    ) throws -> (root: URL, entries: [String]) {
        let root = scratch.appendingPathComponent("WebStoreSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let manifest: [String: Any] = ["name": name, "version": version, "manifest_version": 3]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("manifest.json"))
        var entries = ["manifest.json"]

        if let markerFile {
            try Data("proof this came from the Web Store download, not Arc's disk copy".utf8)
                .write(to: root.appendingPathComponent(markerFile))
            entries.append(markerFile)
        }
        return (root, entries)
    }

    private func zipDirectory(root: URL, entries: [String]) throws -> Data {
        let archiveURL = scratch.appendingPathComponent("WebStoreZip-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", archiveURL.path] + entries
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "/usr/bin/zip failed to build the test fixture archive.")
        return try Data(contentsOf: archiveURL)
    }
}

// MARK: - StubURLProtocol

private final class ArcImportExtensionStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Script {
        case respond(status: Int, headers: [String: String], body: Data)
        case redirect(to: URL)
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Script)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ArcImportExtensionStubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch handler(request) {
        case .redirect(let redirectURL):
            let redirectRequest = URLRequest(url: redirectURL)
            let redirectResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectURL.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: redirectResponse)
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - A minimal, self-contained CRX3 fixture (mirrors OrbitTests/CRX3ArchiveTests.swift's CRX3TestFixture)

/// A CRX3 container built entirely in-process with a real RSA keypair, assembled byte-for-byte the way CRX3Archive.parse(_:) expects to read it back.
private enum ArcImportCRXFixture {
    enum FixtureError: Error {
        case keyGenerationFailed(String)
        case exportFailed(String)
        case signingFailed(String)
    }

    struct BuiltCRX {
        let bytes: Data
        let publicKeyBase64: String
    }

    static func build(zipPayload: Data) throws -> BuiltCRX {
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var generationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &generationError) else {
            throw FixtureError.keyGenerationFailed(cfErrorDescription(generationError))
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw FixtureError.keyGenerationFailed("SecKeyCopyPublicKey returned nil.")
        }

        var exportError: Unmanaged<CFError>?
        guard let pkcs1DER = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw FixtureError.exportFailed(cfErrorDescription(exportError))
        }
        let spki = wrapAsSubjectPublicKeyInfo(pkcs1DER: pkcs1DER)

        let crxID = Data(SHA256.hash(data: spki).prefix(16))
        let signedHeaderData = lengthDelimitedField(1, crxID)

        var signedPayload = Data("CRX3 SignedData\u{0}".utf8)
        signedPayload.append(uint32LE(UInt32(signedHeaderData.count)))
        signedPayload.append(signedHeaderData)
        signedPayload.append(zipPayload)

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, signedPayload as CFData, &signingError
        ) as Data? else {
            throw FixtureError.signingFailed(cfErrorDescription(signingError))
        }

        let proofBytes = lengthDelimitedField(1, spki) + lengthDelimitedField(2, signature)
        // signed_header_data is field 10000, not field 4 (verified_contents).
        let headerBytes = lengthDelimitedField(2, proofBytes) + lengthDelimitedField(10000, signedHeaderData)

        var bytes = Data([0x43, 0x72, 0x32, 0x34]) // "Cr24"
        bytes.append(uint32LE(3))
        bytes.append(uint32LE(UInt32(headerBytes.count)))
        bytes.append(headerBytes)
        bytes.append(zipPayload)

        return BuiltCRX(bytes: bytes, publicKeyBase64: spki.base64EncodedString())
    }

    private static func wrapAsSubjectPublicKeyInfo(pkcs1DER: Data) -> Data {
        let rsaEncryptionOID = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        let oid = derTLV(tag: 0x06, content: rsaEncryptionOID)
        let null = derTLV(tag: 0x05, content: Data())
        let algorithmIdentifier = derTLV(tag: 0x30, content: oid + null)
        var bitStringContent = Data([0x00])
        bitStringContent.append(pkcs1DER)
        let bitString = derTLV(tag: 0x03, content: bitStringContent)
        return derTLV(tag: 0x30, content: algorithmIdentifier + bitString)
    }

    private static func derTLV(tag: UInt8, content: Data) -> Data {
        var result = Data([tag])
        result.append(derLength(content.count))
        result.append(content)
        return result
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var magnitudeBytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            magnitudeBytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(magnitudeBytes.count)] + magnitudeBytes)
    }

    private static func varintBytes(_ value: UInt64) -> Data {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return Data(bytes)
    }

    private static func lengthDelimitedField(_ fieldNumber: Int, _ value: Data) -> Data {
        let tag = UInt64((fieldNumber << 3) | 0x2)
        var result = varintBytes(tag)
        result.append(varintBytes(UInt64(value.count)))
        result.append(value)
        return result
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        var littleEndianValue = value.littleEndian
        return Data(bytes: &littleEndianValue, count: MemoryLayout<UInt32>.size)
    }

    private static func cfErrorDescription(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "Security.framework did not provide a reason." }
        return (error.takeRetainedValue() as Error).localizedDescription
    }
}
