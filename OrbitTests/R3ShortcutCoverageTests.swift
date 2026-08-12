import AppKit
import XCTest

@MainActor
final class R3ShortcutCoverageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ShortcutRegistry.shared.resetToDefaults()
    }

    override func tearDown() {
        ShortcutRegistry.shared.resetToDefaults()
        super.tearDown()
    }

    func test_everyShortcutCommandID_hasExactlyOneRegistryEntry() {
        var seen: [ShortcutCommandID: Int] = [:]
        for command in ShortcutRegistry.shared.commands {
            seen[command.id, default: 0] += 1
        }
        for id in ShortcutCommandID.allCases {
            let count = seen[id] ?? 0
            XCTAssertEqual(count, 1, "\(id) has \(count) entries in ShortcutRegistry's command table (expected exactly 1).")
        }
    }

    func test_noTwoShortcutCommands_shareADefaultBinding() {
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

    func test_everyDefaultBinding_resolvesBackToItsOwnCommand() {
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

    func test_addSplit_bindingResolvesAndIsUncontested() {
        guard let command = ShortcutRegistry.shared.commands.first(where: { $0.id == .addSplit }) else {
            XCTFail(".addSplit has no ShortcutRegistry entry at all.")
            return
        }
        guard let binding = command.defaultBinding else {
            XCTFail(".addSplit has a registry entry but no default binding.")
            return
        }
        let resolved = ShortcutRegistry.shared.command(matching: KeyEventFixtures.keyDownEvent(for: binding))
        XCTAssertEqual(resolved, .addSplit, "\(binding.displayString) did not resolve back to .addSplit.")
    }
}
