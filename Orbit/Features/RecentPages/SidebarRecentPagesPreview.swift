import Foundation

// MARK: - Controller

@MainActor
@Observable
public final class SidebarRecentPagesPreviewController {

    // One controller per row, not a shared singleton: two rows can be hovered in quick succession
    // and each needs its own in-flight generation.
    public init() {}

    public private(set) var data: RecentPagesData?

    public var hoverDelayNanoseconds: UInt64 = 450_000_000

    public var dismissGraceNanoseconds: UInt64 = 250_000_000

    // Bumped on every call that changes what should be shown, so a load already in flight when the
    // pointer leaves can never land its result, even if its Task doesn't observe cancellation promptly.
    private var generation = 0
    private var runningTask: Task<Void, Never>?

    // Pinned and Favorited rows only; .today and Folder rows are not this card's business.
    public static func service(for tab: Tab) -> RecentPagesService? {
        guard tab.section == .pinned || tab.section == .favorite else { return nil }
        return RecentPagesService.matching(tab.url)
    }

    public func hoverChanged(
        hovering: Bool,
        tab: Tab,
        isSpacePersistent: Bool,
        source: RecentPagesSource,
        query: RecentPagesQuery = RecentPagesQuery()
    ) {
        guard hovering,
              isSpacePersistent,
              let service = Self.service(for: tab)
        else {
            scheduleDismiss()
            return
        }

        if let data, data.service == service {
            cancelInFlight()
            return
        }

        cancelInFlight()
        let thisGeneration = generation
        let delay = hoverDelayNanoseconds
        runningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.load(service: service, generation: thisGeneration, source: source, query: query)
        }
    }

    public func dismiss() {
        cancelInFlight()
        data = nil
    }

    // MARK: Private

    private func scheduleDismiss() {
        guard data != nil else {
            dismiss()
            return
        }
        cancelInFlight()
        let thisGeneration = generation
        let grace = dismissGraceNanoseconds
        runningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: grace)
            guard !Task.isCancelled else { return }
            await self?.dismissIfUnclaimed(generation: thisGeneration)
        }
    }

    private func dismissIfUnclaimed(generation expectedGeneration: Int) async {
        guard expectedGeneration == generation else { return }
        data = nil
    }

    private func load(
        service: RecentPagesService,
        generation expectedGeneration: Int,
        source: RecentPagesSource,
        query: RecentPagesQuery
    ) async {
        let entries = await source.historyEntries(service, query)
        guard !Task.isCancelled, expectedGeneration == generation else { return }
        data = RecentPagesCard.build(service: service, entries: entries, query: query)
    }

    private func cancelInFlight() {
        generation += 1
        runningTask?.cancel()
        runningTask = nil
    }
}

// MARK: - The "+" button's destination

public enum RecentPagesNewDocument {

    // nil means no "+" on the card: Confluence has no site-wide create URL without a space key.
    public static func url(for service: RecentPagesService) -> URL? {
        switch service {
        case .notion: return URL(string: "https://www.notion.so/new") // 307s to app.notion.com/new; kept as the stable redirector
        case .figma: return URL(string: "https://www.figma.com/new")
        case .linear: return URL(string: "https://linear.app/new")
        case .confluence: return nil
        }
    }
}
