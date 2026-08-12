import XCTest
@testable import Orbit

@MainActor
final class RestoreDataTests: XCTestCase {

    private var scratchRoot: URL!

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitAppTests-RestoreData-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratchRoot {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
        scratchRoot = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeStore(maxBackups: Int = 10) -> BrowserStore {
        let root = scratchRoot.appendingPathComponent("Store-\(UUID().uuidString)", isDirectory: true)
        return BrowserStore(
            stateStore: StateStore(rootDirectory: root, maxBackups: maxBackups),
            autoArchiveInterval: nil
        )
    }

    private static func backupFileName(at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "state-\(stamp).json"
    }

    @discardableResult
    private func seedBackup(in store: BrowserStore, at date: Date, spaceName: String = "Seeded") throws -> URL {
        let stateStore = store.stateStore
        try FileManager.default.createDirectory(at: stateStore.backupsDirectory, withIntermediateDirectories: true)

        let profile = Profile(name: "Seeded Profile")
        var state = OrbitState()
        state.profiles = [profile]
        state.spaces = [Space(name: spaceName, profileID: profile.id)]
        state.activeSpaceID = state.spaces[0].id

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let url = stateStore.backupsDirectory
            .appendingPathComponent(Self.backupFileName(at: date), isDirectory: false)
        try encoder.encode(state).write(to: url, options: .atomic)
        return url
    }

    private static func daysAgo(_ days: Int, from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    // Must be fixed at noon, not Date(): subtracting a few minutes from a real "now" near local midnight can push the result onto the previous calendar day, splitting same-day fixtures across StateBackupRetention.bucket's day boundary.
    private static let fixedNoon: Date = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12, minute: 0, second: 0))!

    // MARK: - Filename timestamps

    func testBackupFilenameCarriesTheInstantTheDocumentWasCurrent() throws {
        let moment = Date(timeIntervalSince1970: 1_666_281_780) // 2022-10-20T14:43:00Z
        let name = Self.backupFileName(at: moment)

        let parsed = try XCTUnwrap(
            StateStore.capturedDate(fromBackupFileName: name),
            "The name StateStore itself writes must be readable by StateStore itself."
        )
        XCTAssertEqual(parsed.timeIntervalSince1970, moment.timeIntervalSince1970, accuracy: 0.01)
    }

    func testBackupFilenameWithACollisionDisambiguatorStillParses() throws {
        let moment = Date(timeIntervalSince1970: 1_666_281_780)
        let base = Self.backupFileName(at: moment)
        let collided = base.replacingOccurrences(of: ".json", with: "-2.json")

        let parsed = try XCTUnwrap(StateStore.capturedDate(fromBackupFileName: collided))
        XCTAssertEqual(parsed.timeIntervalSince1970, moment.timeIntervalSince1970, accuracy: 0.01)
    }

    // MARK: - Retention schedule

    func testRetentionKeepsTenOfTodaysBackupsAndDropsTheEleventh() {
        let now = Self.fixedNoon
        let todays = (0..<14).map { index in
            StateBackup(
                url: URL(fileURLWithPath: "/tmp/today-\(index).json"),
                capturedAt: now.addingTimeInterval(TimeInterval(-index * 60))
            )
        }

        let kept = StateBackupRetention.backupsToKeep(from: todays, now: now, sameDayLimit: 10)

        XCTAssertEqual(kept.count, 10)
        XCTAssertEqual(
            kept.first?.url.lastPathComponent, "today-0.json",
            "The newest of today's backups must survive."
        )
        XCTAssertFalse(
            kept.contains { $0.url.lastPathComponent == "today-13.json" },
            "The oldest of today's must be the one evicted, not a newer one."
        )
    }

    func testRetentionCollapsesAnEarlierDayToItsNewestBackup() {
        let now = Self.fixedNoon
        let thatDay = Self.daysAgo(3, from: now)
        let sameDay = (0..<6).map { index in
            StateBackup(
                url: URL(fileURLWithPath: "/tmp/d3-\(index).json"),
                capturedAt: thatDay.addingTimeInterval(TimeInterval(-index * 600))
            )
        }

        let kept = StateBackupRetention.backupsToKeep(from: sameDay, now: now, sameDayLimit: 10)

        XCTAssertEqual(kept.count, 1, "A day inside the daily tier keeps exactly one backup.")
        XCTAssertEqual(kept[0].url.lastPathComponent, "d3-0.json", "and it is that day's newest.")
    }

    func testRetentionThinsToWeeklyThenMonthlyAndDropsBeyondAYear() {
        let now = Date()
        func backup(_ label: String, _ daysBack: Int) -> StateBackup {
            StateBackup(
                url: URL(fileURLWithPath: "/tmp/\(label).json"),
                capturedAt: Self.daysAgo(daysBack, from: now)
            )
        }

        let candidates = [
            backup("day-2", 2),
            backup("week-15", 15),
            backup("week-16", 16),
            backup("month-150", 150),
            backup("month-180", 180),
            backup("ancient-500", 500),
        ]

        let kept = StateBackupRetention.backupsToKeep(from: candidates, now: now, sameDayLimit: 10)
        let keptNames = Set(kept.map { $0.url.lastPathComponent })

        XCTAssertTrue(keptNames.contains("day-2.json"), "the daily tier keeps a 2-day-old backup")
        XCTAssertTrue(keptNames.contains("month-150.json"))
        XCTAssertTrue(keptNames.contains("month-180.json"))
        XCTAssertFalse(
            keptNames.contains("ancient-500.json"),
            "Arc's schedule stops at one per month for the year prior; nothing older survives."
        )

        let weeklySurvivors = keptNames.intersection(["week-15.json", "week-16.json"])
        XCTAssertFalse(weeklySurvivors.isEmpty, "the weekly tier must keep something from that fortnight")
        let bucket15 = StateBackupRetention.bucket(for: Self.daysAgo(15, from: now), now: now)
        let bucket16 = StateBackupRetention.bucket(for: Self.daysAgo(16, from: now), now: now)
        if bucket15 == bucket16 {
            XCTAssertEqual(weeklySurvivors.count, 1, "two backups in one week keep exactly one")
        }
    }

    func testRetentionTreatsAFutureTimestampAsTodayRatherThanDroppingIt() {
        let now = Date()
        let fromTheFuture = StateBackup(
            url: URL(fileURLWithPath: "/tmp/future.json"),
            capturedAt: now.addingTimeInterval(86_400 * 3)
        )

        let kept = StateBackupRetention.backupsToKeep(from: [fromTheFuture], now: now)

        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(StateBackupRetention.bucket(for: fromTheFuture.capturedAt, now: now), .today)
    }

    // MARK: - Retention, through the real writer

    func testSavingRepeatedlyTodayDoesNotEvictOlderDaysBackups() throws {
        let store = makeStore(maxBackups: 10)
        let now = Date()

        let oldURLs = try [2, 5, 9, 20, 120].map { daysBack in
            try seedBackup(in: store, at: Self.daysAgo(daysBack, from: now), spaceName: "Day-\(daysBack)")
        }

        for index in 0..<14 {
            store.state.spaces[0].name = "Save \(index)"
            try store.saveNow()
        }

        // Compared by file name, not URL: contentsOfDirectory returns
        // /private/var/... where NSTemporaryDirectory() gives /var/....
        let survivingNames = Set(store.availableBackups().map { $0.url.lastPathComponent })
        for url in oldURLs {
            XCTAssertTrue(
                survivingNames.contains(url.lastPathComponent),
                "\(url.lastPathComponent) was evicted by today's saves. A flat cap does that; the tiered schedule must not."
            )
        }

        let todaysBackups = store.availableBackups().filter {
            Calendar.current.isDate($0.capturedAt, inSameDayAs: now)
        }
        XCTAssertLessThanOrEqual(
            todaysBackups.count, 10,
            "Today's tier is still capped at Arc's ten — the tiers must not turn pruning off altogether."
        )
    }

    func testTotalBackupDirectorySizeStaysBoundedAcrossACompleteRetentionHistory() throws {
        let store = makeStore(maxBackups: 10)
        let now = Date()

        for daysBack in 1...400 {
            _ = try seedBackup(in: store, at: Self.daysAgo(daysBack, from: now), spaceName: "Day-\(daysBack)")
        }

        for index in 0..<15 {
            store.state.spaces[0].name = "Save \(index)"
            try store.saveNow()
        }

        let onDisk = try FileManager.default.contentsOfDirectory(
            at: store.stateStore.backupsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        // Upper bound: 10 (today) + 10 (daily) + 5 (weekly) + 12 (monthly) =
        // 37; 400 days of seeding is roughly ten times that.
        XCTAssertLessThanOrEqual(
            onDisk.count, 40,
            "Backups/ must stay bounded across the whole retention schedule, not just today's tier: found \(onDisk.count) files after 400 days of simulated history."
        )

        let survivingNames = Set(onDisk.map { $0.lastPathComponent })
        let ancientName = Self.backupFileName(at: Self.daysAgo(390, from: now))
        XCTAssertFalse(
            survivingNames.contains(ancientName),
            "a backup from 390 days back must not survive real pruning through the writer."
        )
    }

    func testAvailableBackupsAreOrderedNewestFirst() throws {
        let store = makeStore()
        let now = Date()
        try seedBackup(in: store, at: Self.daysAgo(5, from: now), spaceName: "Older")
        try seedBackup(in: store, at: Self.daysAgo(1, from: now), spaceName: "Newer")

        let listed = store.availableBackups()

        XCTAssertEqual(listed.count, 2)
        XCTAssertGreaterThan(
            listed[0].capturedAt, listed[1].capturedAt,
            "The popup lists newest first (refs/reference/web/arc-restore-data-window-backup-list.png)."
        )
    }

    // MARK: - Restoring

    func testRestoringABackupBringsBackDeletedSpacesAndTabs() throws {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let keptSpaceID = store.state.spaces[0].id
        let doomedSpaceID = store.createSpace(name: "Doomed", profileID: profileID)
        let doomedTabID = store.openTab(url: URL(string: "https://example.com/lost")!, in: doomedSpaceID)

        try store.saveNow()                       // establishes state.json
        store.state.spaces[0].name = "Touched"    // any change, so the next save backs the good doc up
        try store.saveNow()

        let backup = try XCTUnwrap(store.availableBackups().first)

        store.deleteSpace(doomedSpaceID)
        XCTAssertNil(store.space(doomedSpaceID), "precondition: the Space really is gone")
        XCTAssertNil(store.tab(doomedTabID), "precondition: its tab went with it")

        let outcome = try store.restore(from: backup)

        XCTAssertNotNil(store.space(doomedSpaceID), "the deleted Space must be back")
        XCTAssertEqual(store.tab(doomedTabID)?.url.absoluteString, "https://example.com/lost")
        XCTAssertTrue(store.spaces.contains { $0.id == keptSpaceID })
        XCTAssertEqual(outcome.spaceCount, store.state.spaces.count)
        XCTAssertEqual(outcome.tabCount, store.state.tabs.count)
    }

    func testRestoringFilesThePreRestoreDocumentAwayAsTheNewestBackup() throws {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        _ = store.createSpace(name: "Original", profileID: profileID)
        try store.saveNow()
        store.state.spaces[0].name = "Touched"
        try store.saveNow()

        let oldBackup = try XCTUnwrap(store.availableBackups().first)

        let regrettableSpaceID = store.createSpace(name: "Made After The Backup", profileID: profileID)
        try store.saveNow()
        XCTAssertNotNil(store.space(regrettableSpaceID))

        try store.restore(from: oldBackup)
        XCTAssertNil(store.space(regrettableSpaceID), "precondition: the restore really did roll that Space away")

        let undoCandidate = try XCTUnwrap(
            store.availableBackups().first,
            "restoring must leave the pre-restore document as a backup"
        )
        try store.restore(from: undoCandidate)

        XCTAssertNotNil(
            store.space(regrettableSpaceID),
            "Restoring the newest backup after a restore must undo that restore."
        )
    }

    func testSidebarScopeLeavesBoostsEaselsAndNotesUntouched() throws {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let doomedSpaceID = store.createSpace(name: "Doomed", profileID: profileID)
        try store.saveNow()
        store.state.spaces[0].name = "Touched"
        try store.saveNow()
        let backup = try XCTUnwrap(store.availableBackups().first)

        store.deleteSpace(doomedSpaceID)
        let boost = Boost(name: "Written after the backup", host: "example.com")
        store.state.boosts = [boost]
        store.state.routingRules = [RoutingRule(pattern: "example.com", destination: .space(doomedSpaceID))]

        try store.restore(from: backup, scope: .sidebar)

        XCTAssertNotNil(store.space(doomedSpaceID), "the sidebar half must have been restored")
        XCTAssertEqual(store.state.boosts.map(\.id), [boost.id], "a Boost written after the backup must survive it")
        XCTAssertEqual(store.state.routingRules.count, 1, "routing rules are not part of the Sidebar scope")
    }

    func testRestoringBringsBackAProfileTheLiveDocumentHasLost() throws {
        let store = makeStore()
        let secondProfileID = store.createProfile(name: "Work")
        let workSpaceID = store.createSpace(name: "Work", profileID: secondProfileID)
        try store.saveNow()
        store.state.spaces[0].name = "Touched"
        try store.saveNow()
        let backup = try XCTUnwrap(store.availableBackups().first)

        XCTAssertTrue(store.deleteProfile(secondProfileID))
        XCTAssertNil(store.state.profiles.first { $0.id == secondProfileID }, "precondition: the Profile is gone")
        XCTAssertNotEqual(
            store.space(workSpaceID)?.profileID, secondProfileID,
            "precondition: its Space was reassigned off it"
        )

        let outcome = try store.restore(from: backup)

        XCTAssertEqual(outcome.rescuedProfileCount, 1)
        XCTAssertNotNil(
            store.state.profiles.first { $0.id == secondProfileID },
            "the Profile the restored Space needs must come back with it"
        )
        let restoredSpace = try XCTUnwrap(store.space(workSpaceID))
        XCTAssertEqual(restoredSpace.profileID, secondProfileID, "and the Space must still point at it")
    }

    func testAnUnreadableBackupThrowsAndLeavesTheDocumentUntouched() throws {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let liveSpaceID = store.createSpace(name: "Live", profileID: profileID)
        try store.saveNow()

        let corruptURL = store.stateStore.backupsDirectory
            .appendingPathComponent(Self.backupFileName(at: Date()), isDirectory: false)
        try FileManager.default.createDirectory(
            at: store.stateStore.backupsDirectory, withIntermediateDirectories: true
        )
        try Data("{ not json at all".utf8).write(to: corruptURL, options: .atomic)

        let corrupt = try XCTUnwrap(
            store.availableBackups().first { $0.url.lastPathComponent == corruptURL.lastPathComponent }
        )
        let spacesBefore = store.state.spaces.map(\.id)

        XCTAssertThrowsError(try store.restore(from: corrupt))
        XCTAssertEqual(store.state.spaces.map(\.id), spacesBefore, "a failed restore must not partially apply")
        XCTAssertNotNil(store.space(liveSpaceID))
    }

    // MARK: - The window's model

    func testRestoreIsRefusedUntilABackupIsChosen() throws {
        try env.store.saveNow()
        env.store.state.spaces[0].name = "Touched"
        try env.store.saveNow()

        let model = RestoreDataWindowController._test_makeModel(env: env)
        model.presentError = { XCTFail("no error was expected: \($0)") }

        XCTAssertFalse(model.backups.isEmpty, "precondition: there is something to restore")
        XCTAssertNil(model.selectedBackup, "Arc's default state has an empty second popup")
        XCTAssertFalse(model.canRestore, "so Restore is greyed out")
        XCTAssertFalse(model.restore(), "and invoking it anyway must be a no-op")

        model.selectedBackup = model.backups[0]
        XCTAssertTrue(model.canRestore)
        XCTAssertTrue(model.restore())
    }

    func testTheUnselectedRowLabelIsEmptyAndABackupRowIsJustATimestamp() {
        XCTAssertEqual(RestoreDataModel.label(for: nil), "")

        let backup = StateBackup(
            url: URL(fileURLWithPath: "/tmp/x.json"),
            capturedAt: Date(timeIntervalSince1970: 1_666_281_780)
        )
        let label = RestoreDataModel.label(for: backup)

        XCTAssertFalse(label.isEmpty)
        XCTAssertFalse(
            label.contains("state-"),
            "rows are a formatted timestamp, never a filename"
        )
        XCTAssertTrue(
            label.rangeOfCharacter(from: .decimalDigits) != nil,
            "a timestamp row has to contain digits"
        )
    }

    func testAFailingRestoreIsReportedRatherThanSwallowed() throws {
        try env.store.saveNow()

        let backupsDirectory = env.store.stateStore.backupsDirectory
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let corruptURL = backupsDirectory
            .appendingPathComponent(Self.backupFileName(at: Date()), isDirectory: false)
        try Data("{{{".utf8).write(to: corruptURL, options: .atomic)

        let model = RestoreDataWindowController._test_makeModel(env: env)
        var reported: [Error] = []
        model.presentError = { reported.append($0) }
        model.selectedBackup = try XCTUnwrap(
            model.backups.first { $0.url.lastPathComponent == corruptURL.lastPathComponent }
        )

        XCTAssertFalse(model.restore())
        XCTAssertEqual(reported.count, 1, "the failure must be presented, not swallowed")
    }

    // MARK: - The Help menu item

    func testRestoreDataIsAWiredHelpMenuLeafAboveTheHairline() throws {
        let helpMenu = try XCTUnwrap(
            MainMenuBuilder.build().items.compactMap(\.submenu).first { $0.title == "Help" }
        )
        let index = try XCTUnwrap(
            helpMenu.items.firstIndex { $0.title == "Restore Data" },
            "Help must offer Restore Data."
        )
        let item = helpMenu.items[index]

        XCTAssertNil(item.submenu, "it is a leaf, not a submenu")
        XCTAssertEqual(item.keyEquivalent, "", "no item in Arc's Help menu carries a shortcut glyph")
        XCTAssertTrue(
            helpMenu.items[index + 1].isSeparatorItem,
            "it is the last item above the menu's single hairline"
        )
        XCTAssertEqual(
            helpMenu.items[index + 2].title, "Troubleshooting",
            "and Troubleshooting follows that hairline, as in Arc"
        )
        XCTAssertNotNil(item.action, "an item with no action is the inert placeholder this was withheld to avoid")
        XCTAssertNotNil(item.target, "and one with no target never fires")
        XCTAssertTrue(item.isEnabled)
    }

    // MARK: - Live renderers after a restore

    func testRestoringReleasesEveryLiveWebContents() throws {
        try env.store.saveNow()
        env.store.state.spaces[0].name = "Touched"
        try env.store.saveNow()

        let tabID = try XCTUnwrap(env.store.state.tabs.keys.first)
        let contents = MockWebContents()
        env._test_attachWebContents(contents, for: tabID)
        XCTAssertNotNil(env.webContents[tabID], "precondition: a renderer is attached")

        let backup = try XCTUnwrap(env.availableStateBackups().first)
        try env.restoreData(from: backup)

        XCTAssertTrue(contents.isClosed, "the renderer must actually be closed, not just dropped from the map")
        XCTAssertNil(env.webContents[tabID])
        XCTAssertTrue(env.navigationStates.isEmpty, "and its mirrored engine state must go with it")
    }
}
