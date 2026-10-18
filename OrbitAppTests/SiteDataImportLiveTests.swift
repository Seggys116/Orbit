//  Orbit writes the merged database itself, so only an engine reading it back proves it.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class SiteDataImportLiveTests: XCTestCase {

    private static let page = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>"

    private var scratch: URL?
    private var importedDatabase: URL?

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        // The profile directory is shared by every isolated engine in this process, so the staged database must not outlive the test.
        if let importedDatabase { try? FileManager.default.removeItem(at: importedDatabase) }
        importedDatabase = nil
        super.tearDown()
    }

    func testImportedSiteDataIsReadableByThePageItCameFrom() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteDataImportLiveTests-\(UUID().uuidString)", isDirectory: true)
        self.scratch = scratch
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let userDataDirectory = try XCTUnwrap(
            EngineStorageDirectory.directory(for: .isolated),
            "the isolated engine profile is what the engine about to start will use"
        )
        importedDatabase = userDataDirectory.appendingPathComponent("Local Storage/leveldb", isDirectory: true)

        let result = try WebKitLiveEngineHost.runLive(timeout: 120) { () -> (href: String?, imported: String?, own: String?) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: SiteDataImportLiveTests.page)
            ])
            defer { server.stop() }
            let origin = "http://127.0.0.1:\(server.baseURL.port ?? 0)"

            try Self.stageAndInstall(origin: origin, scratch: scratch, userDataDirectory: userDataDirectory)

            return try await WebKitLiveEngineHost.withFreshEngine { engine in
                let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
                defer { contents.close() }

                contents.load(server.baseURL)
                let deadline = ContinuousClock.now + .seconds(15)
                while contents.navigationState.url?.host != "127.0.0.1" {
                    guard ContinuousClock.now < deadline else {
                        throw EngineError(
                            code: .engineUnavailable,
                            underlyingDescription: "the fixture navigation never committed"
                        )
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

                let href = try await contents.evaluateJavaScript("document.location.href") as? String
                let imported = try await contents.evaluateJavaScript("localStorage.getItem('excalidraw')") as? String
                let own = try await contents.evaluateJavaScript("localStorage.getItem('excalidraw-theme')") as? String
                return (href, imported, own)
            }
        }

        XCTAssertEqual(
            result.href?.hasPrefix("http://127.0.0.1:"), true,
            "test precondition: the assertions below did not run against the fixture page (href \(String(describing: result.href)))"
        )
        XCTAssertEqual(
            result.imported, "[{\"type\":\"rectangle\"}]",
            "the engine did not read the Local Storage database the import wrote, so nothing a site saved in Arc — a drawing, a draft, a signed-in app's state — survives the move"
        )
        XCTAssertEqual(result.own, "dark", "a second key of the same site must come across with it")
    }

    /// The real path: an Arc-shaped profile, staged, merged into the profile about to open.
    private static func stageAndInstall(origin: String, scratch: URL, userDataDirectory: URL) throws {
        let arcProfile = scratch.appendingPathComponent("Arc", isDirectory: true)
        let writer = try LevelDBWriter(directory: arcProfile.appendingPathComponent("Local Storage/leveldb", isDirectory: true))
        try writer.append([
            LevelDBRecord(key: Data("VERSION".utf8), value: Data("1".utf8)),
            LevelDBRecord(key: localStorageKey(origin: origin, item: "excalidraw"), value: latin1("[{\"type\":\"rectangle\"}]")),
            LevelDBRecord(key: localStorageKey(origin: origin, item: "excalidraw-theme"), value: latin1("dark")),
        ])
        try writer.finish()

        let staging = scratch.appendingPathComponent("PendingSiteData", isDirectory: true)
        _ = try ArcSiteDataStager.stage(profileDirectory: arcProfile, into: staging)
        PendingSiteDataInstaller.installIfPending(stagingDirectory: staging, userDataDirectory: userDataDirectory)
    }

    private static func localStorageKey(origin: String, item: String) -> Data {
        var key = Data("_\(origin)".utf8)
        key.append(contentsOf: [0x00, 0x01])
        key.append(Data(item.utf8))
        return key
    }

    /// Chromium's encoding for a Latin-1 value: a 1 byte, then the bytes.
    private static func latin1(_ value: String) -> Data {
        var encoded = Data([0x01])
        encoded.append(Data(value.utf8))
        return encoded
    }
}
