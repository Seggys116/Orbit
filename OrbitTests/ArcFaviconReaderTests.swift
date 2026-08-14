import AppKit
import XCTest
#if canImport(SQLite3)
import SQLite3
#endif

final class ArcFaviconReaderTests: XCTestCase {

    private var profile: URL!

    override func setUp() {
        super.setUp()
        profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ArcFavicons-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let profile {
            try? FileManager.default.removeItem(at: profile)
        }
        profile = nil
        super.tearDown()
    }

    // MARK: - The main actor must not do the disk work

    // A bulk import used to PNG-encode, atomically write and stat-scan the whole
    // cache directory synchronously on the main actor, once per icon, which froze
    // the app. The disk work still costs what it costs; it just must not be
    // billed to the main actor.
    @MainActor
    func testABulkImportDoesNotBlockTheMainActorOnDiskWork() async throws {
        let directory = profile.appendingPathComponent("favicons", isDirectory: true)
        let cache = FaviconCache(diskDirectory: directory)
        var icons: [String: Data] = [:]
        for index in 0..<200 {
            icons["host\(index).example"] = try pngData(width: 32, height: 32)
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let accepted = cache.cacheImported(imageDataByHost: icons)
        let onMainActor = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        await cache._test_awaitPendingWrites()
        let includingDisk = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        XCTAssertEqual(accepted, 200)
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: directory.path), true,
            "the icons must genuinely have been written, or this measures nothing"
        )
        XCTAssertLessThan(
            onMainActor, includingDisk,
            "the main actor returned only after the disk work finished, so the work is still synchronous on it — \(onMainActor)ms of \(includingDisk)ms total"
        )
        XCTAssertLessThan(
            onMainActor, 250,
            "storing 200 icons blocked the main actor for \(onMainActor)ms; the PNG encode, atomic write and eviction scan have moved back onto it"
        )
    }

    // The decode stays on the main actor because the accepted-count is returned
    // synchronously; measured at ~55ms per 200 icons, and only on a one-off
    // import. Fails if that ever grows into the per-page path's territory.
    @MainActor
    func testASinglePageLoadsFaviconBarelyTouchesTheMainActor() async throws {
        let cache = FaviconCache(diskDirectory: profile.appendingPathComponent("favicons", isDirectory: true))
        let icon = try pngData(width: 32, height: 32)

        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(cache.cache(imageData: icon, forHost: "example.com"))
        let onMainActor = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        XCTAssertNotNil(cache.cachedImage(forHost: "example.com"),
                        "the icon must be readable synchronously the instant it is cached, or tab rows flicker")
        XCTAssertLessThan(
            onMainActor, 10,
            "caching one favicon blocked the main actor for \(onMainActor)ms; this runs on every page load"
        )
        await cache._test_awaitPendingWrites()
    }

    // MARK: - Absence

    func testAProfileWithNoFaviconsDatabaseImportsNothing() throws {
        XCTAssertEqual(
            try ArcFaviconReader.read(profileDirectory: profile, browser: .arc),
            [],
            "A profile that never stored an icon must import nothing rather than throwing and failing the whole import."
        )
    }

    // MARK: - Choosing one bitmap per host

    func testTheLargestBitmapAHostOffersIsTheOneImported() throws {
        try writeDatabase([
            Row(pageURL: "https://example.com/", iconID: 1, width: 16, height: 16),
            Row(pageURL: "https://example.com/docs", iconID: 1, width: 48, height: 48),
            Row(pageURL: "https://example.com/", iconID: 1, width: 32, height: 32),
        ])

        let favicons = try ArcFaviconReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(favicons.count, 1, "One host must yield one icon, not one per page URL: \(favicons.map(\.host))")
        XCTAssertEqual(favicons.first?.host, "example.com")
        XCTAssertEqual(favicons.first?.width, 48, "The 16pt icon would be upscaled and blurry next to the 48pt one Arc already had.")
    }

    func testASquareBitmapWinsOverAStretchedOneOfTheSameWidth() throws {
        try writeDatabase([
            Row(pageURL: "https://example.com/", iconID: 1, width: 32, height: 16),
            Row(pageURL: "https://example.com/", iconID: 1, width: 32, height: 32),
        ])

        let favicon = try XCTUnwrap(try ArcFaviconReader.read(profileDirectory: profile, browser: .arc).first)

        XCTAssertEqual(favicon.height, 32, "A 32x16 bitmap renders letterboxed in a square favicon slot.")
    }

    func testZeroSizedAndEmptyBitmapsAreSkippedRatherThanImportedAsBlanks() throws {
        try writeDatabase([
            Row(pageURL: "https://sized.example/", iconID: 1, width: 0, height: 0),
            Row(pageURL: "https://sized.example/", iconID: 1, width: 24, height: 24),
            Row(pageURL: "https://empty.example/", iconID: 2, width: 32, height: 32, imageData: Data()),
        ])

        let favicons = try ArcFaviconReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(favicons.map(\.host), ["sized.example"], "A host whose only bitmap has no bytes has no icon to import.")
        XCTAssertEqual(favicons.first?.width, 24)
    }

    func testAnIconChromiumMarkedInvalidIsNotImported() throws {
        try writeDatabase([
            Row(pageURL: "https://invalid.example/", iconID: 1, width: 32, height: 32, iconType: 0),
            Row(pageURL: "https://valid.example/", iconID: 2, width: 32, height: 32),
        ])

        XCTAssertEqual(
            try ArcFaviconReader.read(profileDirectory: profile, browser: .arc).map(\.host),
            ["valid.example"]
        )
    }

    // MARK: - Hosts

    func testOnlyWebPagesYieldAHostAndItMatchesTheKeyOrbitCachesLiveIconsUnder() throws {
        try writeDatabase([
            Row(pageURL: "https://WWW.Example.ORG/path?q=1", iconID: 1, width: 32, height: 32),
            Row(pageURL: "chrome://newtab/", iconID: 2, width: 32, height: 32),
            Row(pageURL: "about:blank", iconID: 3, width: 32, height: 32),
            Row(pageURL: "not a url", iconID: 4, width: 32, height: 32),
            Row(pageURL: "file:///Users/someone/page.html", iconID: 5, width: 32, height: 32),
        ])

        XCTAssertEqual(
            try ArcFaviconReader.read(profileDirectory: profile, browser: .arc).map(\.host),
            ["www.example.org"],
            "Orbit keys its cache on URL.host(), so www must survive and internal pages must contribute nothing."
        )
    }

    func testTheLimitCapsHowManyHostsAreImported() throws {
        try writeDatabase([
            Row(pageURL: "https://one.example/", iconID: 1, width: 32, height: 32),
            Row(pageURL: "https://two.example/", iconID: 2, width: 32, height: 32),
            Row(pageURL: "https://three.example/", iconID: 3, width: 32, height: 32),
        ])

        XCTAssertEqual(try ArcFaviconReader.read(profileDirectory: profile, browser: .arc, limit: 2).count, 2)
        XCTAssertEqual(
            try ArcFaviconReader.read(profileDirectory: profile, browser: .arc, limit: 0),
            [],
            "A zero limit must read nothing at all, not everything."
        )
    }

    // MARK: - Icons reached through another host's links

    func testAHostsOwnIconWinsOverOneReachedThroughItsRedirectorLinks() throws {
        let blobs = try writeDatabase([
            Row(
                pageURL: "https://www.youtube.com/redirect?q=https%3A%2F%2Fgithub.com%2F",
                iconID: 2,
                width: 32,
                height: 32,
                iconURL: "https://github.githubassets.com/favicons/favicon-dark.svg",
                lastUpdated: 13_400_000_000_000_000,
                fill: .systemGreen
            ),
            Row(
                pageURL: "https://www.youtube.com/",
                iconID: 1,
                width: 32,
                height: 32,
                iconURL: "https://www.youtube.com/s/desktop/img/favicon.ico",
                lastUpdated: 13_300_000_000_000_000,
                fill: .systemRed
            ),
            Row(
                pageURL: "https://www.youtube.com/watch?v=1",
                iconID: 1,
                width: 32,
                height: 32,
                iconURL: "https://www.youtube.com/s/desktop/img/favicon.ico",
                lastUpdated: 13_300_000_000_000_000,
                fill: .systemRed
            ),
        ])

        let favicons = try ArcFaviconReader.read(profileDirectory: profile, browser: .arc)

        XCTAssertEqual(favicons.map(\.host), ["www.youtube.com"])
        XCTAssertEqual(
            favicons.first?.imageData,
            blobs[1],
            "youtube.com/redirect?q=github.com really does show GitHub's icon, so Arc maps it under youtube.com — importing it as youtube.com's own icon is the crossed mapping."
        )
    }

    func testAnIconServedFromTheHostItselfBreaksATieAgainstAForeignOne() throws {
        let blobs = try writeDatabase([
            Row(
                pageURL: "https://shop.example/out?to=vendor",
                iconID: 2,
                width: 32,
                height: 32,
                iconURL: "https://vendor.invalid/favicon.ico",
                lastUpdated: 13_400_000_000_000_000,
                fill: .systemGreen
            ),
            Row(
                pageURL: "https://shop.example/",
                iconID: 1,
                width: 32,
                height: 32,
                iconURL: "https://shop.example/favicon.ico",
                lastUpdated: 13_300_000_000_000_000,
                fill: .systemRed
            ),
        ])

        XCTAssertEqual(
            try ArcFaviconReader.read(profileDirectory: profile, browser: .arc).first?.imageData,
            blobs[1],
            "With one page URL each, the icon the host serves itself is the only trustworthy signal."
        )
    }

    func testAHostWithFewPageURLsIsStillImportedAlongsideOneWithMany() throws {
        var rows: [Row] = (0..<20).map { index in
            Row(pageURL: "https://busy.example/page\(index)", iconID: 1, width: 32, height: 32)
        }
        rows.append(Row(pageURL: "https://quiet.example/", iconID: 2, width: 32, height: 32))
        try writeDatabase(rows)

        XCTAssertEqual(
            try ArcFaviconReader.read(profileDirectory: profile, browser: .arc, limit: 2).map(\.host),
            ["busy.example", "quiet.example"],
            "A row limit spent on one busy host's page URLs is what left most sites with no icon at all."
        )
    }

    // MARK: - Landing in Orbit's cache

    @MainActor
    func testAnImportedIconIsFoundByTheLookupThatDrawsTabRowsAndTheCommandBar() throws {
        try writeDatabase([
            Row(pageURL: "https://example.com/", iconID: 1, width: 32, height: 32),
        ])
        let cache = FaviconCache(diskDirectory: temporaryCacheDirectory())

        let favicons = try ArcFaviconReader.read(profileDirectory: profile, browser: .arc)
        let stored = cache.cache(imageDataByHost: Dictionary(
            favicons.map { ($0.host, $0.imageData) },
            uniquingKeysWith: { first, _ in first }
        ))

        XCTAssertEqual(stored, 1)
        let image = try XCTUnwrap(
            cache.cachedImage(forHost: "example.com"),
            "The import is pointless unless the ordinary lookup finds it."
        )
        XCTAssertEqual(image.size, NSSize(width: 32, height: 32))
        XCTAssertNotNil(
            cache.cachedImage(forHost: "EXAMPLE.COM"),
            "Hosts arrive in mixed case from page URLs; the cache key is case-insensitive."
        )
        XCTAssertNil(cache.cachedImage(forHost: "never-visited.example"))
    }

    @MainActor
    func testAnImportedIconSurvivesARestartByBeingOnDiskAndNotOnlyInMemory() async throws {
        try writeDatabase([
            Row(pageURL: "https://example.com/", iconID: 1, width: 32, height: 32),
        ])
        let directory = temporaryCacheDirectory()
        let favicons = try ArcFaviconReader.read(profileDirectory: profile, browser: .arc)
        let writer = FaviconCache(diskDirectory: directory)
        _ = writer.cache(
            imageData: try XCTUnwrap(favicons.first?.imageData),
            forHost: "example.com"
        )
        // The write lands on a background actor now; wait for it the way a real
        // restart would, by letting time pass, rather than racing a fresh
        // instance's disk read against it.
        await writer._test_awaitPendingWrites()

        XCTAssertNotNil(
            FaviconCache(diskDirectory: directory).cachedImage(forHost: "example.com"),
            "A fresh cache over the same directory is what the next launch does."
        )
    }

    @MainActor
    func testBytesThatArentAnImageAreRefusedRatherThanWrittenAsABrokenIcon() {
        let cache = FaviconCache(diskDirectory: temporaryCacheDirectory())

        XCTAssertFalse(cache.cache(imageData: Data("this is not an image".utf8), forHost: "broken.example"))
        XCTAssertNil(cache.cachedImage(forHost: "broken.example"))
        XCTAssertEqual(
            cache.cache(imageDataByHost: [
                "broken.example": Data("this is not an image".utf8),
                "good.example": (try? pngData(width: 16, height: 16)) ?? Data(),
            ]),
            1,
            "The count must report what actually landed, not what was offered."
        )
    }

    // MARK: - Correcting what an earlier import wrote

    @MainActor
    func testAReImportReplacesAnIconAnEarlierImportFiledUnderTheWrongHost() async throws {
        let directory = temporaryCacheDirectory()
        let wrong = try pngData(width: 16, height: 16, fill: .systemGreen)
        let right = try pngData(width: 32, height: 32, fill: .systemRed)

        let firstImport = FaviconCache(diskDirectory: directory)
        XCTAssertEqual(firstImport.cache(imageDataByHost: ["youtube.com": wrong]), 1)
        await firstImport._test_awaitPendingWrites()
        XCTAssertEqual(FaviconCache(diskDirectory: directory).cachedImage(forHost: "youtube.com")?.size, NSSize(width: 16, height: 16))

        let secondImport = FaviconCache(diskDirectory: directory)
        XCTAssertEqual(secondImport.cacheImported(imageDataByHost: ["youtube.com": right]), 1)
        await secondImport._test_awaitPendingWrites()
        XCTAssertEqual(
            FaviconCache(diskDirectory: directory).cachedImage(forHost: "youtube.com")?.size,
            NSSize(width: 32, height: 32),
            "A reader fix is worthless while the wrong PNG is still the one on disk."
        )

        let thirdImport = FaviconCache(diskDirectory: directory)
        XCTAssertEqual(thirdImport.cacheImported(imageDataByHost: ["other.example": right]), 1)
        await thirdImport._test_awaitPendingWrites()
        XCTAssertNil(
            FaviconCache(diskDirectory: directory).cachedImage(forHost: "youtube.com"),
            "A host the newest import no longer covers must not keep the previous import's icon."
        )
    }

    @MainActor
    func testAnImportLeavesIconsOrbitFetchedItselfAfterwardsAlone() async throws {
        let directory = temporaryCacheDirectory()
        let icon = try pngData(width: 32, height: 32)

        let firstImport = FaviconCache(diskDirectory: directory)
        XCTAssertEqual(firstImport.cacheImported(imageDataByHost: ["imported.example": icon]), 1)
        await firstImport._test_awaitPendingWrites()

        let fetched = FaviconCache(diskDirectory: directory)
        fetched.cache(FaviconCache.fallbackIcon(forHost: "fetched.example"), forHost: "fetched.example")
        await fetched._test_awaitPendingWrites()

        let secondImport = FaviconCache(diskDirectory: directory)
        XCTAssertEqual(secondImport.cacheImported(imageDataByHost: ["imported.example": icon]), 1)
        await secondImport._test_awaitPendingWrites()

        XCTAssertNotNil(
            FaviconCache(diskDirectory: directory).cachedImage(forHost: "fetched.example"),
            "Only what an import wrote is the import's to replace."
        )
    }

    // MARK: - Fixture

    private struct Row {
        var pageURL: String
        var iconID: Int
        var width: Int
        var height: Int
        var iconType: Int = 1
        var imageData: Data?
        var iconURL: String?
        var lastUpdated: Int64?
        var fill: NSColor = .systemBlue
    }

    private func temporaryCacheDirectory() -> URL {
        let url = profile.appendingPathComponent("FaviconCache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Returns the bytes inserted for each row, in the order given, so a test can name the exact icon it expects.
    @discardableResult
    private func writeDatabase(_ rows: [Row]) throws -> [Data] {
        let handle = try openDatabase(at: profile.appendingPathComponent("Favicons", isDirectory: false))
        defer { sqlite3_close(handle) }

        try exec(handle, """
        CREATE TABLE favicons (
            id INTEGER PRIMARY KEY,
            url LONGVARCHAR NOT NULL,
            icon_type INTEGER DEFAULT 0 NOT NULL
        );
        CREATE TABLE favicon_bitmaps (
            id INTEGER PRIMARY KEY,
            icon_id INTEGER NOT NULL,
            last_updated INTEGER DEFAULT 0,
            image_data BLOB,
            width INTEGER DEFAULT 0,
            height INTEGER DEFAULT 0,
            last_requested INTEGER DEFAULT 0
        );
        CREATE TABLE icon_mapping (
            id INTEGER PRIMARY KEY,
            page_url LONGVARCHAR NOT NULL,
            icon_id INTEGER,
            page_url_type INTEGER DEFAULT 0
        );
        """)

        var declaredIcons = Set<Int>()
        var blobs: [Data] = []
        for (offset, row) in rows.enumerated() {
            if declaredIcons.insert(row.iconID).inserted {
                let iconURL = row.iconURL ?? "https://icons.example/\(row.iconID).png"
                try exec(handle, """
                INSERT INTO favicons (id, url, icon_type)
                VALUES (\(row.iconID), '\(iconURL)', \(row.iconType));
                """)
            }
            let bytes = try row.imageData ?? pngData(width: max(row.width, 1), height: max(row.height, 1), fill: row.fill)
            blobs.append(bytes)
            let lastUpdated = row.lastUpdated ?? Int64(13_322_774_400_000_000 - offset)
            try exec(handle, """
            INSERT INTO favicon_bitmaps (icon_id, last_updated, image_data, width, height, last_requested)
            VALUES (\(row.iconID), \(lastUpdated), X'\(hex(bytes))', \(row.width), \(row.height), 0);
            """)
            try exec(handle, """
            INSERT INTO icon_mapping (page_url, icon_id, page_url_type)
            VALUES ('\(row.pageURL)', \(row.iconID), 0);
            """)
        }
        return blobs
    }

    private func pngData(width: Int, height: Int, fill: NSColor = .systemBlue) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw fixtureError("Couldn't make a \(width)x\(height) bitmap.")
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fill.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw fixtureError("Couldn't encode the fixture bitmap as PNG.")
        }
        XCTAssertEqual(
            NSImage(data: png)?.size,
            NSSize(width: width, height: height),
            "Fixture check: the size assertions below mean nothing if the fixture PNG isn't the size it claims."
        )
        return png
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw fixtureError("Couldn't create the fixture database at \(url.path).")
        }
        return handle
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw fixtureError("Fixture SQL failed: \(message)")
        }
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "ArcFaviconReaderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
