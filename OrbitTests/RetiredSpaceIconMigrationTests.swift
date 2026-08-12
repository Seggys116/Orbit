import XCTest

@MainActor
final class RetiredSpaceIconMigrationTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-IconMigration-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private func makeStateStore() -> StateStore {
        StateStore(rootDirectory: scratchDirectory)
    }

    private func reloadStore(withSpaceIcon icon: String, isEmoji: Bool) -> BrowserStore {
        let stateStore = makeStateStore()

        let seeding = BrowserStore(stateStore: stateStore, autoArchiveInterval: nil)
        var document = seeding.state
        XCTAssertEqual(document.spaces.count, 1, "bootstrap should seed exactly one Space")
        document.spaces[0].icon = icon
        document.spaces[0].iconIsEmoji = isEmoji
        XCTAssertNoThrow(try stateStore.saveNow(document))

        return BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
    }

    // MARK: - The regression itself

    func test_persistedSparklesIcon_isRewrittenOnLoad() {
        let store = reloadStore(withSpaceIcon: "sparkles", isEmoji: false)

        XCTAssertEqual(
            store.state.spaces.count, 1,
            "migration must not add or drop Spaces"
        )
        XCTAssertNotEqual(
            store.state.spaces[0].icon, "sparkles",
            """
            A Space whose persisted icon was "sparkles" still had it after \
            loading. This is the exact bug the user reported repeatedly: \
            changing the seeded default does nothing for an existing \
            state.json.
            """
        )
        XCTAssertFalse(
            store.state.spaces[0].iconIsEmoji,
            "the replacement must still be an SF Symbol, not an emoji"
        )
        XCTAssertFalse(
            store.state.spaces[0].icon.isEmpty,
            "the Space must be left with a usable icon, not an empty string"
        )
        XCTAssertNotEqual(
            store.state.spaces[0].icon, "circle.grid.2x2",
            """
            The migration replaced "sparkles" with "circle.grid.2x2" — the glyph it used to \
            replace it with, and the one the user then spent another round staring at in the \
            sidebar's bottom-left corner. Swapping one glyph for another is not a removal; that \
            is the "NOT ALTERED, NOT CHANGED, REMOVED" complaint verbatim. Any neutral SF Symbol \
            is fine here EXCEPT that one, and except "sparkles" itself. See \
            BrowserStore.migrateRetiredDefaultSpaceIcon()'s doc comment for why the migration \
            does not also retire a stored "circle.grid.2x2" (four other files still hand it out \
            as a default). Note this message used to add "and the corner is empty regardless, \
            since SpaceSwitcherPagerView renders nothing below two Spaces" — that is no longer \
            true: the user has since asked for the Space switcher to be visible and centred even \
            with a single Space, so a bad default glyph IS now on screen for everyone.
            """
        )
    }

    func test_migratedIcon_isPersisted() async throws {
        let store = reloadStore(withSpaceIcon: "sparkles", isEmoji: false)
        let migrated = store.state.spaces[0].icon
        try store.saveNow()

        let reloaded = try makeStateStore().load()
        XCTAssertEqual(
            reloaded.spaces.first?.icon, migrated,
            "the migrated icon must be what is on disk for the next launch"
        )
        XCTAssertNotEqual(reloaded.spaces.first?.icon, "sparkles")
    }

    // MARK: - What the migration must NOT touch

    func test_sparkleEmoji_isLeftAlone() {
        let store = reloadStore(withSpaceIcon: "\u{2728}", isEmoji: true)

        XCTAssertEqual(store.state.spaces[0].icon, "\u{2728}")
        XCTAssertTrue(store.state.spaces[0].iconIsEmoji)
    }

    func test_otherSFSymbolIcons_areLeftAlone() {
        for icon in ["briefcase", "airplane", "circle.grid.2x2", "star"] {
            let store = reloadStore(withSpaceIcon: icon, isEmoji: false)
            XCTAssertEqual(
                store.state.spaces[0].icon, icon,
                "\(icon) is a user-chosen icon and must survive the migration untouched"
            )
        }
    }

    func test_documentWithoutRetiredIcon_isUnchanged() {
        let store = reloadStore(withSpaceIcon: "briefcase", isEmoji: false)
        let before = store.state

        XCTAssertEqual(before.spaces.map(\.icon), ["briefcase"])
        XCTAssertEqual(before.spaces.map(\.id), store.state.spaces.map(\.id))
    }
}
