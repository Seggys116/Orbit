import Foundation

@MainActor
@Observable
final class TidyDownloadsCoordinator {

    static let shared = TidyDownloadsCoordinator()

    init() {}

    struct Announcement: Identifiable, Equatable {
        var id: UUID
        var newFileName: String
        var originalFileName: String
    }

    private(set) var announcement: Announcement?

    /// Downloads already considered, so a stream of `.completed` callbacks for one download cannot start several requests.
    private var handled: Set<UUID> = []

    func reset() {
        announcement = nil
        handled.removeAll()
    }

    // MARK: - Decisions (pure, testable without a provider)

    func shouldConsider(downloadID id: UUID) -> Bool { !handled.contains(id) }

    // MARK: - The core, sink-taking path

    @discardableResult
    func tidy(
        downloadID: UUID,
        originalFileName: String,
        sourceURL: URL,
        pageTitle: String?,
        sink: AssistSink,
        runtime: AssistRuntime = AssistRuntime.shared,
        rename: (String) -> URL?
    ) async -> Announcement? {
        handled.insert(downloadID)

        let suggestion = try? await runtime.tidiedDownloadName(
            originalFileName: originalFileName,
            sourceURL: sourceURL,
            pageTitle: pageTitle,
            sink: sink
        )
        guard let candidate = suggestion ?? nil, candidate != originalFileName else { return nil }
        guard let moved = rename(candidate) else { return nil }

        let result = Announcement(
            id: downloadID,
            newFileName: moved.lastPathComponent,
            originalFileName: originalFileName
        )
        announcement = result
        return result
    }

    /// Clears the card whether or not the move succeeded — a failed undo must not offer to undo again.
    func undo(rename: (String) -> URL?) {
        guard let announcement else { return }
        _ = rename(announcement.originalFileName)
        self.announcement = nil
    }

    func dismissAnnouncement() { announcement = nil }

    // MARK: - Production entry points

    func start(env: AppEnvironment) {
        guard !AssistSettings.isTidyDownloadsEnabled else { return }
        announcement = nil
    }

    func downloadDidComplete(id: UUID, pageTitle: String?, env: AppEnvironment) {
        guard AssistSettings.isTidyDownloadsEnabled else { return }
        guard shouldConsider(downloadID: id) else { return }
        guard let item = env.downloadStore.downloads.first(where: { $0.id == id }) else { return }
        guard let sink = AssistRuntime.providerOnlySink() else { return }

        let originalName = item.destinationURL.lastPathComponent
        let sourceURL = item.sourceURL
        Task { [weak env] in
            await tidy(
                downloadID: id,
                originalFileName: originalName,
                sourceURL: sourceURL,
                pageTitle: pageTitle,
                sink: sink
            ) { newName in
                env?.downloadStore.renameFile(id: id, to: newName)
            }
        }
    }

    func undoAnnouncedRename(env: AppEnvironment) {
        guard let id = announcement?.id else { return }
        undo { newName in env.downloadStore.renameFile(id: id, to: newName) }
    }
}
