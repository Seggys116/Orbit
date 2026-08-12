import Foundation

nonisolated struct SiteSearchDocument: Codable, Equatable, Sendable {
    var engines: [SiteSearchEngine]
    var triggerKey: SiteSearchTriggerKey
    // hasSeededDefaults, not "the list is empty": seeding on an empty list would silently resurrect the three defaults after a user deleted them all.
    var hasSeededDefaults: Bool

    init(engines: [SiteSearchEngine] = [], triggerKey: SiteSearchTriggerKey = .tab, hasSeededDefaults: Bool = true) {
        self.engines = engines
        self.triggerKey = triggerKey
        self.hasSeededDefaults = hasSeededDefaults
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.engines = try container.decodeIfPresent([SiteSearchEngine].self, forKey: .engines) ?? []
        self.triggerKey = try container.decodeIfPresent(SiteSearchTriggerKey.self, forKey: .triggerKey) ?? .tab
        self.hasSeededDefaults = try container.decodeIfPresent(Bool.self, forKey: .hasSeededDefaults) ?? true
    }
}

@MainActor
@Observable
final class SiteSearchStore {

    private(set) var engines: [SiteSearchEngine] = []
    private(set) var triggerKey: SiteSearchTriggerKey = .tab

    private var hasSeededDefaults = false
    private let writer: AtomicJSONFileWriter<SiteSearchDocument>

    init(fileURL: URL = SiteSearchStore.defaultFileURL) {
        self.writer = AtomicJSONFileWriter(fileURL: fileURL)
        let loaded = writer.loadNow(default: SiteSearchDocument(engines: [], triggerKey: .tab, hasSeededDefaults: false))
        self.engines = loaded.engines
        self.triggerKey = loaded.triggerKey
        self.hasSeededDefaults = loaded.hasSeededDefaults
        if !hasSeededDefaults {
            self.engines = SiteSearchEngine.sourcedDefaults()
            self.hasSeededDefaults = true
            persist()
        }
    }

    nonisolated static var defaultFileURL: URL { OrbitDataRoot.processDefault.siteSearchFile }

    // MARK: - Reads

    func state(active: SiteSearchEngine? = nil) -> SiteSearchState {
        SiteSearchState(engines: engines, active: active, triggerKey: triggerKey)
    }

    func engine(_ id: UUID) -> SiteSearchEngine? {
        engines.first { $0.id == id }
    }

    // MARK: - CRUD

    @discardableResult
    func createEngine(name: String, shortcut: String, urlTemplate: String) -> SiteSearchEngine {
        let engine = SiteSearchEngine(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            shortcut: shortcut.trimmingCharacters(in: .whitespacesAndNewlines),
            urlTemplate: urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        engines.append(engine)
        persist()
        return engine
    }

    func updateEngine(_ id: UUID, _ transform: (inout SiteSearchEngine) -> Void) {
        guard let index = engines.firstIndex(where: { $0.id == id }) else { return }
        transform(&engines[index])
        engines[index].name = engines[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        engines[index].shortcut = engines[index].shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        engines[index].urlTemplate = engines[index].urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func deleteEngine(_ id: UUID) {
        engines.removeAll { $0.id == id }
        persist()
    }

    func deleteAllEngines() {
        guard !engines.isEmpty else { return }
        for id in engines.map(\.id) { deleteEngine(id) }
    }

    func setTriggerKey(_ key: SiteSearchTriggerKey) {
        guard key != triggerKey else { return }
        triggerKey = key
        persist()
    }

    // MARK: - Persistence

    func saveNow() throws {
        try writer.saveNow(document)
    }

    private var document: SiteSearchDocument {
        SiteSearchDocument(engines: engines, triggerKey: triggerKey, hasSeededDefaults: hasSeededDefaults)
    }

    private func persist() {
        writer.scheduleSave(document)
    }
}
