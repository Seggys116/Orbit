//  Neither model nor view tests exercise the real AppKit sizing mechanism
//  (NSHostingController.sizingOptions = [.preferredContentSize], as NSPopover.show uses).

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class ExtensionActionPopupHostingSizingTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.contentViewController = nil
            window.orderOut(nil)
            window.close()
        }
        windows = []
        super.tearDown()
    }

    private func makeModel() -> (ExtensionActionPopupModel, PopupHostingTestEngine) {
        let engine = PopupHostingTestEngine()
        let model = ExtensionActionPopupModel(
            engine: engine,
            session: engine.defaultSession,
            url: URL(string: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/popup.html")!
        )
        return (model, engine)
    }

    /// Hosts `model` the way `OrbitHoverPopover.Coordinator` configures a real
    /// popup's popover, in an off-screen window so layout settles with no screen/accessibility permission.
    private func settledPreferredContentSize(for model: ExtensionActionPopupModel) -> CGSize {
        let hostingController = NSHostingController(rootView: ExtensionActionPopupView(model: model))
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = hostingController

        for _ in 0..<4 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        return hostingController.preferredContentSize
    }

    // MARK: - Loading state

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_beforeAnyReport_theHostingControllersPreferredContentSizeIsThePopupLoadingSize

    func test_beforeAnyReport_theHostingControllersPreferredContentSizeIsThePopupLoadingSize() {
        let (model, _) = makeModel()
        model.start()

        XCTAssertEqual(
            settledPreferredContentSize(for: model), ExtensionActionPopupSupport.popupLoadingSize,
            "A popup with no preferred-size report yet must offer its real popover host the compact loading size, not the 320x420 default that used to flash a huge box before every small popup's first layout."
        )
    }

    // MARK: - The reported defect itself, at the AppKit chrome layer

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aToggleSizedReport_shrinksTheRealPopoverHostToExactlyThatSize

    func test_aToggleSizedReport_shrinksTheRealPopoverHostToExactlyThatSize() throws {
        let (model, engine) = makeModel()
        model.start()
        let contents = try XCTUnwrap(engine.lastCreatedContents)

        contents.reportPreferredSize(CGSize(width: 180, height: 64))

        let preferred = settledPreferredContentSize(for: model)
        XCTAssertEqual(
            preferred, CGSize(width: 180, height: 64),
            "The real NSHostingController.preferredContentSize (what NSPopover actually reads) did not shrink to the reported content size -- exactly the class of defect where the popover keeps showing at some larger fixed frame regardless of tiny real content."
        )
        XCTAssertLessThan(
            preferred.width, ExtensionActionPopupSupport.popupDefaultSize.width,
            "A toggle-sized popup must not fall back to the 320pt-wide default at the real popover host."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aGrowingReport_growsTheRealPopoverHostToTheLargerFrame

    func test_aGrowingReport_growsTheRealPopoverHostToTheLargerFrame() throws {
        let (model, engine) = makeModel()
        model.start()
        let contents = try XCTUnwrap(engine.lastCreatedContents)

        contents.reportPreferredSize(CGSize(width: 200, height: 120))
        contents.reportPreferredSize(CGSize(width: 200, height: 340))

        XCTAssertEqual(
            settledPreferredContentSize(for: model), CGSize(width: 200, height: 340),
            "A popup that grows after its first report (e.g. an async list rendering) must grow the real popover host with it, matching Chrome's own behaviour."
        )
    }

    // MARK: - Clamping survives the real host, not just the model

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anOversizedReport_clampsTheRealPopoverHostToChromesMaximum

    func test_anOversizedReport_clampsTheRealPopoverHostToChromesMaximum() throws {
        let (model, engine) = makeModel()
        model.start()
        let contents = try XCTUnwrap(engine.lastCreatedContents)

        contents.reportPreferredSize(CGSize(width: 5000, height: 5000))

        XCTAssertEqual(settledPreferredContentSize(for: model), ExtensionActionPopupSupport.popupMaximumSize)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anUndersizedReport_clampsTheRealPopoverHostUpToChromesMinimum

    func test_anUndersizedReport_clampsTheRealPopoverHostUpToChromesMinimum() throws {
        let (model, engine) = makeModel()
        model.start()
        let contents = try XCTUnwrap(engine.lastCreatedContents)

        contents.reportPreferredSize(CGSize(width: 2, height: 2))

        XCTAssertEqual(settledPreferredContentSize(for: model), ExtensionActionPopupSupport.popupMinimumSize)
    }

    // MARK: - The failure state is not left at the popup's stale web-content size

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aLoadFailure_hostsAtThePopupMessageWidth_notWhateverSizeWasReportedBeforeItFailed

    func test_aLoadFailure_hostsAtThePopupMessageWidth_notWhateverSizeWasReportedBeforeItFailed() throws {
        let (model, engine) = makeModel()
        model.start()
        let contents = try XCTUnwrap(engine.lastCreatedContents)
        contents.reportPreferredSize(CGSize(width: 700, height: 500))

        contents.delegate?.webContents(contents, didFailLoading: EngineError(code: .engineUnavailable, underlyingDescription: "no route"))

        let preferred = settledPreferredContentSize(for: model)
        XCTAssertEqual(preferred.width, ExtensionActionPopupSupport.popupMessageWidth, accuracy: 1)
    }
}

@MainActor
private final class PopupHostingTestEngine: BrowserEngine {
    static let kind: EngineKind = .chromium
    let capabilities: EngineCapabilities = [.extensions]
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation = .immediate
    let versionDescription = "Stub (ExtensionActionPopupHostingSizingTests — no real engine is running)"

    var failsToCreateContents = false
    private(set) var lastCreatedContents: MockWebContents?

    private lazy var stubSession = MockEngineSession(identifier: "popup-hosting", isPersistent: true)

    func start() throws {}
    func shutdown() -> Bool { true }
    func tick() {}

    func session(identifier: String, persistent: Bool) throws -> EngineSession { stubSession }
    var defaultSession: EngineSession { stubSession }

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        if failsToCreateContents {
            throw EngineError(code: .engineUnavailable, underlyingDescription: "stubbed failure")
        }
        let contents = MockWebContents(session: session)
        if let initialURL { contents.load(initialURL) }
        lastCreatedContents = contents
        return contents
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
