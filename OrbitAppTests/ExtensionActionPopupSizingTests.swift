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

    func test_popoverContentSizeFollowsALaterPreferredSize() {
        let loading = ExtensionActionPopupSupport.popupLoadingSize
        let page = NSSize(width: 320, height: 240)
        XCTAssertEqual(
            OrbitHoverPopoverContentSize.next(current: NSSize(width: loading.width, height: loading.height), preferred: page),
            page,
            "The bubble is shown at the loading size. A page that then reports its own size has to resize that bubble."
        )
    }

    func test_popoverContentSizeIgnoresAnUnchangedOrEmptyPreferredSize() {
        let current = NSSize(width: 220, height: 148)
        XCTAssertNil(OrbitHoverPopoverContentSize.next(current: current, preferred: current))
        XCTAssertNil(OrbitHoverPopoverContentSize.next(current: current, preferred: .zero))
    }

    func test_beforeAnyReport_thePopupIsTheCompactLoadingSize() {
        let (model, _) = makeModel()
        model.start()

        XCTAssertFalse(model.hasReportedContentSize)
        XCTAssertEqual(model.contentSize, ExtensionActionPopupSupport.popupLoadingSize)
        XCTAssertLessThanOrEqual(
            ExtensionActionPopupSupport.popupLoadingSize.width, ExtensionActionPopupSupport.popupMinimumSize.width,
            "A loading viewport taller than the minimum is measured as the page height"
        )
        XCTAssertLessThanOrEqual(
            ExtensionActionPopupSupport.popupLoadingSize.height, ExtensionActionPopupSupport.popupMinimumSize.height
        )
    }

    func test_aDocumentDeclaringAKnownSizeProducesExactlyThatPopoverSize() throws {
        let (model, engine) = makeModel()
        model.start()

        let contents = try XCTUnwrap(engine.lastCreatedContents)
        contents.reportPreferredSize(CGSize(width: 220, height: 148))

        XCTAssertTrue(model.hasReportedContentSize)
        XCTAssertEqual(model.contentSize, CGSize(width: 220, height: 148))
        XCTAssertFalse(
            ExtensionActionPopupSupport.showsSpuriousScrollbars(
                content: CGSize(width: 220, height: 148), frame: model.contentSize
            ),
            "The frame must match the page. A taller frame, or one shorter by less than a scrollbar, scrolls on both axes."
        )
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

    func test_aFrameTallerThanThePageShowsSpuriousScrollbars() {
        let page = CGSize(width: 180, height: 64)
        let host = CGSize(width: 200, height: 112)
        XCTAssertTrue(
            ExtensionActionPopupSupport.showsSpuriousScrollbars(content: page, frame: host),
            "A host taller than the page is the loading-size bug: the observer reports the viewport, and the page scrolls inside it."
        )
        XCTAssertFalse(
            ExtensionActionPopupSupport.showsSpuriousScrollbars(
                content: page, frame: ExtensionActionPopupSupport.popupFrame(fitting: page)
            )
        )
    }

    func test_aFrameShorterThanThePageByLessThanAScrollbarShowsBothScrollbars() {
        let page = CGSize(width: 214, height: 132)
        let shortfall = ExtensionActionPopupSupport.popupScrollbarThickness / 2
        let short = CGSize(width: page.width - shortfall, height: page.height - shortfall)
        XCTAssertTrue(
            ExtensionActionPopupSupport.showsSpuriousScrollbars(content: page, frame: short),
            "Short by less than one scrollbar: the first bar shrinks the other axis and both appear."
        )
        let fitted = ExtensionActionPopupSupport.popupFrame(fitting: page)
        XCTAssertEqual(fitted, page)
        XCTAssertFalse(ExtensionActionPopupSupport.showsSpuriousScrollbars(content: page, frame: fitted))
    }

    func test_aPageTallerThanTheMaximumKeepsItsWidthClearOfTheVerticalScrollbar() {
        let page = CGSize(width: 384, height: 900)
        let frame = ExtensionActionPopupSupport.popupFrame(fitting: page)
        XCTAssertEqual(frame.height, ExtensionActionPopupSupport.popupMaximumSize.height, accuracy: 0.5)
        XCTAssertEqual(
            frame.width,
            page.width + ExtensionActionPopupSupport.popupScrollbarThickness,
            accuracy: 0.5,
            "The vertical bar takes width from the page. Without that width added back, the page scrolls sideways too."
        )
        XCTAssertFalse(page.width > frame.width + 0.5, "The document width fits, so there is no horizontal scroll.")
    }

    func test_aPageLargerThanTheMaximumMayScroll() {
        let page = CGSize(width: 3000, height: 3000)
        let frame = ExtensionActionPopupSupport.popupFrame(fitting: page)
        XCTAssertEqual(frame, ExtensionActionPopupSupport.popupMaximumSize)
        XCTAssertFalse(
            ExtensionActionPopupSupport.showsSpuriousScrollbars(content: page, frame: frame),
            "Past the maximum the page is supposed to scroll; that overflow is larger than a scrollbar."
        )
    }

    func test_screenClampSubtractsPopoverChromeOnce() {
        let screen = CGSize(width: 420, height: 360)
        let frame = ExtensionActionPopupSupport.popupFrame(fitting: CGSize(width: 3000, height: 3000), on: screen)
        XCTAssertEqual(frame.width, screen.width - ExtensionActionPopupSupport.popupWindowChrome.width, accuracy: 0.5)
        XCTAssertEqual(frame.height, screen.height - ExtensionActionPopupSupport.popupWindowChrome.height, accuracy: 0.5)
        let paddedTwice = CGSize(
            width: frame.width - ExtensionActionPopupSupport.popupWindowChrome.width,
            height: frame.height - ExtensionActionPopupSupport.popupWindowChrome.height
        )
        XCTAssertNotEqual(frame, paddedTwice)
    }

    func test_aViewportSizedReportIsReplacedWithTheMeasuredPage() async throws {
        let (model, engine) = makeModel()
        model.start()
        let contents = try XCTUnwrap(engine.lastCreatedContents)
        contents.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        contents.evaluateJavaScriptHandler = { _ in "214x132" }

        contents.reportPreferredSize(CGSize(width: 800, height: 600))

        XCTAssertFalse(
            model.hasReportedContentSize,
            "800×600 is the web view, measured before the page laid out. Adopting it leaves both scroll bars."
        )
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.hasReportedContentSize, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let page = CGSize(width: 214, height: 132)
        XCTAssertEqual(model.contentSize, page)
        XCTAssertFalse(model.scrollsHorizontally)
        XCTAssertFalse(model.scrollsVertically)
        XCTAssertFalse(ExtensionActionPopupSupport.showsSpuriousScrollbars(content: page, frame: model.contentSize))
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
    static let kind: EngineKind = .webkit
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
