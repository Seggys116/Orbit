import Foundation

actor SearchSuggestionsClient {
    static let shared = SearchSuggestionsClient()

    private let session: URLSession
    private let debounceNanoseconds: UInt64
    private let requestTimeout: TimeInterval
    private var activeTask: Task<[String], Never>?

    init(session: URLSession = .shared, debounceNanoseconds: UInt64 = 160_000_000, requestTimeout: TimeInterval = 3.5) {
        self.session = session
        self.debounceNanoseconds = debounceNanoseconds
        self.requestTimeout = requestTimeout
    }

    func suggestions(for query: String, engine: SearchEngine = .fallback) async -> [String] {
        activeTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let task = Task<[String], Never> {
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return [] }
            guard let url = engine.suggestionsURL(for: trimmed) else {
                return []
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = requestTimeout
            do {
                let (data, _) = try await session.data(for: request)
                guard !Task.isCancelled else { return [] }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                      json.count > 1, let suggestions = json[1] as? [String] else {
                    return []
                }
                return suggestions
            } catch {
                return []
            }
        }
        activeTask = task
        return await task.value
    }
}
