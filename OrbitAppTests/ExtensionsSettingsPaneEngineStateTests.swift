//  Sibling visual suites stop at the pure views extracted, never evaluating
//  ExtensionsSettingsPane.body's capabilitiesSupportExtensions gate; these mount the whole pane.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class ExtensionsSettingsPaneEngineStateTests: XCTestCase {

    private lazy var demoEnvironment: AppEnvironment = AppEnvironment.demo
    private let orbitEnvironment = AppEnvironment.shared
    private let engine = ChromiumLikeStubEngine()
    private var window: NSWindow?

    override func tearDown() {
        demoEnvironment._test_engineOverride = nil
        orbitEnvironment._test_engineOverride = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        super.tearDown()
    }

    // MARK: - 1. A running Chromium engine draws the real pane, in both environments

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theRealChromiumEngineAdvertisesExtensions

    func test_theRealChromiumEngineAdvertisesExtensions() {
        XCTAssertTrue(
            ChromiumEngine(storage: .isolated).capabilities.contains(.extensions),
            """
            ChromiumEngine no longer reports .extensions, so every extensions surface in the app \
            silently turns itself off. Chromium is the only engine Orbit embeds; if this is false, \
            the pane's "not running yet" state has become permanent rather than transient.
            """
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theOrbitEnvironmentWithARunningEngine_drawsTheInstallControls

    func test_theOrbitEnvironmentWithARunningEngine_drawsTheInstallControls() {
        orbitEnvironment._test_engineOverride = engine
        let window = hostExtensionsPane(env: orbitEnvironment)

        XCTAssertFalse(
            textFields(in: window).isEmpty,
            "The Extensions pane drew no install field for an engine that reports .extensions — the real pane is not being reached."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theDemoEnvironmentWithARunningEngine_drawsTheSameInstallControls

    func test_theDemoEnvironmentWithARunningEngine_drawsTheSameInstallControls() {
        demoEnvironment._test_engineOverride = engine
        let window = hostExtensionsPane(env: demoEnvironment)

        XCTAssertFalse(
            textFields(in: window).isEmpty,
            """
            The Extensions pane drew no install field in a demo environment whose engine reports \
            .extensions. The demo must render exactly the pane Orbit renders; anything else means \
            the demo is being handed a different AppEnvironment than the one that owns the engine.
            """
        )
    }

    // MARK: - 2. No engine yet: honest and transient, never a claim about a backend

    // ExtensionsSettingsPaneRowStatesVisualTests covers what this state *does* paint;
    // this covers what it must not offer.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anEnvironmentWithNoEngine_offersNoInstallControls
    func test_anEnvironmentWithNoEngine_offersNoInstallControls() {
        demoEnvironment._test_engineOverride = nil
        XCTAssertFalse(
            demoEnvironment.capabilitiesSupportExtensions,
            "This test needs an environment with no engine; something started one."
        )

        let window = hostExtensionsPane(env: demoEnvironment)

        XCTAssertTrue(
            textFields(in: window).isEmpty,
            "The Extensions pane offered an install field with no engine to install into."
        )
    }

    // MARK: - 3. One Settings surface, identical in both app entry points

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_bothAppEntryPointsDeclareTheSameSettingsScene

    func test_bothAppEntryPointsDeclareTheSameSettingsScene() throws {
        let orbit = try Self.settingsSceneBody(ofAppFile: "Orbit/OrbitApp.swift")
        let demo = try Self.settingsSceneBody(ofAppFile: "OrbitDemo/OrbitDemoApp.swift")

        XCTAssertEqual(
            orbit, demo,
            """
            Orbit and Orbit Demo declare different Settings scenes. There is one Settings surface; \
            two scene bodies is how the demo ended up showing a Settings window bound to a \
            different AppEnvironment than the one running the engine.
            """
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_neitherAppEntryPointBuildsItsOwnSettingsHierarchy

    func test_neitherAppEntryPointBuildsItsOwnSettingsHierarchy() throws {
        for file in ["Orbit/OrbitApp.swift", "OrbitDemo/OrbitDemoApp.swift"] {
            let body = try Self.settingsSceneBody(ofAppFile: file)
            XCTAssertFalse(
                body.contains("SettingsRootView"),
                """
                \(file)'s Settings scene builds SettingsRootView itself. A scene body is evaluated \
                while the scene graph is assembled — before OrbitAppDelegate points \
                AppEnvironment.processRoot at the environment that owns the engine — so whatever \
                environment it captures there is frozen into that window forever.
                """
            )
            XCTAssertFalse(
                body.contains("AppEnvironment"),
                "\(file)'s Settings scene names an AppEnvironment. Resolving one at scene-graph-build time is the defect; SettingsWindowController resolves it when the window is actually opened."
            )
            XCTAssertTrue(
                body.contains("SettingsSceneRedirectView"),
                "\(file)'s Settings scene no longer routes to the one Settings window."
            )
        }
    }

    // MARK: - 4. The deleted WebKit backend must not come back as prose

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noShippedSourceDescribesTheDeletedWebKitBackend

    func test_noShippedSourceDescribesTheDeletedWebKitBackend() throws {
        let phrases = ["WebKit fallback", "WKWebView", "Safari Web Extensions", "fallback backend", "fallback engine"]
        var offences: [String] = []

        for root in ["Orbit", "OrbitDemo"] {
            let directory = Self.repositoryRoot.appendingPathComponent(root, isDirectory: true)
            for fileURL in try Self.swiftFiles(under: directory) {
                guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                for phrase in phrases where contents.contains(phrase) {
                    offences.append("\(Self.relativePath(of: fileURL)): \"\(phrase)\"")
                }
            }
        }

        XCTAssertTrue(
            offences.isEmpty,
            """
            Orbit embeds Chromium and nothing else — there is no WebKit fallback backend, no \
            WKWebView and no Safari Web Extensions support to describe. The following \
            source(s) describe one anyway: \(offences.sorted().joined(separator: "; ")). \
            Every one of these is a branch or a string the user can be shown that is simply \
            untrue; delete it rather than rewording it.
            """
        )
    }

    // MARK: - Harness

    private func hostExtensionsPane(env: AppEnvironment, size: CGSize = CGSize(width: 720, height: 620)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ScrollView { ExtensionsSettingsPane().environment(env) })
        host.safeAreaRegions = []
        host.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.displayIfNeeded()
        pump(seconds: 0.4)
        self.window = window
        return window
    }

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func textFields(in window: NSWindow) -> [NSTextField] {
        allDescendants(of: window.contentView, ofType: NSTextField.self).filter(\.isEditable)
    }

    private func allDescendants<T: NSView>(of view: NSView?, ofType type: T.Type) -> [T] {
        guard let view else { return [] }
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for subview in view.subviews { result.append(contentsOf: allDescendants(of: subview, ofType: type)) }
        return result
    }

    // MARK: - Source lookup

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func relativePath(of url: URL) -> String {
        let root = repositoryRoot.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url)
        }
        return results
    }

    /// The text between `Settings {` and the matching closing brace.
    private static func settingsSceneBody(ofAppFile path: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(path)
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "Settings {") else {
            XCTFail("\(path) declares no `Settings {` scene, so nothing claims Cmd-, and the app has no scene at all.")
            return ""
        }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            if depth == 0 { break }
            index = source.index(after: index)
        }
        return source[start.upperBound..<index].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Stands in for a started ChromiumEngine: the capabilities the pane gates on,
/// none of the process the real one needs.
@MainActor
private final class ChromiumLikeStubEngine: BrowserEngine {
    static let kind: EngineKind = .chromium
    let capabilities: EngineCapabilities = [.extensions, .developerTools, .backgroundSnapshots]
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation = .immediate
    let versionDescription = "Stub (ExtensionsSettingsPaneEngineStateTests — no real engine is running)"

    private lazy var stubSession = MockEngineSession()

    func start() throws {}
    func shutdown() -> Bool { true }
    func tick() {}

    func session(identifier: String, persistent: Bool) throws -> EngineSession { stubSession }
    var defaultSession: EngineSession { stubSession }

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        throw EngineError(code: .engineUnavailable)
    }

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
    func addUserScript(_ script: UserScript, session: EngineSession) {}
    func removeUserScript(id: UUID, session: EngineSession) {}
    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}

    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
        throw EngineError(code: .engineUnavailable)
    }
    func unloadExtension(id: String, session: EngineSession) {}
    func loadedExtensions(session: EngineSession) -> [LoadedExtension] { [] }
}
