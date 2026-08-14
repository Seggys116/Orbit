import Foundation

// Must stay @MainActor, not a plain actor: some ModelTypes Codable conformances are main-actor-isolated under this project's build settings.
@MainActor
final class AtomicJSONFileWriter<Value: Codable & Sendable> {

    private let fileURL: URL
    private let debounceDuration: Duration
    private let maximumSaveDelay: Duration
    private var pendingValue: Value?
    private var pendingDeadline: ContinuousClock.Instant?
    private var debounceTask: Task<Void, Never>?

    init(fileURL: URL, debounceDuration: Duration = .milliseconds(400), maximumSaveDelay: Duration = .seconds(5)) {
        self.fileURL = fileURL
        self.debounceDuration = debounceDuration
        self.maximumSaveDelay = maximumSaveDelay
    }

    // Xcode 26.6's EarlyPerfInliner crashes on the synthesised destructor of a
    // generic class at a 14.6 deployment target. An explicit one steps around it.
    deinit {}

    func loadNow(default defaultValue: Value) -> Value {
        guard let data = try? Data(contentsOf: fileURL) else { return defaultValue }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Value.self, from: data)) ?? defaultValue
    }

    /// Capped: a source that mutates faster than the debounce (download progress, say) would otherwise starve the trailing timer and never reach disk at all.
    func scheduleSave(_ value: Value) {
        pendingValue = value
        let now = ContinuousClock.now
        let deadline = pendingDeadline ?? now.advanced(by: maximumSaveDelay)
        pendingDeadline = deadline
        let duration = min(debounceDuration, max(.zero, now.duration(to: deadline)))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Discards any pending debounced write; this supersedes it.
    func saveNow(_ value: Value) throws {
        debounceTask?.cancel()
        debounceTask = nil
        pendingValue = nil
        pendingDeadline = nil
        try Self.write(value, to: fileURL)
    }

    private func flush() {
        guard let value = pendingValue else { return }
        pendingValue = nil
        pendingDeadline = nil
        try? Self.write(value, to: fileURL)
    }

    private static func write(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: tempURL, options: .atomic)

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }
}
