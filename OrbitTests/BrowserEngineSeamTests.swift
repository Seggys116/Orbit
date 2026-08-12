import XCTest

/// Protocol-level regression tests for the `BrowserEngine` seam. No engine is linked
/// here by design; these fakes stand in for a second implementation.
final class BrowserEngineSeamTests: XCTestCase {

    @MainActor
    func testAnEngineThatNeverNeedsPumpingIsNotForcedToImplementTick() {
        // SeamTestEngine below declares no `tick()` at all -- if the protocol
        // ever loses its default `tick()` implementation, this file fails to
        // compile, which is the regression this test exists to catch.
        let engine = SeamTestEngine()
        engine.tick()
        engine.tick()
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
        // Both are still BrowserEngine.kind == .chromium: kind names the
        // rendering technology (Chromium), not the embedding technique.
        XCTAssertEqual(type(of: nextLaunchShaped).kind, type(of: immediateShaped).kind)
    }
}

// MARK: - A minimal stand-in for a second engine implementation

@MainActor
private final class SeamTestEngine: BrowserEngine {
    static let kind: EngineKind = .chromium
    let capabilities: EngineCapabilities = []
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation
    let versionDescription = "SeamTestEngine"

    init(activation: ExtensionActivation = .immediate) {
        self.extensionActivation = activation
    }

    func start() throws {}
    func shutdown() -> Bool { true }
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
        throw EngineError(code: .engineUnavailable, underlyingDescription: "not exercised by these tests")
    }
    func unloadExtension(id: String, session: EngineSession) {}
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
