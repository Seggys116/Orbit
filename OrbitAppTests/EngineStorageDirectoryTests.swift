//  Proves the storage-mode plumbing: which directory each EngineStorage resolves
//  to, and that nothing a scoped run resolves lands on the real profile. Never
//  calls engine.start(); OrbitDemo's DemoEngineProbe proves a running engine honours it.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class EngineStorageDirectoryTests: XCTestCase {

    /// Above PID_MAX (99999 on macOS), so no process can ever hold it.
    private static let unusableProcessID: pid_t = 2_000_000_000

    private var scratchRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EngineStorageDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchRoot, FileManager.default.fileExists(atPath: scratchRoot.path) {
            try FileManager.default.removeItem(at: scratchRoot)
        }
        scratchRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Which mode gets an override

    func testPersistentResolvesOutsideTheRealProfileUnderATestHost() throws {
        XCTAssertFalse(
            OrbitRuntimeScope.current.isProduction,
            "a process hosting a test bundle resolved as the production browser, so every path below is the real user's"
        )

        let directory = try XCTUnwrap(
            EngineStorageDirectory.directory(for: .persistent),
            "a scoped run has to be handed an explicit profile directory — nil leaves the engine on DefaultOrbitUserDataDir(), which is the real user's profile"
        )
        XCTAssertEqual(
            directory, OrbitDataRoot.processDefault.url,
            "the engine and the Swift stores must land in the same scoped root, or a reset clears half of it"
        )

        let production = EngineStorageDirectory.productionProfile.resolvingSymlinksInPath().path
        let resolved = directory.resolvingSymlinksInPath().path
        XCTAssertNotEqual(resolved, production)
        XCTAssertFalse(
            resolved.hasPrefix(production + "/"),
            "\(resolved) is inside the real user's profile at \(production)"
        )
    }

    func testOnlyTheProductionScopeLeavesTheEngineOnItsOwnDefault() {
        let roots = [
            scratchRoot!,
            OrbitDataRoot.processDefault.url,
            EngineStorageDirectory.productionProfile,
            URL(fileURLWithPath: "/Users/example/somewhere-else", isDirectory: true),
        ]
        for root in roots {
            XCTAssertNil(
                EngineStorageDirectory.persistentDirectory(for: .production, root: root),
                "the shipping browser sends no user-data-dir override at all, whatever root it is handed: \(root.path)"
            )
            XCTAssertEqual(
                EngineStorageDirectory.persistentDirectory(for: .development, root: root),
                root,
                "a development run has to be pinned to its own root — nil would leave the engine on DefaultOrbitUserDataDir(), the real user's profile"
            )
            XCTAssertEqual(
                EngineStorageDirectory.persistentDirectory(for: .test, root: root),
                root,
                "a test run has to be pinned to its own root — nil would leave the engine on DefaultOrbitUserDataDir(), the real user's profile"
            )
        }
    }

    func testThePersistentDirectoryDefaultsToTheProcessRoot() {
        XCTAssertEqual(
            EngineStorageDirectory.persistentDirectory(for: .test),
            OrbitDataRoot.processDefault.url,
            "the injected root is for the tests; with none supplied the engine and the Swift stores must still share one root"
        )
    }

    func testProductionProfileMatchesTheEnginesOwnDefault() {
        XCTAssertEqual(
            EngineStorageDirectory.productionProfile.path,
            NSHomeDirectory() + "/Library/Application Support/Orbit",
            "this mirrors DefaultOrbitUserDataDir() in Chromium/Embedder/common/orbit_user_data_dir.cc"
        )
    }

    func testAPrivateModeResolvesToOneDirectoryOutsideTheProductionProfile() throws {
        // Deliberately not asserting which of the two private modes named it:
        // one process runs one engine, so the first private mode asked wins
        // and every later call gets the same directory back.
        let directory = try XCTUnwrap(EngineStorageDirectory.directory(for: .isolated))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            "the directory has to exist before the engine starts: the network sandbox parameters are canonicalised from it"
        )
        XCTAssertTrue(isDirectory.boolValue)

        let production = EngineStorageDirectory.productionProfile.resolvingSymlinksInPath().path
        let resolved = directory.resolvingSymlinksInPath().path
        XCTAssertNotEqual(resolved, production)
        XCTAssertFalse(
            resolved.hasPrefix(production + "/"),
            "\(resolved) is inside the real user's profile at \(production)"
        )
        XCTAssertEqual(EngineStorageDirectory.ownerProcessID(ofDirectoryNamed: directory.lastPathComponent), getpid())

        XCTAssertEqual(directory, EngineStorageDirectory.directory(for: .isolated))
        XCTAssertEqual(directory, EngineStorageDirectory.directory(for: .ephemeral))
    }

    func testEachPrivateModeNamesItsOwnDirectory() {
        let isolated = EngineStorageDirectory.makePrivateDirectory(for: .isolated, in: scratchRoot)
        let ephemeral = EngineStorageDirectory.makePrivateDirectory(for: .ephemeral, in: scratchRoot)
        XCTAssertTrue(isolated.lastPathComponent.hasPrefix("Orbit-Engine-isolated-\(getpid())-"))
        XCTAssertTrue(ephemeral.lastPathComponent.hasPrefix("Orbit-Engine-ephemeral-\(getpid())-"))
        XCTAssertNotEqual(isolated, ephemeral)
        XCTAssertEqual(isolated.deletingLastPathComponent().path, scratchRoot.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ephemeral.path))
    }

    // MARK: - Ownership parsing

    func testOwnerProcessIDReadsThePidOutOfANameThisTypeCreated() {
        let name = EngineStorageDirectory
            .makePrivateDirectory(for: .isolated, in: scratchRoot)
            .lastPathComponent
        XCTAssertEqual(EngineStorageDirectory.ownerProcessID(ofDirectoryNamed: name), getpid())
    }

    func testOwnerProcessIDRejectsAnythingThisTypeDidNotCreate() {
        let uuid = UUID().uuidString
        for name in [
            "Orbit",
            "OrbitDemo-\(uuid)",
            "Orbit-Engine-\(uuid)",
            "Orbit-Engine-isolated-\(uuid)",
            "Orbit-Engine-isolated-notanumber-\(uuid)",
            "Orbit-Engine-isolated-0-\(uuid)",
            "Orbit-Engine-production-123-\(uuid)",
            "Orbit-Engine-isolated-123-not-a-uuid",
            "com.apple.something",
        ] {
            XCTAssertNil(
                EngineStorageDirectory.ownerProcessID(ofDirectoryNamed: name),
                "\(name) is not one of this type's directories and must never be a deletion candidate"
            )
        }
    }

    // MARK: - Cleanup

    func testAbandonedDirectoriesAreRemovedAndEverythingElseIsKept() throws {
        let fileManager = FileManager.default
        let uuid = UUID().uuidString

        let mine = EngineStorageDirectory.makePrivateDirectory(for: .isolated, in: scratchRoot)
        let abandoned = scratchRoot.appendingPathComponent(
            "Orbit-Engine-isolated-\(Self.unusableProcessID)-\(uuid)", isDirectory: true
        )
        let unrelated = scratchRoot.appendingPathComponent("OrbitDemo-\(uuid)", isDirectory: true)
        try fileManager.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("profile".utf8).write(to: abandoned.appendingPathComponent("Preferences"))
        try fileManager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let strayFile = scratchRoot.appendingPathComponent(
            "Orbit-Engine-isolated-\(Self.unusableProcessID)-\(uuid).txt"
        )
        try Data("keep me".utf8).write(to: strayFile)

        EngineStorageDirectory.removeAbandonedDirectories(in: scratchRoot)

        XCTAssertFalse(fileManager.fileExists(atPath: abandoned.path), "a dead process's profile is dead weight")
        XCTAssertTrue(fileManager.fileExists(atPath: mine.path), "this process is still using its own profile")
        XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path), "nothing outside this type's naming may be touched")
        XCTAssertTrue(fileManager.fileExists(atPath: strayFile.path), "a file, not a directory, is never a candidate")
    }

    func testIsProcessAliveRecognisesThisProcessAndRejectsAnImpossibleOne() {
        XCTAssertTrue(EngineStorageDirectory.isProcessAlive(getpid()))
        XCTAssertFalse(EngineStorageDirectory.isProcessAlive(Self.unusableProcessID))
    }

    // MARK: - The real profile

    // Weak alone (no engine runs here), but proves resolving/sweeping private
    // directories touches nothing in the real profile. Strong version: DemoEngineProbe's checkRealProfileUntouched.
    func testResolvingAPrivateDirectoryLeavesTheRealProfileUntouched() {
        let before = snapshotOfProductionProfile()
        _ = EngineStorageDirectory.makePrivateDirectory(for: .isolated, in: scratchRoot)
        _ = EngineStorageDirectory.makePrivateDirectory(for: .ephemeral, in: scratchRoot)
        EngineStorageDirectory.removeAbandonedDirectories(in: scratchRoot)
        _ = EngineStorageDirectory.directory(for: .persistent)
        _ = EngineStorageDirectory.directory(for: .isolated)
        XCTAssertEqual(before, snapshotOfProductionProfile())
    }

    /// Top level only: an engine writing here would restamp entries like
    /// Preferences or GPUCache, deep enough to catch the defect without racing cache churn deeper in the tree.
    private func snapshotOfProductionProfile() -> [String: String] {
        let root = EngineStorageDirectory.productionProfile
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [:] }
        var snapshot: [String: String] = [:]
        for name in names {
            let values = try? root.appendingPathComponent(name).resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
            let size = values?.fileSize ?? -1
            snapshot[name] = "\(modified)/\(size)"
        }
        return snapshot
    }
}
