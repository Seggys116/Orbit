import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#endif
@testable import Orbit

@MainActor
final class BrowserImportCoordinatorTests: XCTestCase {

    private var scratch: URL!
    private var home: URL!
    private var spaceID: SpaceID!
    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-BrowserImport-\(UUID().uuidString)", isDirectory: true)
        home = scratch.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        spaceID = env.store.createSpace(name: "Import Fixture \(UUID().uuidString)", activate: false)
    }

    override func tearDown() async throws {
        if let spaceID { env.store.deleteSpace(spaceID) }
        spaceID = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        home = nil
        try await super.tearDown()
    }

    private func makeHistoryStore() throws -> HistoryStore {
        try HistoryStore(
            databaseURL: scratch.appendingPathComponent("history-\(UUID().uuidString).sqlite3", isDirectory: false)
        )
    }

    private func reader() -> BrowserDataReader {
        BrowserDataReader(homeDirectory: home)
    }

    // MARK: - Bookmarks become real folders and tabs

    func testImportCreatesTheImportedFromFolderMirroringTheSourceTree() async throws {
        try writeChromeFixture()
        let historyStore = try makeHistoryStore()

        let summary = try await BrowserImportCoordinator.performImport(
            .chrome,
            into: spaceID,
            env: env,
            reader: reader(),
            historyStore: historyStore
        )

        XCTAssertEqual(summary.browser, .chrome)
        XCTAssertEqual(summary.bookmarksImported, 3)
        XCTAssertEqual(summary.foldersCreated, 4)

        let root = try XCTUnwrap(rootImportFolder(named: "Imported From Google Chrome"))
        XCTAssertEqual(
            root.children.compactMap { node -> String? in
                guard case .folder(let folder) = node else { return nil }
                return folder.name
            },
            ["Bookmarks Bar", "Other Bookmarks"],
            "The source browser's own top-level folders must be reproduced under the Imported From folder."
        )

        let bar = try XCTUnwrap(root.allDescendantFolders.first { $0.name == "Bookmarks Bar" })
        let barTabs = bar.children.compactMap { node -> Tab? in
            guard case .tab(let id) = node else { return nil }
            return env.state.tabs[id]
        }
        XCTAssertEqual(barTabs.map(\.url.absoluteString), ["https://github.com/"])
        XCTAssertEqual(barTabs.map(\.displayTitle), ["GitHub"], "The bookmark's real title must reach the sidebar.")
        XCTAssertEqual(barTabs.map(\.section), [.pinned], "Imported bookmarks must land in the Pinned section.")

        let work = try XCTUnwrap(root.allDescendantFolders.first { $0.name == "Work" })
        let workTabs = work.children.compactMap { node -> Tab? in
            guard case .tab(let id) = node else { return nil }
            return env.state.tabs[id]
        }
        XCTAssertEqual(workTabs.map(\.url.absoluteString), ["https://linear.app/"])
        XCTAssertEqual(workTabs.map(\.displayTitle), ["Linear"])

        let other = try XCTUnwrap(root.allDescendantFolders.first { $0.name == "Other Bookmarks" })
        XCTAssertEqual(other.allTabIDs.count, 1)

        XCTAssertEqual(root.allTabIDs.count, 3, "Every imported bookmark must be reachable under the Imported From folder.")
        for tabID in root.allTabIDs {
            XCTAssertEqual(env.state.tabs[tabID]?.spaceID, spaceID, "Imported tabs must belong to the target Space.")
        }
        XCTAssertNotEqual(env.state.activeTabBySpace[spaceID], root.allTabIDs.first, "An import must not steal focus onto an imported tab.")
    }

    // MARK: - History becomes real HistoryStore rows

    func testImportRecordsRealHistoryRowsWithTheSourceTimestamps() async throws {
        try writeChromeFixture()
        let historyStore = try makeHistoryStore()

        let summary = try await BrowserImportCoordinator.performImport(
            .chrome,
            into: spaceID,
            env: env,
            reader: reader(),
            historyStore: historyStore
        )
        XCTAssertEqual(summary.historyEntriesImported, 2)

        let range = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 4_000_000_000)
        let entries = try await historyStore.entries(in: range, limit: 100)
        XCTAssertEqual(entries.count, 2, "Both imported visits must be real rows in the HistoryStore.")

        let github = try XCTUnwrap(entries.first { $0.url.absoluteString == "https://github.com/" })
        XCTAssertEqual(github.title, "GitHub")
        XCTAssertEqual(
            github.visitedAt.timeIntervalSince1970,
            1_678_300_800,
            accuracy: 0.001,
            "The source browser's own timestamp must be preserved, not replaced with Date()."
        )
        XCTAssertTrue(github.wasTyped, "Chromium's typed_count must survive into the imported row.")

        let profileID = try XCTUnwrap(env.store.space(spaceID)?.profileID)
        XCTAssertEqual(github.profileID, profileID, "Imported history must be attributed to the target Space's Profile.")
        XCTAssertEqual(github.spaceID, spaceID)

        let linear = try XCTUnwrap(entries.first { $0.url.absoluteString == "https://linear.app/" })
        XCTAssertEqual(
            linear.visitedAt.timeIntervalSince1970,
            1_356_998_400,
            accuracy: 0.001,
            "A visit from 2013 must still be dated 2013 after import."
        )
        XCTAssertFalse(linear.wasTyped)

        let found = try await historyStore.search("github", limit: 10)
        XCTAssertEqual(found.map(\.url.absoluteString), ["https://github.com/"])
    }

    // MARK: - Re-importing

    func testImportingTwiceCreatesASecondNumberedFolderRatherThanDuplicatingIntoTheFirst() async throws {
        try writeChromeFixture()
        let historyStore = try makeHistoryStore()

        _ = try await BrowserImportCoordinator.performImport(
            .chrome, into: spaceID, env: env, reader: reader(), historyStore: historyStore
        )
        let second = try await BrowserImportCoordinator.performImport(
            .chrome, into: spaceID, env: env, reader: reader(), historyStore: historyStore
        )
        let third = try await BrowserImportCoordinator.performImport(
            .chrome, into: spaceID, env: env, reader: reader(), historyStore: historyStore
        )
        XCTAssertEqual(second.bookmarksImported, 3)
        XCTAssertEqual(third.bookmarksImported, 3)

        let rootFolderNames = env.store.pinnedNodes(in: spaceID).compactMap { node -> String? in
            guard case .folder(let folder) = node else { return nil }
            return folder.name
        }
        XCTAssertEqual(
            rootFolderNames,
            ["Imported From Google Chrome", "Imported From Google Chrome 2", "Imported From Google Chrome 3"],
            "A repeat import must get its own numbered folder, never merge into or duplicate inside the existing one."
        )

        let first = try XCTUnwrap(rootImportFolder(named: "Imported From Google Chrome"))
        XCTAssertEqual(first.allTabIDs.count, 3, "The original imported folder must be left exactly as it was.")
        let secondFolder = try XCTUnwrap(rootImportFolder(named: "Imported From Google Chrome 2"))
        XCTAssertEqual(secondFolder.allTabIDs.count, 3)
        XCTAssertTrue(
            Set(first.allTabIDs).isDisjoint(with: Set(secondFolder.allTabIDs)),
            "The two imports must contain distinct tabs."
        )
    }

    // MARK: - Failure paths reach the caller intact

    func testImportingABrowserWithNoDataThrowsNotInstalled() async throws {
        let historyStore = try makeHistoryStore()
        do {
            _ = try await BrowserImportCoordinator.performImport(
                .chrome, into: spaceID, env: env, reader: reader(), historyStore: historyStore
            )
            XCTFail("Importing from an empty home directory should have thrown.")
        } catch let error as BrowserImportError {
            guard case .notInstalled(let browser) = error else {
                return XCTFail("Expected .notInstalled, got \(error).")
            }
            XCTAssertEqual(browser, .chrome)
        }
        XCTAssertTrue(env.store.pinnedNodes(in: spaceID).isEmpty, "A failed import must leave no folder behind.")
    }

    func testABrowserWithBookmarksButNoHistoryStillImportsTheBookmarks() async throws {
        try writeChromeFixture(includeHistory: false)
        let historyStore = try makeHistoryStore()

        let summary = try await BrowserImportCoordinator.performImport(
            .chrome, into: spaceID, env: env, reader: reader(), historyStore: historyStore
        )
        XCTAssertEqual(summary.bookmarksImported, 3)
        XCTAssertEqual(summary.historyEntriesImported, 0)
        XCTAssertNotNil(rootImportFolder(named: "Imported From Google Chrome"))
    }

    // MARK: - Helpers

    private func rootImportFolder(named name: String) -> Folder? {
        for node in env.store.pinnedNodes(in: spaceID) {
            if case .folder(let folder) = node, folder.name == name { return folder }
        }
        return nil
    }

    private func writeChromeFixture(includeHistory: Bool = true) throws {
        let profileDirectory = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

        let bookmarks: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": [
                    "type": "folder",
                    "name": "Bookmarks Bar",
                    "children": [
                        ["type": "url", "name": "GitHub", "url": "https://github.com/"] as [String: Any],
                        [
                            "type": "folder",
                            "name": "Work",
                            "children": [
                                ["type": "url", "name": "Linear", "url": "https://linear.app/"] as [String: Any],
                            ],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
                "other": [
                    "type": "folder",
                    "name": "Other Bookmarks",
                    "children": [
                        ["type": "url", "name": "Wikipedia", "url": "https://en.wikipedia.org/"] as [String: Any],
                    ],
                ] as [String: Any],
            ],
        ]
        try JSONSerialization.data(withJSONObject: bookmarks, options: [])
            .write(to: profileDirectory.appendingPathComponent("Bookmarks", isDirectory: false))

        guard includeHistory else { return }

        var handle: OpaquePointer?
        let databaseURL = profileDirectory.appendingPathComponent("History", isDirectory: false)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "BrowserImportCoordinatorTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create the fixture History database.",
            ])
        }
        defer { sqlite3_close(handle) }

        let sql = """
        CREATE TABLE urls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url LONGVARCHAR,
            title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0 NOT NULL,
            typed_count INTEGER DEFAULT 0 NOT NULL,
            last_visit_time INTEGER NOT NULL,
            hidden INTEGER DEFAULT 0 NOT NULL
        );
        INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden)
        VALUES ('https://github.com/', 'GitHub', 12, 3, 13322774400000000, 0);
        INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden)
        VALUES ('https://linear.app/', 'Linear', 4, 0, 13001472000000000, 0);
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(domain: "BrowserImportCoordinatorTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Fixture SQL failed: \(message)",
            ])
        }
    }
}
