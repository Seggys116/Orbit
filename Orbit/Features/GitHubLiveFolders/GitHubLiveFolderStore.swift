import Foundation
import Observation

@MainActor
@Observable
public final class GitHubLiveFolderStore {

    public static let shared = GitHubLiveFolderStore(source: .unconfigured)

    public init(source: GitHubLiveFolderSource, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.now = now
    }

    // MARK: - State

    public private(set) var status: GitHubLiveFolderStatus = .idle

    public private(set) var createdByMe: [GitHubPullRequest] = []

    public private(set) var reviewRequests: [GitHubPullRequest] = []

    public private(set) var login: String?

    public var lastSuccessfulFetch: Date?

    public var config: GitHubLiveFolderConfig = GitHubLiveFolderConfig()

    public private(set) var isTransmissionPermitted: Bool = true

    public var onAutoActivate: (@MainActor () -> Void)?

    private var source: GitHubLiveFolderSource
    private let now: () -> Date
    private var pollTask: Task<Void, Never>?
    private var hasAutoActivated = false

    // MARK: - The gate

    public var hasLiveData: Bool {
        isTransmissionPermitted && lastSuccessfulFetch != nil && !visiblePullRequests.isEmpty
    }

    // The fetched PRs are global but filters are per-Space; hasFetchedContents ignores filters so
    // one Space with both filters off can't hide every other Space's folder. The sidebar applies
    // the owning Space's own filters via GitHubLiveFolderVisibility.shouldRender.
    public var hasFetchedContents: Bool {
        isTransmissionPermitted
            && lastSuccessfulFetch != nil
            && !(createdByMe.isEmpty && reviewRequests.isEmpty)
    }

    public var visiblePullRequests: [GitHubPullRequest] {
        var seen: Set<String> = []
        var merged: [GitHubPullRequest] = []
        if config.includesCreatedByMe {
            for pullRequest in createdByMe where seen.insert(pullRequest.id).inserted {
                merged.append(pullRequest)
            }
        }
        if config.includesReviewRequests {
            for pullRequest in reviewRequests where seen.insert(pullRequest.id).inserted {
                merged.append(pullRequest)
            }
        }
        return merged.sorted(by: Self.isOrderedBefore)
    }

    nonisolated static func isOrderedBefore(_ lhs: GitHubPullRequest, _ rhs: GitHubPullRequest) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?):
            if left != right { return left > right }
            return lhs.id < rhs.id
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            return lhs.id < rhs.id
        }
    }

    // MARK: - Pointing the store at a session

    // nonisolated(unsafe): default-argument expressions evaluate in a nonisolated context; written
    // once at launch before any window exists, read from the main actor thereafter.
    nonisolated(unsafe) public static var browserUserAgent: String = ""

    public func activate(
        session: any EngineSession,
        isEphemeral: Bool,
        userAgent: String = GitHubLiveFolderStore.browserUserAgent,
        urlSession: URLSession = .shared
    ) {
        isTransmissionPermitted = !isEphemeral && session.isPersistent
        guard isTransmissionPermitted else {
            stop()
            clearContents()
            status = .idle
            return
        }
        source = .live(session: session, userAgent: userAgent, urlSession: urlSession)
        // Guarded on isPolling rather than restarted unconditionally: activate() runs on every tab
        // open, and start() refreshes immediately, so an unconditional restart would fire a request
        // per new tab. A swapped session needs no restart — the loop reads source fresh each tick.
        if !isPolling { start() }
    }

    public func activate(space: Space, session: any EngineSession, userAgent: String = GitHubLiveFolderStore.browserUserAgent) {
        config = space.githubLiveFolder ?? GitHubLiveFolderConfig()
        activate(session: session, isEphemeral: space.isEphemeral, userAgent: userAgent)
    }

    public func deactivate() {
        stop()
        source = .unconfigured
        isTransmissionPermitted = false
        clearContents()
        status = .idle
    }

    private func clearContents() {
        createdByMe = []
        reviewRequests = []
        login = nil
        lastSuccessfulFetch = nil
    }

    // MARK: - Fetching

    public func refresh() async {
        guard isTransmissionPermitted else { return }

        status = .loading

        guard let resolvedLogin = await source.currentLogin(), !resolvedLogin.isEmpty else {
            clearContents()
            status = .failed(.signedOut, lastSuccess: nil)
            return
        }
        login = resolvedLogin

        let created = await source.search(GitHubLiveFolderQuery.createdByMe(login: resolvedLogin))
        let review = await source.search(GitHubLiveFolderQuery.reviewRequested(login: resolvedLogin))

        if case let .failure(error) = created {
            apply(error)
            return
        }
        if case let .failure(error) = review {
            apply(error)
            return
        }
        guard case let .success(createdRows) = created, case let .success(reviewRows) = review else { return }

        createdByMe = createdRows
        reviewRequests = reviewRows
        let instant = now()
        lastSuccessfulFetch = instant
        status = .loaded(instant)
        autoActivateIfNeeded()
    }

    // signedOut drops contents; every other failure keeps the previous contents and fetch time.
    private func apply(_ error: GitHubLiveFolderError) {
        if error == .signedOut {
            clearContents()
            status = .failed(.signedOut, lastSuccess: nil)
            return
        }
        status = .failed(error, lastSuccess: lastSuccessfulFetch)
    }

    private func autoActivateIfNeeded() {
        guard !hasAutoActivated, !createdByMe.isEmpty else { return }
        hasAutoActivated = true
        config.isEnabled = true
        onAutoActivate?()
    }

    // MARK: - Polling

    public static let refreshInterval: TimeInterval = 5 * 60

    public static let rateLimitedRefreshInterval: TimeInterval = 15 * 60

    public var nextRefreshInterval: TimeInterval {
        if case .failed(.rateLimited, _) = status { return Self.rateLimitedRefreshInterval }
        return Self.refreshInterval
    }

    public private(set) var pollGeneration = 0

    public func start() {
        guard isTransmissionPermitted else { return }
        stop()
        pollGeneration += 1
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(self.nextRefreshInterval))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public var isPolling: Bool { pollTask != nil }
}
