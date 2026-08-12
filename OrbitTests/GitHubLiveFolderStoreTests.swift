// A folder that looks live and never updates is worse than no folder. No test here
// touches the network; everything runs through the GitHubLiveFolderSource seam.

import Foundation
import XCTest

// MARK: - Doubles

final class GitHubSourceRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var storedLogin: String?
    private var createdReply: Result<[GitHubPullRequest], GitHubLiveFolderError> = .success([])
    private var reviewReply: Result<[GitHubPullRequest], GitHubLiveFolderError> = .success([])
    private var queries: [String] = []
    private var loginCalls = 0

    func setLogin(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        storedLogin = value
    }

    func setCreatedByMeReply(_ reply: Result<[GitHubPullRequest], GitHubLiveFolderError>) {
        lock.lock(); defer { lock.unlock() }
        createdReply = reply
    }

    func setReviewRequestsReply(_ reply: Result<[GitHubPullRequest], GitHubLiveFolderError>) {
        lock.lock(); defer { lock.unlock() }
        reviewReply = reply
    }

    var recordedQueries: [String] {
        lock.lock(); defer { lock.unlock() }
        return queries
    }

    var recordedLoginCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return loginCalls
    }

    var totalCalls: Int { recordedQueries.count + recordedLoginCalls }

    var source: GitHubLiveFolderSource {
        GitHubLiveFolderSource(
            search: { [self] query in
                lock.lock()
                queries.append(query)
                let reply = query.contains("review-requested:") ? reviewReply : createdReply
                lock.unlock()
                return reply
            },
            currentLogin: { [self] in
                lock.lock()
                loginCalls += 1
                let value = storedLogin
                lock.unlock()
                return value
            }
        )
    }
}

@MainActor
final class RecordedGitHubEngineSession: EngineSession {

    let identifier: String
    let isPersistent: Bool
    var storageURL: URL? { nil }

    init(identifier: String = "test", isPersistent: Bool) {
        self.identifier = identifier
        self.isPersistent = isPersistent
    }

    func setUserAgent(_ userAgent: String) {}
    func cookies(for url: URL) async -> [HTTPCookie] { [] }
    func setCookies(_ cookies: [EngineCookie]) async -> Int { 0 }
    func deleteCookies(for url: URL) async {}
    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting { .unsupported }
    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL) {}
}

// MARK: - Fixtures

enum GitHubLiveFolderFixture {

    static func pullRequest(
        id: String,
        number: Int = 1,
        title: String = "A pull request",
        owner: String = "PebbleBird-co",
        repository: String = "FinalFinal-Chinese",
        author: String = "zak",
        createdAt: Date? = Date(timeIntervalSince1970: 1_770_000_000)
    ) -> GitHubPullRequest {
        GitHubPullRequest(
            id: id,
            number: number,
            title: title,
            ownerLogin: owner,
            repositoryName: repository,
            authorLogin: author,
            isDraft: false,
            isMerged: false,
            state: "open",
            createdAt: createdAt,
            url: URL(string: "https://github.com/\(owner)/\(repository)/pull/\(number)")!
        )
    }
}

// MARK: - The gate, and what each failure costs

@MainActor
final class GitHubLiveFolderStoreTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeStore(_ recorder: GitHubSourceRecorder, now: Date? = nil) -> GitHubLiveFolderStore {
        let instant = now ?? fixedNow
        let store = GitHubLiveFolderStore(source: recorder.source, now: { instant })
        store.config = GitHubLiveFolderConfig()
        return store
    }

    // MARK: 1. Signed out

    func test_signedOut_leavesNoLiveDataAndNoContents() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin(nil)
        let store = makeStore(recorder)

        await store.refresh()

        XCTAssertFalse(store.hasLiveData, "Signed out must render nothing at all — see this file's header.")
        XCTAssertTrue(store.createdByMe.isEmpty)
        XCTAssertTrue(store.reviewRequests.isEmpty)
        XCTAssertNil(store.lastSuccessfulFetch)
        XCTAssertNil(store.login)
        XCTAssertEqual(store.status, .failed(.signedOut, lastSuccess: nil))
        XCTAssertTrue(recorder.recordedQueries.isEmpty, "There is nobody to search for, so no search may be spent.")
    }

    func test_signingOutAfterASuccess_dropsTheContentsRatherThanGoingStale() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1")]))
        let store = makeStore(recorder)

        await store.refresh()
        XCTAssertTrue(store.hasLiveData, "precondition: the fixture must have produced live data")

        recorder.setLogin(nil)
        await store.refresh()

        XCTAssertFalse(store.hasLiveData)
        XCTAssertTrue(store.createdByMe.isEmpty, "Signed-out is the one case where prior contents are dropped.")
        XCTAssertNil(store.lastSuccessfulFetch, "A stale `Last fetch:` under a signed-out folder would be a lie.")
    }

    // MARK: 2. Success

    func test_successfulFetch_populatesTheContentsAndOpensTheGate() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1", number: 6)]))
        recorder.setReviewRequestsReply(.success([GitHubLiveFolderFixture.pullRequest(id: "2", number: 9)]))
        let store = makeStore(recorder)

        await store.refresh()

        XCTAssertEqual(store.login, "zak")
        XCTAssertEqual(store.createdByMe.map(\.id), ["1"])
        XCTAssertEqual(store.reviewRequests.map(\.id), ["2"])
        XCTAssertEqual(store.lastSuccessfulFetch, fixedNow)
        XCTAssertEqual(store.status, .loaded(fixedNow))
        XCTAssertTrue(store.hasLiveData)
        XCTAssertEqual(
            recorder.recordedQueries,
            [
                "is:pr is:open author:zak sort:updated",
                "is:pr is:open review-requested:zak sort:updated",
            ],
            "Both searches run on every refresh, whatever the display filters say."
        )
    }

    func test_aSuccessfulButEmptyFetch_stillRendersNothing() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        let store = makeStore(recorder)

        await store.refresh()

        XCTAssertNotNil(store.lastSuccessfulFetch, "the fetch itself succeeded")
        XCTAssertFalse(store.hasLiveData, "…but there is nothing to draw, so there must be no folder")
    }

    func test_contentsWithNoSuccessfulFetchBehindThemAreNotLiveData() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1")]))
        let store = makeStore(recorder)
        await store.refresh()
        XCTAssertTrue(store.hasLiveData, "precondition")

        store.lastSuccessfulFetch = nil

        XCTAssertFalse(
            store.visiblePullRequests.isEmpty,
            "the contents are still there — it is the successful-fetch instant that is missing"
        )
        XCTAssertFalse(store.hasLiveData, "…and without one there is nothing truthful to draw")
    }

    // MARK: 3. Non-signed-out failure retains everything

    func test_aNetworkFailureAfterASuccess_retainsTheContentsAndTheOriginalFetchTime() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1")]))
        let store = makeStore(recorder)

        await store.refresh()
        let originalFetch = store.lastSuccessfulFetch
        XCTAssertNotNil(originalFetch)

        recorder.setCreatedByMeReply(.failure(.network("The Internet connection appears to be offline.")))
        await store.refresh()

        XCTAssertEqual(
            store.createdByMe.map(\.id), ["1"],
            """
            A network failure must RETAIN the previous contents. Dropping them turns a temporary \
            outage into an empty folder, which reads as "you have no pull requests".
            """
        )
        XCTAssertEqual(
            store.lastSuccessfulFetch, originalFetch,
            "`Last fetch:` must keep showing when the data on screen is actually from."
        )
        XCTAssertEqual(
            store.status,
            .failed(.network("The Internet connection appears to be offline."), lastSuccess: originalFetch)
        )
        XCTAssertTrue(store.hasLiveData, "The retained contents are still real contents, so the folder stays.")
    }

    // MARK: 4. Rate limiting

    func test_aRateLimit_retainsTheContentsAndBacksTheIntervalOff() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1")]))
        let store = makeStore(recorder)

        await store.refresh()
        XCTAssertEqual(
            store.nextRefreshInterval, GitHubLiveFolderStore.refreshInterval,
            "precondition: an ordinary refresh polls on the ordinary interval"
        )

        recorder.setReviewRequestsReply(.failure(.rateLimited))
        await store.refresh()

        XCTAssertEqual(store.status, .failed(.rateLimited, lastSuccess: store.lastSuccessfulFetch))
        XCTAssertEqual(store.createdByMe.map(\.id), ["1"], "A rate limit must not empty the folder.")
        XCTAssertEqual(
            store.nextRefreshInterval, GitHubLiveFolderStore.rateLimitedRefreshInterval,
            "Retrying a rate limit on the same cadence earns a longer one — the loop must back off."
        )
        XCTAssertGreaterThan(
            GitHubLiveFolderStore.rateLimitedRefreshInterval, GitHubLiveFolderStore.refreshInterval,
            "the backoff has to actually be longer, or it is not a backoff"
        )
    }

    // MARK: 5. Incognito — nothing is transmitted

    func test_anEphemeralSpaceNeverReachesTheSource() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1")]))
        let store = makeStore(recorder)
        let session = RecordedGitHubEngineSession(isPersistent: true)

        store.activate(session: session, isEphemeral: true)
        await store.refresh()

        XCTAssertEqual(
            recorder.totalCalls, 0,
            """
            Something was transmitted on behalf of an ephemeral Space. Nothing — not even the \
            "who is signed in" call, which is itself a request — may leave an incognito context.
            """
        )
        XCTAssertFalse(store.isTransmissionPermitted)
        XCTAssertFalse(store.hasLiveData)
    }

    func test_aNonPersistentSessionNeverReachesTheSource() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        let store = makeStore(recorder)
        let session = RecordedGitHubEngineSession(isPersistent: false)

        store.activate(session: session, isEphemeral: false)
        await store.refresh()

        XCTAssertEqual(recorder.totalCalls, 0, "A non-persistent session is an in-memory, incognito one.")
        XCTAssertFalse(store.isTransmissionPermitted)
    }

    func test_activatingIntoAnIncognitoContext_dropsExistingContentsAndWillNotPoll() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1")]))
        let store = makeStore(recorder)

        await store.refresh()
        XCTAssertTrue(store.hasLiveData, "precondition")

        store.activate(session: RecordedGitHubEngineSession(isPersistent: false), isEphemeral: false)

        XCTAssertTrue(store.createdByMe.isEmpty)
        XCTAssertNil(store.lastSuccessfulFetch)
        store.start()
        XCTAssertFalse(store.isPolling, "An incognito store must not start a poll loop.")
    }

    func test_anOrdinarySpaceOnAPersistentSessionIsPermitted() {
        let store = makeStore(GitHubSourceRecorder())
        store.activate(session: RecordedGitHubEngineSession(isPersistent: true), isEphemeral: false)
        XCTAssertTrue(store.isTransmissionPermitted)
    }

    func test_activatingAPermittedSessionStartsThePollLoop() {
        let store = makeStore(GitHubSourceRecorder())
        XCTAssertFalse(store.isPolling, "precondition: a fresh store is not polling")

        store.activate(session: RecordedGitHubEngineSession(isPersistent: true), isEphemeral: false)

        XCTAssertTrue(
            store.isPolling,
            "Activation is the only place a real session exists, so it is the only place that can start the loop."
        )
    }

    func test_activatingAgainDoesNotRestartTheLoopOnEveryTabOpen() {
        let store = makeStore(GitHubSourceRecorder())
        store.activate(session: RecordedGitHubEngineSession(isPersistent: true), isEphemeral: false)
        let first = store.pollGeneration

        store.activate(session: RecordedGitHubEngineSession(isPersistent: true), isEphemeral: false)

        XCTAssertEqual(
            store.pollGeneration, first,
            "A second activation must reuse the running loop rather than tearing it down and refetching."
        )
    }

    func test_activatingWithAnEphemeralSpaceReadsTheMarkerOffTheSpace() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        let store = makeStore(recorder)

        var space = Space(name: "Incognito", profileID: UUID(), isEphemeral: true)
        space.githubLiveFolder = GitHubLiveFolderConfig(enabled: true, name: "PRs")

        store.activate(space: space, session: RecordedGitHubEngineSession(isPersistent: true))
        await store.refresh()

        XCTAssertEqual(store.config.displayName, "PRs", "the Space's configuration must be adopted")
        XCTAssertEqual(recorder.totalCalls, 0, "`Space.ephemeral` must block transmission on its own")
    }

    func test_deactivateForgetsEverything() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1")]))
        let store = makeStore(recorder)
        await store.refresh()

        store.deactivate()

        XCTAssertFalse(store.hasLiveData)
        XCTAssertTrue(store.createdByMe.isEmpty)
        XCTAssertNil(store.lastSuccessfulFetch)
        XCTAssertEqual(store.status, .idle)
    }

    // MARK: 6. Filters

    private func makeFilterStore() async -> GitHubLiveFolderStore {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([
            GitHubLiveFolderFixture.pullRequest(id: "mine", number: 1, createdAt: Date(timeIntervalSince1970: 200)),
        ]))
        recorder.setReviewRequestsReply(.success([
            GitHubLiveFolderFixture.pullRequest(id: "theirs", number: 2, createdAt: Date(timeIntervalSince1970: 100)),
        ]))
        let store = makeStore(recorder)
        await store.refresh()
        return store
    }

    func test_onlyCreatedByMe() async {
        let store = await makeFilterStore()
        store.config.includesCreatedByMe = true
        store.config.includesReviewRequests = false

        XCTAssertEqual(store.visiblePullRequests.map(\.id), ["mine"])
        XCTAssertTrue(store.hasLiveData)
    }

    func test_onlyReviewRequests() async {
        let store = await makeFilterStore()
        store.config.includesCreatedByMe = false
        store.config.includesReviewRequests = true

        XCTAssertEqual(store.visiblePullRequests.map(\.id), ["theirs"])
        XCTAssertTrue(store.hasLiveData)
    }

    func test_bothFilters() async {
        let store = await makeFilterStore()
        store.config.includesCreatedByMe = true
        store.config.includesReviewRequests = true

        XCTAssertEqual(store.visiblePullRequests.map(\.id), ["mine", "theirs"], "newest first")
        XCTAssertTrue(store.hasLiveData)
    }

    func test_neitherFilter_meansNoLiveData() async {
        let store = await makeFilterStore()
        store.config.includesCreatedByMe = false
        store.config.includesReviewRequests = false

        XCTAssertTrue(store.visiblePullRequests.isEmpty)
        XCTAssertFalse(store.hasLiveData)
        XCTAssertNotNil(store.lastSuccessfulFetch, "the fetch did succeed — it is the filters that leave nothing")
    }

    func test_aPullRequestInBothListsAppearsOnce() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        let both = GitHubLiveFolderFixture.pullRequest(id: "shared", number: 4)
        recorder.setCreatedByMeReply(.success([both]))
        recorder.setReviewRequestsReply(.success([both]))
        let store = makeStore(recorder)

        await store.refresh()

        XCTAssertEqual(store.visiblePullRequests.map(\.id), ["shared"])
    }

    func test_visiblePullRequestsSortNewestFirstAndUndatedLast() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([
            GitHubLiveFolderFixture.pullRequest(id: "old", number: 1, createdAt: Date(timeIntervalSince1970: 100)),
            GitHubLiveFolderFixture.pullRequest(id: "undated", number: 2, createdAt: nil),
            GitHubLiveFolderFixture.pullRequest(id: "new", number: 3, createdAt: Date(timeIntervalSince1970: 900)),
        ]))
        let store = makeStore(recorder)

        await store.refresh()

        XCTAssertEqual(store.visiblePullRequests.map(\.id), ["new", "old", "undated"])
    }

    // MARK: 7. Automatic activation

    func test_theFirstOwnPullRequestActivatesTheFolderExactlyOnce() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setCreatedByMeReply(.success([GitHubLiveFolderFixture.pullRequest(id: "1")]))
        let store = makeStore(recorder)

        var activations = 0
        store.onAutoActivate = { activations += 1 }
        XCTAssertFalse(store.config.isEnabled, "precondition: off until GitHub says otherwise")

        await store.refresh()
        XCTAssertTrue(store.config.isEnabled)
        XCTAssertEqual(activations, 1)

        await store.refresh()
        XCTAssertEqual(activations, 1, "The creation toast fires once, not on every poll.")
    }

    func test_reviewRequestsAloneDoNotAutoActivate() async {
        let recorder = GitHubSourceRecorder()
        recorder.setLogin("zak")
        recorder.setReviewRequestsReply(.success([GitHubLiveFolderFixture.pullRequest(id: "theirs")]))
        let store = makeStore(recorder)

        var activations = 0
        store.onAutoActivate = { activations += 1 }
        await store.refresh()

        XCTAssertEqual(activations, 0)
        XCTAssertFalse(store.config.isEnabled)
    }

    // MARK: Polling

    func test_startIsIdempotentAndStopEndsIt() {
        let store = makeStore(GitHubSourceRecorder())
        store.start()
        store.start()
        XCTAssertTrue(store.isPolling)
        store.stop()
        XCTAssertFalse(store.isPolling)
    }

    func test_thePollIntervalsAreSane() {
        XCTAssertEqual(GitHubLiveFolderStore.refreshInterval, 5 * 60)
        XCTAssertEqual(GitHubLiveFolderStore.rateLimitedRefreshInterval, 15 * 60)
    }
}
