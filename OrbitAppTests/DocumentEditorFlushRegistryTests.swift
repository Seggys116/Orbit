//  NoteStore/EaselStore.saveNow() had no production callers, so an edit inside
//  its debounce window was lost at Cmd+Q. Disk assertions read back through a fresh store.

import XCTest
@testable import Orbit

@MainActor
final class DocumentEditorFlushRegistryTests: XCTestCase {

    private var scratchDirectory: URL!

    /// Deregistered in tearDown so a closure from one test can never fire in
    /// another: `DocumentEditorFlushRegistry.shared` is a process-wide singleton.
    private var registeredTokens: [UUID] = []

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-DocumentEditorFlushRegistry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for token in registeredTokens {
            DocumentEditorFlushRegistry.shared.deregister(token)
        }
        registeredTokens = []
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Harness

    @discardableResult
    private func registerTrackedFlush(_ flush: @escaping () -> Void) -> UUID {
        let token = UUID()
        DocumentEditorFlushRegistry.shared.register(token, flush: flush)
        registeredTokens.append(token)
        return token
    }

    private func runTerminateFlushSequence(noteStore: NoteStore, easelStore: EaselStore) {
        DocumentEditorFlushRegistry.shared.flushAll()
        try? noteStore.saveNow()
        try? easelStore.saveNow()
    }

    private func makeNoteStore() -> NoteStore {
        NoteStore(directory: scratchDirectory.appendingPathComponent("Notes", isDirectory: true))
    }

    private func makeEaselStore() -> EaselStore {
        EaselStore(directory: scratchDirectory.appendingPathComponent("Easels", isDirectory: true))
    }

    private func noteStoreReadFromDisk() -> NoteStore {
        NoteStore(directory: scratchDirectory.appendingPathComponent("Notes", isDirectory: true))
    }

    private func easelStoreReadFromDisk() -> EaselStore {
        EaselStore(directory: scratchDirectory.appendingPathComponent("Easels", isDirectory: true))
    }

    // MARK: - Registry bookkeeping

    func test_registeringTheSameTokenTwice_replacesRatherThanAccumulates() {
        let countBefore = DocumentEditorFlushRegistry.shared.registeredCount
        let token = UUID()
        var firstClosureFired = false
        var secondClosureFired = false

        DocumentEditorFlushRegistry.shared.register(token) { firstClosureFired = true }
        DocumentEditorFlushRegistry.shared.register(token) { secondClosureFired = true }
        registeredTokens.append(token)

        XCTAssertEqual(
            DocumentEditorFlushRegistry.shared.registeredCount, countBefore + 1,
            "Registering the same token twice changed registeredCount by \(DocumentEditorFlushRegistry.shared.registeredCount - countBefore), not by 1 — the second register(_:flush:) call accumulated a second entry instead of replacing the first."
        )

        DocumentEditorFlushRegistry.shared.flushAll()

        XCTAssertFalse(firstClosureFired, "The first-registered closure fired even though register(_:flush:) was called again for the same token before flushAll() ran — it should have been replaced, not merely joined.")
        XCTAssertTrue(secondClosureFired, "The second-registered closure — the one that should have replaced the first under the same token — never fired.")
    }

    func test_flushAll_runsEveryRegisteredClosure() {
        var firedTokens: Set<UUID> = []
        let tokenA = registerTrackedFlush { firedTokens.insert(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!) }
        let tokenB = registerTrackedFlush { firedTokens.insert(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!) }
        let tokenC = registerTrackedFlush { firedTokens.insert(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!) }
        _ = (tokenA, tokenB, tokenC)

        DocumentEditorFlushRegistry.shared.flushAll()

        XCTAssertEqual(
            firedTokens,
            [
                UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
                UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
            ],
            "flushAll() did not run every registered closure — found: \(firedTokens)."
        )
    }

    func test_aDeregisteredEditorDoesNotFireAtQuit() {
        var fired = false
        let token = UUID()
        DocumentEditorFlushRegistry.shared.register(token) { fired = true }
        registeredTokens.append(token)

        DocumentEditorFlushRegistry.shared.deregister(token)

        DocumentEditorFlushRegistry.shared.flushAll()

        XCTAssertFalse(fired, "A deregistered editor's flush closure fired anyway when flushAll() ran.")
    }

    // MARK: - End-to-end: a debounced Note edit really reaches disk

    func test_terminateSequence_flushesAPendingNoteEditThroughToAFreshStoreReadFromDisk() throws {
        let noteStore = makeNoteStore()
        let easelStore = makeEaselStore()

        let originalBody = try XCTUnwrap(NotesEditorView.encode(NSAttributedString(string: "Original body — must be superseded.")))
        let note = noteStore.createNote(title: "Scratch Note", bodyData: originalBody)
        try noteStore.saveNow()

        let editedBody = try XCTUnwrap(NotesEditorView.encode(NSAttributedString(string: "TYPED, THEN NEVER FLUSHED UNTIL TERMINATE")))
        registerTrackedFlush {
            noteStore.setBody(editedBody, forNote: note.id)
        }

        let beforeTerminate = noteStoreReadFromDisk()
        let bodyBeforeTerminate = beforeTerminate.note(note.id).flatMap { NotesEditorView.decode($0.bodyData) }?.string
        XCTAssertEqual(
            bodyBeforeTerminate, "Original body — must be superseded.",
            "Fixture check: the edit had already reached disk before the terminate sequence ran (found \"\(String(describing: bodyBeforeTerminate))\") — nothing below is testing the reported defect."
        )

        runTerminateFlushSequence(noteStore: noteStore, easelStore: easelStore)

        let afterTerminate = noteStoreReadFromDisk()
        let bodyAfterTerminate = afterTerminate.note(note.id).flatMap { NotesEditorView.decode($0.bodyData) }?.string
        XCTAssertEqual(
            bodyAfterTerminate, "TYPED, THEN NEVER FLUSHED UNTIL TERMINATE",
            """
            The edit sitting in the debounce window at "quit" was not on disk afterwards (found \
            "\(String(describing: bodyAfterTerminate))"), read back through a brand-new NoteStore at the same \
            scratch directory rather than the store instance under test's own loadedDocuments cache. This is the \
            defect OrbitAppDelegate.applicationWillTerminate's flushAll()/saveNow() sequence exists to close.
            """
        )
    }

    // MARK: - End-to-end: a debounced Easel edit really reaches disk

    func test_terminateSequence_flushesAPendingEaselTitleEditThroughToAFreshStoreReadFromDisk() throws {
        let noteStore = makeNoteStore()
        let easelStore = makeEaselStore()

        let easel = easelStore.createEasel(title: "Original Title — must be superseded.")
        try easelStore.saveNow()

        registerTrackedFlush {
            easelStore.renameEasel(easel.id, to: "RENAMED, THEN NEVER FLUSHED UNTIL TERMINATE")
        }

        let beforeTerminate = easelStoreReadFromDisk()
        XCTAssertEqual(
            beforeTerminate.easel(easel.id)?.title, "Original Title — must be superseded.",
            "Fixture check: the rename had already reached disk before the terminate sequence ran — nothing below is testing the reported defect."
        )

        runTerminateFlushSequence(noteStore: noteStore, easelStore: easelStore)

        let afterTerminate = easelStoreReadFromDisk()
        XCTAssertEqual(
            afterTerminate.easel(easel.id)?.title, "RENAMED, THEN NEVER FLUSHED UNTIL TERMINATE",
            """
            The rename sitting in the debounce window at "quit" was not on disk afterwards (found \
            "\(String(describing: afterTerminate.easel(easel.id)?.title))"), read back through a brand-new \
            EaselStore at the same scratch directory rather than the store instance under test's own \
            loadedDocuments cache.
            """
        )
    }

    func test_terminateSequence_doesNotFlushAnEditFromADeregisteredEditor() throws {
        let noteStore = makeNoteStore()
        let easelStore = makeEaselStore()

        let originalBody = try XCTUnwrap(NotesEditorView.encode(NSAttributedString(string: "Original body — must survive untouched.")))
        let note = noteStore.createNote(title: "Deregistered Scratch Note", bodyData: originalBody)
        try noteStore.saveNow()

        let editedBody = try XCTUnwrap(NotesEditorView.encode(NSAttributedString(string: "MUST NEVER REACH DISK")))
        let token = registerTrackedFlush {
            noteStore.setBody(editedBody, forNote: note.id)
        }
        DocumentEditorFlushRegistry.shared.deregister(token)

        runTerminateFlushSequence(noteStore: noteStore, easelStore: easelStore)

        let afterTerminate = noteStoreReadFromDisk()
        let bodyAfterTerminate = afterTerminate.note(note.id).flatMap { NotesEditorView.decode($0.bodyData) }?.string
        XCTAssertEqual(
            bodyAfterTerminate, "Original body — must survive untouched.",
            "A deregistered editor's pending edit (\"MUST NEVER REACH DISK\") reached disk anyway after the terminate sequence ran; found: \"\(String(describing: bodyAfterTerminate))\"."
        )
    }
}
