import XCTest

final class SiteDataImportTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-SiteData-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    // MARK: - LevelDB

    func testWrittenDatabaseReadsBackEveryRecord() throws {
        let records = [
            record("VERSION", "1"),
            record("META:https://excalidraw.com", "\u{8}\u{1}"),
            record("_https://excalidraw.com\u{0}\u{1}excalidraw", "[{\"type\":\"rectangle\"}]"),
            record("_https://excalidraw.com\u{0}\u{1}excalidraw-theme", "dark"),
        ]
        let directory = root.appendingPathComponent("leveldb", isDirectory: true)

        let writer = try LevelDBWriter(directory: directory)
        try writer.append(records)
        try writer.finish()

        XCTAssertEqual(try LevelDBReader.readAll(directory: directory), records.sorted { $0.key.lexicographicallyPrecedes($1.key) })
    }

    /// A value spanning LevelDB's 32 KB log blocks must be fragmented or it is unrecoverable.
    func testAValueLargerThanALogBlockSurvivesTheRoundTrip() throws {
        let large = String(repeating: "excalidraw scene ", count: 20_000)
        let records = [record("_https://excalidraw.com\u{0}\u{1}scene", large)]
        let directory = root.appendingPathComponent("leveldb", isDirectory: true)

        let writer = try LevelDBWriter(directory: directory)
        try writer.append(records)
        try writer.finish()

        let read = try LevelDBReader.readAll(directory: directory)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.value.count, Data(large.utf8).count)
        XCTAssertEqual(read.first, records.first)
    }

    func testTheWrittenDatabaseHasTheThreeFilesLevelDBRecoversFrom() throws {
        let directory = root.appendingPathComponent("leveldb", isDirectory: true)
        let writer = try LevelDBWriter(directory: directory)
        try writer.append([record("VERSION", "1")])
        try writer.finish()

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(names, ["CURRENT", "MANIFEST-000001", "000003.log"])
        let current = try String(contentsOf: directory.appendingPathComponent("CURRENT"), encoding: .utf8)
        XCTAssertEqual(current, "MANIFEST-000001\n")
    }

    // MARK: - Storage keys

    func testStorageKeysAreReadFromEveryKeyShapeChromiumWrites() {
        XCTAssertEqual(LocalStorageKey.storageKey(of: data("_https://excalidraw.com\u{0}\u{1}theme")), "https://excalidraw.com")
        XCTAssertEqual(LocalStorageKey.storageKey(of: data("META:https://excalidraw.com")), "https://excalidraw.com")
        XCTAssertEqual(LocalStorageKey.storageKey(of: data("METAACCESS:https://excalidraw.com")), "https://excalidraw.com")
        XCTAssertEqual(
            LocalStorageKey.storageKey(of: data("_https://embed.example\u{0}\u{1}k")),
            "https://embed.example"
        )
        XCTAssertNil(LocalStorageKey.storageKey(of: data("VERSION")))
    }

    func testOnlyWebOriginsAreCarriedAcross() {
        XCTAssertTrue(LocalStorageKey.isWebOrigin("https://excalidraw.com"))
        XCTAssertTrue(LocalStorageKey.isWebOrigin("http://localhost:3000"))
        XCTAssertFalse(LocalStorageKey.isWebOrigin("chrome-extension://bmnlcjabgnpnenekpadlanbbkooimhnj"))
        XCTAssertFalse(LocalStorageKey.isWebOrigin("devtools://devtools"))
        XCTAssertFalse(LocalStorageKey.isWebOrigin("chrome://settings"))
    }

    // MARK: - Staging

    func testStagingKeepsWebOriginsAndDropsTheOtherBrowsersOwnSurfaces() throws {
        let profile = root.appendingPathComponent("Arc", isDirectory: true)
        try writeLocalStorage(in: profile, records: [
            record("VERSION", "1"),
            record("_https://excalidraw.com\u{0}\u{1}excalidraw", "[]"),
            record("META:https://excalidraw.com", "x"),
            record("_chrome-extension://abcdefghijklmnop\u{0}\u{1}state", "1"),
            record("_devtools://devtools\u{0}\u{1}panel", "1"),
        ])
        try writeIndexedDB(in: profile, directories: [
            "https_excalidraw.com_0.indexeddb.leveldb",
            "https_excalidraw.com_0.indexeddb.blob",
            "chrome-extension_abcdefghijklmnop_0.indexeddb.leveldb",
        ])

        let staging = root.appendingPathComponent("PendingSiteData", isDirectory: true)
        let summary = try ArcSiteDataStager.stage(profileDirectory: profile, into: staging)

        XCTAssertEqual(summary.localStorageOrigins, 1)
        XCTAssertEqual(summary.localStorageEntries, 2, "Both the record and its META entry belong to the site.")
        XCTAssertEqual(summary.indexedDBOrigins, 1)
        XCTAssertGreaterThan(summary.bytesStaged, 0)

        var stagedKeys: [String] = []
        try ArcSiteDataStager.forEachStagedEntry(in: staging.appendingPathComponent(ArcSiteDataStager.localStorageEntriesName)) { key, _ in
            stagedKeys.append(LocalStorageKey.storageKey(of: key) ?? "")
        }
        XCTAssertEqual(Set(stagedKeys), ["https://excalidraw.com"])

        let staged = Set(try FileManager.default.contentsOfDirectory(
            atPath: staging.appendingPathComponent(ArcSiteDataStager.indexedDBDirectoryName).path
        ))
        XCTAssertEqual(staged, ["https_excalidraw.com_0.indexeddb.leveldb", "https_excalidraw.com_0.indexeddb.blob"])
    }

    func testStagingReportsAProfileWithNoSiteData() {
        let profile = root.appendingPathComponent("Empty", isDirectory: true)
        XCTAssertThrowsError(try ArcSiteDataStager.stage(profileDirectory: profile, into: root.appendingPathComponent("staging")))
    }

    // MARK: - Installing

    func testInstallingAddsNewSitesAndLeavesTheOnesOrbitAlreadyHas() throws {
        let profile = root.appendingPathComponent("Arc", isDirectory: true)
        try writeLocalStorage(in: profile, records: [
            record("_https://excalidraw.com\u{0}\u{1}excalidraw", "arc-scene"),
            record("_https://linear.app\u{0}\u{1}session", "arc-session"),
        ])
        let staging = root.appendingPathComponent("PendingSiteData", isDirectory: true)
        _ = try ArcSiteDataStager.stage(profileDirectory: profile, into: staging)

        let userData = root.appendingPathComponent("UserData", isDirectory: true)
        try writeLocalStorage(in: userData, records: [
            record("VERSION", "1"),
            record("_https://linear.app\u{0}\u{1}session", "orbit-session"),
        ])

        let outcome = try XCTUnwrap(PendingSiteDataInstaller.installIfPending(
            stagingDirectory: staging,
            userDataDirectory: userData
        ))

        XCTAssertEqual(outcome.localStorageOriginsInstalled, 1)
        XCTAssertEqual(outcome.localStorageOriginsSkipped, 1)

        let merged = try LevelDBReader.readAll(directory: userData.appendingPathComponent("Local Storage/leveldb"))
        XCTAssertEqual(value(of: "_https://excalidraw.com\u{0}\u{1}excalidraw", in: merged), "arc-scene")
        XCTAssertEqual(
            value(of: "_https://linear.app\u{0}\u{1}session", in: merged),
            "orbit-session",
            "A site Orbit already holds data for must keep Orbit's copy."
        )
        XCTAssertEqual(value(of: "VERSION", in: merged), "1")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: userData.appendingPathComponent("Local Storage/leveldb-before-import").path),
            "The replaced database is kept, so a bad merge is recoverable."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "Staged data is consumed once installed.")
    }

    func testInstallingWritesTheSchemaVersionWhenOrbitHasNoDatabaseYet() throws {
        let profile = root.appendingPathComponent("Arc", isDirectory: true)
        try writeLocalStorage(in: profile, records: [record("_https://excalidraw.com\u{0}\u{1}excalidraw", "arc-scene")])
        let staging = root.appendingPathComponent("PendingSiteData", isDirectory: true)
        _ = try ArcSiteDataStager.stage(profileDirectory: profile, into: staging)

        let userData = root.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)

        _ = PendingSiteDataInstaller.installIfPending(stagingDirectory: staging, userDataDirectory: userData)

        let merged = try LevelDBReader.readAll(directory: userData.appendingPathComponent("Local Storage/leveldb"))
        XCTAssertEqual(value(of: "VERSION", in: merged), "1", "Chromium rejects a Local Storage database with no schema version.")
        XCTAssertEqual(value(of: "_https://excalidraw.com\u{0}\u{1}excalidraw", in: merged), "arc-scene")
    }

    func testInstallingMovesOnlyTheIndexedDBSitesOrbitHasNone() throws {
        let profile = root.appendingPathComponent("Arc", isDirectory: true)
        try writeLocalStorage(in: profile, records: [record("_https://excalidraw.com\u{0}\u{1}k", "v")])
        try writeIndexedDB(in: profile, directories: [
            "https_excalidraw.com_0.indexeddb.leveldb",
            "https_excalidraw.com_0.indexeddb.blob",
            "https_www.youtube.com_0.indexeddb.leveldb",
        ])
        let staging = root.appendingPathComponent("PendingSiteData", isDirectory: true)
        _ = try ArcSiteDataStager.stage(profileDirectory: profile, into: staging)

        let userData = root.appendingPathComponent("UserData", isDirectory: true)
        let existing = userData.appendingPathComponent("IndexedDB/https_www.youtube.com_0.indexeddb.leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("orbit".utf8).write(to: existing.appendingPathComponent("CURRENT"))

        let outcome = try XCTUnwrap(PendingSiteDataInstaller.installIfPending(
            stagingDirectory: staging,
            userDataDirectory: userData
        ))

        XCTAssertEqual(outcome.indexedDBOriginsInstalled, 1)
        XCTAssertEqual(outcome.indexedDBOriginsSkipped, 1)

        let installed = Set(try FileManager.default.contentsOfDirectory(atPath: userData.appendingPathComponent("IndexedDB").path))
        XCTAssertEqual(installed, [
            "https_excalidraw.com_0.indexeddb.leveldb",
            "https_excalidraw.com_0.indexeddb.blob",
            "https_www.youtube.com_0.indexeddb.leveldb",
        ])
        XCTAssertEqual(
            try String(contentsOf: existing.appendingPathComponent("CURRENT"), encoding: .utf8),
            "orbit",
            "A site Orbit already has an IndexedDB for must not be overwritten."
        )
    }

    func testInstallingDoesNothingWhenNothingIsStaged() {
        XCTAssertNil(PendingSiteDataInstaller.installIfPending(
            stagingDirectory: root.appendingPathComponent("PendingSiteData"),
            userDataDirectory: root.appendingPathComponent("UserData")
        ))
    }

    /// A database Orbit cannot merge must not retry forever.
    func testStagedDataIsDroppedAfterRepeatedFailedAttempts() throws {
        let staging = root.appendingPathComponent("PendingSiteData", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var manifest = PendingSiteDataManifest(
            formatVersion: PendingSiteDataManifest.currentFormatVersion,
            source: "arc",
            stagedAt: Date(),
            localStorageOrigins: [],
            localStorageEntries: 0,
            indexedDBDirectories: [],
            installAttempts: PendingSiteDataInstaller.maximumInstallAttempts
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(ArcSiteDataStager.manifestName))
        manifest.installAttempts = 0

        XCTAssertNil(PendingSiteDataInstaller.installIfPending(
            stagingDirectory: staging,
            userDataDirectory: root.appendingPathComponent("UserData")
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: - Helpers

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func record(_ key: String, _ value: String) -> LevelDBRecord {
        LevelDBRecord(key: data(key), value: data(value))
    }

    private func value(of key: String, in records: [LevelDBRecord]) -> String? {
        records.first { $0.key == data(key) }.map { String(decoding: $0.value, as: UTF8.self) }
    }

    private func writeLocalStorage(in profile: URL, records: [LevelDBRecord]) throws {
        let writer = try LevelDBWriter(directory: profile.appendingPathComponent("Local Storage/leveldb", isDirectory: true))
        try writer.append(records)
        try writer.finish()
    }

    private func writeIndexedDB(in profile: URL, directories: [String]) throws {
        for name in directories {
            let directory = profile.appendingPathComponent("IndexedDB/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("arc".utf8).write(to: directory.appendingPathComponent("CURRENT"))
        }
    }
}
