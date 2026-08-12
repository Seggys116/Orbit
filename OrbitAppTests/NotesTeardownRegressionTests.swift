import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class NotesTeardownRegressionTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?
    private var scratchSpaceID: SpaceID!

    override func setUp() {
        super.setUp()
        FeatureRegistration.installAll(into: env)
        let profileID = env.createDefaultProfileIfNeeded()
        scratchSpaceID = env.createSpace(
            name: "Notes Teardown Scratch",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: profileID
        )
        env.selectSpace(scratchSpaceID)
    }

    override func tearDown() {
        NotesEditorView.controllerObserverForTests = nil
        window?.orderOut(nil)
        window = nil
        if let scratchSpaceID { env.deleteSpace(scratchSpaceID) }
        scratchSpaceID = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func hostLikeProduction<V: View>(_ content: V, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
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

    private struct NoteIdentityHost: View {
        var noteID: UUID
        let env: AppEnvironment

        var body: some View {
            NotesEditorView(noteID: noteID)
                .environment(env)
        }
    }

    private func hostNoteIdentityDirectly(noteID: UUID, size: CGSize) -> (window: NSWindow, host: NSHostingView<NoteIdentityHost>) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NoteIdentityHost(noteID: noteID, env: env))
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
        return (window, host)
    }

    private func firstDescendant<T: NSView>(of view: NSView?, ofType type: T.Type) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstDescendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    private func allDescendants<T: NSView>(of view: NSView?, ofType type: T.Type, into result: inout [T]) {
        guard let view else { return }
        if let match = view as? T { result.append(match) }
        for subview in view.subviews { allDescendants(of: subview, ofType: type, into: &result) }
    }

    private func bodyTextView(in window: NSWindow) -> NSTextView? {
        firstDescendant(of: window.contentView, ofType: NSTextView.self)
    }

    private func titleFields(in window: NSWindow) -> [NSTextField] {
        var result: [NSTextField] = []
        allDescendants(of: window.contentView, ofType: NSTextField.self, into: &result)
        return result
    }

    // MARK: - Fixtures

    private struct NoteFixture {
        let id: UUID
        let title: String
        let body: String
    }

    @discardableResult
    private func makeNote(title: String, body: String) -> NoteFixture {
        let note = env.noteStore.createNote(title: title)
        guard let encoded = NotesEditorView.encode(NSAttributedString(string: body)) else {
            XCTFail("NotesEditorView.encode returned nil for a plain-string fixture — the fixture itself is broken.")
            return NoteFixture(id: note.id, title: title, body: body)
        }
        env.noteStore.setBody(encoded, forNote: note.id)
        return NoteFixture(id: note.id, title: title, body: body)
    }

    private func openNoteTab(_ fixture: NoteFixture) -> TabID {
        env.openTab(
            url: URL(string: "orbit://note/\(fixture.id.uuidString)")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )
    }

    // MARK: - Disk verification

    private func reflectedURL(of object: AnyObject, propertyNamed name: String) -> URL? {
        Mirror(reflecting: object).children.first(where: { $0.label == name })?.value as? URL
    }

    private func noteStoreReadFromDisk() -> NoteStore? {
        do {
            try env.noteStore.saveNow()
        } catch {
            XCTFail("env.noteStore.saveNow() threw: \(error)")
            return nil
        }
        guard let directory = reflectedURL(of: env.noteStore, propertyNamed: "directory") else {
            XCTFail("Could not reflect NoteStore's private `directory` property — NoteStore's internal storage layout changed.")
            return nil
        }
        return NoteStore(directory: directory)
    }

    // MARK: - Render carryover (H1, structural half)

    func test_theRichTextNSTextViewSurvivesUnchangedAcrossASwitchToADifferentNoteTab() {
        let noteA = makeNote(title: "Note A — must stay closed", body: "Note A original body — must never be shown for Note B.")
        let noteB = makeNote(title: "Note B — the one being opened", body: "Note B original body — must survive being opened.")

        let (window, host) = hostNoteIdentityDirectly(noteID: noteA.id, size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        guard let firstTextView = bodyTextView(in: window) else {
            XCTFail("No NSTextView was found in the hosted tree while showing Note A; the harness itself is broken.")
            return
        }
        XCTAssertEqual(
            firstTextView.string, noteA.body,
            "Fixture check: opening Note A did not load Note A's real body at all — nothing below is testing the reported defect."
        )

        host.rootView = NoteIdentityHost(noteID: noteB.id, env: env)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let secondTextView = bodyTextView(in: window) else {
            XCTFail("No NSTextView was found in the hosted tree after reassigning rootView to Note B's noteID.")
            return
        }

        XCTAssertTrue(
            secondTextView === firstTextView,
            """
            A brand-new NSTextView instance appeared after reassigning `NSHostingView.rootView` on the same host — \
            that would mean SwiftUI itself tore `NotesEditorView` down for a same-type `rootView` reassignment, \
            which is not how `NSHostingView` is documented to behave and would mean this harness itself is no \
            longer testing what it claims to.
            """
        )
        XCTAssertEqual(
            secondTextView.string, noteB.body,
            """
            The pane still showed "\(secondTextView.string)" instead of Note B's real, on-disk content \
            ("\(noteB.body)") after `noteID` changed to Note B's, even though the very same NSTextView instance \
            (per the assertion above) was reused rather than remounted. NotesEditorView.body's \
            `.task(id: noteID)` (NotesEditorView.swift) is what is supposed to reload title/attributedText whenever \
            `noteID` changes on its own, independently of whether SwiftUI ever tears the view down — this is that \
            guarantee holding under the worst case it has to survive.
            """
        )
    }

    func test_theTitleFieldCorrectlyReloadsForASecondNoteTabDespiteReusingTheSameViewIdentity() {
        let noteA = makeNote(title: "Note A Title — must stay closed", body: "Note A body.")
        let noteB = makeNote(title: "Note B Title — the one being opened", body: "Note B body.")
        let tabA = openNoteTab(noteA)
        let tabB = openNoteTab(noteB)

        env.activateTab(tabA)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        XCTAssertTrue(
            titleFields(in: window).contains(where: { $0.stringValue == noteA.title }),
            "Fixture check: Note A's title never rendered at all."
        )

        env.activateTab(tabB)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let visibleTitles = titleFields(in: window).map(\.stringValue)
        XCTAssertTrue(
            visibleTitles.contains(noteB.title),
            "Switching to Note B's tab should show Note B's real title; found titles: \(visibleTitles)."
        )
        XCTAssertFalse(
            visibleTitles.contains(noteA.title),
            "Note A's stale title (\"\(noteA.title)\") was still visible after switching to Note B's tab — the " +
            "title field did not reload; found titles: \(visibleTitles)."
        )
    }

    // MARK: - Save corruption (H1, disk half)

    func test_typingWhileNoteBsTabIsActive_revealsWhichNotesFileActuallyReceivesTheEdit() {
        let noteA = makeNote(title: "Note A — must stay closed", body: "Note A original body.")
        let noteB = makeNote(title: "Note B — the one being opened", body: "Note B original body.")
        let tabA = openNoteTab(noteA)
        let tabB = openNoteTab(noteB)

        env.activateTab(tabA)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)
        guard bodyTextView(in: window) != nil else {
            XCTFail("Fixture check: Note A's NSTextView never mounted.")
            return
        }

        env.activateTab(tabB)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let textView = bodyTextView(in: window) else {
            XCTFail("Fixture check: no NSTextView present after switching to Note B's tab.")
            return
        }
        XCTAssertEqual(
            textView.string, noteB.body,
            "Fixture check: Note B's real body never rendered after switching to its tab — nothing below is testing what it claims to."
        )

        let typedMarker = "TYPED WHILE THE PANE SHOWED NOTE B"
        window.makeFirstResponder(textView)
        pump(seconds: 0.1)
        textView.insertText(typedMarker, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        pump(seconds: 1.2)

        guard let diskStore = noteStoreReadFromDisk() else { return }
        let noteABody = diskStore.note(noteA.id).flatMap { NotesEditorView.decode($0.bodyData) }?.string
        let noteBBody = diskStore.note(noteB.id).flatMap { NotesEditorView.decode($0.bodyData) }?.string

        XCTAssertEqual(
            noteBBody, typedMarker,
            """
            Note B's file on disk was not updated with the typed marker (found \
            "\(String(describing: noteBBody))") even though the pane visibly showed Note B's tab, and its own \
            NSTextView, while the edit was made. NotesEditorView.scheduleSave(for:)'s explicit `id` parameter — \
            closed over by RichTextEditorView's onEdit and refreshed into the coordinator on every \
            RichTextEditorView.updateNSView call (RichTextController.swift) — is what is supposed to keep the save \
            target pinned to whichever note is actually on screen, never whichever note mounted first.
            """
        )
        XCTAssertEqual(
            noteABody, noteA.body,
            """
            Note A's file on disk changed (now "\(String(describing: noteABody))", was "\(noteA.body)") from an \
            edit made while Note A's own tab was never active during this test. An edit made while Note B's tab \
            was showing must never be able to reach Note A's document.
            """
        )
    }

    // MARK: - Single-note pane switch (the user's report, verbatim, with no second note involved)

    func test_singleNote_typedContentSurvivesSwitchingThePaneAwayToAWebTabAndBack() {
        let note = makeNote(title: "Solo Note", body: "Original body.")
        let noteTab = openNoteTab(note)
        let webTab = env.openTab(
            url: URL(string: "https://example.com/notes-teardown-regression")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )

        env.activateTab(noteTab)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        guard let textView = bodyTextView(in: window) else {
            XCTFail("Fixture check: the note's NSTextView never mounted.")
            return
        }
        XCTAssertEqual(
            textView.string, note.body,
            "Fixture check: the note's original body never rendered at all — nothing below is testing the reported defect."
        )

        let typedMarker = "TYPED INTO THE ONE AND ONLY NOTE TAB"
        window.makeFirstResponder(textView)
        pump(seconds: 0.1)
        textView.insertText(typedMarker, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        pump(seconds: 0.1)

        env.activateTab(webTab)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        XCTAssertNil(
            bodyTextView(in: window),
            "The note's NSTextView is still present in the hosted tree after switching to a web tab — the pane never actually left the note, so nothing below is testing a real teardown-and-remount."
        )

        env.activateTab(noteTab)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let textViewAfterReturn = bodyTextView(in: window) else {
            XCTFail("No NSTextView was found after switching back to the note's own tab — the pane, not just its content, failed to come back.")
            return
        }
        XCTAssertEqual(
            textViewAfterReturn.string, typedMarker,
            """
            Switching the pane away to a web tab and back left the note showing "\(textViewAfterReturn.string)" \
            instead of what was typed ("\(typedMarker)") — this is the user's report verbatim: "As soon as I \
            click off and click back on, the note gets completely erased."
            """
        )

        guard let diskStore = noteStoreReadFromDisk() else { return }
        let savedBody = diskStore.note(note.id).flatMap { NotesEditorView.decode($0.bodyData) }?.string
        XCTAssertEqual(
            savedBody, typedMarker,
            """
            The typed content never actually reached disk (found "\(String(describing: savedBody))", expected \
            "\(typedMarker)"), read back through a brand-new NoteStore pointed at the same directory rather than \
            env.noteStore's own in-memory cache — this is a claim about the bytes NoteStore actually wrote, not a \
            value still sitting in a dictionary.
            """
        )
    }

    // MARK: - Retain cycle (F1)

    func test_theControllerNoLongerRetainsThisViewAfterATeardown_breakingTheF1RetainCycle() {
        let note = makeNote(
            title: "Leak Check",
            body: "A body long enough that, if this stayed resident for the rest of the app session, it would matter."
        )
        let noteTab = openNoteTab(note)
        let webTab = env.openTab(
            url: URL(string: "https://example.com/notes-retain-cycle-regression")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )

        weak var capturedController: RichTextController?
        NotesEditorView.controllerObserverForTests = { controller in
            capturedController = controller
        }

        env.activateTab(noteTab)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        guard let controller = capturedController else {
            XCTFail("Fixture check: NotesEditorView.controllerObserverForTests never fired, so nothing below is testing a real, live RichTextController instance.")
            return
        }
        NotesEditorView.controllerObserverForTests = nil

        XCTAssertNotNil(
            controller.onChange,
            "Fixture check: load(for:) never actually assigned controller.onChange, so nothing below is testing the F1 cycle this file exists to prove broken."
        )

        env.activateTab(webTab)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        XCTAssertNil(
            controller.onChange,
            """
            controller.onChange was still set after the pane was torn down and switched to a web tab — meaning the \
            F1 retain cycle (RichTextController.onChange -> the closure load(for:) assigns it -> that closure's \
            captured NotesEditorView copy -> _controller: State<RichTextController>'s storage -> the same \
            controller) was never actually broken. tearDown()'s `controller.onChange = nil` (NotesEditorView.swift) \
            is what is supposed to cut this cycle on the way out.
            """
        )
    }

    // MARK: - Quit-time flush registration (F2)

    func test_flushRegistryRegistersOnAppearAndDeregistersOnDisappear_andAQuitTimeFlushReachesDisk() {
        let note = makeNote(title: "Quit Flush Check", body: "Original body.")
        let noteTab = openNoteTab(note)
        let webTab = env.openTab(
            url: URL(string: "https://example.com/notes-flush-registry-regression")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )

        let baselineCount = DocumentEditorFlushRegistry.shared.registeredCount

        env.activateTab(noteTab)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        XCTAssertEqual(
            DocumentEditorFlushRegistry.shared.registeredCount, baselineCount + 1,
            """
            Mounting a single note tab should register exactly one flush closure with \
            DocumentEditorFlushRegistry.shared; found \(DocumentEditorFlushRegistry.shared.registeredCount) \
            registered against a baseline of \(baselineCount) taken before this note's editor was ever mounted.
            """
        )

        guard let textView = bodyTextView(in: window) else {
            XCTFail("Fixture check: the note's NSTextView never mounted.")
            return
        }
        let typedMarker = "TYPED JUST BEFORE A SIMULATED QUIT"
        window.makeFirstResponder(textView)
        pump(seconds: 0.1)
        textView.insertText(typedMarker, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        pump(seconds: 0.1)

        DocumentEditorFlushRegistry.shared.flushAll()
        guard let diskStore = noteStoreReadFromDisk() else { return }
        let savedBody = diskStore.note(note.id).flatMap { NotesEditorView.decode($0.bodyData) }?.string
        XCTAssertEqual(
            savedBody, typedMarker,
            """
            The typed content never reached disk after a simulated quit-time flush (found \
            "\(String(describing: savedBody))", expected "\(typedMarker)") — DocumentEditorFlushRegistry.shared \
            .flushAll() is supposed to reach this note's still-debounced edit even though the 500ms save timer \
            never actually fired on its own.
            """
        )

        env.activateTab(webTab)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        XCTAssertEqual(
            DocumentEditorFlushRegistry.shared.registeredCount, baselineCount,
            """
            Switching the pane away should deregister this note's flush entry via tearDown(); found \
            \(DocumentEditorFlushRegistry.shared.registeredCount) registered against a baseline of \
            \(baselineCount), meaning the entry was left behind after a genuine teardown.
            """
        )
    }

    // MARK: - Opening a note must not itself edit it (F5)

    func test_mountingANoteEditorDoesNotRewriteItOrChangeUpdatedAt() {
        let note = makeNote(
            title: "Untouched While Merely Viewed",
            body: "Original body — this test never types into the note at all."
        )
        guard let beforeStore = noteStoreReadFromDisk() else { return }
        guard let originalUpdatedAt = beforeStore.note(note.id)?.updatedAt else {
            XCTFail("Fixture check: the note was never actually persisted.")
            return
        }
        guard let originalIndexEntry = beforeStore.index.first(where: { $0.id == note.id }) else {
            XCTFail("Fixture check: the note never made it into NoteStore's index.")
            return
        }

        let noteTab = openNoteTab(note)
        env.activateTab(noteTab)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.6)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard bodyTextView(in: window) != nil else {
            XCTFail("Fixture check: the note's NSTextView never mounted.")
            return
        }

        guard let afterStore = noteStoreReadFromDisk() else { return }
        let reloadedNote = afterStore.note(note.id)
        XCTAssertEqual(
            reloadedNote?.updatedAt, originalUpdatedAt,
            """
            Merely opening the note changed its updatedAt from \(originalUpdatedAt) to \
            \(String(describing: reloadedNote?.updatedAt)) — opening a note must never itself count as an edit.
            """
        )
        XCTAssertEqual(
            reloadedNote?.title, note.title,
            "Merely opening the note changed its title from \"\(note.title)\" to \"\(String(describing: reloadedNote?.title))\"."
        )

        let reloadedIndexEntry = afterStore.index.first(where: { $0.id == note.id })
        XCTAssertEqual(
            reloadedIndexEntry?.updatedAt, originalIndexEntry.updatedAt,
            """
            The note's own NoteIndexEntry.updatedAt changed from merely opening the note (was \
            \(originalIndexEntry.updatedAt), now \(String(describing: reloadedIndexEntry?.updatedAt))) — this is \
            exactly what would bump it to the top of a recency-ordered Library list purely from being looked at.
            """
        )
    }
}
