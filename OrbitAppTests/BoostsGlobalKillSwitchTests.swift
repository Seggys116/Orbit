import XCTest
@testable import Orbit

@MainActor
final class BoostsGlobalKillSwitchTests: XCTestCase {

    private var scratchDirectory: URL!
    private var suiteName: String!
    private var scratchDefaults: UserDefaults!
    private var originalDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-BoostKillSwitch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        suiteName = "OrbitTests-BoostKillSwitch-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: suiteName)
        originalDefaults = BoostsGlobalSettings.defaults
        BoostsGlobalSettings.defaults = scratchDefaults
    }

    override func tearDown() {
        BoostsGlobalSettings.defaults = originalDefaults
        scratchDefaults?.removePersistentDomain(forName: suiteName)
        scratchDefaults = nil
        suiteName = nil
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private var boostsFileURL: URL {
        scratchDirectory.appendingPathComponent("boosts.json", isDirectory: false)
    }

    private final class RecordingSink {
        private(set) var installed: [(script: UserScript, sessionIdentifier: String)] = []
        private(set) var uninstalledIDs: [UUID] = []

        var sink: BoostRuntime.ScriptSink {
            BoostRuntime.ScriptSink(
                install: { [weak self] script, session in
                    self?.installed.append((script, session.identifier))
                },
                uninstall: { [weak self] id, _ in
                    self?.uninstalledIDs.append(id)
                }
            )
        }
    }

    @discardableResult
    private func saveBoostThenReload() throws -> BoostStore {
        let writing = BoostStore(fileURL: boostsFileURL)
        let boost = writing.createBoost(name: "Kill Switch Boost", host: "example.com")
        writing.updateBoost(boost.id) { boost in
            boost.invertLightness = true
            boost.pageSizeScale = 1.25
            boost.customJavaScript = "document.title = 'boosted';"
        }
        try writing.saveNow()
        return BoostStore(fileURL: boostsFileURL)
    }

    // MARK: - The default

    func test_withNoStoredPreference_boostsAreEnabled() throws {
        XCTAssertNil(
            scratchDefaults.object(forKey: "OrbitBoostsGloballyEnabled"),
            "this test is only meaningful with the key genuinely absent"
        )
        XCTAssertTrue(BoostsGlobalSettings.isEnabled)

        let store = try saveBoostThenReload()
        XCTAssertFalse(
            store.allCompiledScripts().isEmpty,
            "with no stored preference a saved Boost must still compile and install"
        )
    }

    func test_label_isArcsOwnWording() {
        XCTAssertEqual(BoostsGlobalSettings.label, "Enable Boosts on websites you visit.")
    }

    // MARK: - Path 1: pre-page-load registration

    func test_killSwitchOff_installsNothingOnThePrePageLoadPath() throws {
        let store = try saveBoostThenReload()
        let runtime = BoostRuntime()
        let recorder = RecordingSink()
        let session = MockEngineSession(identifier: "profile-a")

        BoostsGlobalSettings.isEnabled = false
        runtime.installAllBoosts(from: store, into: session, sink: recorder.sink)

        XCTAssertTrue(
            recorder.installed.isEmpty,
            """
            \(recorder.installed.count) script(s) reached the engine with Boosts globally off. \
            This is the pre-page-load registration path — the one a kill-switch \
            written against the editor alone would miss entirely.
            """
        )
    }

    // MARK: - Path 2: navigation commit

    func test_killSwitchOff_installsAndInjectsNothingOnTheCommitPath() throws {
        let store = try saveBoostThenReload()
        let runtime = BoostRuntime()
        let recorder = RecordingSink()
        let session = MockEngineSession(identifier: "profile-a")
        let contents = MockWebContents(session: session)

        BoostsGlobalSettings.isEnabled = false
        runtime.pageDidCommit(
            url: URL(string: "https://example.com/article")!,
            in: session,
            contents: contents,
            store: store,
            sink: recorder.sink
        )

        XCTAssertTrue(recorder.installed.isEmpty, "a script was registered into the session with Boosts globally off")
        XCTAssertTrue(
            contents.injectedUserScripts.isEmpty,
            "a script was injected straight into the live page with Boosts globally off"
        )
    }

    func test_killSwitchOff_emptiesBothCompiledScriptAccessors() throws {
        let store = try saveBoostThenReload()

        XCTAssertFalse(store.allCompiledScripts().isEmpty)
        XCTAssertFalse(store.compiledScripts(forHost: "example.com").isEmpty)

        BoostsGlobalSettings.isEnabled = false

        XCTAssertTrue(store.allCompiledScripts().isEmpty)
        XCTAssertTrue(store.compiledScripts(forHost: "example.com").isEmpty)
        XCTAssertEqual(
            store.boosts.count, 1,
            "the switch must gate compilation, not delete the user's Boosts"
        )
        XCTAssertTrue(
            store.boosts[0].isEnabled,
            "each Boost's own enabled state must be left alone so switching back on restores exactly what was there"
        )
    }

    // MARK: - Path 3: the toggle itself, and switching back on

    func test_togglingOffRemovesRegisteredScripts_andTogglingOnRestoresThem() throws {
        let store = try saveBoostThenReload()
        let runtime = BoostRuntime()
        let recorder = RecordingSink()
        let session = MockEngineSession(identifier: "profile-a")

        runtime.installAllBoosts(from: store, into: session, sink: recorder.sink)
        let installedWhileOn = recorder.installed.map(\.script.id)
        XCTAssertFalse(installedWhileOn.isEmpty, "nothing was installed while the switch was on")
        XCTAssertTrue(recorder.uninstalledIDs.isEmpty)

        BoostsGlobalSettings.isEnabled = false
        runtime.installAllBoosts(from: store, into: session, sink: recorder.sink)

        XCTAssertEqual(
            recorder.installed.map(\.script.id), installedWhileOn,
            "switching off must install nothing further"
        )
        XCTAssertEqual(
            Set(recorder.uninstalledIDs), Set(installedWhileOn),
            """
            switching Boosts off left \(installedWhileOn.count - recorder.uninstalledIDs.count) \
            already-registered script(s) in the session — the switch stopped new \
            registrations but never removed the live ones
            """
        )

        BoostsGlobalSettings.isEnabled = true
        runtime.installAllBoosts(from: store, into: session, sink: recorder.sink)

        let installedAfterRestore = recorder.installed.map(\.script.id).suffix(installedWhileOn.count)
        XCTAssertEqual(
            Array(installedAfterRestore), installedWhileOn,
            "switching Boosts back on must restore exactly the scripts that were there before"
        )
    }

    func test_killSwitchOff_stopsTheJavaScriptHalfToo() throws {
        let store = try saveBoostThenReload()

        let whileOn = store.allCompiledScripts()
        XCTAssertTrue(whileOn.contains { $0.kind == .stylesheet }, "fixture must produce a stylesheet")
        XCTAssertTrue(whileOn.contains { $0.kind == .javaScript }, "fixture must produce a user script")

        BoostsGlobalSettings.isEnabled = false
        XCTAssertTrue(store.allCompiledScripts().isEmpty)
    }

    func test_killSwitchOff_installsNothingThroughTheRealDelegateCallback() throws {
        let env = AppEnvironment.demo
        let recorder = RecordingSink()

        let boost = env.boostStore.createBoost(name: "Kill Switch Delegate", host: "killswitch-boosts.test")
        env.boostStore.updateBoost(boost.id) { $0.textCase = .uppercase }
        defer { env.boostStore.deleteBoost(boost.id) }

        BoostRuntime.shared.reset()
        env._test_boostScriptSinkOverride = recorder.sink
        defer {
            env._test_boostScriptSinkOverride = nil
            BoostRuntime.shared.reset()
        }

        let session = MockEngineSession(identifier: "killswitch-session-\(UUID().uuidString)")
        let contents = MockWebContents(session: session)
        let tabID = UUID()
        env._test_attachWebContents(contents, for: tabID)
        defer { env._test_detachWebContents(for: tabID) }

        let url = URL(string: "https://killswitch-boosts.test/index.html")!
        contents.navigationState.url = url

        BoostsGlobalSettings.isEnabled = false
        env.webContents(contents, didCommitNavigationTo: url, kind: .typed)

        XCTAssertTrue(
            recorder.installed.isEmpty,
            "the real delegate path registered a script with Boosts globally off"
        )
        XCTAssertTrue(
            contents.injectedUserScripts.isEmpty,
            "the real delegate path injected a script with Boosts globally off"
        )
    }
}
