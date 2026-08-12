import XCTest

final class ArcKeyBindingsReaderTests: XCTestCase {

    private var home: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ArcKeyBindings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        super.tearDown()
    }

    // MARK: - The empty and absent cases

    func testAnAbsentDocumentIsNoRemapsRatherThanAnError() throws {
        let result = try ArcKeyBindingsReader.read(homeDirectory: home)
        XCTAssertTrue(
            result.isEmpty,
            "Arc that has never written the file has no remaps, which is not an error."
        )
    }

    func testTheEmptyOverridesListEveryRealInstallShowsReadsAsNoRemaps() throws {
        try write(#"{"userOverrides": [], "version": 1}"#)

        let result = try ArcKeyBindingsReader.read(homeDirectory: home)
        XCTAssertEqual(result.bindings, [])
        XCTAssertEqual(result.unmappedActions, [])
        XCTAssertEqual(result.undecodableEntryCount, 0)
    }

    func testOnlyOverridesAreImportedSoOrbitsOwnDefaultsSurvive() throws {
        try write(#"{"version": 1, "userOverrides": []}"#)
        XCTAssertTrue(try ArcKeyBindingsReader.read(homeDirectory: home).bindings.isEmpty)
    }

    // MARK: - Decoding

    func testAnOverrideDecodesIntoTheKeyAndModifiersOrbitStores() throws {
        // 1048576 is NSEvent.ModifierFlags.command.rawValue.
        try write("""
        {
          "version": 1,
          "userOverrides": [
            { "action": "newTab", "shortcut": { "chars": "K", "flags": 1048576 } }
          ]
        }
        """)

        let result = try ArcKeyBindingsReader.read(homeDirectory: home)
        XCTAssertEqual(result.bindings.count, 1)
        let binding = try XCTUnwrap(result.bindings.first)
        XCTAssertEqual(binding.action, "newTab")
        XCTAssertEqual(binding.key, "k", "The key is stored lowercased, as KeyBinding stores it.")
        XCTAssertTrue(binding.modifierFlags.contains(.command))
        XCTAssertEqual(ArcShortcutCommandMap.command(for: binding.action), .newTabCommandBar)
    }

    func testAShortcutWithNoModifiersIsALegalOverrideRatherThanAFailedRow() throws {
        try write("""
        {"version": 1, "userOverrides": [{"action": "goBack", "shortcut": {"chars": "b"}}]}
        """)

        let result = try ArcKeyBindingsReader.read(homeDirectory: home)
        XCTAssertEqual(result.bindings.count, 1)
        XCTAssertEqual(result.bindings.first?.modifiers, 0)
        XCTAssertEqual(result.undecodableEntryCount, 0)
    }

    func testArrowKeysBecomeOrbitsSymbolicNamesSoTheyCanActuallyFire() throws {
        // `\u{F702}` is NSLeftArrowFunctionKey.
        try write("""
        {"version": 1, "userOverrides": [
          {"action": "previousSpace", "shortcut": {"chars": "\u{F702}", "flags": 1048576}},
          {"action": "nextSpace", "shortcut": {"chars": "ArrowRight", "flags": 1048576}}
        ]}
        """)

        let result = try ArcKeyBindingsReader.read(homeDirectory: home)
        XCTAssertEqual(result.bindings.map(\.key), ["left", "right"])
    }

    func testAnEntryWithNoUsableShortcutIsCountedRatherThanTreatedAsAnUnbinding() throws {
        try write("""
        {"version": 1, "userOverrides": [
          {"action": "newTab"},
          {"action": "", "shortcut": {"chars": "k", "flags": 1048576}},
          {"shortcut": {"chars": "j", "flags": 1048576}}
        ]}
        """)

        let result = try ArcKeyBindingsReader.read(homeDirectory: home)
        XCTAssertEqual(result.bindings, [], "No row here is understood well enough to produce a binding.")
        XCTAssertEqual(result.undecodableEntryCount, 3, "Every unusable row must be counted, never silently dropped.")
    }

    func testAMultiCharacterKeyThatIsNotAKnownNameIsRefusedRatherThanTruncated() throws {
        try write("""
        {"version": 1, "userOverrides": [{"action": "newTab", "shortcut": {"chars": "kj", "flags": 1048576}}]}
        """)

        let result = try ArcKeyBindingsReader.read(homeDirectory: home)
        XCTAssertEqual(
            result.bindings,
            [],
            "Truncating to the first character would bind something the user never asked for."
        )
        XCTAssertEqual(result.undecodableEntryCount, 1)
    }

    func testMalformedJSONThrowsUnreadable() throws {
        try write("{ this is not JSON")

        do {
            _ = try ArcKeyBindingsReader.read(homeDirectory: home)
            XCTFail("A malformed StorableKeyBindings.json should have reported .unreadable.")
        } catch let error as BrowserImportError {
            guard case .unreadable(let browser, _) = error else {
                return XCTFail("Expected .unreadable, got \(error).")
            }
            XCTAssertEqual(browser, .arc)
        }
    }

    // MARK: - Mapping onto Orbit's commands

    func testArcActionsMapOntoTheOrbitCommandsThatGenuinelyMatch() {
        let expected: [(String, ShortcutCommandID)] = [
            ("newTab", .newTabCommandBar),
            ("focusURLBar", .addressBarCommandBar),
            ("closeTab", .closeTabOrWindow),
            ("reopenLastClosedTab", .reopenLastClosedTab),
            ("toggleSidebar", .toggleSidebar),
            ("pinTab", .pinUnpinTab),
            ("goBack", .goBack),
            ("reload", .refresh),
            ("findOnPage", .findOnPage),
            ("copyURL", .copyURL),
            ("switchToSpace3", .jumpToSpace3),
            ("switchTo5thSidebarItem", .jumpToSidebarItem5),
            ("showArchive", .archivedTabs),
            ("newLittleArc", .newLittleOrbit),
        ]
        for (action, command) in expected {
            XCTAssertEqual(
                ArcShortcutCommandMap.command(for: action),
                command,
                "\(action) should map onto \(command)."
            )
        }
    }

    func testIdentifierMatchingIgnoresCasingAndSeparators() {
        for spelling in ["switchToSpace1", "switch-to-space-1", "switch_to_space_1", "SWITCHTOSPACE1"] {
            XCTAssertEqual(
                ArcShortcutCommandMap.command(for: spelling),
                .jumpToSpace1,
                "\(spelling) must resolve to the same command."
            )
        }
    }

    func testAnArcActionOrbitDoesNotHaveMapsToNothingRatherThanToSomethingNear() {
        for action in ["editBoost", "openBoostsEditor", "joinNextMeeting", "typeTravel"] {
            XCTAssertNil(
                ArcShortcutCommandMap.command(for: action),
                "\(action) has no Orbit command and must map to nothing."
            )
        }
    }

    func testNotesAndEaselsDoMapBecauseOrbitHasThem() {
        XCTAssertEqual(ArcShortcutCommandMap.command(for: "newNote"), .newNote)
        XCTAssertEqual(ArcShortcutCommandMap.command(for: "newEasel"), .newEasel)
        XCTAssertEqual(ArcShortcutCommandMap.command(for: "toggleDeveloperMode"), .toggleDeveloperMode)
    }

    func testEveryMappedCommandIsRealAndNoOrbitCommandIsClaimedTwice() {
        let mapped = Set(ShortcutCommandID.allCases).intersection(
            ShortcutCommandID.allCases.filter { command in
                ArcShortcutCommandMap.table.values.contains(command)
            }
        )
        XCTAssertFalse(mapped.isEmpty)
        for command in ArcShortcutCommandMap.table.values {
            XCTAssertTrue(
                ShortcutCommandID.allCases.contains(command),
                "\(command) is not a real Orbit command."
            )
        }
    }

    // MARK: - Applying

    func testApplyingRemapsWritesThroughToTheRegistryWithoutTouchingTheRealOne() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        XCTAssertEqual(
            registry.binding(for: .newTabCommandBar),
            KeyBinding(key: "t", modifiers: .command),
            "The in-memory registry must start from the same factory table the app uses."
        )

        registry.setBinding(KeyBinding(key: "k", modifiers: [.command, .shift]), for: .newTabCommandBar)
        XCTAssertEqual(registry.binding(for: .newTabCommandBar), KeyBinding(key: "k", modifiers: [.command, .shift]))

        XCTAssertNotEqual(
            ShortcutRegistry.shared.binding(for: .newTabCommandBar),
            KeyBinding(key: "k", modifiers: [.command, .shift]),
            "A test registry must never reach the shared one."
        )
    }

    // MARK: - Fixture

    private func write(_ json: String) throws {
        let directory = ArcImportReader.dataDirectory(homeDirectory: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.write(
            to: directory.appendingPathComponent("StorableKeyBindings.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
