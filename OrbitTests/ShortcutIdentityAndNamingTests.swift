import AppKit
import XCTest

@MainActor
final class ShortcutIdentityAndNamingTests: XCTestCase {

    private var suiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OrbitTests-ShortcutIdentity-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: suiteName)
        ShortcutRegistry.defaults = scratchDefaults
        ShortcutRegistry.shared.resetToDefaults()
    }

    override func tearDown() {
        scratchDefaults?.removePersistentDomain(forName: suiteName)
        ShortcutRegistry.defaults = .standard
        ShortcutRegistry.shared.reloadOverridesFromStore()
        scratchDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The Shortcuts pane specifically claims nothing about extensions

    func testNoCommandTitleMentionsExtensions() {
        let offenders = ShortcutRegistry.shared.commands
            .filter { $0.title.localizedCaseInsensitiveContains("extension") }
            .map(\.title)
        XCTAssertTrue(
            offenders.isEmpty,
            "These shortcut titles claim an extensions-specific command that does not exist: \(offenders.joined(separator: ", "))."
        )
    }

    func testNoCategoryNameMentionsExtensions() {
        let offenders = ShortcutCategory.allCases
            .map(\.rawValue)
            .filter { $0.localizedCaseInsensitiveContains("extension") }
        XCTAssertTrue(
            offenders.isEmpty,
            "These shortcut category names claim an extensions-specific grouping that does not exist: \(offenders.joined(separator: ", "))."
        )
    }

    // MARK: - The retitled command still works

    func testSiteControlsKeepsItsWorkingBinding() {
        guard let command = ShortcutRegistry.shared.command(for: .siteControls) else {
            return XCTFail(".siteControls has no registry entry, so it cannot appear in the Shortcuts pane at all.")
        }
        XCTAssertEqual(command.title, "Site Controls", "The command should be named for what it actually opens.")

        guard let binding = ShortcutRegistry.shared.binding(for: .siteControls) else {
            return XCTFail("⌘E was dropped. Retitling a command must not unbind it.")
        }
        XCTAssertEqual(binding.key, "e")
        XCTAssertEqual(binding.modifierFlags, .command)

        let event = KeyEventFixtures.keyDownEvent(for: binding)
        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: event), .siteControls,
            "⌘E no longer resolves to the Site Controls command — the binding is dead even though the table still lists it."
        )
    }

    // MARK: - Persisted identity

    func testOldPersistedRawValueStillDecodesToTheRenamedCommand() {
        XCTAssertEqual(
            ShortcutCommandID(rawValue: "extensionsPopover"), .siteControls,
            "A saved override written by an earlier build can no longer be decoded — renaming the case dropped the user's remap."
        )
        XCTAssertEqual(
            ShortcutCommandID.siteControls.rawValue, "extensionsPopover",
            "The persisted identity changed. Anything already written to OrbitShortcutOverrides.v1 for this command is now unreachable."
        )
    }

    func testCategoryNamesAreNotPartOfThePersistedKeySpace() {
        for category in ShortcutCategory.allCases {
            XCTAssertNil(
                ShortcutCommandID(rawValue: category.rawValue),
                "\"\(category.rawValue)\" is both a category display name and a valid ShortcutCommandID raw value — renaming the category would then move a persisted key."
            )
        }
    }

    func testARemapOfTheRetitledCommandTakesEffect() throws {
        let custom = KeyBinding(key: "e", modifiers: [.command, .shift])
        ShortcutRegistry.shared.setBinding(custom, for: .siteControls)

        XCTAssertEqual(
            ShortcutRegistry.shared.binding(for: .siteControls), custom,
            "The remap did not take effect in the registry."
        )
        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: KeyEventFixtures.keyDownEvent(for: custom)), .siteControls,
            "The remapped key does not resolve back to the command it was bound to."
        )

        scratchDefaults.synchronize()
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let data = try XCTUnwrap(
            store.data(forKey: ShortcutRegistry.defaultsKey),
            "The remap was never written, so nothing about its persisted identity can be asserted."
        )
        let decoded = try JSONDecoder().decode([String: KeyBinding?].self, from: data)
        XCTAssertEqual(
            decoded["extensionsPopover"] ?? nil, custom,
            "The remap is not stored under \"extensionsPopover\" — an existing install's saved binding for this command is now unreachable. Stored keys: \(decoded.keys.sorted())."
        )

        ShortcutRegistry.shared.resetToDefaults()
        XCTAssertEqual(ShortcutRegistry.shared.binding(for: .siteControls)?.modifierFlags, .command)
    }
}
