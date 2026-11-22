import XCTest

/// Protocol-level regression tests for the `BrowserEngine` seam. No engine is linked
/// here by design; these fakes stand in for a second implementation.
final class BrowserEngineSeamTests: XCTestCase {

    @MainActor
    func testAnEngineThatNeverNeedsPumpingIsNotForcedToImplementTick() {
        // SeamTestEngine below declares no `tick()` at all -- if the protocol
        // ever loses its default `tick()` implementation, this file fails to
        // compile; the assertions pin that the default does nothing observable.
        let engine = SeamTestEngine()
        let activationBefore = engine.extensionActivation

        engine.tick()
        engine.tick()

        XCTAssertEqual(engine.calls, [], "the default tick() must not call back into any engine operation")
        XCTAssertEqual(engine.extensionActivation, activationBefore)
        XCTAssertTrue(engine.extensionActionStates.snapshots.isEmpty)
    }

    @MainActor
    func testTheDefaultUninstallFallsBackToUnloadingTheSameExtension() {
        let engine = SeamTestEngine()
        let session = engine.defaultSession

        engine.uninstallExtension(id: "ext-1", session: session)

        XCTAssertEqual(
            engine.calls, ["unloadExtension(ext-1)"],
            "an engine that does not wipe stored data must still stop the extension: uninstall defaults to unload with the same id"
        )
    }

    @MainActor
    func testTheDefaultReasonedLoadForwardsToThePlainLoadWhateverTheReason() async throws {
        let engine = SeamTestEngine()
        let session = engine.defaultSession
        let directory = URL(fileURLWithPath: "/tmp/seam-ext")

        for reason in ExtensionLoadReason.allCases {
            engine.calls.removeAll()
            let loaded = try await engine.loadExtension(at: directory, session: session, reason: reason)

            XCTAssertEqual(engine.calls, ["loadExtension(/tmp/seam-ext)"], "reason \(reason) must reach the engine's own loadExtension exactly once")
            XCTAssertEqual(loaded.directory, directory)
        }
    }

    @MainActor
    func testTheDefaultActionStateStoreIsTheSharedInertStore() {
        let first = SeamTestEngine()
        let second = SeamTestEngine()

        XCTAssertTrue(first.extensionActionStates === ExtensionActionStateStore.inert)
        XCTAssertTrue(second.extensionActionStates === first.extensionActionStates)
    }

    @MainActor
    func testExtensionActivationDescribesAnEngineThatActivatesImmediately() {
        XCTAssertEqual(
            Set(ExtensionActivation.allCases),
            [.unsupported, .nextLaunch, .immediate],
            """
            ExtensionActivation has grown or lost a case. A future engine that installs extensions \
            without a restart must be able \
            to say so through .immediate -- do not remove it, and give any new case a real meaning \
            rather than folding it into .nextLaunch.
            """
        )
    }

    @MainActor
    func testLoadedExtensionDefaultsDescribeAnAlreadyRunningExtension() {
        let extensionInfo = LoadedExtension(
            id: "abc",
            name: "Test",
            version: "1.0",
            directory: URL(fileURLWithPath: "/tmp/abc")
        )
        XCTAssertTrue(extensionInfo.isEnabled)
        XCTAssertTrue(
            extensionInfo.isActivated,
            "isActivated defaults to true: the field exists to flag the .nextLaunch gap, not to make callers opt in to activation."
        )
    }

    @MainActor
    func testASecondEngineImplementationCanReportImmediateActivationAlongsideTheFirst() {
        let nextLaunchShaped = SeamTestEngine(activation: .nextLaunch)
        let immediateShaped = SeamTestEngine(activation: .immediate)

        XCTAssertEqual(nextLaunchShaped.extensionActivation, .nextLaunch)
        XCTAssertEqual(immediateShaped.extensionActivation, .immediate)
        XCTAssertNotEqual(nextLaunchShaped.extensionActivation, immediateShaped.extensionActivation)
        XCTAssertEqual(type(of: nextLaunchShaped).kind, .webkit)
    }
}

// MARK: - A minimal stand-in for a second engine implementation

@MainActor
private final class SeamTestEngine: BrowserEngine {
    static let kind: EngineKind = .webkit
    let capabilities: EngineCapabilities = []
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation
    let versionDescription = "SeamTestEngine"
    var calls: [String] = []

    init(activation: ExtensionActivation = .immediate) {
        self.extensionActivation = activation
    }

    func start() throws { calls.append("start") }
    func shutdown() -> Bool { calls.append("shutdown"); return true }
    // Deliberately no tick() override -- exercises BrowserEngine's default.

    func session(identifier: String, persistent: Bool) throws -> EngineSession {
        SeamTestSession(identifier: identifier)
    }
    lazy var defaultSession: EngineSession = SeamTestSession(identifier: "default")

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        throw EngineError(code: .engineUnavailable, underlyingDescription: "not exercised by these tests")
    }

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
    func addUserScript(_ script: UserScript, session: EngineSession) {}
    func removeUserScript(id: UUID, session: EngineSession) {}
    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}

    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
        calls.append("loadExtension(\(directory.path))")
        return LoadedExtension(id: "seam", name: "Seam", version: "1", directory: directory)
    }
    func unloadExtension(id: String, session: EngineSession) { calls.append("unloadExtension(\(id))") }
    func loadedExtensions(session: EngineSession) -> [LoadedExtension] { [] }
}

@MainActor
private final class SeamTestSession: EngineSession {
    let identifier: String
    let isPersistent: Bool = true
    var storageURL: URL? { nil }
    init(identifier: String) { self.identifier = identifier }
    func setUserAgent(_ userAgent: String) {}
    func cookies(for url: URL) async -> [HTTPCookie] { [] }
    func deleteCookies(for url: URL) async {}
    func setCookies(_ cookies: [EngineCookie]) async -> Int { 0 }
    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting { .unsupported }
    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL) {}
}
