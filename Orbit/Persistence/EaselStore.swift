import Foundation

// On disk: Easels/index.json ([EaselIndexEntry]) + Easels/<easel-id>.json + Easels/<easel-id>-Images/ side-cars.

nonisolated public struct EaselIndexEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date
    public var itemCount: Int

    public init(id: UUID, title: String, updatedAt: Date, itemCount: Int) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.itemCount = itemCount
    }
}

@MainActor
@Observable
public final class EaselStore {

    public private(set) var index: [EaselIndexEntry] = []

    private let directory: URL
    private let indexWriter: AtomicJSONFileWriter<[EaselIndexEntry]>
    private var documentWriters: [UUID: AtomicJSONFileWriter<Easel>] = [:]
    private var loadedDocuments: [UUID: Easel] = [:]

    public init(directory: URL = EaselStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.indexWriter = AtomicJSONFileWriter(fileURL: directory.appendingPathComponent("index.json", isDirectory: false))
        self.index = indexWriter.loadNow(default: [])
    }

    public nonisolated static var defaultDirectory: URL { OrbitDataRoot.processDefault.easels }

    // MARK: - CRUD

    @discardableResult
    public func createEasel(title: String = "Untitled Easel") -> Easel {
        let easel = Easel(title: title)
        loadedDocuments[easel.id] = easel
        persistDocument(easel)
        index.insert(EaselIndexEntry(id: easel.id, title: easel.title, updatedAt: easel.updatedAt, itemCount: easel.items.count), at: 0)
        persistIndex()
        return easel
    }

    public func easel(_ id: UUID) -> Easel? {
        if let loaded = loadedDocuments[id] { return loaded }
        guard index.contains(where: { $0.id == id }) else { return nil }
        let loaded = writer(for: id).loadNow(default: Easel(id: id))
        loadedDocuments[id] = loaded
        return loaded
    }

    public func updateEasel(_ id: UUID, _ transform: (inout Easel) -> Void) {
        guard var easel = easel(id) else { return }
        transform(&easel)
        easel.updatedAt = Date()
        loadedDocuments[id] = easel
        persistDocument(easel)

        if let indexPosition = index.firstIndex(where: { $0.id == id }) {
            index[indexPosition].title = easel.title
            index[indexPosition].updatedAt = easel.updatedAt
            index[indexPosition].itemCount = easel.items.count
        } else {
            index.append(EaselIndexEntry(id: id, title: easel.title, updatedAt: easel.updatedAt, itemCount: easel.items.count))
        }
        persistIndex()
    }

    public func renameEasel(_ id: UUID, to title: String) {
        updateEasel(id) { $0.title = title }
    }

    public func deleteEasel(_ id: UUID) {
        loadedDocuments.removeValue(forKey: id)
        documentWriters.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: documentURL(for: id))
        try? FileManager.default.removeItem(at: imagesDirectory(for: id))
        index.removeAll { $0.id == id }
        persistIndex()
    }

    public func deleteAllEasels() {
        for id in index.map(\.id) { deleteEasel(id) }
    }

    // MARK: - Image side-cars

    @discardableResult
    public func storeImage(_ data: Data, forEasel id: UUID, preferredFileName: String? = nil) throws -> String {
        let dir = imagesDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = preferredFileName ?? "\(UUID().uuidString).png"
        let url = dir.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return fileName
    }

    public func imageURL(fileName: String, forEasel id: UUID) -> URL {
        imagesDirectory(for: id).appendingPathComponent(fileName, isDirectory: false)
    }

    public func loadImageData(fileName: String, forEasel id: UUID) -> Data? {
        try? Data(contentsOf: imageURL(fileName: fileName, forEasel: id))
    }

    public func deleteImage(fileName: String, forEasel id: UUID) {
        try? FileManager.default.removeItem(at: imageURL(fileName: fileName, forEasel: id))
    }

    // MARK: - Persistence

    public func saveNow() throws {
        try indexWriter.saveNow(index)
        for (id, document) in loadedDocuments {
            try writer(for: id).saveNow(document)
        }
    }

    private func persistDocument(_ easel: Easel) {
        writer(for: easel.id).scheduleSave(easel)
    }

    private func persistIndex() {
        indexWriter.scheduleSave(index)
    }

    private func writer(for id: UUID) -> AtomicJSONFileWriter<Easel> {
        if let existing = documentWriters[id] { return existing }
        let created = AtomicJSONFileWriter<Easel>(fileURL: documentURL(for: id))
        documentWriters[id] = created
        return created
    }

    private func documentURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func imagesDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-Images", isDirectory: true)
    }
}
