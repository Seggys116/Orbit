//  A second process can't start here, so "the runtime bootstraps again" is a
//  fresh ExtensionRuntime binding to the SAME running engine -- what a relaunch would find.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionPersistenceLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func makeFixture(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-Persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let manifest = """
        { "manifest_version": 3, "name": "\(name)", "version": "1.0" }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return directory
    }

    private static func pollUntil(timeout: Duration = .seconds(15), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "pollUntil timed out after \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testAnExtensionInstalledUnderOneExtensionRuntimeIsReactivatedWhenAFreshExtensionRuntimeBindsToTheSameEngineWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrbitAppTests-PersistenceStore-\(UUID().uuidString)", isDirectory: true)
            self.tempDirectories.append(root)

            // "Session" 1: a store, a runtime bound to it, an install.
            let store1 = ExtensionStore(root: root)
            let runtime1 = ExtensionRuntime(store: store1)
            runtime1.bind(to: engine)

            let fixtureDirectory = try self.makeFixture(named: "Orbit Persistence Test")
            let installed = try store1.install(unpackedAt: fixtureDirectory, publicKey: nil)
            try await Self.pollUntil {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }

            // End "session" 1 without ever calling store.remove: the on-disk
            // record must survive, exactly as it would across a real relaunch.
            runtime1.unbind()
            engine.unloadExtension(id: installed.id, session: engine.defaultSession)
            XCTAssertFalse(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id },
                "test precondition: the engine must genuinely not know about the extension before the second runtime binds"
            )

            // A fresh ExtensionStore, same root: proves the JSON record is
            // what a relaunch would read, not just the original in-memory store's own memory.
            let store2 = ExtensionStore(root: root)
            XCTAssertTrue(
                store2.installed().contains { $0.id == installed.id },
                "the installed.json record did not survive as a fresh ExtensionStore over the same root -- there is nothing for a relaunch to bootstrap from"
            )

            // "Session" 2: a second ExtensionRuntime bound to the SAME
            // still-running engine; its bind()-triggered bootstrap is the exact call a real launch makes.
            let runtime2 = ExtensionRuntime(store: store2)
            defer { runtime2.unbind() }
            runtime2.bind(to: engine)

            try await Self.pollUntil {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id }
            }
            XCTAssertTrue(
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == installed.id && $0.isEnabled },
                "an extension installed under one ExtensionRuntime must be present in the running engine once a fresh ExtensionRuntime bootstraps against the same store, with no restart of Orbit itself"
            )
        }
    }
}
