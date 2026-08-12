//  Live coverage that installing DIFFERENT bytes under the same id replaces
//  the running engine's registration in place, and repeated cycles never duplicate it.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionUpdateNoRestartLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // A fixed key so two independently-written source trees derive the SAME
    // extension id, exactly like a real Web Store update does.
    private let sharedPublicKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

    private func writeVersionedSource(name: String, version: String, uniqueFileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-UpdateSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        { "manifest_version": 3, "name": "\(name)", "version": "\(version)" }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "orbit-update-marker-\(version)".write(to: directory.appendingPathComponent(uniqueFileName), atomically: true, encoding: .utf8)
        return directory
    }

    private func makeTrackedStore() -> ExtensionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-UpdateStore-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(root)
        return ExtensionStore(root: root)
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

    // MARK: - Install over an existing version (the real update path)

    func testInstallingOverAnExistingVersionThroughExtensionStoreUpdatesTheRunningEngineWithNoDuplicateRegistrationAndNoStaleFilesWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let store = self.makeTrackedStore()
            let runtime = ExtensionRuntime(store: store)
            runtime.bind(to: engine)
            defer {
                for record in store.installed() { try? store.remove(id: record.id) }
                runtime.unbind()
            }

            let v1Source = try self.writeVersionedSource(name: "Orbit Update Test", version: "1.0", uniqueFileName: "v1-only.txt")
            let v1 = try store.install(unpackedAt: v1Source, publicKey: self.sharedPublicKey)
            try await Self.pollUntil {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == v1.id && $0.version == "1.0" }
            }

            let v2Source = try self.writeVersionedSource(name: "Orbit Update Test", version: "2.0", uniqueFileName: "v2-only.txt")
            let v2 = try store.install(unpackedAt: v2Source, publicKey: self.sharedPublicKey)
            XCTAssertEqual(v2.id, v1.id, "an update installed under the same key must keep the same extension id")

            try await Self.pollUntil {
                engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == v2.id && $0.version == "2.0" }
            }

            let matchingRegistrations = engine.loadedExtensions(session: engine.defaultSession).filter { $0.id == v2.id }
            XCTAssertEqual(matchingRegistrations.count, 1, "installing over an existing version must leave exactly one registration for the id in the running engine, not two")

            let runningDirectory = try XCTUnwrap(matchingRegistrations.first?.directory)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: runningDirectory.appendingPathComponent("v1-only.txt").path),
                "a file only v1 shipped survived the update in the directory the running engine itself reports for this extension"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: runningDirectory.appendingPathComponent("v2-only.txt").path),
                "v2's own file is missing from the directory the running engine reports for this extension"
            )

            // Not just a filesystem check: ask Chromium's own chrome-extension:// scheme handler to serve the new file.
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(URL(string: "chrome-extension://\(v2.id)/v2-only.txt")!)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let served = try await contents.evaluateJavaScript("document.body ? document.body.textContent : null") as? String
            XCTAssertEqual(served, "orbit-update-marker-2.0", "chrome-extension:// did not serve the updated version's own file after the update")
        }
    }

    // MARK: - Repeated cycles never duplicate a registration

    func testRepeatedLoadUnloadCyclesOfAnUnpackedExtensionNeverProduceADuplicateRegistrationWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try LiveExtensionFixture.write(named: "Orbit Repeated Cycle Test", matchHost: "127.0.0.1")
            self.tempDirectories.append(fixture.directory)

            var lastID: String?
            for cycle in 0..<3 {
                let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
                if let lastID {
                    XCTAssertEqual(loaded.id, lastID, "cycle \(cycle): reloading the same unpacked directory must keep deriving the same id")
                }
                lastID = loaded.id

                let matching = engine.loadedExtensions(session: engine.defaultSession).filter { $0.id == loaded.id }
                XCTAssertEqual(matching.count, 1, "cycle \(cycle): the running engine reports \(matching.count) registrations for one id, expected exactly 1")

                engine.unloadExtension(id: loaded.id, session: engine.defaultSession)
                XCTAssertFalse(engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == loaded.id }, "cycle \(cycle): unload did not remove the registration")
            }
        }
    }
}
