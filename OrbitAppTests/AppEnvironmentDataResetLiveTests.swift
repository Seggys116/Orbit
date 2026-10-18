// Resets run against real website data written by a live WKWebView, not against files.

import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class AppEnvironmentDataResetLiveTests: XCTestCase {

    private static let pageOrigin = URL(string: "https://reset.orbit.test/")!

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var scratchRoot: URL!
    private var originalTargets: DataResetTargets?
    private var sessions: [WebKitSession] = []
    private var openContents: [WebKitWebContents] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppEnvironmentDataResetLiveTests-\(UUID().uuidString)", isDirectory: true)
        let directories = ["Favicons", "SpaceIcons", "Extensions", "ContentSettings", "Sync", "ContentBlocking"]
            .map { scratchRoot.appendingPathComponent($0, isDirectory: true) }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        originalTargets = DataResetTargets.override
        DataResetTargets.override = DataResetTargets(
            faviconCache: FaviconCache(diskDirectory: directories[0]),
            spaceIconImages: SpaceIconImageStore(diskDirectory: directories[1]),
            extensions: ExtensionStore(root: directories[2]),
            contentBlocking: ContentBlockingController(
                store: FilterListStore(directory: directories[5]),
                defaults: OrbitDefaults.standard
            ),
            contentSettingsDirectory: directories[3],
            syncDirectory: directories[4],
            contentBlockingDirectory: directories[5],
            engineSessions: { [unowned self] in self.sessions }
        )
    }

    override func tearDownWithError() throws {
        DataResetTargets.override = originalTargets
        env._test_engineOverride = nil
        let leftovers = (contents: openContents, sessions: sessions)
        openContents.removeAll()
        sessions.removeAll()
        _ = try? WebKitLiveEngineHost.runLive {
            for contents in leftovers.contents where !contents.isClosed { contents.close() }
            for session in leftovers.sessions {
                try? await WKWebsiteDataStore.remove(forIdentifier: WebKitSession.dataStoreIdentifier(for: session.identifier))
            }
        }
        try? FileManager.default.removeItem(at: scratchRoot)
        try super.tearDownWithError()
    }

    // MARK: - Cookies and logins

    func testCookiesAndLoginsResetClearsEveryKindOfSiteDataFromTheStore() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.env._test_engineOverride = engine
            let session = try self.makeSession(on: engine)

            let wroteFileSystem = try await self.writeSiteData(on: engine, session: session)
            let before = try await self.readSiteData(on: engine, session: session)
            XCTAssertEqual(before.local, "kept", "Precondition: localStorage reached disk and a fresh page can read it.")
            XCTAssertEqual(before.cookie, "orbit-reset=1")
            XCTAssertEqual(before.databases, ["orbit-reset-db"])
            if wroteFileSystem { XCTAssertEqual(before.files, ["orbit-reset.txt"]) }
            let storedCookies = await session.cookies(for: Self.pageOrigin)
            XCTAssertFalse(storedCookies.isEmpty, "Precondition: the cookie is in the data store.")

            let outcome = await self.env.resetData([.cookiesAndLogins])

            XCTAssertEqual(outcome.clearedCategories, [.cookiesAndLogins])
            XCTAssertTrue(outcome.failedCategories.isEmpty)
            XCTAssertFalse(outcome.needsRelaunch)
            let after = try await self.readSiteData(on: engine, session: session)
            XCTAssertNil(after.local, "localStorage survived a Cookies and Logins reset.")
            XCTAssertEqual(after.cookie, "", "A cookie survived the reset.")
            XCTAssertEqual(after.databases, [], "An IndexedDB database survived the reset.")
            XCTAssertEqual(after.files, [], "File system storage survived the reset.")
            let remaining = await session.cookies(for: Self.pageOrigin)
            XCTAssertTrue(remaining.isEmpty, "The data store still holds the cookie.")
        }
    }

    func testCookiesAndLoginsResetReachesEverySessionNotJustTheDefault() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.env._test_engineOverride = engine
            let first = try self.makeSession(on: engine)
            let second = try self.makeSession(on: engine)
            _ = try await self.writeSiteData(on: engine, session: first)
            _ = try await self.writeSiteData(on: engine, session: second)

            await self.env.resetData([.cookiesAndLogins])

            for session in [first, second] {
                let after = try await self.readSiteData(on: engine, session: session)
                XCTAssertNil(after.local, "\(session.identifier) kept its localStorage.")
            }
        }
    }

    // MARK: - Cache

    func testCacheResetLeavesCookiesAndStorageAlone() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.env._test_engineOverride = engine
            let session = try self.makeSession(on: engine)
            _ = try await self.writeSiteData(on: engine, session: session)

            let outcome = await self.env.resetData([.cache])

            XCTAssertEqual(outcome.clearedCategories, [.cache])
            let after = try await self.readSiteData(on: engine, session: session)
            XCTAssertEqual(after.local, "kept", "A cache reset removed localStorage.")
            XCTAssertEqual(after.cookie, "orbit-reset=1", "A cache reset removed a cookie.")
        }
    }

    // MARK: - Reset everything

    func testEverythingResetEmptiesAndRemovesEachPersistentStore() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let session = try self.makeSession(on: engine)
            _ = try await self.writeSiteData(on: engine, session: session)
            let uuid = WebKitSession.dataStoreIdentifier(for: session.identifier)
            let identifiersBefore = await WKWebsiteDataStore.allDataStoreIdentifiers
            XCTAssertTrue(identifiersBefore.contains(uuid), "Precondition: the session's persistent store exists.")

            await self.env.clearEverythingInEngine()

            let after = try await self.readSiteData(on: engine, session: session)
            XCTAssertNil(after.local)
            XCTAssertEqual(after.cookie, "")
            XCTAssertEqual(after.databases, [])
        }
    }

    func testRemovingAPersistentStoreSucceedsOnceItsWebViewsAreGone() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let session = try self.makeSession(on: engine)
            _ = try await self.writeSiteData(on: engine, session: session)
            for contents in self.openContents where !contents.isClosed { contents.close() }
            self.openContents.removeAll()

            let removed = await session.removePersistentDataStore()

            XCTAssertTrue(removed, "WebKit refused to remove a store no web view uses.")
            let after = try await self.readSiteData(on: engine, session: session)
            XCTAssertNil(after.local, "The recreated store still held the old localStorage.")
        }
    }

    // MARK: - Helpers

    private struct SiteData {
        var local: String?
        var cookie: String
        var databases: [String]
        var files: [String]
    }

    private func makeSession(on engine: WebKitEngine) throws -> WebKitSession {
        let session = try XCTUnwrap(
            try engine.session(identifier: "data-reset-live-\(UUID().uuidString)", persistent: true) as? WebKitSession
        )
        sessions.append(session)
        return session
    }

    // A fresh web view each time: whatever it reads has come from the data store, not a page's memory.
    private func openPage(on engine: WebKitEngine, session: WebKitSession) async throws -> WebKitWebContents {
        let contents = try XCTUnwrap(try engine.makeWebContents(session: session, initialURL: nil) as? WebKitWebContents)
        openContents.append(contents)
        contents.webView.loadHTMLString("<html><body>reset probe</body></html>", baseURL: Self.pageOrigin)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        let deadline = ContinuousClock.now + .seconds(10)
        while (try await contents.evaluateJavaScript("location.origin")) as? String != "https://reset.orbit.test" {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "probe page never reached its origin")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return contents
    }

    private func closePages() {
        for contents in openContents where !contents.isClosed { contents.close() }
        openContents.removeAll()
    }

    // Returns whether origin-private file system storage was available to write.
    private func writeSiteData(on engine: WebKitEngine, session: WebKitSession) async throws -> Bool {
        let contents = try await openPage(on: engine, session: session)
        defer { closePages() }
        let result = try await contents.webView.callAsyncJavaScript(
            """
            localStorage.setItem('orbit-reset', 'kept');
            document.cookie = 'orbit-reset=1; path=/';
            await new Promise((resolve, reject) => {
              const open = indexedDB.open('orbit-reset-db', 1);
              open.onupgradeneeded = () => open.result.createObjectStore('items');
              open.onerror = () => reject(open.error);
              open.onsuccess = () => {
                const tx = open.result.transaction('items', 'readwrite');
                tx.objectStore('items').put('value', 'key');
                tx.oncomplete = () => { open.result.close(); resolve(); };
                tx.onerror = () => reject(tx.error);
              };
            });
            let fileSystem = false;
            try {
              const root = await navigator.storage.getDirectory();
              const handle = await root.getFileHandle('orbit-reset.txt', { create: true });
              const writable = await handle.createWritable();
              await writable.write('kept');
              await writable.close();
              fileSystem = true;
            } catch (error) {}
            return fileSystem;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        return (result as? Bool) ?? false
    }

    private func readSiteData(on engine: WebKitEngine, session: WebKitSession) async throws -> SiteData {
        let contents = try await openPage(on: engine, session: session)
        defer { closePages() }
        let result = try await contents.webView.callAsyncJavaScript(
            """
            const databases = (await indexedDB.databases()).map(database => database.name);
            const files = [];
            try {
              const root = await navigator.storage.getDirectory();
              for await (const name of root.keys()) files.push(name);
            } catch (error) {}
            return { local: localStorage.getItem('orbit-reset'), cookie: document.cookie, databases, files };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let values = try XCTUnwrap(result as? [String: Any])
        return SiteData(
            local: values["local"] as? String,
            cookie: values["cookie"] as? String ?? "",
            databases: values["databases"] as? [String] ?? [],
            files: values["files"] as? [String] ?? []
        )
    }
}
