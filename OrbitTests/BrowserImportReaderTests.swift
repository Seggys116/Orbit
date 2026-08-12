import XCTest
#if canImport(SQLite3)
import SQLite3
#endif

final class BrowserImportReaderTests: XCTestCase {

    private var home: URL!
    // Left open for the WAL test; closed in tearDown, not at each call site.
    private var openDatabaseHandles: [OpaquePointer] = []

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-BrowserImport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for handle in openDatabaseHandles { sqlite3_close(handle) }
        openDatabaseHandles = []
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
        home = nil
        super.tearDown()
    }

    // MARK: - Absence

    func testEmptyHomeDirectoryOffersNoBrowsersAndReportsNotInstalled() throws {
        let reader = BrowserDataReader(homeDirectory: home)
        XCTAssertEqual(reader.availableBrowsers(), [], "A home directory with no browser data must offer nothing to import.")

        for browser in ImportableBrowser.allCases {
            XCTAssertFalse(browser.isPresent(homeDirectory: home), "\(browser.displayName) reported present in an empty home directory.")
            do {
                _ = try reader.read(browser)
                XCTFail("Reading \(browser.displayName) from an empty home directory should have thrown notInstalled.")
            } catch let error as BrowserImportError {
                guard case .notInstalled(let reported) = error else {
                    return XCTFail("Expected .notInstalled for \(browser.displayName), got \(error).")
                }
                XCTAssertEqual(reported, browser)
            }
        }
    }

    // MARK: - Safari bookmarks (real binary plist)

    func testSafariBookmarksParseFromARealBinaryPropertyList() throws {
        let plistURL = try writeSafariBookmarksFixture()

        let magic = try Data(contentsOf: plistURL).prefix(8)
        XCTAssertEqual(String(decoding: magic, as: UTF8.self), "bplist00", "Fixture is not a binary property list.")

        let payload = try BrowserDataReader(homeDirectory: home).read(.safari)

        XCTAssertEqual(payload.browser, .safari)
        XCTAssertEqual(payload.bookmarkRoot.name, "Imported From Safari")

        let topLevel = payload.bookmarkRoot.subfolders.map(\.name)
        XCTAssertEqual(
            topLevel,
            ["Favourites", "Bookmarks Menu"],
            "Safari's internal BookmarksBar/BookmarksMenu titles must be renamed, and com.apple.ReadingList must not be imported."
        )

        let favourites = try XCTUnwrap(payload.bookmarkRoot.subfolders.first)
        XCTAssertEqual(
            favourites.bookmarks,
            [
                ImportedBookmark(title: "Apple", url: URL(string: "https://www.apple.com/")!),
                ImportedBookmark(title: "Hacker News", url: URL(string: "https://news.ycombinator.com/")!),
            ],
            "Exact titles come from URIDictionary.title and exact URLs from URLString."
        )

        XCTAssertEqual(favourites.bookmarks.count, 2)

        XCTAssertEqual(
            favourites.subfolders.map(\.name),
            ["Dev"],
            "The empty top-level \"Empty\" list must not survive as a folder."
        )
        let nested = try XCTUnwrap(favourites.subfolders.first)
        XCTAssertEqual(nested.name, "Dev")
        XCTAssertEqual(
            nested.subfolders.map(\.name),
            ["Apple Docs"],
            "Nested empty folders — including one that only contains another empty folder — must be pruned recursively."
        )
        XCTAssertEqual(nested.bookmarks.map(\.title), ["Swift Forums"])
        XCTAssertEqual(nested.bookmarks.first?.url, URL(string: "https://forums.swift.org/")!)

        let deeper = try XCTUnwrap(nested.subfolders.first)
        XCTAssertEqual(deeper.name, "Apple Docs", "Three levels of nesting must survive the walk.")
        XCTAssertEqual(deeper.bookmarks.map(\.url.absoluteString), ["https://developer.apple.com/documentation/"])

        XCTAssertEqual(payload.bookmarkRoot.totalBookmarkCount, 5, "totalBookmarkCount must count every nested bookmark.")
    }

    func testCorruptSafariBookmarksPlistReportsUnreadableRatherThanCrashing() throws {
        let directory = home.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is definitely not a property list".utf8)
            .write(to: directory.appendingPathComponent("Bookmarks.plist"))

        do {
            _ = try BrowserDataReader(homeDirectory: home).read(.safari)
            XCTFail("A corrupt Bookmarks.plist should throw .unreadable.")
        } catch let error as BrowserImportError {
            guard case .unreadable(let browser, _) = error else {
                return XCTFail("Expected .unreadable, got \(error).")
            }
            XCTAssertEqual(browser, .safari)
            XCTAssertNotNil(error.errorDescription)
        }
    }

    // MARK: - Safari history (real SQLite, CFAbsoluteTime epoch)

    func testSafariHistoryConvertsCFAbsoluteTimeToTheCorrectDate() throws {
        try writeSafariHistoryFixture()

        let payload = try BrowserDataReader(homeDirectory: home).read(.safari)
        XCTAssertEqual(payload.visits.count, 2, "Both history_visits rows must come through the join.")

        let newest = try XCTUnwrap(payload.visits.first)
        XCTAssertEqual(newest.url, URL(string: "https://www.swift.org/")!)
        XCTAssertEqual(newest.title, "Swift.org")
        XCTAssertEqual(newest.visitCount, 7)
        XCTAssertFalse(newest.wasTyped, "Safari's schema has no typed flag; wasTyped must never be fabricated.")

        XCTAssertEqual(newest.visitedAt.timeIntervalSince1970, 1_678_307_200, accuracy: 0.001)
        XCTAssertEqual(Self.iso8601(newest.visitedAt), "2023-03-08T20:26:40Z")

        let older = payload.visits[1]
        XCTAssertEqual(Self.iso8601(older.visitedAt), "2001-01-01T00:00:00Z", "visit_time 0 is the CFAbsoluteTime reference date, not 1970.")
        XCTAssertTrue(newest.visitedAt > older.visitedAt, "Visits must come back most-recent-first.")
    }

    func testHistoryIsReadableWhileTheSourceDatabaseIsWALActiveAndStillOpen() throws {
        let directory = home.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("History.db", isDirectory: false)

        let handle = try openDatabase(at: databaseURL)
        openDatabaseHandles.append(handle)
        try exec(handle, "PRAGMA journal_mode = WAL;")
        try exec(handle, Self.safariSchema)
        try exec(handle, """
        INSERT INTO history_items (id, url, visit_count) VALUES (1, 'https://www.swift.org/', 7);
        INSERT INTO history_visits (id, history_item, visit_time, title)
        VALUES (1, 1, 700000000.0, 'Swift.org');
        """)

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walSize = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(walSize, 0, "Fixture did not actually leave data in a -wal sidecar; this test would prove nothing.")

        let payload = try BrowserDataReader(homeDirectory: home).read(.safari)
        XCTAssertEqual(payload.visits.count, 1, "The reader must copy the -wal alongside the database and replay it.")
        XCTAssertEqual(payload.visits.first?.url, URL(string: "https://www.swift.org/")!)
        XCTAssertEqual(Self.iso8601(try XCTUnwrap(payload.visits.first).visitedAt), "2023-03-08T20:26:40Z")
    }

    func testCorruptHistoryDatabaseReportsUnreadableRatherThanCrashing() throws {
        let directory = home.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8192)
            .write(to: directory.appendingPathComponent("History.db"))

        do {
            _ = try BrowserDataReader(homeDirectory: home).read(.safari)
            XCTFail("A corrupt History.db should throw .unreadable.")
        } catch let error as BrowserImportError {
            guard case .unreadable(let browser, let reason) = error else {
                return XCTFail("Expected .unreadable, got \(error).")
            }
            XCTAssertEqual(browser, .safari)
            XCTAssertFalse(reason.isEmpty, "The failure reason must carry SQLite's own message.")
        }
    }

    // MARK: - Chromium bookmarks + history

    func testChromeBookmarksAndHistoryParseWithTheCorrectChromiumEpoch() throws {
        try writeChromiumFixture(for: .chrome, profileDirectoryName: "Default", profileDisplayName: "Person 1")

        let reader = BrowserDataReader(homeDirectory: home)
        XCTAssertEqual(reader.availableBrowsers(), [.chrome])

        let payload = try reader.read(.chrome)
        XCTAssertEqual(payload.bookmarkRoot.name, "Imported From Google Chrome")
        XCTAssertEqual(payload.bookmarkRoot.subfolders.map(\.name), ["Bookmarks Bar", "Other Bookmarks"])

        let bar = try XCTUnwrap(payload.bookmarkRoot.subfolders.first)
        XCTAssertEqual(
            bar.bookmarks,
            [ImportedBookmark(title: "GitHub", url: URL(string: "https://github.com/")!)],
            "chrome://settings must be filtered out; only the real web URL survives."
        )
        let work = try XCTUnwrap(bar.subfolders.first)
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(work.bookmarks.map(\.title), ["Linear"])
        XCTAssertEqual(
            work.subfolders.map(\.name),
            ["Docs"],
            "The nested empty \"Archive\" folder must be pruned; \"Mobile Bookmarks\" (empty at the root) must not appear either."
        )
        XCTAssertEqual(work.subfolders.first?.bookmarks.map(\.url.absoluteString), ["https://docs.example.com/"])
        XCTAssertEqual(payload.bookmarkRoot.totalBookmarkCount, 4)

        XCTAssertEqual(payload.visits.count, 2, "The chrome://newtab row must be excluded even though it has the newest timestamp.")
        XCTAssertFalse(
            payload.visits.contains { $0.url.scheme == "chrome" },
            "Internal chrome:// pages must never be imported into history."
        )
        let newest = try XCTUnwrap(payload.visits.first)
        XCTAssertEqual(newest.url, URL(string: "https://github.com/")!)
        XCTAssertEqual(newest.title, "GitHub")
        XCTAssertEqual(newest.visitCount, 12)
        XCTAssertTrue(newest.wasTyped, "typed_count 3 must map to wasTyped == true.")

        XCTAssertEqual(newest.visitedAt.timeIntervalSince1970, 1_678_300_800, accuracy: 0.001)
        XCTAssertEqual(Self.iso8601(newest.visitedAt), "2023-03-08T18:40:00Z")

        let older = payload.visits[1]
        XCTAssertFalse(older.wasTyped, "typed_count 0 must map to wasTyped == false.")
        XCTAssertEqual(Self.iso8601(older.visitedAt), "2013-01-01T00:00:00Z")
    }

    func testMultipleChromeProfilesAreKeptSeparateAndNamedFromPreferences() throws {
        try writeChromiumFixture(for: .chrome, profileDirectoryName: "Default", profileDisplayName: "Person 1")
        try writeChromiumFixture(for: .chrome, profileDirectoryName: "Profile 1", profileDisplayName: "Work Account")

        let payload = try BrowserDataReader(homeDirectory: home).read(.chrome)
        XCTAssertEqual(
            payload.bookmarkRoot.subfolders.map(\.name),
            ["Person 1", "Work Account"],
            "With more than one profile, each profile's tree must be nested under that profile's display name from its Preferences file."
        )
        XCTAssertEqual(payload.bookmarkRoot.totalBookmarkCount, 8, "Both profiles' bookmarks must come through.")
        XCTAssertEqual(payload.visits.count, 4, "Both profiles' history must come through.")
        XCTAssertEqual(
            payload.visits.map { $0.visitedAt },
            payload.visits.map { $0.visitedAt }.sorted(by: >),
            "Merged multi-profile history must be re-sorted most-recent-first."
        )
    }

    func testHistoryLimitClampsTheNumberOfRowsRead() throws {
        try writeChromiumFixture(for: .chrome, profileDirectoryName: "Default", profileDisplayName: "Person 1")
        let payload = try BrowserDataReader(homeDirectory: home).read(.chrome, historyLimit: 1)
        XCTAssertEqual(payload.visits.count, 1)
        XCTAssertEqual(payload.visits.first?.url, URL(string: "https://github.com/")!, "The limit must keep the most recent visit.")
    }

    func testCorruptChromeBookmarksJSONReportsUnreadable() throws {
        try writeChromiumFixture(for: .chrome, profileDirectoryName: "Default", profileDisplayName: "Person 1")
        let bookmarks = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")
        try Data("{ not json".utf8).write(to: bookmarks)

        do {
            _ = try BrowserDataReader(homeDirectory: home).read(.chrome)
            XCTFail("A corrupt Bookmarks JSON file should throw .unreadable.")
        } catch let error as BrowserImportError {
            guard case .unreadable(let browser, _) = error else {
                return XCTFail("Expected .unreadable, got \(error).")
            }
            XCTAssertEqual(browser, .chrome)
        }
    }

    // MARK: - The other Chromium browsers, each at its own real path

    func testBraveIsReadFromItsOwnUserDataDirectory() throws {
        try writeChromiumFixture(for: .brave, profileDirectoryName: "Default", profileDisplayName: "Person 1")
        let reader = BrowserDataReader(homeDirectory: home)
        XCTAssertEqual(reader.availableBrowsers(), [.brave])
        let payload = try reader.read(.brave)
        XCTAssertEqual(payload.bookmarkRoot.name, "Imported From Brave")
        XCTAssertEqual(payload.bookmarkRoot.totalBookmarkCount, 4)
        XCTAssertEqual(payload.visits.count, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks").path
            ),
            "Fixture must sit at Brave's real path, or this test proves nothing about path resolution."
        )
    }

    func testEdgeIsReadFromItsOwnUserDataDirectory() throws {
        try writeChromiumFixture(for: .edge, profileDirectoryName: "Default", profileDisplayName: "Person 1")
        let reader = BrowserDataReader(homeDirectory: home)
        XCTAssertEqual(reader.availableBrowsers(), [.edge])
        let payload = try reader.read(.edge)
        XCTAssertEqual(payload.bookmarkRoot.name, "Imported From Microsoft Edge")
        XCTAssertEqual(payload.bookmarkRoot.totalBookmarkCount, 4)
        XCTAssertEqual(payload.visits.count, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Library/Application Support/Microsoft Edge/Default/Bookmarks").path
            )
        )
    }

    func testOperaIsReadFromTheUserDataDirectoryItselfWithNoProfileSubfolder() throws {
        try writeChromiumFixture(for: .opera, profileDirectoryName: nil, profileDisplayName: nil)
        let reader = BrowserDataReader(homeDirectory: home)
        XCTAssertEqual(reader.availableBrowsers(), [.opera])
        let payload = try reader.read(.opera)
        XCTAssertEqual(payload.bookmarkRoot.name, "Imported From Opera")
        XCTAssertEqual(payload.bookmarkRoot.totalBookmarkCount, 4)
        XCTAssertEqual(payload.visits.count, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Library/Application Support/com.operasoftware.Opera/Bookmarks").path
            ),
            "Opera's Bookmarks file must be found without a Default/ subfolder."
        )
    }

    func testAvailableBrowsersListsEveryBrowserWithDataPresent() throws {
        try writeSafariBookmarksFixture()
        try writeChromiumFixture(for: .chrome, profileDirectoryName: "Default", profileDisplayName: "Person 1")
        try writeChromiumFixture(for: .edge, profileDirectoryName: "Default", profileDisplayName: "Person 1")

        XCTAssertEqual(
            BrowserDataReader(homeDirectory: home).availableBrowsers(),
            [.safari, .chrome, .edge],
            "availableBrowsers must list exactly the browsers with real data, in allCases order."
        )
    }

    // MARK: - Fixture builders

    @discardableResult
    private func writeSafariBookmarksFixture() throws -> URL {
        func leaf(_ title: String, _ urlString: String) -> [String: Any] {
            [
                "WebBookmarkType": "WebBookmarkTypeLeaf",
                "WebBookmarkUUID": UUID().uuidString,
                "URLString": urlString,
                "URIDictionary": ["title": title],
            ]
        }
        func list(_ title: String, _ children: [Any]) -> [String: Any] {
            [
                "WebBookmarkType": "WebBookmarkTypeList",
                "WebBookmarkUUID": UUID().uuidString,
                "Title": title,
                "Children": children,
            ]
        }

        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkUUID": UUID().uuidString,
            "Title": "",
            "Children": [
                list("BookmarksBar", [
                    leaf("Apple", "https://www.apple.com/"),
                    [
                        "WebBookmarkType": "WebBookmarkTypeProxy",
                        "WebBookmarkIdentifier": "History",
                        "Title": "History",
                    ] as [String: Any],
                    leaf("Hacker News", "https://news.ycombinator.com/"),
                    list("Dev", [
                        leaf("Swift Forums", "https://forums.swift.org/"),
                        list("Apple Docs", [
                            leaf("Documentation", "https://developer.apple.com/documentation/"),
                        ]),
                        list("Scratch", []),
                        list("Outer Scratch", [list("Inner Scratch", [])]),
                    ]),
                ]),
                list("BookmarksMenu", [
                    leaf("Wikipedia", "https://en.wikipedia.org/"),
                ]),
                list("com.apple.ReadingList", [
                    leaf("Saved For Later", "https://example.com/saved"),
                ]),
                list("Empty", []),
            ],
        ]

        let directory = home.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Bookmarks.plist", isDirectory: false)
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: url)
        return url
    }

    private static let safariSchema = """
    CREATE TABLE history_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL UNIQUE,
        domain_expansion TEXT NULL,
        visit_count INTEGER NOT NULL,
        daily_visit_counts BLOB NOT NULL DEFAULT x'',
        weekly_visit_counts BLOB NULL,
        autocomplete_triggers BLOB NULL,
        should_recompute_derived_visit_counts INTEGER NOT NULL DEFAULT 0,
        visit_count_score INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE history_visits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
        visit_time REAL NOT NULL,
        title TEXT NULL,
        load_successful BOOLEAN NOT NULL DEFAULT 1,
        http_non_get BOOLEAN NOT NULL DEFAULT 0,
        synthesized BOOLEAN NOT NULL DEFAULT 0,
        redirect_source INTEGER NULL,
        redirect_destination INTEGER NULL,
        origin INTEGER NOT NULL DEFAULT 0,
        generation INTEGER NOT NULL DEFAULT 0,
        attributes INTEGER NOT NULL DEFAULT 0,
        score INTEGER NOT NULL DEFAULT 0
    );
    """

    private func writeSafariHistoryFixture() throws {
        let directory = home.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = try openDatabase(at: directory.appendingPathComponent("History.db", isDirectory: false))
        defer { sqlite3_close(handle) }
        try exec(handle, Self.safariSchema)
        try exec(handle, """
        INSERT INTO history_items (id, url, visit_count) VALUES (1, 'https://www.swift.org/', 7);
        INSERT INTO history_items (id, url, visit_count) VALUES (2, 'https://example.com/', 1);
        INSERT INTO history_visits (id, history_item, visit_time, title)
        VALUES (1, 1, 700000000.0, 'Swift.org');
        INSERT INTO history_visits (id, history_item, visit_time, title)
        VALUES (2, 2, 0.0, 'Example');
        """)
    }

    // profileDirectoryName nil writes the files directly into the user-data
    // directory, which is how Opera lays them out.
    private func writeChromiumFixture(
        for browser: ImportableBrowser,
        profileDirectoryName: String?,
        profileDisplayName: String?
    ) throws {
        let userData = try XCTUnwrap(browser.userDataDirectory(homeDirectory: home))
        let profileDirectory = profileDirectoryName.map { userData.appendingPathComponent($0, isDirectory: true) } ?? userData
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

        let bookmarks: [String: Any] = [
            "version": 1,
            "checksum": "0123456789abcdef",
            "roots": [
                "bookmark_bar": [
                    "type": "folder",
                    "name": "Bookmarks Bar",
                    "children": [
                        ["type": "url", "name": "GitHub", "url": "https://github.com/"] as [String: Any],
                        ["type": "url", "name": "Settings", "url": "chrome://settings"] as [String: Any],
                        [
                            "type": "folder",
                            "name": "Work",
                            "children": [
                                ["type": "url", "name": "Linear", "url": "https://linear.app/"] as [String: Any],
                                [
                                    "type": "folder",
                                    "name": "Docs",
                                    "children": [
                                        ["type": "url", "name": "Docs Home", "url": "https://docs.example.com/"] as [String: Any],
                                    ],
                                ] as [String: Any],
                                ["type": "folder", "name": "Archive", "children": [] as [Any]] as [String: Any],
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
                "synced": [
                    "type": "folder",
                    "name": "Mobile Bookmarks",
                    "children": [] as [Any],
                ] as [String: Any],
            ],
        ]
        try JSONSerialization.data(withJSONObject: bookmarks, options: [])
            .write(to: profileDirectory.appendingPathComponent("Bookmarks", isDirectory: false))

        if let profileDisplayName {
            let preferences: [String: Any] = ["profile": ["name": profileDisplayName]]
            try JSONSerialization.data(withJSONObject: preferences, options: [])
                .write(to: profileDirectory.appendingPathComponent("Preferences", isDirectory: false))
        }

        let handle = try openDatabase(at: profileDirectory.appendingPathComponent("History", isDirectory: false))
        defer { sqlite3_close(handle) }
        try exec(handle, """
        CREATE TABLE urls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url LONGVARCHAR,
            title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0 NOT NULL,
            typed_count INTEGER DEFAULT 0 NOT NULL,
            last_visit_time INTEGER NOT NULL,
            hidden INTEGER DEFAULT 0 NOT NULL
        );
        """)
        try exec(handle, """
        INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden)
        VALUES ('https://github.com/', 'GitHub', 12, 3, 13322774400000000, 0);
        INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden)
        VALUES ('https://linear.app/', 'Linear', 4, 0, 13001472000000000, 0);
        INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden)
        VALUES ('chrome://newtab/', 'New Tab', 99, 0, 13322774400000001, 0);
        """)
    }

    // MARK: - SQLite fixture plumbing (system libsqlite3, same as production)

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "BrowserImportReaderTests", code: 1, userInfo: [
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
            throw NSError(domain: "BrowserImportReaderTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Fixture SQL failed: \(message)",
            ])
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
