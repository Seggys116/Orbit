import Foundation

// On disk: Notes/index.json ([NoteIndexEntry]) + Notes/<note-id>.json per document.

nonisolated public struct NoteIndexEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

@MainActor
@Observable
public final class NoteStore {

    public private(set) var index: [NoteIndexEntry] = []

    private let directory: URL
    private let indexWriter: AtomicJSONFileWriter<[NoteIndexEntry]>
    private var documentWriters: [UUID: AtomicJSONFileWriter<Note>] = [:]
    private var loadedDocuments: [UUID: Note] = [:]

    public init(directory: URL = NoteStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.indexWriter = AtomicJSONFileWriter(fileURL: directory.appendingPathComponent("index.json", isDirectory: false))
        self.index = indexWriter.loadNow(default: [])
    }

    public nonisolated static var defaultDirectory: URL { OrbitDataRoot.processDefault.notes }

    // MARK: - CRUD

    @discardableResult
    public func createNote(title: String = "Untitled Note", bodyData: Data = Data()) -> Note {
        let note = Note(title: title, bodyData: bodyData)
        loadedDocuments[note.id] = note
        persistDocument(note)
        index.insert(NoteIndexEntry(id: note.id, title: note.title, updatedAt: note.updatedAt), at: 0)
        persistIndex()
        return note
    }

    public func note(_ id: UUID) -> Note? {
        if let loaded = loadedDocuments[id] { return loaded }
        guard index.contains(where: { $0.id == id }) else { return nil }
        let loaded = writer(for: id).loadNow(default: Note(id: id))
        loadedDocuments[id] = loaded
        return loaded
    }

    public func updateNote(_ id: UUID, _ transform: (inout Note) -> Void) {
        guard var note = note(id) else { return }
        transform(&note)
        note.updatedAt = Date()
        loadedDocuments[id] = note
        persistDocument(note)

        if let indexPosition = index.firstIndex(where: { $0.id == id }) {
            index[indexPosition].title = note.title
            index[indexPosition].updatedAt = note.updatedAt
        } else {
            index.append(NoteIndexEntry(id: id, title: note.title, updatedAt: note.updatedAt))
        }
        persistIndex()
    }

    public func renameNote(_ id: UUID, to title: String) {
        updateNote(id) { $0.title = title }
    }

    public func setBody(_ data: Data, forNote id: UUID) {
        updateNote(id) { $0.bodyData = data }
    }

    public func deleteNote(_ id: UUID) {
        loadedDocuments.removeValue(forKey: id)
        documentWriters.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: documentURL(for: id))
        index.removeAll { $0.id == id }
        persistIndex()
    }

    public func deleteAllNotes() {
        for id in index.map(\.id) { deleteNote(id) }
    }

    // MARK: - Persistence

    public func saveNow() throws {
        try indexWriter.saveNow(index)
        for (id, document) in loadedDocuments {
            try writer(for: id).saveNow(document)
        }
    }

    private func persistDocument(_ note: Note) {
        writer(for: note.id).scheduleSave(note)
    }

    private func persistIndex() {
        indexWriter.scheduleSave(index)
    }

    private func writer(for id: UUID) -> AtomicJSONFileWriter<Note> {
        if let existing = documentWriters[id] { return existing }
        let created = AtomicJSONFileWriter<Note>(fileURL: documentURL(for: id))
        documentWriters[id] = created
        return created
    }

    private func documentURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}
