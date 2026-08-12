import Foundation

@MainActor
final class DocumentEditorFlushRegistry {

    static let shared = DocumentEditorFlushRegistry()

    private var flushes: [UUID: () -> Void] = [:]

    private init() {}

    // Callers must deregister on disappear — the closure captures view
    // state, so leaving it behind leaks and lets a torn-down editor write at quit.
    func register(_ token: UUID, flush: @escaping () -> Void) {
        flushes[token] = flush
    }

    func deregister(_ token: UUID) {
        flushes.removeValue(forKey: token)
    }

    func flushAll() {
        for flush in flushes.values {
            flush()
        }
    }

    var registeredCount: Int { flushes.count }
}
