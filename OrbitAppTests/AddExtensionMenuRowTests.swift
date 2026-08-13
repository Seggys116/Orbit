import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class AddExtensionMenuRowTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?
    private let engine = StubExtensionsCapableEngine()

    override func setUp() {
        super.setUp()
        env._test_engineOverride = engine
    }

    override func tearDown() {
        SettingsRouter.shared.consumeFocusRequest(.extensionInstallField)
        env._test_engineOverride = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        super.tearDown()
    }

    // MARK: - 1. The menu carries both of Arc's rows

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theExtensionsMenuOffersAddExtensionAboveManageExtensions

    func test_theExtensionsMenuOffersAddExtensionAboveManageExtensions() throws {
        let extensionsMenu = try XCTUnwrap(
            MainMenuBuilder.build().items.compactMap(\.submenu).first { $0.title == "Extensions" },
            "The menu bar has no Extensions menu (refs/reference/arc-mainmenu-nib-dump.txt:191)."
        )

        XCTAssertEqual(
            extensionsMenu.items.map(\.title),
            ["Add Extension…", "Manage Extensions…"],
            "Arc's own two rows, in Arc's own order (nib 192-193). Add Extension… was the one previously left unbuilt."
        )
        for row in extensionsMenu.items {
            XCTAssertNotNil(row.action, "'\(row.title)' carries no action, so choosing it would do nothing.")
            XCTAssertNotNil(row.target, "'\(row.title)' carries no target, so choosing it would do nothing.")
        }
    }

    // MARK: - 2. The focus request the row makes

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aRepeatedRequestIsADistinctRequest

    func test_aRepeatedRequestIsADistinctRequest() {
        SettingsRouter.shared.requestFocus(.extensionInstallField)
        let first = SettingsRouter.shared.focusRequest?.token
        SettingsRouter.shared.requestFocus(.extensionInstallField)
        let second = SettingsRouter.shared.focusRequest?.token

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second, "Two consecutive Add Extension… choices must be two distinct requests, or the second one is silently swallowed.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theOwningPaneCanClearTheRequest

    func test_theOwningPaneCanClearTheRequest() {
        SettingsRouter.shared.requestFocus(.extensionInstallField)
        SettingsRouter.shared.consumeFocusRequest(.extensionInstallField)
        XCTAssertNil(SettingsRouter.shared.focusRequest, "The pane that owns the target must be able to clear it.")
    }

    // MARK: - 3. The caret really lands in the install field

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aMountedExtensionsPaneWithAPendingRequestPutsTheCaretInTheInstallField

    func test_aMountedExtensionsPaneWithAPendingRequestPutsTheCaretInTheInstallField() {
        SettingsRouter.shared.requestFocus(.extensionInstallField)

        let window = hostExtensionsPane(size: CGSize(width: 720, height: 620))
        pump(seconds: 0.5)

        XCTAssertNil(
            SettingsRouter.shared.focusRequest,
            """
            The mounted Extensions pane never consumed the focus request, so nothing in it reacted \
            to Add Extension… at all — the row would open Settings and leave the caret wherever it \
            happened to be.
            """
        )

        let fields = allDescendants(of: window.contentView, ofType: NSTextField.self)
        XCTAssertFalse(
            fields.isEmpty,
            "The Extensions pane rendered no text field at all, so this test is measuring the wrong tree — check that the stub engine still advertises .extensions."
        )
        XCTAssertTrue(
            isEditingAField(in: window),
            """
            Nothing in the Extensions pane took the caret. `Add Extension…` promises to land in the \
            field an extension is installed from; a pane that merely opened would leave the user \
            hunting for the control the menu item named, which is what this row was written to avoid.
            """
        )
    }

    // MARK: - Harness

    /// Checked against the real `NSWindow.firstResponder`, not `@FocusState`:
    /// a misplaced `.focused(_:)` can set that flag without focusing anything.
    private func isEditingAField(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSTextView else { return false }
        return responder.isFieldEditor || responder.delegate is NSTextField
    }

    private func hostExtensionsPane(size: CGSize) -> NSWindow {
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
        self.window = window
        return window
    }

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func allDescendants<T: NSView>(of view: NSView?, ofType type: T.Type) -> [T] {
        guard let view else { return [] }
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for subview in view.subviews { result.append(contentsOf: allDescendants(of: subview, ofType: type)) }
        return result
    }
}

/// Makes `AppEnvironment.capabilitiesSupportExtensions` answer `true` without
/// starting a real engine, so `ExtensionsSettingsPane` draws its install section.
@MainActor
private final class StubExtensionsCapableEngine: BrowserEngine {
    static let kind: EngineKind = .chromium
    let capabilities: EngineCapabilities = [.extensions]
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation = .nextLaunch
    let versionDescription = "Stub (AddExtensionMenuRowTests — no real engine is running)"

    private lazy var session = MockEngineSession()

    func start() throws {}
    func shutdown() -> Bool { true }
    func tick() {}

    func session(identifier: String, persistent: Bool) throws -> EngineSession { session }
    var defaultSession: EngineSession { session }

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
