//  An extension popup is sized by the renderer, not its host: the model puts
//  its WebContents into auto-resize mode and adopts what comes back. Before
//  that, popup.html was laid out at a fixed 320x420, rendering a 200pt-wide document's controls at 320pt.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ExtensionActionPopupSizingTests: XCTestCase {

    private func makeModel() -> (ExtensionActionPopupModel, PopupTestEngine) {
        let engine = PopupTestEngine()
        let model = ExtensionActionPopupModel(
            engine: engine,
            session: engine.defaultSession,
            url: URL(string: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/popup.html")!
        )
        return (model, engine)
    }

    func test_start_putsTheContentsIntoAutoResizeAtChromesPopupBounds() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        let bounds = try XCTUnwrap(contents.contentSizingBounds)
        XCTAssertEqual(bounds.minimum, ExtensionActionPopupSupport.popupMinimumSize)
        XCTAssertEqual(bounds.maximum, ExtensionActionPopupSupport.popupMaximumSize)
    }

    func test_start_requestsContentSizingBeforeNavigating() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        XCTAssertNotNil(
            contents.contentSizingBounds,
            "auto-resize must be on before the first navigation, or the first layout is done at the host's size"
        )
        XCTAssertNotNil(contents.navigationState.url, "the popup URL should still have been loaded")
    }

    func test_beforeAnyReport_thePopupIsTheCompactLoadingSize() {
        let (model, _) = makeModel()
        model.start()

        XCTAssertFalse(model.hasReportedContentSize)
        XCTAssertEqual(model.contentSize, ExtensionActionPopupSupport.popupLoadingSize)
    }

    func test_aDocumentDeclaringAKnownSizeProducesExactlyThatPopoverSize() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        contents.reportPreferredSize(CGSize(width: 220, height: 148))

        XCTAssertTrue(model.hasReportedContentSize)
        XCTAssertEqual(model.contentSize, CGSize(width: 220, height: 148))
    }

    func test_aReportBelowChromesMinimumIsClampedUp() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        contents.reportPreferredSize(CGSize(width: 4, height: 4))

        XCTAssertEqual(model.contentSize, ExtensionActionPopupSupport.popupMinimumSize)
    }

    func test_aReportAboveChromesMaximumIsClampedDown() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        contents.reportPreferredSize(CGSize(width: 3000, height: 3000))

        XCTAssertEqual(model.contentSize, ExtensionActionPopupSupport.popupMaximumSize)
    }

    func test_aLaterReportReplacesTheEarlierOne() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        contents.reportPreferredSize(CGSize(width: 200, height: 100))
        contents.reportPreferredSize(CGSize(width: 200, height: 340))

        XCTAssertEqual(
            model.contentSize,
            CGSize(width: 200, height: 340),
            "a popup that grows after load (an async list rendering) must grow with it, as it does in Chrome"
        )
    }

    func test_aDegenerateReportIsIgnoredRatherThanCollapsingThePopup() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        contents.reportPreferredSize(CGSize(width: 240, height: 160))
        contents.reportPreferredSize(CGSize(width: 0, height: 0))

        XCTAssertEqual(model.contentSize, CGSize(width: 240, height: 160))
    }

    func test_teardownClosesTheContents() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        model.teardown()

        XCTAssertTrue(contents.isClosed)
        XCTAssertNil(model.contents)
    }

    func test_aFailingEngineSurfacesAFailureInsteadOfAnEmptyPopup() {
        let engine = PopupTestEngine()
        engine.failsToCreateContents = true
        let model = ExtensionActionPopupModel(
            engine: engine,
            session: engine.defaultSession,
            url: URL(string: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/popup.html")!
        )
        model.start()

        XCTAssertNil(model.contents)
        XCTAssertNotNil(model.loadFailure)
    }
}

@MainActor
private final class PopupTestEngine: BrowserEngine {
    static let kind: EngineKind = .chromium
    let capabilities: EngineCapabilities = [.extensions]
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation = .immediate
    let versionDescription = "Stub (ExtensionActionPopupSizingTests — no real engine is running)"

    var failsToCreateContents = false
    private(set) var lastCreatedContents: MockWebContents?

    private lazy var stubSession = MockEngineSession(identifier: "popup", isPersistent: true)

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
