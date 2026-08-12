import XCTest
#if canImport(SQLite3)
import SQLite3
#endif

final class FirefoxImportReaderTests: XCTestCase {

    private var home: URL!

    private static let visitPRTime: Int64 = 1_678_300_800_000_000
    private static let expectedVisitDate = Date(timeIntervalSince1970: 1_678_300_800)

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-FirefoxImport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        super.tearDown()
    }

    // MARK: - Presence

    func testFirefoxIsOfferedOnlyWhenAProfileActuallyHasAPlacesDatabase() throws {
        XCTAssertFalse(
            ImportableBrowser.firefox.isPresent(homeDirectory: home),
            "Firefox must not be offered when there is no Firefox data at all."
        )

        let root = FirefoxProfileLocator.rootDirectory(homeDirectory: home)
        let profileDirectory = root.appendingPathComponent("Profiles/abcd1234.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try """
        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abcd1234.default-release
        """.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)

        XCTAssertFalse(
            ImportableBrowser.firefox.isPresent(homeDirectory: home),
            "A profiles.ini entry whose directory has no places.sqlite must not count as Firefox being present."
        )

        try writePlacesFixture(in: profileDirectory)
        XCTAssertTrue(ImportableBrowser.firefox.isPresent(homeDirectory: home))
    }

    // MARK: - Bookmarks

    func testBookmarkTreeComesOutWithFoldersNestingPreservedAndInFirefoxsOwnOrder() throws {
        try writeFirefoxFixture(profiles: [("default-release", "abcd1234.default-release")])

        let payload = try BrowserDataReader(homeDirectory: home).read(.firefox)
        XCTAssertEqual(payload.browser, .firefox)
        XCTAssertEqual(payload.bookmarkRoot.name, "Imported From Firefox")

        let roots = payload.bookmarkRoot.subfolders
        XCTAssertEqual(
            roots.map(\.name),
            ["Bookmarks Toolbar", "Bookmarks Menu", "Other Bookmarks"],
            "Roots must be named from their guids, in the declared order, with the empty Mobile root pruned."
        )

        let toolbar = try XCTUnwrap(roots.first)
        XCTAssertEqual(
            toolbar.bookmarks.map(\.title),
            ["GitHub", "Linear"],
            "Bookmarks must come out in moz_bookmarks.position order, not alphabetically or by id."
        )
        XCTAssertEqual(toolbar.bookmarks.first?.url, URL(string: "https://github.com/"))

        let work = try XCTUnwrap(toolbar.subfolders.first(where: { $0.name == "Work" }))
        XCTAssertEqual(work.bookmarks.map(\.title), ["Docs Home"])
        let nested = try XCTUnwrap(work.subfolders.first)
        XCTAssertEqual(nested.name, "Deeper")
        XCTAssertEqual(nested.bookmarks.map(\.title), ["Nested Page"])

        XCTAssertEqual(
            toolbar.totalBookmarkCount,
            4,
            "Every bookmark under the toolbar, nested ones included, must be imported."
        )
    }

    func testTagsAreNeverImportedAsBookmarks() throws {
        try writeFirefoxFixture(profiles: [("default-release", "abcd1234.default-release")])

        let payload = try BrowserDataReader(homeDirectory: home).read(.firefox)
        XCTAssertFalse(
            payload.bookmarkRoot.subfolders.contains(where: { $0.name.lowercased().contains("tag") }),
            "Firefox's tags root must never be imported — its children are pointers to already-bookmarked URLs."
        )
        XCTAssertEqual(
            payload.bookmarkRoot.totalBookmarkCount,
            6,
            "A tagged bookmark must be imported once, not once per tag it carries."
        )
        XCTAssertEqual(
            allBookmarks(payload.bookmarkRoot).filter { $0.url.absoluteString == "https://tagged.example.com/" }.count,
            1,
            "The tagged URL must appear exactly once."
        )
    }

    func testInternalAndBookmarkletEntriesAreExcluded() throws {
        try writeFirefoxFixture(profiles: [("default-release", "abcd1234.default-release")])

        let payload = try BrowserDataReader(homeDirectory: home).read(.firefox)
        let everyURL = allBookmarks(payload.bookmarkRoot).map(\.url.absoluteString)
        XCTAssertFalse(
            everyURL.contains(where: { $0.hasPrefix("place:") }),
            "Firefox's `place:` smart-folder queries are not pages and must not become bookmarks."
        )
        XCTAssertFalse(
            everyURL.contains(where: { $0.hasPrefix("javascript:") }),
            "A bookmarklet would be an entry that silently does nothing when clicked."
        )
    }

    // MARK: - History and the epoch

    func testHistoryConvertsPRTimeMicrosecondsSinceTheUnixEpoch() throws {
        try writeFirefoxFixture(profiles: [("default-release", "abcd1234.default-release")])

        let payload = try BrowserDataReader(homeDirectory: home).read(.firefox)
        let visit = try XCTUnwrap(payload.visits.first(where: { $0.url.absoluteString == "https://github.com/" }))

        XCTAssertEqual(
            visit.visitedAt.timeIntervalSince1970,
            Self.expectedVisitDate.timeIntervalSince1970,
            accuracy: 0.001,
            "PRTime is microseconds since 1970 — a wrong scale here lands in 1970 or in the far future without looking like an epoch bug."
        )
        XCTAssertEqual(visit.title, "GitHub")
        XCTAssertEqual(visit.visitCount, 12)
        XCTAssertTrue(visit.wasTyped, "moz_places.typed > 0 is Firefox's own record that the user typed the URL.")
    }

    func testHiddenRowsAreExcludedSoTheyDoNotEatIntoTheHistoryLimit() throws {
        try writeFirefoxFixture(profiles: [("default-release", "abcd1234.default-release")])

        let payload = try BrowserDataReader(homeDirectory: home).read(.firefox)
        XCTAssertFalse(
            payload.visits.contains(where: { $0.url.absoluteString.contains("redirect.example.com") }),
            "hidden = 1 rows are redirect waypoints and framed subdocuments Firefox itself does not show."
        )
    }

    func testHistoryLimitClampsTheNumberOfRowsRead() throws {
        try writeFirefoxFixture(profiles: [("default-release", "abcd1234.default-release")])

        let payload = try BrowserDataReader(homeDirectory: home).read(.firefox, historyLimit: 1)
        XCTAssertEqual(payload.visits.count, 1)
        XCTAssertEqual(
            payload.visits.first?.url.absoluteString,
            "https://github.com/",
            "The single row kept must be the most recent one."
        )
    }

    // MARK: - Profiles

    func testSeveralProfilesAreKeptSeparateAndNamedFromProfilesINI() throws {
        try writeFirefoxFixture(profiles: [
            ("default-release", "abcd1234.default-release"),
            ("Work", "efgh5678.work"),
        ])

        let payload = try BrowserDataReader(homeDirectory: home).read(.firefox)
        XCTAssertEqual(
            payload.bookmarkRoot.subfolders.map(\.name),
            ["default-release", "Work"],
            "With more than one profile, each profile's tree must be nested under its own name from profiles.ini."
        )
    }

    func testAProfileNotListedInProfilesINIIsStillFound() throws {
        let root = FirefoxProfileLocator.rootDirectory(homeDirectory: home)
        let orphan = root.appendingPathComponent("Profiles/zzzz9999.manual", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try writePlacesFixture(in: orphan)

        let profiles = FirefoxProfileLocator.profiles(in: root)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(
            profiles.first?.displayName,
            "manual",
            "The random 8-character prefix Firefox generates is noise and must not reach the user."
        )
    }

    func testAProfileIsNotListedTwiceWhenProfilesININamesIt() throws {
        try writeFirefoxFixture(profiles: [("default-release", "abcd1234.default-release")])

        let profiles = FirefoxProfileLocator.profiles(in: FirefoxProfileLocator.rootDirectory(homeDirectory: home))
        XCTAssertEqual(
            profiles.count,
            1,
            "The Profiles/ sweep is a fallback for profiles the ini omitted, not a second pass over the ones it named."
        )
        XCTAssertEqual(profiles.first?.displayName, "default-release")
    }

    func testInstallAndGeneralSectionsAreNotMistakenForProfiles() throws {
        let root = FirefoxProfileLocator.rootDirectory(homeDirectory: home)
        let profileDirectory = root.appendingPathComponent("Profiles/abcd1234.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try writePlacesFixture(in: profileDirectory)
        try """
        [General]
        StartWithLastProfile=1
        Version=2

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abcd1234.default-release

        [Install2656FF1E876E9973]
        Default=Profiles/abcd1234.default-release
        Locked=1
        """.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)

        let profiles = FirefoxProfileLocator.profiles(in: root)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.displayName, "default-release")
    }

    // MARK: - Failure modes

    func testACorruptPlacesDatabaseReportsUnreadableRatherThanCrashing() throws {
        let root = FirefoxProfileLocator.rootDirectory(homeDirectory: home)
        let profileDirectory = root.appendingPathComponent("Profiles/abcd1234.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try Data("this is not a SQLite database".utf8)
            .write(to: profileDirectory.appendingPathComponent("places.sqlite"))

        do {
            _ = try BrowserDataReader(homeDirectory: home).read(.firefox)
            XCTFail("A corrupt places.sqlite should have reported .unreadable.")
        } catch let error as BrowserImportError {
            guard case .unreadable(let browser, _) = error else {
                return XCTFail("Expected .unreadable, got \(error).")
            }
            XCTAssertEqual(browser, .firefox)
        }
    }

    // MARK: - Fixtures

    private func allBookmarks(_ folder: ImportedBookmarkFolder) -> [ImportedBookmark] {
        folder.bookmarks + folder.subfolders.flatMap(allBookmarks)
    }

    private func writeFirefoxFixture(profiles: [(name: String, path: String)]) throws {
        let root = FirefoxProfileLocator.rootDirectory(homeDirectory: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var ini = "[General]\nStartWithLastProfile=1\nVersion=2\n"
        for (index, profile) in profiles.enumerated() {
            ini += "\n[Profile\(index)]\nName=\(profile.name)\nIsRelative=1\nPath=Profiles/\(profile.path)\n"
            let directory = root.appendingPathComponent("Profiles/\(profile.path)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writePlacesFixture(in: directory)
        }
        try ini.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
    }

    private func writePlacesFixture(in directory: URL) throws {
        let handle = try openDatabase(at: directory.appendingPathComponent("places.sqlite", isDirectory: false))
        defer { sqlite3_close(handle) }

        try exec(handle, """
        CREATE TABLE moz_places (
            id INTEGER PRIMARY KEY,
            url LONGVARCHAR,
            title LONGVARCHAR,
            rev_host LONGVARCHAR,
            visit_count INTEGER DEFAULT 0,
            hidden INTEGER DEFAULT 0 NOT NULL,
            typed INTEGER DEFAULT 0 NOT NULL,
            frecency INTEGER DEFAULT -1 NOT NULL,
            last_visit_date INTEGER,
            guid TEXT
        );
        """)
        try exec(handle, """
        CREATE TABLE moz_bookmarks (
            id INTEGER PRIMARY KEY,
            type INTEGER,
            fk INTEGER DEFAULT NULL,
            parent INTEGER,
            position INTEGER,
            title LONGVARCHAR,
            dateAdded INTEGER,
            lastModified INTEGER,
            guid TEXT
        );
        """)

        try exec(handle, """
        INSERT INTO moz_places (id, url, title, visit_count, hidden, typed, last_visit_date) VALUES
            (101, 'https://github.com/', 'GitHub', 12, 0, 3, \(Self.visitPRTime)),
            (102, 'https://linear.app/', 'Linear', 4, 0, 0, \(Self.visitPRTime - 86_400_000_000)),
            (103, 'https://docs.example.com/', 'Docs Home', 2, 0, 0, \(Self.visitPRTime - 172_800_000_000)),
            (104, 'https://nested.example.com/', 'Nested Page', 1, 0, 0, \(Self.visitPRTime - 259_200_000_000)),
            (105, 'https://tagged.example.com/', 'Tagged Page', 7, 0, 0, \(Self.visitPRTime - 345_600_000_000)),
            (106, 'place:type=6&sort=14&maxResults=10', 'Most Visited', 0, 0, 0, NULL),
            (107, 'javascript:void(0)', 'Bookmarklet', 0, 0, 0, NULL),
            (108, 'https://redirect.example.com/', 'Redirect Waypoint', 3, 1, 0, \(Self.visitPRTime - 1_000_000));
        """)

        try exec(handle, """
        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
            (50, 2, NULL, 0,  0, '',        'root________'),
            (54, 2, NULL, 50, 0, 'menu',    'menu________'),
            (51, 2, NULL, 50, 1, 'toolbar', 'toolbar_____'),
            (57, 2, NULL, 50, 2, 'tags',    'tags________'),
            (53, 2, NULL, 50, 3, 'unfiled', 'unfiled_____'),
            (55, 2, NULL, 50, 4, 'mobile',  'mobile______');
        """)

        try exec(handle, """
        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
            (201, 1, 101, 51, 0, 'GitHub',       'bm0000000001'),
            (200, 1, 102, 51, 1, 'Linear',       'bm0000000002'),
            (202, 2, NULL, 51, 2, 'Work',        'fd0000000001'),
            (203, 1, 103, 202, 0, 'Docs Home',   'bm0000000003'),
            (204, 2, NULL, 202, 1, 'Deeper',     'fd0000000002'),
            (205, 1, 104, 204, 0, 'Nested Page', 'bm0000000004'),
            (206, 2, NULL, 202, 2, 'Empty',      'fd0000000003');
        """)

        try exec(handle, """
        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
            (210, 1, 106, 54, 0, 'Most Visited', 'bm0000000005'),
            (211, 3, NULL, 54, 1, NULL,          'sp0000000001'),
            (212, 1, 107, 54, 2, 'Bookmarklet',  'bm0000000006'),
            (213, 1, 105, 54, 3, 'Tagged Page',  'bm0000000007');
        """)

        try exec(handle, """
        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
            (220, 1, 103, 53, 0, 'Docs Home', 'bm0000000008');
        """)

        try exec(handle, """
        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
            (230, 2, NULL, 57, 0, 'reading',     'tg0000000001'),
            (231, 1, 105, 230, 0, 'Tagged Page', 'tg0000000002');
        """)
    }

    // MARK: SQLite plumbing (system libsqlite3, same as production)

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "FirefoxImportReaderTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create the fixture database at \(url.path).",
            ])
        }
        return handle
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(domain: "FirefoxImportReaderTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Fixture SQL failed: \(message)",
            ])
        }
    }
}
