import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class FindAndReplaceMenuRowTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        super.tearDown()
    }

    // MARK: - 1. The row's shape

    private func findAndReplaceRow() throws -> NSMenuItem {
        let findMenu = try XCTUnwrap(
            MainMenuBuilder.build().items
                .compactMap(\.submenu)
                .first { $0.title == "Edit" }?
                .items
                .first { $0.title == "Find" }?
                .submenu,
            "The Edit menu has no Find submenu (refs/reference/arc-mainmenu-nib-dump.txt:65-71)."
        )
        return try XCTUnwrap(
            findMenu.items.first { $0.title == "Find and Replace" },
            "Edit ▸ Find has no Find and Replace row."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theRowIsAStandardResponderChainActionAndNotAnOrbitCommand

    func test_theRowIsAStandardResponderChainActionAndNotAnOrbitCommand() throws {
        let row = try findAndReplaceRow()

        XCTAssertNil(
            row.target,
            """
            Find and Replace has a target again, which means it dispatches to one specific object \
            instead of the first responder. That is how the row came to be permanently lit over \
            AppEnvironment.perform(.findAndReplace), which returns false and does nothing.
            """
        )
        XCTAssertEqual(
            row.action, #selector(NSResponder.performTextFinderAction(_:)),
            "The row must carry AppKit's own find action, which is what a focused NSTextView implements. Arc wires its whole Find submenu the same way (nib 66-71)."
        )
        XCTAssertEqual(
            row.tag, NSTextFinder.Action.showReplaceInterface.rawValue,
            "performTextFinderAction: reads the sender's tag to decide which find action is meant; showReplaceInterface is the one that opens the find bar with its replace field."
        )
        XCTAssertFalse(
            row is CommandMenuItem,
            "The row is a CommandMenuItem again, so it dispatches through perform(.findAndReplace) — the exact wiring that made it dead."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theRowStillCarriesTheRegistrysBindingForFindAndReplace

    func test_theRowStillCarriesTheRegistrysBindingForFindAndReplace() throws {
        let row = try findAndReplaceRow()
        let binding = try XCTUnwrap(
            ShortcutRegistry.shared.binding(for: .findAndReplace),
            ".findAndReplace has no effective binding, so this test would pass for the wrong reason."
        )

        XCTAssertEqual(row.keyEquivalent, binding.menuKeyEquivalent, "The row must show the key the registry currently holds, not a literal baked in at build time.")
        XCTAssertEqual(row.keyEquivalentModifierMask, binding.modifierFlags)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_openingTheFindMenuRefreshesTheRowsKeyEquivalentAfterARemap

    func test_openingTheFindMenuRefreshesTheRowsKeyEquivalentAfterARemap() throws {
        let findItem = try XCTUnwrap(
            MainMenuBuilder.build().items
                .compactMap(\.submenu)
                .first { $0.title == "Edit" }?
                .items
                .first { $0.title == "Find" },
            "The Edit menu has no Find submenu."
        )
        let findMenu = try XCTUnwrap(findItem.submenu, "Find carries no submenu.")
        XCTAssertTrue(
            findMenu is ShortcutRefreshingMenu,
            "The Find submenu is a plain NSMenu again, so nothing refreshes the Find and Replace row's key equivalent and a remap would only show up at the next launch."
        )
        let row = try XCTUnwrap(findMenu.items.first { $0.title == "Find and Replace" } as? TextFinderMenuItem)

        row.keyEquivalent = "…"
        findMenu.update()

        XCTAssertEqual(
            row.keyEquivalent,
            ShortcutRegistry.shared.binding(for: .findAndReplace)?.menuKeyEquivalent ?? "",
            "Displaying the Find menu did not re-read the binding, so the glyph on the row and the key that actually works can disagree."
        )
    }

    // MARK: - 2 and 3. A real Note editor answers it; a default NSTextView does not

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aMountedNoteEditorValidatesTheRowAndABareTextViewDoesNot

    func test_aMountedNoteEditorValidatesTheRowAndABareTextViewDoesNot() throws {
        let row = try findAndReplaceRow()

        let note = env.noteStore.createNote(title: "Find and Replace")
        let window = hostNoteEditor(noteID: note.id, size: CGSize(width: 640, height: 480))
        let editor = try XCTUnwrap(
            firstDescendant(of: window.contentView, ofType: NSTextView.self),
            "No NSTextView was found in the hosted Note editor; the harness itself is broken."
        )

        XCTAssertTrue(
            editor.usesFindBar,
            """
            The Note editor's NSTextView has no find bar, which is the property NSTextView's own \
            validateUserInterfaceItem: checks before it will answer performTextFinderAction:. \
            Without it every row of Edit ▸ Find would be permanently grey over the one editor in \
            Orbit that can genuinely replace text.
            """
        )
        XCTAssertTrue(
            editor.validateUserInterfaceItem(row),
            """
            A focused Note editor refuses Edit ▸ Find ▸ Find and Replace, so the row would be greyed \
            out everywhere and the menu path would still be dead. This is the assertion that the row \
            actually reaches a responder that handles it.
            """
        )

        let bare = NSTextView()
        XCTAssertFalse(
            bare.validateUserInterfaceItem(row),
            """
            A stock NSTextView already validates this row, so the assertion above proves nothing \
            about usesFindBar and this test would keep passing if that line were deleted.
            """
        )
    }

    // MARK: - 4. The keyboard path is unchanged

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theCommandItselfStillReportsFindAndReplaceUnhandled

    func test_theCommandItselfStillReportsFindAndReplaceUnhandled() {
        XCTAssertFalse(
            env.perform(.findAndReplace),
            "perform(.findAndReplace) started claiming the command. That swallows ⌥⌘F app-wide, taking it away from the focused text view that actually implements Find/Replace."
        )
    }

    // MARK: - Harness

    private func hostNoteEditor(noteID: UUID, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NotesEditorView(noteID: noteID).environment(env))
        host.safeAreaRegions = []
        host.sizingOptions = []
        let container = OrbitWindowContentView(frame: NSRect(origin: .zero, size: size))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.displayIfNeeded()
        self.window = window
        return window
    }

    private func firstDescendant<T: NSView>(of view: NSView?, ofType type: T.Type) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstDescendant(of: subview, ofType: type) { return match }
        }
        return nil
    }
}
