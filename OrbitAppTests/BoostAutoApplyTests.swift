import XCTest
@testable import Orbit

@MainActor
final class BoostAutoApplyTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-BoostAutoApply-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
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

        var installedStylesheets: [UserScript] { installed.map(\.script).filter { $0.kind == .stylesheet } }
        var installedJavaScripts: [UserScript] { installed.map(\.script).filter { $0.kind == .javaScript } }
    }

    private func saveBoostThenReload(
        host: String,
        _ configure: (inout Boost) -> Void
    ) throws -> BoostStore {
        let writing = BoostStore(fileURL: boostsFileURL)
        let boost = writing.createBoost(name: "Test Boost", host: host)
        writing.updateBoost(boost.id, configure)
        try writing.saveNow()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: boostsFileURL.path),
            "the Boost must actually be on disk before the reload half of this test means anything"
        )
        return BoostStore(fileURL: boostsFileURL)
    }

    // MARK: - The regression itself

    func test_savedBoost_isInstalledOnAFreshLoadAfterReload() throws {
        let reloaded = try saveBoostThenReload(host: "example.com") { boost in
            boost.invertLightness = true
            boost.pageSizeScale = 1.25
        }

        XCTAssertEqual(
            reloaded.boosts.count, 1,
            "the Boost must survive the write/read cycle at all before anything else here is meaningful"
        )

        let runtime = BoostRuntime()
        let recorder = RecordingSink()
        let session = MockEngineSession(identifier: "profile-a")
        let contents = MockWebContents(session: session)
        let url = URL(string: "https://example.com/some/article")!

        XCTAssertFalse(
            runtime.hasInstalled(into: session),
            "a session nothing has touched must report as un-installed, or the guard below proves nothing"
        )

        let didInstall = runtime.pageDidCommit(
            url: url,
            in: session,
            contents: contents,
            store: reloaded,
            sink: recorder.sink
        )

        XCTAssertTrue(didInstall, "the first committed load in a session must install this profile's Boosts")

        let stylesheets = recorder.installedStylesheets
        XCTAssertEqual(
            stylesheets.count, 1,
            """
            No stylesheet reached the engine on a fresh load of a boosted site. \
            This is the exact defect: the Boost was on disk and compiled fine, \
            but nothing outside the editor ever registered it.
            """
        )

        let stylesheet = try XCTUnwrap(stylesheets.first)
        XCTAssertTrue(
            MatchPatternSet(stylesheet.matchPatterns).matches(url),
            "the installed script must actually match the URL that was loaded, not merely exist"
        )
        XCTAssertTrue(
            stylesheet.source.contains("invert(1)"),
            "invert lightness was saved but did not survive into the stylesheet the engine received"
        )
        XCTAssertTrue(
            stylesheet.source.contains("zoom"),
            "the page size control was saved but did not survive into the stylesheet the engine received"
        )
    }

    func test_committedNavigation_installsBoostsThroughTheRealDelegateCallback() throws {
        let env = AppEnvironment.demo
        let recorder = RecordingSink()

        let boost = env.boostStore.createBoost(name: "Delegate Boost", host: "delegate-boosts.test")
        env.boostStore.updateBoost(boost.id) { $0.textCase = .uppercase }
        defer { env.boostStore.deleteBoost(boost.id) }

        BoostRuntime.shared.reset()
        env._test_boostScriptSinkOverride = recorder.sink
        defer {
            env._test_boostScriptSinkOverride = nil
            BoostRuntime.shared.reset()
        }

        let session = MockEngineSession(identifier: "delegate-session-\(UUID().uuidString)")
        let contents = MockWebContents(session: session)
        let tabID = UUID()
        env._test_attachWebContents(contents, for: tabID)
        defer { env._test_detachWebContents(for: tabID) }

        let url = URL(string: "https://delegate-boosts.test/index.html")!
        contents.navigationState.url = url

        env.webContents(contents, didCommitNavigationTo: url, kind: .typed)

        let matching = recorder.installedStylesheets.filter {
            MatchPatternSet($0.matchPatterns).matches(url)
        }
        XCTAssertEqual(
            matching.count, 1,
            """
            A committed navigation to a boosted host installed nothing. \
            `AppEnvironment`'s `didCommitNavigationTo` callback is where \
            `WebContentsDelegate`'s own doc comment says Boosts are re-applied.
            """
        )
        XCTAssertTrue(
            try XCTUnwrap(matching.first).source.contains("text-transform: uppercase"),
            "the customisation the user saved must be what reaches the page"
        )
    }

    func test_secondNavigationInAnInstalledSession_doesNotInjectAgain() throws {
        let reloaded = try saveBoostThenReload(host: "example.com") { boost in
            boost.customJavaScript = "window.__orbitBoostRan = (window.__orbitBoostRan || 0) + 1;"
        }

        let runtime = BoostRuntime()
        let recorder = RecordingSink()
        let session = MockEngineSession(identifier: "profile-a")
        let contents = MockWebContents(session: session)
        let url = URL(string: "https://example.com/")!

        XCTAssertTrue(runtime.pageDidCommit(url: url, in: session, contents: contents, store: reloaded, sink: recorder.sink))
        let injectedAfterFirst = contents.injectedUserScripts.count
        XCTAssertGreaterThan(
            injectedAfterFirst, 0,
            "the very first load is the one the session-level registration is too late for, so it must be injected directly"
        )
        let installedAfterFirst = recorder.installed.count

        XCTAssertFalse(
            runtime.pageDidCommit(url: url, in: session, contents: contents, store: reloaded, sink: recorder.sink),
            "a session that already carries the current Boost generation needs no second install"
        )
        XCTAssertEqual(
            contents.injectedUserScripts.count, injectedAfterFirst,
            """
            The second navigation injected into the live document again. \
            The engine already ran these scripts at document start, so this \
            runs every Boost's JavaScript a second time on one page.
            """
        )
        XCTAssertEqual(recorder.installed.count, installedAfterFirst)
    }

    func test_reinstallingReplacesThePreviousGeneration() throws {
        let store = try saveBoostThenReload(host: "example.com") { $0.invertLightness = true }
        let runtime = BoostRuntime()
        let recorder = RecordingSink()
        let session = MockEngineSession(identifier: "profile-a")

        let first = runtime.installAllBoosts(from: store, into: session, sink: recorder.sink)
        XCTAssertTrue(recorder.uninstalledIDs.isEmpty, "there was nothing to remove the first time")

        let second = runtime.installAllBoosts(from: store, into: session, sink: recorder.sink)
        XCTAssertEqual(
            recorder.uninstalledIDs, first.map(\.id),
            "the previous generation must be removed before the new one is added"
        )
        XCTAssertEqual(
            second.map(\.id), first.map(\.id),
            """
            The same Boost compiled to a different script id on the second \
            pass. Ids must be stable per Boost or nothing can ever remove a \
            generation it did not personally install — across a relaunch, \
            nothing can.
            """
        )
    }

    func test_boostForOneHost_doesNotMatchAnother() throws {
        let store = try saveBoostThenReload(host: "example.com") { $0.invertLightness = true }
        let runtime = BoostRuntime()
        let recorder = RecordingSink()
        let session = MockEngineSession(identifier: "profile-a")

        runtime.installAllBoosts(from: store, into: session, sink: recorder.sink)

        let stylesheet = try XCTUnwrap(recorder.installedStylesheets.first)
        let patterns = MatchPatternSet(stylesheet.matchPatterns)
        XCTAssertTrue(patterns.matches(URL(string: "https://example.com/x")!))
        XCTAssertTrue(
            patterns.matches(URL(string: "https://news.example.com/x")!),
            "Boosts are stored against a domain and cover its subdomains"
        )
        XCTAssertFalse(
            patterns.matches(URL(string: "https://notexample.com/x")!),
            "a host that merely ends with the same letters is a different site"
        )
        XCTAssertFalse(patterns.matches(URL(string: "https://other.test/x")!))
    }

    func test_disabledBoost_isNotInstalled() throws {
        let store = try saveBoostThenReload(host: "example.com") { boost in
            boost.invertLightness = true
            boost.isEnabled = false
        }

        let runtime = BoostRuntime()
        let recorder = RecordingSink()
        let session = MockEngineSession(identifier: "profile-a")
        let contents = MockWebContents(session: session)

        runtime.pageDidCommit(
            url: URL(string: "https://example.com/")!,
            in: session,
            contents: contents,
            store: store,
            sink: recorder.sink
        )

        XCTAssertTrue(recorder.installed.isEmpty, "a disabled Boost must compile to nothing and install nothing")
        XCTAssertTrue(contents.injectedUserScripts.isEmpty)
    }

    func test_replacedSessionUnderTheSameIdentifier_isInstalledIntoAgain() throws {
        let store = try saveBoostThenReload(host: "example.com") { $0.invertLightness = true }
        let runtime = BoostRuntime()
        let recorder = RecordingSink()

        let first = MockEngineSession(identifier: "profile-a")
        runtime.installAllBoosts(from: store, into: first, sink: recorder.sink)
        XCTAssertTrue(runtime.hasInstalled(into: first))

        let replacement = MockEngineSession(identifier: "profile-a")
        XCTAssertFalse(
            runtime.hasInstalled(into: replacement),
            "a different session object under a reused identifier has none of these scripts in it"
        )
    }

    // MARK: - Persistence of the visual controls

    func test_everyVisualControl_survivesReloadAndReachesTheStylesheet() throws {
        let store = try saveBoostThenReload(host: "example.com") { boost in
            boost.invertLightness = true
            boost.contrast = 1.4
            boost.brightness = 0.8
            boost.saturation = 0.5
            boost.pageSizeScale = 1.5
            boost.textCase = .capitalize
        }

        let boost = try XCTUnwrap(store.boosts.first)
        XCTAssertTrue(boost.invertLightness)
        XCTAssertEqual(boost.contrast, 1.4, accuracy: 0.0001)
        XCTAssertEqual(boost.brightness, 0.8, accuracy: 0.0001)
        XCTAssertEqual(boost.saturation, 0.5, accuracy: 0.0001)
        XCTAssertEqual(boost.pageSizeScale, 1.5, accuracy: 0.0001)
        XCTAssertEqual(boost.textCase, .capitalize)

        let css = BoostCompiler.compiledCSS(for: boost)
        for expected in [
            "invert(1)",
            "hue-rotate(180deg)",
            "contrast(",
            "brightness(",
            "saturate(",
            "zoom:",
            "text-transform: capitalize",
        ] {
            XCTAssertTrue(
                css.contains(expected),
                "\(expected) is missing from the compiled stylesheet — that control does nothing"
            )
        }
    }

    func test_untouchedBoost_compilesToNothing() {
        let boost = Boost(name: "Empty", host: "example.com")
        XCTAssertTrue(BoostCompiler.compiledCSS(for: boost).isEmpty)
        XCTAssertTrue(BoostCompiler.compile(boost).isEmpty)
        XCTAssertTrue(boost.hasDefaultVisualAdjustments)
    }

    func test_resetToOriginalColors_clearsOnlyTheColourControls() {
        var boost = Boost(name: "Reset", host: "example.com")
        boost.invertLightness = true
        boost.contrast = 1.5
        boost.brightness = 0.5
        boost.saturation = 0
        boost.backgroundColor = ThemeColor(red: 1, green: 0, blue: 0, alpha: 1)
        boost.pageSizeScale = 1.25
        boost.textCase = .uppercase
        boost.fontFamily = "Georgia"
        boost.customCSS = "a { color: red; }"

        boost.resetToOriginalColors()

        XCTAssertTrue(boost.hasDefaultVisualAdjustments)
        XCTAssertEqual(boost.pageSizeScale, 1.25, accuracy: 0.0001, "Size is not a colour")
        XCTAssertEqual(boost.textCase, .uppercase, "Case is not a colour")
        XCTAssertEqual(boost.fontFamily, "Georgia", "the font is not a colour")
        XCTAssertEqual(boost.customCSS, "a { color: red; }", "hand-written CSS is never touched by a reset button")
    }

    func test_sizeButton_cyclesTheDocumentedLadderAndWraps() {
        var boost = Boost(name: "Size", host: "example.com")
        XCTAssertEqual(boost.pageSizeScale, 1.0, "an untouched Boost leaves the page at its own size")
        XCTAssertEqual(boost.pageSizeButtonLabel, "Size")

        var seen: [Double] = []
        for _ in 0..<Boost.pageSizeScaleLadder.count {
            boost.pageSizeScale = boost.nextPageSizeScale
            seen.append(boost.pageSizeScale)
        }
        XCTAssertEqual(
            Set(seen), Set(Boost.pageSizeScaleLadder),
            "cycling must reach every stop exactly once before repeating"
        )
        XCTAssertEqual(boost.pageSizeScale, 1.0, "and must come back round to the original size")

        boost.pageSizeScale = 1.25
        XCTAssertEqual(boost.pageSizeButtonLabel, "125%")
    }

    func test_caseButton_cyclesAndWraps() {
        var state = BoostTextCase.original
        var seen: [BoostTextCase] = []
        for _ in 0..<BoostTextCase.allCases.count {
            state = state.next
            seen.append(state)
        }
        XCTAssertEqual(Set(seen), Set(BoostTextCase.allCases))
        XCTAssertEqual(state, .original)
    }

    func test_sharedPayloadWrittenWithoutTheVisualControls_stillDecodes() throws {
        let json = """
        {
          "formatVersion": 1,
          "name": "Hacker News",
          "host": "news.ycombinator.com",
          "zappedSelectors": ["#footer"],
          "customCSS": "body { max-width: 900px; }"
        }
        """
        let payload = try XCTUnwrap(BoostSharing.decode(Data(json.utf8)))

        XCTAssertEqual(payload.name, "Hacker News")
        XCTAssertEqual(payload.zappedSelectors, ["#footer"])
        XCTAssertFalse(payload.invertLightness)
        XCTAssertEqual(payload.pageSizeScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(payload.textCase, .original)
    }

    func test_sharedPayload_carriesTheVisualControls() throws {
        var boost = Boost(name: "Dark HN", host: "news.ycombinator.com")
        boost.invertLightness = true
        boost.pageSizeScale = 1.1
        boost.textCase = .lowercase

        guard case .success(let payload) = BoostSharing.makePayload(for: boost) else {
            return XCTFail("a CSS-only Boost must be shareable")
        }
        let data = try XCTUnwrap(BoostSharing.encode(payload))
        let decoded = try XCTUnwrap(BoostSharing.decode(data))

        XCTAssertTrue(decoded.invertLightness)
        XCTAssertEqual(decoded.pageSizeScale, 1.1, accuracy: 0.0001)
        XCTAssertEqual(decoded.textCase, .lowercase)
    }

    func test_importedPayload_appliesTheVisualControlsToTheNewBoost() throws {
        var source = Boost(name: "Dark HN", host: "news.ycombinator.com")
        source.invertLightness = true
        source.contrast = 1.3
        source.pageSizeScale = 1.5
        source.textCase = .capitalize

        guard case .success(let payload) = BoostSharing.makePayload(for: source) else {
            return XCTFail("a CSS-only Boost must be shareable")
        }
        let fileURL = scratchDirectory.appendingPathComponent("shared.orbitboost.json", isDirectory: false)
        try XCTUnwrap(BoostSharing.encode(payload)).write(to: fileURL, options: .atomic)

        let store = BoostStore(fileURL: boostsFileURL)
        let imported = try XCTUnwrap(BoostSharing.importPayload(from: fileURL, into: store))

        XCTAssertTrue(imported.invertLightness)
        XCTAssertEqual(imported.contrast, 1.3, accuracy: 0.0001)
        XCTAssertEqual(imported.pageSizeScale, 1.5, accuracy: 0.0001)
        XCTAssertEqual(imported.textCase, .capitalize)
    }

    func test_outOfRangeValues_areClamped() {
        var boost = Boost(name: "Clamp", host: "example.com")
        boost.pageSizeScale = 12
        boost.contrast = -5
        let css = BoostCompiler.compiledCSS(for: boost)

        XCTAssertTrue(css.contains("zoom: 1.5"), "page size must be held at the documented 150% ceiling")
        XCTAssertTrue(css.contains("contrast(0)"), "contrast must be held at its floor rather than emitted negative")
    }
}
