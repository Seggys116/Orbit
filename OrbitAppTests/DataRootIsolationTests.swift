//  Proves no demo/test run resolves a store onto ~/Library/Application Support/Orbit
//  and pruneOrphaned only deletes inside its own store; every write here goes to scratch.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class DataRootIsolationTests: XCTestCase {

    // Chromium's own directory is excluded: it is the engine's, it runs to
    // hundreds of thousands of entries, and EngineStorageDirectoryTests covers it.
    private static let watchedSubdirectories = [
        "State", "SpaceIcons", "Favicons", "Extensions", "Downloads",
        "Boosts", "Notes", "Easels", "SiteSearch", "History", "Sync", "ContentBlocking",
    ]

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var scratchRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DataRootIsolationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchRoot, FileManager.default.fileExists(atPath: scratchRoot.path) {
            try FileManager.default.removeItem(at: scratchRoot)
        }
        scratchRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Production paths

    func testProductionRootResolvesToExactlyThePathsTheShippingBrowserUses() {
        let base = NSHomeDirectory() + "/Library/Application Support/Orbit"
        let root = OrbitDataRoot.production

        XCTAssertEqual(root.url.path, base)
        XCTAssertEqual(root.state.path, base + "/State")
        XCTAssertEqual(root.notes.path, base + "/Notes")
        XCTAssertEqual(root.easels.path, base + "/Easels")
        XCTAssertEqual(root.spaceIcons.path, base + "/SpaceIcons")
        XCTAssertEqual(root.favicons.path, base + "/Favicons")
        XCTAssertEqual(root.extensions.path, base + "/Extensions")
        XCTAssertEqual(root.contentBlocking.path, base + "/ContentBlocking")
        XCTAssertEqual(root.sync.path, base + "/Sync")
        XCTAssertEqual(root.chromiumProfile.path, base + "/Chromium")
        XCTAssertEqual(root.downloadsFile.path, base + "/Downloads/downloads.json")
        XCTAssertEqual(root.boostsFile.path, base + "/Boosts/boosts.json")
        XCTAssertEqual(root.siteSearchFile.path, base + "/SiteSearch/site-search.json")
        XCTAssertEqual(root.historyDatabase.path, base + "/History/history.sqlite3")
    }

    func testProductionRootMatchesTheEnginesOwnProfileDirectory() {
        XCTAssertEqual(
            OrbitDataRoot.production.url.path,
            EngineStorageDirectory.productionProfile.path,
            "the Swift stores and the engine must agree on what the real profile is, or a reset clears half of it"
        )
    }

    // MARK: - Nothing reachable from a test run resolves onto the real profile

    func testProcessDefaultRootIsScratchUnderXCTest() {
        XCTAssertFalse(
            OrbitDataRoot.processDefault.isProduction,
            "a process hosting a test bundle must never hand a store the real profile"
        )
        assertOutsideTheRealProfile(OrbitDataRoot.processDefault.url, what: "the process default root")
    }

    func testTheEnginesPersistentProfileResolvesOutsideTheRealProfile() throws {
        let directory = try XCTUnwrap(
            EngineStorageDirectory.directory(for: .persistent),
            "nil leaves the engine on DefaultOrbitUserDataDir(), which is the real user's profile"
        )
        assertOutsideTheRealProfile(directory, what: "the engine's persistent profile")
    }

    func testOrbitDefaultsIsItsOwnPreferencesDomainUnderXCTest() {
        XCTAssertFalse(
            OrbitDefaults.standard === UserDefaults.standard,
            "a process hosting a test bundle was handed the real browser's preferences domain"
        )

        let key = "DataRootIsolationProbe-\(UUID().uuidString)"
        OrbitDefaults.standard.set("scoped", forKey: key)
        defer { OrbitDefaults.standard.removeObject(forKey: key) }

        XCTAssertEqual(OrbitDefaults.standard.string(forKey: key), "scoped", "the scoped domain did not keep its own write")
        XCTAssertNil(
            UserDefaults.standard.object(forKey: key),
            "a write through OrbitDefaults landed in the real user's preferences"
        )
    }

    func testTheRealPreferencesAreNotReadableThroughOrbitDefaultsUnderXCTest() {
        let key = "DataRootIsolationInboundProbe-\(UUID().uuidString)"
        UserDefaults.standard.set("real-preferences-probe", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: key),
            "real-preferences-probe",
            "the probe never reached the real domain, so the assertion below would pass for the wrong reason"
        )
        XCTAssertNil(
            OrbitDefaults.standard.object(forKey: key),
            "the scoped suite read a value out of the real browser's own preferences — a scoped run must be excluded in both directions, or it inherits settings it can then overwrite"
        )
    }

    func testEveryStoreDefaultResolvesOutsideTheRealProfile() {
        let defaults: [(String, URL)] = [
            ("StateStore", StateStore.defaultRootDirectory()),
            ("DownloadStore", DownloadStore.defaultFileURL),
            ("BoostStore", BoostStore.defaultFileURL),
            ("NoteStore", NoteStore.defaultDirectory),
            ("EaselStore", EaselStore.defaultDirectory),
            ("SiteSearchStore", SiteSearchStore.defaultFileURL),
            ("HistoryStore", HistoryStore.defaultDatabaseURL),
            ("SpaceIconImageStore", SpaceIconImageStore.defaultDiskDirectory),
            ("FaviconCache", FaviconCache.defaultDiskDirectory),
            ("ExtensionStore", ExtensionStore.defaultRoot()),
            ("FilterListStore", FilterListStore.defaultDirectory()),
        ]
        for (name, url) in defaults {
            assertOutsideTheRealProfile(url, what: "\(name)'s default path")
        }
    }

    func testTheSharedEnvironmentUnderXCTestOwnsNoRealProfilePath() {
        let shared = AppEnvironment.shared
        XCTAssertFalse(shared.dataRoot.isProduction)
        assertOutsideTheRealProfile(shared.spaceIconImages.diskDirectory, what: "AppEnvironment.shared's Space icons")
        assertOutsideTheRealProfile(shared.faviconCache.diskDirectory, what: "AppEnvironment.shared's favicons")
        assertOutsideTheRealProfile(shared.extensionStore.root, what: "AppEnvironment.shared's extensions")
    }

    func testADemoEnvironmentOwnsNoRealProfilePath() {
        XCTAssertFalse(env.dataRoot.isProduction)
        assertOutsideTheRealProfile(env.dataRoot.url, what: "the demo environment's root")
        assertOutsideTheRealProfile(env.spaceIconImages.diskDirectory, what: "the demo environment's Space icons")
        assertOutsideTheRealProfile(env.faviconCache.diskDirectory, what: "the demo environment's favicons")
        assertOutsideTheRealProfile(env.extensionStore.root, what: "the demo environment's extensions")
    }

    // MARK: - Exercising the stores leaves the real profile byte-identical

    func testExercisingADemoEnvironmentsStoresTouchesNothingInTheRealProfile() throws {
        try requireScoped(env)

        let before = realProfileSnapshot()
        try exerciseEveryStore(of: env)
        let after = realProfileSnapshot()

        assertSnapshotsMatch(before, after)
    }

    func testPruningFromADemoEnvironmentTouchesNothingInTheRealProfile() throws {
        try requireScoped(env)

        // The exact call AppEnvironment.startEngineIfNeeded() makes at
        // launch; before the stores were scoped this deleted every Space icon the real browser owned.
        let before = realProfileSnapshot()
        env.spaceIconImages.pruneOrphaned(keeping: Set(env.state.spaces.compactMap(\.iconImageID)))
        let after = realProfileSnapshot()

        assertSnapshotsMatch(before, after)
    }

    // MARK: - pruneOrphaned stays inside the store it belongs to

    func testPruneOrphanedDeletesOrphansInItsOwnDirectoryAndNeverAnothers() throws {
        let mineDirectory = scratchRoot.appendingPathComponent("mine", isDirectory: true)
        let theirsDirectory = scratchRoot.appendingPathComponent("theirs", isDirectory: true)
        let mine = SpaceIconImageStore(diskDirectory: mineDirectory)
        let theirs = SpaceIconImageStore(diskDirectory: theirsDirectory)

        let png = try makeProbePNGData()
        let keptByMe = try mine.importImage(data: png, sourceExtension: "png")
        let orphanOfMine = try mine.importImage(data: png, sourceExtension: "png")
        let theirOnly = try theirs.importImage(data: png, sourceExtension: "png")

        mine.pruneOrphaned(keeping: [keptByMe])

        XCTAssertNotNil(mine.cachedImage(for: keptByMe), "a live id must survive its own store's prune")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mineDirectory.appendingPathComponent("\(orphanOfMine.uuidString).png").path),
            "pruning must still delete orphans — it is real garbage collection, not a no-op"
        )
        XCTAssertNotNil(
            theirs.cachedImage(for: theirOnly),
            "one environment's prune deleted another environment's icon — the exact failure scoping the store exists to prevent"
        )
    }

    // MARK: - A window-scoped environment shares, never duplicates

    func testAWindowScopedEnvironmentSharesItsHostsStores() throws {
        let host = env
        let spaceID = try XCTUnwrap(host.state.spaces.first?.id)
        let scoped = AppEnvironment.makeWindowScoped(sharing: host, activeSpaceID: spaceID)

        XCTAssertEqual(scoped.dataRoot, host.dataRoot)
        XCTAssertTrue(scoped.spaceIconImages === host.spaceIconImages)
        XCTAssertTrue(scoped.faviconCache === host.faviconCache)
        XCTAssertTrue(scoped.extensionStore === host.extensionStore)
    }

    // MARK: - Helpers

    private var realProfile: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Orbit", isDirectory: true)
    }

    /// Fails rather than skips: a store still rooted in the real profile is
    /// the bug. Every caller returns without writing when this throws, so an unscoped build isn't damaged.
    private func requireScoped(_ env: AppEnvironment) throws {
        let directories = [env.spaceIconImages.diskDirectory, env.faviconCache.diskDirectory, env.extensionStore.root]
        for directory in directories where isInsideTheRealProfile(directory) {
            XCTFail("\(directory.path) is inside the real profile — refusing to write or prune through it")
            throw XCTSkip("environment is not scoped away from the real profile")
        }
    }

    private func isInsideTheRealProfile(_ url: URL) -> Bool {
        let profile = realProfile.resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        return resolved == profile || resolved.hasPrefix(profile + "/")
    }

    private func assertOutsideTheRealProfile(_ url: URL, what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            isInsideTheRealProfile(url),
            "\(what) resolves to \(url.path), inside the real user's profile",
            file: file,
            line: line
        )
    }

    private struct Entry: Equatable {
        var path: String
        var size: Int
        var modified: Date?
    }

    private func realProfileSnapshot() -> [Entry] {
        var entries: [Entry] = []
        for name in Self.watchedSubdirectories {
            let directory = realProfile.appendingPathComponent(name, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: []
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                entries.append(Entry(path: url.path, size: values?.fileSize ?? 0, modified: values?.contentModificationDate))
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func assertSnapshotsMatch(_ before: [Entry], _ after: [Entry], file: StaticString = #filePath, line: UInt = #line) {
        let beforePaths = Set(before.map(\.path))
        let afterPaths = Set(after.map(\.path))
        XCTAssertTrue(
            afterPaths.subtracting(beforePaths).isEmpty,
            "new entries appeared in the real profile: \(afterPaths.subtracting(beforePaths).sorted())",
            file: file, line: line
        )
        XCTAssertTrue(
            beforePaths.subtracting(afterPaths).isEmpty,
            "entries were deleted from the real profile: \(beforePaths.subtracting(afterPaths).sorted())",
            file: file, line: line
        )
        XCTAssertEqual(before, after, "an entry in the real profile changed size or modification date", file: file, line: line)
    }

    private func exerciseEveryStore(of env: AppEnvironment) throws {
        let png = try makeProbePNGData()

        _ = try env.spaceIconImages.importImage(data: png, sourceExtension: "png")
        env.faviconCache.cache(try XCTUnwrap(NSImage(data: png)), forHost: "data-root-isolation.invalid")

        let unpacked = scratchRoot.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Data(#"{"name":"Isolation Probe","version":"1.0","manifest_version":3}"#.utf8)
            .write(to: unpacked.appendingPathComponent("manifest.json"))
        _ = try env.extensionStore.install(unpackedAt: unpacked, publicKey: nil)

        _ = env.noteStore.createNote(title: "Isolation probe")
        _ = env.boostStore.createBoost(name: "Isolation probe", host: "example.com")
        _ = env.siteSearchStore.createEngine(name: "Probe", shortcut: "probe", urlTemplate: "https://example.com?q=%s")
        try env.store.saveNow()
    }

    private func makeProbePNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
