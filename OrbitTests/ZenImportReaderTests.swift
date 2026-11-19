import Compression
import XCTest
#if canImport(SQLite3)
import SQLite3
#endif

final class ZenImportReaderTests: XCTestCase {

    private var home: URL!

    private static let visitPRTime: Int64 = 1_678_300_800_000_000

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ZenImport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        super.tearDown()
    }

    // MARK: - Presence

    func testZenIsOfferedOnlyWhenAProfileActuallyHasAPlacesDatabase() throws {
        XCTAssertFalse(ImportableBrowser.zen.isPresent(homeDirectory: home))

        let root = try XCTUnwrap(ImportableBrowser.zen.firefoxFamilyRoot(homeDirectory: home))
        XCTAssertEqual(root.path, home.appendingPathComponent("Library/Application Support/zen").path)
        let directory = root.appendingPathComponent("Profiles/abcd1234.Default (release)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "[Profile0]\nName=Default (release)\nIsRelative=1\nPath=Profiles/abcd1234.Default (release)\n"
            .write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        XCTAssertFalse(ImportableBrowser.zen.isPresent(homeDirectory: home))

        try writePlaces(in: directory)
        XCTAssertTrue(ImportableBrowser.zen.isPresent(homeDirectory: home))
        XCTAssertFalse(
            ImportableBrowser.firefox.isPresent(homeDirectory: home),
            "Zen's profile directory must not make Firefox appear present."
        )
    }

    // MARK: - mozLz4

    func testMozLz4RoundTripsAndRejectsForeignData() throws {
        let json = Data(String(repeating: "{\"url\":\"https://example.com/\"}", count: 40).utf8)
        XCTAssertEqual(MozLz4.decode(mozLz4(json)), json)

        XCTAssertNil(MozLz4.decode(Data("not a mozlz4 file at all".utf8)))
        var truncated = mozLz4(json)
        truncated.removeLast(truncated.count / 2)
        XCTAssertNil(MozLz4.decode(truncated), "A truncated block must be rejected, not partially decoded.")
    }

    // MARK: - Bookmarks and history reuse the Firefox reader

    func testBookmarksAndHistoryComeFromPlacesSqliteLikeFirefox() throws {
        try writeZenProfile(files: [:])

        let payload = try BrowserDataReader(homeDirectory: home).read(.zen)
        XCTAssertEqual(payload.browser, .zen)
        XCTAssertEqual(payload.bookmarkRoot.name, "Imported From Zen Browser")
        XCTAssertEqual(payload.bookmarkRoot.subfolders.map(\.name), ["Bookmarks Toolbar"])
        XCTAssertEqual(payload.bookmarkRoot.subfolders.first?.bookmarks.map(\.title), ["GitHub"])
        XCTAssertEqual(payload.visits.map(\.url.absoluteString), ["https://github.com/"])
        XCTAssertEqual(payload.visits.first?.visitedAt, Date(timeIntervalSince1970: 1_678_300_800))
    }

    func testAProfileWithNoZenFilesStillImportsAndReportsNoStructure() throws {
        try writeZenProfile(files: [:])
        let payload = try BrowserDataReader(homeDirectory: home).read(.zen)
        XCTAssertNil(payload.zen, "Absent Zen files must be skipped, not turned into an empty structure.")
    }

    // MARK: - zen-sessions.jsonlz4

    func testSessionFileMapsWorkspacesPinnedEssentialAndOpenTabs() throws {
        try writeZenProfile(files: ["zen-sessions.jsonlz4": mozLz4(Self.sessionJSON)])

        let zen = try XCTUnwrap(try BrowserDataReader(homeDirectory: home).read(.zen).zen)

        XCTAssertEqual(zen.workspaces.map(\.name), ["Home", "Work"], "Workspaces must follow their position, not array order.")
        let homeSpace = try XCTUnwrap(zen.workspaces.first)
        let work = try XCTUnwrap(zen.workspaces.last)
        XCTAssertNil(homeSpace.emoji,"An SVG icon path is not an emoji and must not become the Space icon.")
        XCTAssertEqual(work.emoji, "\u{1F4BC}")

        let theme = try XCTUnwrap(work.theme)
        XCTAssertEqual(theme.colors.count, 2)
        XCTAssertEqual(theme.colors[0].red, 1, accuracy: 0.001)
        XCTAssertEqual(theme.colors[0].blue, 0, accuracy: 0.001)
        XCTAssertEqual(theme.colors[1].blue, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(theme.rotation), 45, accuracy: 0.001)
        XCTAssertEqual(theme.texture, 0.25, accuracy: 0.001)
        XCTAssertNil(homeSpace.theme)

        let pinned = zen.tabs.filter { $0.kind == .pinned }
        XCTAssertEqual(pinned.map(\.url.absoluteString), ["https://github.com/", "https://linear.app/"])
        XCTAssertEqual(pinned[0].title, "GitHub", "A pinned tab imports the entry the tab is on, not its first history entry.")
        XCTAssertEqual(pinned[0].workspaceUUID, "ws-work")
        XCTAssertEqual(pinned[0].folderID, "g1")
        XCTAssertEqual(pinned[1].url.absoluteString, "https://linear.app/", "A pinned tab that navigated away keeps its pinned home URL.")
        XCTAssertEqual(pinned[1].title, "Linear Home")
        XCTAssertNil(pinned[1].folderID)

        let essentials = zen.tabs.filter { $0.kind == .essential }
        XCTAssertEqual(essentials.map(\.url.absoluteString), ["https://mail.example.com/"])

        let open = zen.tabs.filter { $0.kind == .open }
        XCTAssertEqual(open.map(\.url.absoluteString), ["https://news.example.com/"])
        XCTAssertEqual(open.first?.workspaceUUID, "ws-home")
        XCTAssertNil(open.first?.folderID, "Only pinned tabs are placed in folders.")
        XCTAssertEqual(open.first?.lastAccessedAt, Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(zen.folders.map(\.name), ["Docs"])
        XCTAssertEqual(zen.folders.first?.isCollapsed, false)
        XCTAssertEqual(zen.tabs.count, 4, "Empty and about: tabs must not be imported.")
    }

    func testACorruptSessionFileIsSkippedWithoutLosingBookmarks() throws {
        try writeZenProfile(files: ["zen-sessions.jsonlz4": Data("mozLz40\0garbage-garbage".utf8)])

        let payload = try BrowserDataReader(homeDirectory: home).read(.zen)
        XCTAssertNil(payload.zen)
        XCTAssertEqual(payload.bookmarkRoot.totalBookmarkCount, 1)
    }

    // MARK: - recovery.jsonlz4

    func testOpenTabsFallBackToTheSessionstoreWindowsWhenZenSessionsIsAbsent() throws {
        let recovery = """
        {"windows":[{"tabs":[
            {"entries":[{"url":"https://a.example.com/","title":"A"}],"index":1,"zenWorkspace":"ws-1"},
            {"entries":[{"url":"https://pinned.example.com/","title":"P"}],"index":1,"pinned":true,"zenWorkspace":"ws-1"}
        ],"spaces":[{"uuid":"ws-1","name":"Only"}]}],"_closedWindows":[
            {"tabs":[{"entries":[{"url":"https://closed.example.com/","title":"C"}],"index":1}]}
        ]}
        """
        try writeZenProfile(files: ["sessionstore-backups/recovery.jsonlz4": mozLz4(Data(recovery.utf8))])

        let zen = try XCTUnwrap(try BrowserDataReader(homeDirectory: home).read(.zen).zen)
        XCTAssertEqual(zen.workspaces.map(\.name), ["Only"])
        XCTAssertEqual(
            zen.tabs.map(\.url.absoluteString),
            ["https://a.example.com/"],
            "Recovery supplies open tabs only, and never tabs from closed windows."
        )
    }

    // MARK: - Older places.sqlite tables

    func testOlderZenTablesInPlacesSqliteSupplyWorkspacesAndPins() throws {
        try writeZenProfile(files: [:]) { handle in
            try self.exec(handle, """
            CREATE TABLE zen_workspaces (
                id INTEGER PRIMARY KEY, uuid TEXT, name TEXT, icon TEXT, container_id INTEGER, position INTEGER,
                theme_type TEXT, theme_colors TEXT, theme_opacity REAL, theme_rotation REAL, theme_texture REAL
            );
            """)
            try self.exec(handle, """
            CREATE TABLE zen_pins (
                id INTEGER PRIMARY KEY, uuid TEXT, title TEXT, url TEXT, container_id INTEGER, workspace_uuid TEXT,
                position INTEGER, is_essential INTEGER DEFAULT 0, is_group INTEGER DEFAULT 0, parent_uuid TEXT,
                edited_title TEXT
            );
            """)
            try self.exec(handle, """
            INSERT INTO zen_workspaces (uuid, name, icon, position, theme_colors, theme_rotation, theme_texture) VALUES
                ('ws-b', 'Second', NULL, 1, NULL, NULL, NULL),
                ('ws-a', 'First', '\u{1F680}', 0, '[{"c":[0,128,255]}]', 90, 0.5);
            """)
            try self.exec(handle, """
            INSERT INTO zen_pins (uuid, title, url, workspace_uuid, position, is_essential, is_group, parent_uuid, edited_title) VALUES
                ('g-1', 'Reading', NULL, 'ws-a', 0, 0, 1, NULL, NULL),
                ('p-1', 'Article', 'https://article.example.com/', 'ws-a', 1, 0, 0, 'g-1', NULL),
                ('p-2', 'Original', 'https://docs.example.com/', 'ws-a', 2, 0, 0, NULL, 'Renamed'),
                ('p-3', 'Mail', 'https://mail.example.com/', 'ws-a', 3, 1, 0, NULL, NULL),
                ('p-4', 'Settings', 'about:preferences', 'ws-a', 4, 0, 0, NULL, NULL);
            """)
        }

        let zen = try XCTUnwrap(try BrowserDataReader(homeDirectory: home).read(.zen).zen)
        XCTAssertEqual(zen.workspaces.map(\.name), ["First", "Second"])
        XCTAssertEqual(zen.workspaces.first?.emoji, "\u{1F680}")
        let theme = try XCTUnwrap(zen.workspaces.first?.theme)
        XCTAssertEqual(theme.colors.count, 1)
        XCTAssertEqual(theme.colors[0].green, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(theme.rotation, 90)
        XCTAssertNil(zen.workspaces.last?.theme)

        XCTAssertEqual(zen.folders.map(\.name), ["Reading"])
        XCTAssertEqual(zen.folders.first?.workspaceUUID, "ws-a")
        let pins = zen.tabs.filter { $0.kind == .pinned }
        XCTAssertEqual(pins.map(\.url.absoluteString), ["https://article.example.com/", "https://docs.example.com/"])
        XCTAssertEqual(pins[0].folderID, "g-1")
        XCTAssertEqual(pins[1].title, "Renamed", "A title the user edited must win over the page title.")
        XCTAssertEqual(zen.tabs.filter { $0.kind == .essential }.map(\.url.absoluteString), ["https://mail.example.com/"])
    }

    // MARK: - Fixtures

    private static let sessionJSON = Data("""
    {
      "spaces": [
        {"uuid": "ws-work", "name": "Work", "icon": "\u{1F4BC}", "position": 1,
         "theme": {"type": "gradient", "gradientColors": [{"c": [255, 0, 0]}, {"c": [0, 0, 255]}],
                   "opacity": 0.5, "rotation": 45, "texture": 0.25}},
        {"uuid": "ws-home", "name": "Home", "icon": "chrome://browser/skin/zen-icons/selectable/heart.svg", "position": 0}
      ],
      "groups": [{"id": "g1", "name": "Docs", "collapsed": false, "pinned": true}],
      "tabs": [
        {"entries": [{"url": "https://old.example.com/", "title": "Old"}, {"url": "https://github.com/", "title": "GitHub"}],
         "index": 2, "pinned": true, "zenWorkspace": "ws-work", "groupId": "g1"},
        {"entries": [{"url": "https://linear.app/issue/1", "title": "Issue 1"}], "index": 1, "pinned": true,
         "zenWorkspace": "ws-work",
         "_zenPinnedInitialState": {"entry": {"url": "https://linear.app/", "title": "Linear Home"}}},
        {"entries": [{"url": "https://mail.example.com/", "title": "Mail"}], "index": 1, "pinned": true,
         "zenEssential": true, "zenWorkspace": "ws-home"},
        {"entries": [{"url": "https://news.example.com/", "title": "News"}], "index": 1,
         "zenWorkspace": "ws-home", "lastAccessed": 1700000000000},
        {"entries": [{"url": "about:blank", "title": ""}], "index": 1, "zenIsEmpty": true, "zenWorkspace": "ws-home"},
        {"entries": [{"url": "about:newtab", "title": "New Tab"}], "index": 1, "zenWorkspace": "ws-home"}
      ]
    }
    """.utf8)

    private func mozLz4(_ json: Data) -> Data {
        var output = Data("mozLz40\0".utf8)
        var size = UInt32(json.count).littleEndian
        output.append(Data(bytes: &size, count: 4))

        let capacity = json.count + json.count / 255 + 64
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer { destination in
            json.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, json.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        output.append(contentsOf: buffer.prefix(written))
        return output
    }

    private func writeZenProfile(
        files: [String: Data],
        extraPlaces: @escaping (OpaquePointer) throws -> Void = { _ in }
    ) throws {
        let root = try XCTUnwrap(ImportableBrowser.zen.firefoxFamilyRoot(homeDirectory: home))
        let directory = root.appendingPathComponent("Profiles/abcd1234.Default (release)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "[Profile0]\nName=Default (release)\nIsRelative=1\nPath=Profiles/abcd1234.Default (release)\nDefault=1\n"
            .write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        try writePlaces(in: directory, extra: extraPlaces)

        for (relativePath, data) in files {
            let url = directory.appendingPathComponent(relativePath, isDirectory: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    private func writePlaces(in directory: URL, extra: (OpaquePointer) throws -> Void = { _ in }) throws {
        let handle = try openDatabase(at: directory.appendingPathComponent("places.sqlite", isDirectory: false))
        defer { sqlite3_close(handle) }

        try exec(handle, """
        CREATE TABLE moz_places (
            id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR,
            visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL,
            frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT
        );
        """)
        try exec(handle, """
        CREATE TABLE moz_bookmarks (
            id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER,
            title LONGVARCHAR, dateAdded INTEGER, lastModified INTEGER, guid TEXT
        );
        """)
        try exec(handle, """
        INSERT INTO moz_places (id, url, title, visit_count, hidden, typed, last_visit_date)
            VALUES (101, 'https://github.com/', 'GitHub', 12, 0, 3, \(Self.visitPRTime));
        """)
        try exec(handle, """
        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
            (50, 2, NULL, 0, 0, '', 'root________'),
            (51, 2, NULL, 50, 1, 'toolbar', 'toolbar_____'),
            (201, 1, 101, 51, 0, 'GitHub', 'bm0000000001');
        """)
        try extra(handle)
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "ZenImportReaderTests", code: 1, userInfo: [
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
            throw NSError(domain: "ZenImportReaderTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Fixture SQL failed: \(message)",
            ])
        }
    }
}
