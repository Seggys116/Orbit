import XCTest
import SwiftUI
@testable import Orbit

// MARK: - A recorded source

private final class ScriptedGitHubSource: @unchecked Sendable {
    private let lock = NSLock()
    private var _login: String?
    private var _created: Result<[GitHubPullRequest], GitHubLiveFolderError>
    private var _review: Result<[GitHubPullRequest], GitHubLiveFolderError>
    private var _queries: [String] = []

    init(
        login: String? = "octocat",
        created: Result<[GitHubPullRequest], GitHubLiveFolderError> = .success([]),
        review: Result<[GitHubPullRequest], GitHubLiveFolderError> = .success([])
    ) {
        _login = login
        _created = created
        _review = review
    }

    var login: String? {
        get { lock.withLock { _login } }
        set { lock.withLock { _login = newValue } }
    }

    var created: Result<[GitHubPullRequest], GitHubLiveFolderError> {
        get { lock.withLock { _created } }
        set { lock.withLock { _created = newValue } }
    }

    var review: Result<[GitHubPullRequest], GitHubLiveFolderError> {
        get { lock.withLock { _review } }
        set { lock.withLock { _review = newValue } }
    }

    var queries: [String] { lock.withLock { _queries } }

    var source: GitHubLiveFolderSource {
        GitHubLiveFolderSource(
            search: { [self] query in
                lock.withLock { _queries.append(query) }
                return query.contains("review-requested:") ? review : created
            },
            currentLogin: { [self] in login }
        )
    }
}

@MainActor
final class GitHubLiveFolderSidebarTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        env.state = OrbitState()
    }

    // MARK: - Fixtures

    private func pullRequest(
        id: String = "4205067172",
        number: Int = 6,
        title: String = "Bump react, react-dom",
        secondsAgo: TimeInterval = 60
    ) -> GitHubPullRequest {
        GitHubPullRequest(
            id: id,
            number: number,
            title: title,
            ownerLogin: "PebbleBird-co",
            repositoryName: "FinalFinal-Chinese",
            authorLogin: "octocat",
            isDraft: false,
            isMerged: false,
            state: "open",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - secondsAgo),
            url: URL(string: "https://github.com/PebbleBird-co/FinalFinal-Chinese/pull/\(number)")!
        )
    }

    private func config(
        enabled: Bool = true,
        createdByMe: Bool? = nil,
        reviewRequests: Bool? = nil,
        expanded: Bool? = false
    ) -> GitHubLiveFolderConfig {
        GitHubLiveFolderConfig(
            enabled: enabled,
            isExpanded: expanded,
            showsCreatedByMe: createdByMe,
            showsReviewRequests: reviewRequests
        )
    }

    private func loadedStore(
        created: [GitHubPullRequest],
        review: [GitHubPullRequest] = [],
        login: String? = "octocat",
        config: GitHubLiveFolderConfig
    ) async -> (store: GitHubLiveFolderStore, source: ScriptedGitHubSource) {
        let scripted = ScriptedGitHubSource(login: login, created: .success(created), review: .success(review))
        let store = GitHubLiveFolderStore(source: scripted.source)
        store.config = config
        await store.refresh()
        return (store, scripted)
    }

    @discardableResult
    private func installSpace(config: GitHubLiveFolderConfig?) -> Space {
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        var space = Space(name: "Work", profileID: profile.id)
        space.githubLiveFolder = config
        state.profiles = [profile]
        state.spaces = [space]
        state.activeSpaceID = space.id
        env.state = state
        return space
    }

    // MARK: - Automatic Activation actually reaches the model

    func test_automaticActivation_switchesTheFolderOnForTheSpace() {
        let space = installSpace(config: nil)
        XCTAssertNil(space.githubLiveFolder, "precondition: the Space starts with no live folder at all")

        env.autoActivateGitHubLiveFolder(in: space.id)

        XCTAssertEqual(
            env.space(space.id)?.githubLiveFolder?.isEnabled, true,
            "Automatic activation has to reach Space.githubLiveFolder, which is the only part of this that persists."
        )
        XCTAssertTrue(
            GitHubLiveFolderStore.shared.config.isEnabled,
            "The store's mirror is what its own filters read, so both copies must move together."
        )
    }

    func test_automaticActivation_preservesANameAndIconTheUserAlreadyChose() {
        var chosen = GitHubLiveFolderConfig()
        chosen.enabled = false
        chosen.name = "My PRs"
        chosen.icon = "star.fill"
        let space = installSpace(config: chosen)

        env.autoActivateGitHubLiveFolder(in: space.id)

        let stored = env.space(space.id)?.githubLiveFolder
        XCTAssertEqual(stored?.isEnabled, true)
        XCTAssertEqual(stored?.name, "My PRs", "A name the user chose is theirs.")
        XCTAssertEqual(stored?.icon, "star.fill", "An icon the user chose is theirs.")
    }

    // MARK: - The gate: every way it must be false

    func test_shouldRender_isFalseWithNoConfigurationAtAll() async {
        let (store, _) = await loadedStore(created: [pullRequest()], config: config())
        XCTAssertFalse(GitHubLiveFolderVisibility.shouldRender(config: nil, store: store))
    }

    func test_shouldRender_isFalseWhenTheSpaceHasItSwitchedOff() async {
        let disabled = config(enabled: false)
        let (store, _) = await loadedStore(created: [pullRequest()], config: disabled)
        XCTAssertTrue(store.hasLiveData, "Precondition: the store itself has data, so only `enabled` can be closing the gate.")
        XCTAssertFalse(GitHubLiveFolderVisibility.shouldRender(config: disabled, store: store))
    }

    func test_shouldRender_isFalseWhenTheStoreWasNeverActivatedOrFetched() {
        let store = GitHubLiveFolderStore(source: .unconfigured)
        store.config = config()
        XCTAssertNil(store.lastSuccessfulFetch, "Precondition: nothing has ever been fetched.")
        XCTAssertFalse(GitHubLiveFolderVisibility.shouldRender(config: config(), store: store))
    }

    func test_shouldRender_isFalseWhenSignedOut() async {
        let (store, _) = await loadedStore(created: [pullRequest()], login: nil, config: config())
        XCTAssertEqual(store.status, .failed(.signedOut, lastSuccess: nil))
        XCTAssertTrue(store.createdByMe.isEmpty, "Signing out must drop the contents, not keep showing them.")
        XCTAssertFalse(GitHubLiveFolderVisibility.shouldRender(config: config(), store: store))
    }

    func test_shouldRender_isFalseWhenBothFiltersAreOff() async {
        let filtered = config(createdByMe: false, reviewRequests: false)
        let (store, _) = await loadedStore(
            created: [pullRequest()],
            review: [pullRequest(id: "2", number: 9)],
            config: filtered
        )
        XCTAssertNotNil(store.lastSuccessfulFetch, "Precondition: the fetch itself succeeded.")
        XCTAssertFalse(GitHubLiveFolderVisibility.shouldRender(config: filtered, store: store))
    }

    func test_shouldRender_isFalseWhenTheFetchSucceededButFoundNothing() async {
        let (store, _) = await loadedStore(created: [], review: [], config: config())
        XCTAssertNotNil(store.lastSuccessfulFetch)
        XCTAssertFalse(GitHubLiveFolderVisibility.shouldRender(config: config(), store: store))
    }

    func test_shouldRender_isFalseOnceTheSessionIsTornDown() async {
        let enabled = config()
        let (store, _) = await loadedStore(created: [pullRequest()], config: enabled)
        XCTAssertTrue(GitHubLiveFolderVisibility.shouldRender(config: enabled, store: store), "precondition")

        store.deactivate()

        XCTAssertFalse(
            store.isTransmissionPermitted,
            "deactivate() must withdraw permission to transmit."
        )
        XCTAssertNil(store.lastSuccessfulFetch, "A torn-down store must not keep claiming a fetch time.")
        XCTAssertFalse(
            GitHubLiveFolderVisibility.shouldRender(config: enabled, store: store),
            "A folder must not survive the session it was fetched with."
        )
    }

    func test_shouldRender_isFalseWhenNoFetchInstantStandsBehindTheContents() async {
        let enabled = config()
        let (store, _) = await loadedStore(created: [pullRequest()], config: enabled)
        XCTAssertTrue(GitHubLiveFolderVisibility.shouldRender(config: enabled, store: store), "Precondition: this store does draw.")

        store.lastSuccessfulFetch = nil

        XCTAssertFalse(store.createdByMe.isEmpty, "Precondition: there are still rows, so only the missing instant can close the gate.")
        XCTAssertFalse(store.hasFetchedContents)
        XCTAssertFalse(
            GitHubLiveFolderVisibility.shouldRender(config: enabled, store: store),
            "A folder whose `Last fetch:` row could only say `Never` must not be on screen at all."
        )
        XCTAssertEqual(GitHubLiveFolderCopy.lastFetch(store.lastSuccessfulFetch), "Last fetch: Never")
    }

    // MARK: - The gate: the one way it is true

    func test_shouldRender_isTrueOnlyWithBothEnabledAndLiveData() async {
        let enabled = config()
        let (store, _) = await loadedStore(created: [pullRequest()], config: enabled)
        XCTAssertTrue(
            GitHubLiveFolderVisibility.shouldRender(config: enabled, store: store),
            "An enabled Space with a store holding genuinely fetched pull requests is the only state that draws a folder."
        )
    }

    func test_shouldRender_staysTrueThroughAFailureAfterASuccess() async {
        let enabled = config()
        let (store, scripted) = await loadedStore(created: [pullRequest()], config: enabled)
        let firstFetch = store.lastSuccessfulFetch

        scripted.created = .failure(.network("offline"))
        await store.refresh()

        XCTAssertEqual(store.lastSuccessfulFetch, firstFetch, "A failed attempt must not move the last-success timestamp.")
        XCTAssertTrue(GitHubLiveFolderVisibility.shouldRender(config: enabled, store: store))
        XCTAssertEqual(
            GitHubLiveFolderCopy.staleness(for: store.status), "Offline — showing last fetch",
            "The menu has to say the folder is showing older data; a bare `Last fetch:` row would imply the time is current."
        )
    }

    // MARK: - What the folder actually lists

    func test_pullRequests_honourEachFilterIndependently() async {
        let mine = pullRequest(id: "mine", number: 1, secondsAgo: 10)
        let theirs = pullRequest(id: "theirs", number: 2, secondsAgo: 20)

        let onlyMine = config(createdByMe: true, reviewRequests: false)
        let (storeA, _) = await loadedStore(created: [mine], review: [theirs], config: onlyMine)
        XCTAssertEqual(GitHubLiveFolderVisibility.pullRequests(config: onlyMine, store: storeA).map(\.id), ["mine"])

        let onlyReviews = config(createdByMe: false, reviewRequests: true)
        let (storeB, _) = await loadedStore(created: [mine], review: [theirs], config: onlyReviews)
        XCTAssertEqual(GitHubLiveFolderVisibility.pullRequests(config: onlyReviews, store: storeB).map(\.id), ["theirs"])
    }

    func test_pullRequests_dedupeAcrossTheTwoSourcesAndSortNewestFirst() async {
        let older = pullRequest(id: "older", number: 1, secondsAgo: 5_000)
        let newer = pullRequest(id: "newer", number: 2, secondsAgo: 5)
        let both = config()
        let (store, _) = await loadedStore(created: [older, newer], review: [newer], config: both)

        let rows = GitHubLiveFolderVisibility.pullRequests(config: both, store: store)
        XCTAssertEqual(rows.map(\.id), ["newer", "older"])
    }

    // MARK: - The row draws nothing when the gate is closed

    func test_row_drawsNothingWhateverWhenTheGateIsClosed() async {
        let (store, _) = await loadedStore(created: [], config: config())
        let space = installSpace(config: config())
        let size = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: OrbitMetrics.sidebarRowHeight * 3)

        let rendered = render(
            GitHubLiveFolderRowView(spaceID: space.id, theme: space.theme, store: store).environment(env),
            size: size
        )

        if let box = rendered.boundingBoxOfContent(tolerance: 0.03) {
            rendered.writeDiagnosticPNG(named: "GitHubLiveFolder-closedGate-FAILED")
            XCTFail(
                "With no fetched pull requests the live folder must draw nothing at all — no row, no empty folder, "
                + "no placeholder. Content was drawn at \(box). See the diagnostic PNG."
            )
        }
    }

    func test_row_drawsWhenTheGateIsOpen() async {
        let (store, _) = await loadedStore(created: [pullRequest()], config: config())
        let space = installSpace(config: config())
        let size = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: OrbitMetrics.sidebarRowHeight * 3)

        let rendered = render(
            GitHubLiveFolderRowView(spaceID: space.id, theme: space.theme, store: store).environment(env),
            size: size
        )

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "GitHubLiveFolder-openGate-FAILED-empty")
            XCTFail("An enabled Space with fetched pull requests must draw the `Pull Requests` row. Nothing was drawn.")
            return
        }
        XCTAssertGreaterThan(box.width, 40, "Expected a badged folder glyph and the folder's label, not a bare glyph. Got \(box).")
    }

    // MARK: - Geometry, against the row it mirrors

    func test_row_leadingInsetMatchesPinnedFolderRowExactly() async {
        let (store, _) = await loadedStore(created: [pullRequest()], config: config())
        let space = installSpace(config: config())
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarRowHeight)

        let live = render(
            GitHubLiveFolderRowView(spaceID: space.id, theme: space.theme, store: store)
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true),
            size: size
        )
        let pinned = render(
            PinnedFolderRowView(folder: Folder(name: "Reading"), spaceID: space.id, theme: space.theme, depth: 0)
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true),
            size: size
        )

        guard let liveBox = live.boundingBoxOfContent(tolerance: 0.03),
              let pinnedBox = pinned.boundingBoxOfContent(tolerance: 0.03) else {
            live.writeDiagnosticPNG(named: "GitHubLiveFolder-inset-FAILED-live")
            pinned.writeDiagnosticPNG(named: "GitHubLiveFolder-inset-FAILED-pinned")
            XCTFail("Both rows must draw something for their insets to be comparable.")
            return
        }

        XCTAssertGreaterThanOrEqual(
            liveBox.minX, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset,
            "The live folder must not draw left of sidebarHorizontalPadding + sidebarRowContentInset; measured \(liveBox.minX)."
        )
        XCTAssertEqual(
            liveBox.minX, pinnedBox.minX, accuracy: 3,
            "The live folder row and PinnedFolderRowView must line up on the leading edge; measured \(liveBox.minX) vs \(pinnedBox.minX)."
        )
        XCTAssertLessThanOrEqual(
            liveBox.maxY, OrbitMetrics.sidebarRowHeight,
            "The badged glyph must stay within one sidebarRowHeight; measured \(liveBox.maxY)."
        )
    }

    func test_row_indentsByExactlyIndentPerDepth() async {
        let (store, _) = await loadedStore(created: [pullRequest()], config: config())
        let space = installSpace(config: config())
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarRowHeight)

        let depth0 = render(
            GitHubLiveFolderRowView(spaceID: space.id, theme: space.theme, depth: 0, store: store).environment(env),
            size: size
        )
        let depth2 = render(
            GitHubLiveFolderRowView(spaceID: space.id, theme: space.theme, depth: 2, store: store).environment(env),
            size: size
        )

        guard let box0 = depth0.boundingBoxOfContent(tolerance: 0.03),
              let box2 = depth2.boundingBoxOfContent(tolerance: 0.03) else {
            XCTFail("Expected the live folder row to draw at both depths.")
            return
        }
        XCTAssertEqual(
            box2.minX - box0.minX, 2 * OrbitMetrics.sidebarIndentPerDepth, accuracy: 3,
            "Two levels of depth must shift the row by exactly 2 × sidebarIndentPerDepth."
        )
    }

    // MARK: - Sourced copy

    func test_menuCopy_matchesTheSourcedStringsExactly() {
        XCTAssertEqual(GitHubLiveFolderCopy.changeIcon, "Change Icon…")
        XCTAssertEqual(GitHubLiveFolderCopy.rename, "Rename")
        XCTAssertEqual(GitHubLiveFolderCopy.deleteLiveFolder, "Delete Live Folder")
        XCTAssertEqual(GitHubLiveFolderCopy.refresh, "Refresh")
        XCTAssertEqual(GitHubLiveFolderCopy.createdByMe, "Created by Me")
        XCTAssertEqual(GitHubLiveFolderCopy.reviewRequests, "Review Requests")
        XCTAssertEqual(GitHubLiveFolderCopy.defaultFolderName, "Pull Requests")
        XCTAssertEqual(GitHubLiveFolderCopy.spaceMenuLiveFolders, "Live Folders")
        XCTAssertEqual(GitHubLiveFolderCopy.spaceMenuGitHub, "GitHub")
    }

    func test_defaultFolderName_isWhatAnUnnamedConfigurationDisplays() {
        XCTAssertEqual(GitHubLiveFolderConfig().displayName, GitHubLiveFolderCopy.defaultFolderName)
    }

    func test_lastFetchLabel_neverImpliesFreshnessTheStoreDoesNotHave() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(GitHubLiveFolderCopy.lastFetch(now, relativeTo: now), "Last fetch: Just now")
        XCTAssertEqual(
            GitHubLiveFolderCopy.lastFetch(now.addingTimeInterval(-120), relativeTo: now),
            "Last fetch: 2 minutes ago"
        )
        XCTAssertEqual(
            GitHubLiveFolderCopy.lastFetch(nil, relativeTo: now), "Last fetch: Never",
            "With no successful fetch the row must say so outright. Falling back to \"Just now\" would be a lie about data that does not exist."
        )
    }

    func test_stalenessRow_namesEachFailureAndSaysNothingOnSuccess() {
        XCTAssertNil(GitHubLiveFolderCopy.staleness(for: .idle))
        XCTAssertNil(GitHubLiveFolderCopy.staleness(for: .loading))
        XCTAssertNil(GitHubLiveFolderCopy.staleness(for: .loaded(Date())))

        XCTAssertEqual(GitHubLiveFolderCopy.staleness(for: .failed(.rateLimited, lastSuccess: nil)), "Rate limited — showing last fetch")
        XCTAssertEqual(GitHubLiveFolderCopy.staleness(for: .failed(.network("timeout"), lastSuccess: nil)), "Offline — showing last fetch")
        XCTAssertEqual(GitHubLiveFolderCopy.staleness(for: .failed(.signedOut, lastSuccess: nil)), "Signed out of GitHub — showing last fetch")
        XCTAssertEqual(GitHubLiveFolderCopy.staleness(for: .failed(.badResponse(503), lastSuccess: nil)), "GitHub returned 503 — showing last fetch")
        XCTAssertEqual(GitHubLiveFolderCopy.staleness(for: .failed(.malformed("bad"), lastSuccess: nil)), "Unreadable response from GitHub — showing last fetch")
    }

    func test_spaceMenuItem_saysWhyItCannotActRatherThanFailingSilently() {
        let signedOut = GitHubLiveFolderCopy.spaceMenuItem(login: nil, hasLiveData: false, isEnabled: false)
        XCTAssertEqual(signedOut.title, "GitHub — Sign in to GitHub")
        XCTAssertFalse(signedOut.isActionable)

        let nothingFetched = GitHubLiveFolderCopy.spaceMenuItem(login: "octocat", hasLiveData: false, isEnabled: false)
        XCTAssertEqual(nothingFetched.title, "GitHub — No pull requests")
        XCTAssertFalse(nothingFetched.isActionable)

        let ready = GitHubLiveFolderCopy.spaceMenuItem(login: "octocat", hasLiveData: true, isEnabled: false)
        XCTAssertEqual(ready.title, "GitHub")
        XCTAssertTrue(ready.isActionable)

        let onButEmpty = GitHubLiveFolderCopy.spaceMenuItem(login: "octocat", hasLiveData: false, isEnabled: true)
        XCTAssertEqual(onButEmpty.title, "GitHub")
        XCTAssertTrue(onButEmpty.isActionable)
    }

    // MARK: - The toast

    func test_toastCopy_matchesTheSourcedStringsExactly() {
        XCTAssertEqual(GitHubLiveFolderCopy.toastTitle, "Live Folder Created")
        XCTAssertEqual(
            GitHubLiveFolderCopy.toastBody,
            "Pull requests from you and your team will show up here automatically"
        )
    }

    func test_toast_announcesTheSourcedMessageAndAutoDismissesOnItsSchedule() {
        var scheduled: [(delay: TimeInterval, dismissal: GitHubLiveFolderToastPresenter.Dismissal)] = []
        let presenter = GitHubLiveFolderToastPresenter(duration: 6) { delay, dismissal in
            scheduled.append((delay, dismissal))
        }

        XCTAssertNil(presenter.message, "Nothing is showing until something is announced.")

        presenter.announceLiveFolderCreated()
        XCTAssertEqual(presenter.message?.title, GitHubLiveFolderCopy.toastTitle)
        XCTAssertEqual(presenter.message?.body, GitHubLiveFolderCopy.toastBody)

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled.first?.delay, 6, "The dismissal must be scheduled at the presenter's own duration.")

        scheduled.first?.dismissal.run()
        XCTAssertNil(presenter.message, "The scheduled work must clear the message — a toast that never leaves is a permanent banner.")
    }

    func test_toast_clickDismissesImmediately() {
        let presenter = GitHubLiveFolderToastPresenter(duration: 6) { _, _ in }
        presenter.announceLiveFolderCreated()
        XCTAssertNotNil(presenter.message)

        presenter.dismiss()
        XCTAssertNil(presenter.message)
    }

    func test_toast_anEarlierTimerCannotDismissALaterMessage() {
        var scheduled: [GitHubLiveFolderToastPresenter.Dismissal] = []
        let presenter = GitHubLiveFolderToastPresenter(duration: 6) { _, dismissal in
            scheduled.append(dismissal)
        }

        presenter.present(title: "First", body: "one")
        presenter.present(title: "Second", body: "two")
        XCTAssertEqual(presenter.message?.title, "Second")

        scheduled.first?.run()
        XCTAssertEqual(
            presenter.message?.title, "Second",
            "The first toast's timer fired after the second replaced it, and must not have cleared it."
        )

        scheduled.last?.run()
        XCTAssertNil(presenter.message, "The second toast's own timer still dismisses it.")
    }
}
