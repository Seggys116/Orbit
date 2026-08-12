import AppKit
import XCTest

@MainActor
final class ShortcutRegistryTests: XCTestCase {

    // Must point ShortcutRegistry.defaults at a scratch suite: xcodebuild runs test classes in parallel processes that share UserDefaults.standard, and without this it would race sibling suites or wipe the real user's saved shortcuts.
    private var suiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OrbitTests-ShortcutRegistry-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: suiteName)
        ShortcutRegistry.defaults = scratchDefaults
        ShortcutRegistry.shared.resetToDefaults()
    }

    override func tearDown() {
        scratchDefaults?.removePersistentDomain(forName: suiteName)
        ShortcutRegistry.defaults = .standard
        // Put the singleton back on the machine's real saved remaps, so a later setBinding here
        // cannot persist this suite's in-memory state over the user's own.
        ShortcutRegistry.shared.reloadOverridesFromStore()
        scratchDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func reloadedStore() -> UserDefaults {
        scratchDefaults.synchronize()
        guard let reloaded = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not construct a second UserDefaults over suite \(suiteName!).")
            return .standard
        }
        return reloaded
    }

    // MARK: - A remap actually reaches storage

    func testARemapIsPersistedUnderItsCommandRawValueAndSurvivesAReload() throws {
        let command = try XCTUnwrap(ShortcutRegistry.shared.commands.first(where: { $0.defaultBinding != nil }))
        let custom = KeyBinding(key: "j", modifiers: [.command, .control])
        XCTAssertNotEqual(custom, command.defaultBinding, "test precondition: the remap must differ from the factory binding")

        ShortcutRegistry.shared.setBinding(custom, for: command.id)

        let data = try XCTUnwrap(
            reloadedStore().data(forKey: ShortcutRegistry.defaultsKey),
            "Nothing was written to \(ShortcutRegistry.defaultsKey); the user's remap would be gone on relaunch."
        )
        let decoded = try JSONDecoder().decode([String: KeyBinding?].self, from: data)
        XCTAssertEqual(
            decoded[command.id.rawValue] ?? nil, custom,
            "The remap is not stored under the command's raw value (\(command.id.rawValue)), so `loadOverrides` could never find it again."
        )

        ShortcutRegistry.shared.reloadOverridesFromStore()
        XCTAssertEqual(
            ShortcutRegistry.shared.binding(for: command.id), custom,
            "The remap did not survive a reload of the registry from its own store."
        )
    }

    func testResetToDefaultsClearsThePersistedOverride() throws {
        let command = try XCTUnwrap(ShortcutRegistry.shared.commands.first)
        ShortcutRegistry.shared.setBinding(KeyBinding(key: "j", modifiers: [.command, .control]), for: command.id)

        ShortcutRegistry.shared.resetToDefaults()
        ShortcutRegistry.shared.reloadOverridesFromStore()

        XCTAssertEqual(
            ShortcutRegistry.shared.binding(for: command.id), command.defaultBinding,
            "The command did not come back to its factory binding after a reset and reload."
        )
        let data = try XCTUnwrap(reloadedStore().data(forKey: ShortcutRegistry.defaultsKey))
        let decoded = try JSONDecoder().decode([String: KeyBinding?].self, from: data)
        XCTAssertNil(decoded[command.id.rawValue] ?? nil, "The reset left a stored override behind.")
    }

    func testEveryCommandIDHasExactlyOneTableEntry() {
        var seen: [ShortcutCommandID: Int] = [:]
        for command in ShortcutRegistry.shared.commands {
            seen[command.id, default: 0] += 1
        }
        for id in ShortcutCommandID.allCases {
            let count = seen[id] ?? 0
            XCTAssertEqual(count, 1, "\(id) has \(count) entries in ShortcutRegistry's command table (expected exactly 1).")
        }
    }

    func testNoTwoCommandsShareADefaultBinding() {
        var owner: [KeyBinding: ShortcutCommandID] = [:]
        for command in ShortcutRegistry.shared.commands {
            guard let binding = command.defaultBinding else { continue }
            if let existing = owner[binding] {
                XCTFail("\(command.id) and \(existing) both default to \(binding.displayString) — only \(existing) can ever be reached by keyboard.")
            } else {
                owner[binding] = command.id
            }
        }
    }

    func testEveryDefaultBindingResolvesToItsOwnCommand() {
        for command in ShortcutRegistry.shared.commands {
            guard let binding = command.defaultBinding else { continue }
            let event = KeyEventFixtures.keyDownEvent(for: binding)
            let resolved = ShortcutRegistry.shared.command(matching: event)
            XCTAssertEqual(
                resolved, command.id,
                "\(binding.displayString) (default binding for \(command.id)) resolved to \(String(describing: resolved)) instead."
            )
        }
    }

    func testCmdSResolvesToToggleSidebar() {
        let binding = ShortcutRegistry.shared.binding(for: .toggleSidebar)
        XCTAssertEqual(binding, KeyBinding.cmd("s"), "toggleSidebar's factory binding drifted from Cmd+S.")
        let event = KeyEventFixtures.keyDownEvent(for: KeyBinding.cmd("s"))
        XCTAssertEqual(ShortcutRegistry.shared.command(matching: event), .toggleSidebar)
    }

    func testSpaceSwitchingShortcutsResolveCorrectly() {
        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: KeyEventFixtures.keyDownEvent(for: .cmdOption("right"))),
            .nextSpace
        )
        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: KeyEventFixtures.keyDownEvent(for: .cmdOption("left"))),
            .previousSpace
        )
        let jumpCommands: [ShortcutCommandID] = [
            .jumpToSpace1, .jumpToSpace2, .jumpToSpace3, .jumpToSpace4, .jumpToSpace5,
            .jumpToSpace6, .jumpToSpace7, .jumpToSpace8, .jumpToSpace9,
        ]
        for (index, id) in jumpCommands.enumerated() {
            let digit = "\(index + 1)"
            let event = KeyEventFixtures.keyDownEvent(for: .ctrl(digit))
            XCTAssertEqual(ShortcutRegistry.shared.command(matching: event), id, "Ctrl+\(digit) did not resolve to \(id).")
        }
    }

    // MARK: - Remapping, and the predicate the Shortcuts pane groups on

    // ShortcutsSettingsPane splits its list into "Customized Shortcuts" and "Default Shortcuts" using exactly one test, registry.binding(for: id) != command.defaultBinding; the tests below drive the real registry calls Remove Shortcut/Reset Shortcut to Default make and assert the resulting state.

    // A hyper-modified key no factory binding uses, so remapping onto it
    // cannot collide with a real command and make these tests lie.
    private var unusedBinding: KeyBinding {
        KeyBinding(key: "q", modifiers: [.control, .option, .shift, .command])
    }

    func testRemappingACommandMakesItDifferFromItsDefault() {
        let registry = ShortcutRegistry.shared
        guard let command = registry.command(for: .toggleSidebar) else {
            return XCTFail("toggleSidebar is missing from the command table.")
        }
        XCTAssertNil(
            registry.command(matching: KeyEventFixtures.keyDownEvent(for: unusedBinding)),
            "This test's stand-in combination is no longer free; pick another."
        )
        XCTAssertEqual(registry.binding(for: command.id), command.defaultBinding, "Precondition: starts at its default.")

        registry.setBinding(unusedBinding, for: command.id)

        XCTAssertNotEqual(
            registry.binding(for: command.id), command.defaultBinding,
            "A remapped command must no longer read as being at its default, or it would stay in Default Shortcuts."
        )
        XCTAssertEqual(registry.binding(for: command.id), unusedBinding)
        XCTAssertEqual(
            registry.command(matching: KeyEventFixtures.keyDownEvent(for: unusedBinding)), command.id,
            "The remapped combination must resolve to the command whose row now displays it."
        )
    }

    func testResettingASingleCommandToItsDefaultRestoresIt() {
        let registry = ShortcutRegistry.shared
        guard let command = registry.command(for: .toggleSidebar) else {
            return XCTFail("toggleSidebar is missing from the command table.")
        }
        registry.setBinding(unusedBinding, for: command.id)
        XCTAssertNotEqual(registry.binding(for: command.id), command.defaultBinding, "Precondition: customized.")

        registry.setBinding(command.defaultBinding, for: command.id)

        XCTAssertEqual(registry.binding(for: command.id), command.defaultBinding)
        XCTAssertNil(
            registry.command(matching: KeyEventFixtures.keyDownEvent(for: unusedBinding)),
            "The abandoned combination must stop resolving once the command is back at its default."
        )
    }

    func testRemovingAShortcutLeavesTheCommandUnbound() {
        let registry = ShortcutRegistry.shared
        guard let command = registry.command(for: .toggleSidebar), let factory = command.defaultBinding else {
            return XCTFail("toggleSidebar is missing a factory binding.")
        }

        registry.setBinding(nil, for: command.id)

        XCTAssertNil(registry.binding(for: command.id), "Remove Shortcut must leave the command unbound.")
        XCTAssertNotEqual(
            registry.binding(for: command.id), command.defaultBinding,
            "An explicitly unbound command differs from its default, so its row belongs in Customized Shortcuts."
        )
        XCTAssertNil(
            registry.command(matching: KeyEventFixtures.keyDownEvent(for: factory)),
            "The removed combination must no longer reach the command."
        )
    }

    func testResetToDefaultsLeavesNoCommandCustomized() {
        let registry = ShortcutRegistry.shared
        registry.setBinding(unusedBinding, for: .toggleSidebar)
        registry.setBinding(nil, for: .newWindow)
        XCTAssertTrue(
            registry.commands.contains { registry.binding(for: $0.id) != $0.defaultBinding },
            "Precondition: at least one command is customized."
        )

        registry.resetToDefaults()

        for command in registry.commands {
            XCTAssertEqual(
                registry.binding(for: command.id), command.defaultBinding,
                "\(command.id) still differs from its default after Reset All to Defaults."
            )
        }
    }

    func testUnmodifiedKeystrokesNeverResolve() {
        let plainS = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
        )!
        XCTAssertNil(ShortcutRegistry.shared.command(matching: plainS))
    }

    // MARK: - Conflict detection

    func testTwoCommandsRemappedOntoTheSameCombination_reportEachOtherAsConflicting() {
        let registry = ShortcutRegistry.shared
        guard let first = registry.command(for: .toggleSidebar), let second = registry.command(for: .newWindow) else {
            return XCTFail("toggleSidebar/newWindow are missing from the command table.")
        }
        XCTAssertTrue(registry.conflicts(for: first.id).isEmpty, "Precondition: no conflict before any remap.")
        XCTAssertTrue(registry.conflicts(for: second.id).isEmpty, "Precondition: no conflict before any remap.")

        registry.setBinding(unusedBinding, for: first.id)
        XCTAssertTrue(registry.conflicts(for: first.id).isEmpty, "A binding claimed by only one command must not report a conflict.")

        registry.setBinding(unusedBinding, for: second.id)

        XCTAssertEqual(registry.conflicts(for: first.id), [second.id], "toggleSidebar did not report newWindow as the command it now conflicts with.")
        XCTAssertEqual(registry.conflicts(for: second.id), [first.id], "newWindow did not report toggleSidebar as the command it now conflicts with.")
        XCTAssertEqual(
            Set(registry.commands(conflictingWith: unusedBinding)), Set([first.id, second.id]),
            "commands(conflictingWith:) must list every command currently on that combination."
        )
        XCTAssertEqual(
            registry.commands(conflictingWith: unusedBinding, excluding: first.id), [second.id],
            "excluding: must drop only the named command, not every match."
        )
    }

    func testResettingOneConflictingCommand_clearsTheConflictForBoth() {
        let registry = ShortcutRegistry.shared
        guard let first = registry.command(for: .toggleSidebar), let second = registry.command(for: .newWindow) else {
            return XCTFail("toggleSidebar/newWindow are missing from the command table.")
        }
        registry.setBinding(unusedBinding, for: first.id)
        registry.setBinding(unusedBinding, for: second.id)
        XCTAssertFalse(registry.conflicts(for: first.id).isEmpty, "Precondition: the two commands conflict.")
        XCTAssertFalse(registry.conflicts(for: second.id).isEmpty, "Precondition: the two commands conflict.")

        registry.setBinding(second.defaultBinding, for: second.id)

        XCTAssertTrue(registry.conflicts(for: first.id).isEmpty, "toggleSidebar still reports a conflict after the other side was reset.")
        XCTAssertTrue(registry.conflicts(for: second.id).isEmpty, "newWindow still reports a conflict after resetting itself.")
        XCTAssertTrue(registry.commands(conflictingWith: unusedBinding).isEmpty || registry.commands(conflictingWith: unusedBinding) == [first.id],
                      "Only toggleSidebar may still be on the abandoned combination; newWindow must have moved off it.")
    }

    func testTwoUnboundCommandsNeverConflict() {
        let registry = ShortcutRegistry.shared
        guard let first = registry.command(for: .toggleSidebar), let second = registry.command(for: .newWindow) else {
            return XCTFail("toggleSidebar/newWindow are missing from the command table.")
        }
        registry.setBinding(nil, for: first.id)
        registry.setBinding(nil, for: second.id)

        XCTAssertTrue(registry.conflicts(for: first.id).isEmpty)
        XCTAssertTrue(registry.conflicts(for: second.id).isEmpty)
    }

    func testACommandNeverConflictsWithItself() {
        let registry = ShortcutRegistry.shared
        guard let command = registry.command(for: .toggleSidebar) else {
            return XCTFail("toggleSidebar is missing from the command table.")
        }
        XCTAssertFalse(
            registry.commands(conflictingWith: unusedBinding, excluding: command.id).contains(command.id)
        )
        registry.setBinding(unusedBinding, for: command.id)
        XCTAssertEqual(registry.conflicts(for: command.id), [], "A command with a unique binding must not list itself.")
    }
}
