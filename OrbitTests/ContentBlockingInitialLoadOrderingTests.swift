import XCTest

final class ContentBlockingInitialLoadOrderingTests: XCTestCase {

    private var createdDirectories: [URL] = []

    override func tearDown() {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let seededListText = "||adnxs.com^\n"

    // Must use "EasyList" as listID: it is FilterListCatalog's real id, so compile() actually reaches it rather than the test passing vacuously.
    private func seedCache(in directory: URL, listID: String = "EasyList", text: String = seededListText) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent("\(listID).txt"), atomically: true, encoding: .utf8)
        let entry = FilterListCacheEntry(
            listID: listID,
            sourceURLs: [URL(string: "https://easylist.to/easylist/easylist.txt")!],
            declaredVersion: "1",
            declaredTitle: listID,
            expiresAfter: 4 * 86_400,
            fetchedAt: Date(),
            lastCheckedAt: Date(),
            etag: nil,
            lastModified: nil,
            byteCount: text.utf8.count,
            contentHash: "test"
        )
        let data = try JSONEncoder.orbitContentBlocking.encode([listID: entry])
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ContentBlockingOrdering-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(url)
        return url
    }

    private func makeController(seeded: Bool) throws -> ContentBlockingController {
        let directory = makeTempDirectory()
        if seeded {
            try seedCache(in: directory)
        }
        let defaults = UserDefaults(suiteName: "OrbitTests.ContentBlockingOrdering.\(UUID().uuidString)")!
        // Confining enabledListIDs to just "EasyList" keeps compiledRuleCount
        // an exact, unambiguous count rather than depending on what an
        // unrelated cache miss contributes.
        defaults.set(["EasyList"], forKey: "contentBlocking.enabledLists")
        return ContentBlockingController(
            store: FilterListStore(directory: directory),
            defaults: defaults
        )
    }

    // MARK: - The core guarantee

    func testAwaitInitialCacheLoadDoesNotReturnBeforeTheCachedCompileHasActuallyRun() async throws {
        let controller = try makeController(seeded: true)

        XCTAssertFalse(controller.hasCompletedInitialCacheLoad, "must start false — nothing has run yet")
        XCTAssertEqual(controller.compiledRuleCount, 0)

        await controller.awaitInitialCacheLoad()

        XCTAssertTrue(controller.hasCompletedInitialCacheLoad)
        XCTAssertEqual(controller.compiledRuleCount, 1, "the one seeded EasyList rule must have actually compiled")
        controller.blocker.isEnabled = true
        XCTAssertTrue(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "the seeded rule must be live in the blocker awaitInitialCacheLoad() unblocked")
    }

    func testAwaitInitialCacheLoadResolvesEvenWhenNothingIsCached() async throws {
        let controller = try makeController(seeded: false)
        await controller.awaitInitialCacheLoad()
        XCTAssertTrue(controller.hasCompletedInitialCacheLoad)
        XCTAssertEqual(controller.compiledRuleCount, 0)
    }

    // MARK: - Idempotency: the mechanism `startEngineIfNeeded()` and
    // `prepareSession` both lean on to be safe to call from two places

    // Proven by identity, not by re-deriving the same answer twice: cancelling
    // the Task returned by the second call must cancel the first one too,
    // which is only possible if both handles name the same underlying job.
    func testBeginInitialCacheLoadIsIdempotentAcrossCalls() async throws {
        let controller = try makeController(seeded: true)

        let first = controller.beginInitialCacheLoad()
        let second = controller.beginInitialCacheLoad()

        second.cancel()
        XCTAssertTrue(first.isCancelled, "a second call must return the SAME task, not start an independent one")

        await first.value
        XCTAssertTrue(controller.hasCompletedInitialCacheLoad, "cancellation must not stop `loadFromCache` — nothing in it checks `Task.isCancelled`, and it must not start doing so silently")
    }

    // MARK: - `ContentBlockingRuntime.prepareSession`'s readiness contract

    // Must use ContentBlockingRuntime(controller:), the #if DEBUG test seam, not .shared, whose controller reads the real on-disk filter-list cache and fires a real, unawaited network refresh() against EasyList/EasyPrivacy's real URLs on prepareSession's first call.

    @MainActor
    func testPrepareSessionReturnsNilForAnAlreadyBoundSessionOnceTheCachedCompileHasLanded() async throws {
        let runtime = ContentBlockingRuntime(controller: try makeController(seeded: false))
        let engine = OrderingTestFakeEngine()
        let session = OrderingTestFakeSession(identifier: "prepareSession-nil-\(UUID().uuidString)")

        if let firstReadiness = runtime.prepareSession(session, engine: engine) {
            await firstReadiness.value
        }
        XCTAssertTrue(runtime.controller.hasCompletedInitialCacheLoad, "the first call must also have started (and this must have waited for) the cached compile")

        let secondReadiness = runtime.prepareSession(session, engine: engine)
        XCTAssertNil(secondReadiness, "an already-bound session must not be made to wait once the cached compile has landed")
    }

    @MainActor
    func testPrepareSessionReturnsATaskThatWaitsForTheCachedCompileOnAFreshRuntime() async throws {
        let runtime = ContentBlockingRuntime(controller: try makeController(seeded: true))
        let engine = OrderingTestFakeEngine()
        let session = OrderingTestFakeSession(identifier: "prepareSession-wait-\(UUID().uuidString)")

        let readiness = try XCTUnwrap(
            runtime.prepareSession(session, engine: engine),
            "a runtime that has never loaded anything must return a Task to wait on"
        )

        XCTAssertFalse(
            runtime.controller.hasCompletedInitialCacheLoad,
            "must not have finished already — this call is what started it"
        )
        await readiness.value
        XCTAssertTrue(
            runtime.controller.hasCompletedInitialCacheLoad,
            "awaiting the readiness Task must not return before the cached compile it gates on has finished"
        )
        XCTAssertEqual(runtime.controller.compiledRuleCount, 1)
    }

    @MainActor
    func testPrepareSessionReturnsNilWhenTheEngineDoesNotSupportContentBlocking() throws {
        let runtime = ContentBlockingRuntime(controller: try makeController(seeded: false))
        let engine = OrderingTestFakeEngine(capabilities: [])
        let session = OrderingTestFakeSession(identifier: "prepareSession-nocap-\(UUID().uuidString)")
        XCTAssertNil(runtime.prepareSession(session, engine: engine))
    }
}

// MARK: - Minimal fakes

@MainActor
private final class OrderingTestFakeSession: EngineSession {
    let identifier: String
    let isPersistent: Bool = true
    var storageURL: URL? { nil }
    init(identifier: String) { self.identifier = identifier }
    func setUserAgent(_ userAgent: String) {}
    func cookies(for url: URL) async -> [HTTPCookie] { [] }
    func setCookies(_ cookies: [EngineCookie]) async -> Int { 0 }
    func deleteCookies(for url: URL) async {}
    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting { .unsupported }
    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL) {}
}

@MainActor
private final class OrderingTestFakeEngine: BrowserEngine {
    static let kind: EngineKind = .chromium
    let capabilities: EngineCapabilities
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation = .unsupported
    let versionDescription = "OrderingTestFakeEngine"

    init(capabilities: EngineCapabilities = .contentBlocking) {
        self.capabilities = capabilities
    }

    func start() throws {}
    func shutdown() -> Bool { true }
    func tick() {}

    func session(identifier: String, persistent: Bool) throws -> EngineSession {
        OrderingTestFakeSession(identifier: identifier)
    }
    lazy var defaultSession: EngineSession = OrderingTestFakeSession(identifier: "default")

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        throw EngineError(code: .engineUnavailable, underlyingDescription: "not exercised by these tests")
    }

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
    func addUserScript(_ script: UserScript, session: EngineSession) {}
    func removeUserScript(id: UUID, session: EngineSession) {}

    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}

    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
        throw EngineError(code: .engineUnavailable, underlyingDescription: "not exercised by these tests")
    }
    func unloadExtension(id: String, session: EngineSession) {}
    func loadedExtensions(session: EngineSession) -> [LoadedExtension] { [] }
}
