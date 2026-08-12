import CoreGraphics
import Foundation

@MainActor
@Observable
final class LinkPreviewController {

    static let shared = LinkPreviewController()

    /// Not `private` — a test constructs its own controller rather than sharing history.
    init() {}

    enum Phase: Equatable {
        case idle
        case loading
        case ready(AssistRuntime.LinkPreview)
        case failed(String)
        /// No page fetched, no model called, works with no Assist provider configured — kept out of `.ready`.
        case recentPages(RecentPagesData)
    }

    private(set) var phase: Phase = .idle
    private(set) var anchor: CGPoint = .zero

    /// `nil` exactly when `phase == .idle`.
    private(set) var previewedURL: URL?

    /// `var`, not `let`, so a test can set it to 0 to skip the debounce wait.
    var debounceNanoseconds: UInt64 = 250_000_000

    /// Incremented on every call that changes what should be shown; `run(...)` checks it before writing `phase`, so a stale in-flight result can never land.
    private var generation = 0
    private var runningTask: Task<Void, Never>?

    func hoverChanged(
        url: URL?,
        shiftDown: Bool,
        at point: CGPoint,
        isSessionPersistent: Bool,
        fetch: @escaping @Sendable (URL) async throws -> LinkPreviewFetcher.LinkPreviewPageData,
        sink: AssistSink?,
        runtime: AssistRuntime = .shared,
        recentPages: RecentPagesSource = .unavailable,
        recentPagesQuery: RecentPagesQuery = RecentPagesQuery()
    ) {
        anchor = point

        guard AssistSettings.isFiveSecondPreviewsEnabled,
              isSessionPersistent,
              shiftDown,
              let url,
              url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
        else {
            cancelInFlight()
            previewedURL = nil
            phase = .idle
            return
        }

        if url == previewedURL {
            switch phase {
            case .loading, .ready, .recentPages:
                return
            case .idle, .failed:
                break
            }
        }

        cancelInFlight()
        previewedURL = url
        phase = .loading

        if let service = RecentPagesService.matching(url) {
            generation += 1
            let thisGeneration = generation
            let waitNanoseconds = debounceNanoseconds
            runningTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: waitNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.runRecentPages(
                    service: service,
                    generation: thisGeneration,
                    source: recentPages,
                    query: recentPagesQuery
                )
            }
            return
        }

        guard let sink else {
            phase = .failed(AssistError.notConfigured.localizedDescription)
            return
        }

        generation += 1
        let thisGeneration = generation
        let waitNanoseconds = debounceNanoseconds
        runningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: waitNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.run(url: url, generation: thisGeneration, fetch: fetch, sink: sink, runtime: runtime)
        }
    }

    func dismiss() {
        cancelInFlight()
        previewedURL = nil
        phase = .idle
    }

    // MARK: - Private

    private func run(
        url: URL,
        generation expectedGeneration: Int,
        fetch: @escaping @Sendable (URL) async throws -> LinkPreviewFetcher.LinkPreviewPageData,
        sink: AssistSink,
        runtime: AssistRuntime
    ) async {
        do {
            let pageData = try await fetch(url)
            guard !Task.isCancelled, expectedGeneration == generation else { return }
            let preview = try await runtime.linkPreview(sourceURL: url, pageData: pageData, sink: sink)
            guard !Task.isCancelled, expectedGeneration == generation else { return }
            phase = .ready(preview)
        } catch {
            guard !Task.isCancelled, expectedGeneration == generation else { return }
            if let assistError = error as? AssistError {
                phase = .failed(assistError.localizedDescription)
            } else if let fetchError = error as? LinkPreviewFetchError {
                phase = .failed(fetchError.localizedDescription)
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Reached by a plain `await` only — no `Task(priority:)`, no bare `nonisolated async` hop; see `PriorityInversionPrimitiveGuardTests`.
    private func runRecentPages(
        service: RecentPagesService,
        generation expectedGeneration: Int,
        source: RecentPagesSource,
        query: RecentPagesQuery
    ) async {
        let entries = await source.historyEntries(service, query)
        guard !Task.isCancelled, expectedGeneration == generation else { return }

        guard let data = RecentPagesCard.build(service: service, entries: entries, query: query) else {
            previewedURL = nil
            phase = .idle
            return
        }
        phase = .recentPages(data)
    }

    private func cancelInFlight() {
        generation += 1
        runningTask?.cancel()
        runningTask = nil
    }
}
