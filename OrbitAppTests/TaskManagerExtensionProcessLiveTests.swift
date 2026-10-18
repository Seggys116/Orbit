//  The Task Manager must show the processes extension pages run in, named for the extension.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class TaskManagerExtensionProcessLiveTests: XCTestCase {

    private static let extensionName = "Orbit Task Manager Extension Probe"

    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-TaskManagerExtension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(Self.extensionName)",
          "version": "1.0",
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "self.orbitProbe = true;".write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        return directory
    }

    func testAnExtensionsBackgroundPageIsListedAsAnExtensionProcessNamedForIt() throws {
        let fixture = try writeFixture()
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            XCTAssertTrue(
                engine.extensionWebViews.contains { $0.name == Self.extensionName },
                "the engine exposes no web view for the extension's background page"
            )

            let attribution = WebKitProcessAttribution.gather(from: engine.openTabs.map(\.webView), extensionViews: engine.extensionWebViews)
            let hosting = attribution.extensionNames.filter { $0.value.contains(Self.extensionName) }.map(\.key)
            XCTAssertFalse(hosting.isEmpty, "no process is attributed to the extension's background page")
            for pid in hosting {
                XCTAssertNotNil(attribution.roles[pid], "the process hosting the extension has no role")
            }

            let model = TaskManagerModel(attributionProvider: { attribution })
            model.refresh()
            let row = model.processes.first { hosting.contains($0.processID) }
            XCTAssertEqual(row?.extensionNames.contains(Self.extensionName), true, "the Task Manager row does not name the extension")
        }
    }
}
