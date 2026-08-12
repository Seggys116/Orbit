//  Complements ExtensionActionPopupSizingTests.swift's model-level contract:
//  covers pixels rendered at loading size and after a real-size report.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class ExtensionActionPopupVisualTests: XCTestCase {

    // MARK: - Fixtures

    private static let popupURL = URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html")!

    private final class FakePopupEngine: BrowserEngine {
        static let kind: EngineKind = .chromium
        var capabilities: EngineCapabilities = [.extensions]
        var manageableContentSettings: Set<PermissionKind> = []
        var extensionActivation: ExtensionActivation = .nextLaunch
        var versionDescription = "FakePopupEngine (ExtensionActionPopupVisualTests -- no real engine is running)"
        var contentsToReturn: MockWebContents?

        func start() throws {}
        func shutdown() -> Bool { true }
        func tick() {}

        func session(identifier: String, persistent: Bool) throws -> EngineSession { MockEngineSession() }
        var defaultSession: EngineSession { MockEngineSession() }

        func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
            guard let contentsToReturn else { throw EngineError(code: .engineUnavailable) }
            return contentsToReturn
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

    private func makeModel(contents: MockWebContents) -> ExtensionActionPopupModel {
        let engine = FakePopupEngine()
        engine.contentsToReturn = contents
        return ExtensionActionPopupModel(engine: engine, session: MockEngineSession(), url: Self.popupURL)
    }

    // MARK: - ExtensionActionPopupSupport: sizing policy (zero coverage before this file)

    func test_clampedPopupSize_fallsBackToTheDefaultWhenGivenNoProposal() {
        XCTAssertEqual(ExtensionActionPopupSupport.clampedPopupSize(nil), ExtensionActionPopupSupport.popupDefaultSize)
    }

    func test_clampedPopupSize_neverShrinksBelowThePolicyMinimum() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.clampedPopupSize(CGSize(width: 1, height: 1)),
            ExtensionActionPopupSupport.popupMinimumSize
        )
    }

    func test_clampedPopupSize_neverGrowsBeyondThePolicyMaximum() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.clampedPopupSize(CGSize(width: 5000, height: 5000)),
            ExtensionActionPopupSupport.popupMaximumSize
        )
    }

    // A popup whose real content is small (icon-plus-toggle scale) must
    // survive clamping unchanged, not be forced back up toward a larger default.
    func test_clampedPopupSize_passesThroughAGenuinelyToggleSizedPopupUnchanged() {
        let toggleSized = CGSize(width: 180, height: 64)
        XCTAssertEqual(ExtensionActionPopupSupport.clampedPopupSize(toggleSized), toggleSized)
    }

    func test_popupLoadingSize_isSmallerThanThePopupDefaultSize() {
        // Exists so most popups don't flash a tall empty box before their
        // first preferred-size report -- see ExtensionActionPopupHosting.swift.
        let loading = ExtensionActionPopupSupport.popupLoadingSize
        let policyDefault = ExtensionActionPopupSupport.popupDefaultSize
        XCTAssertLessThan(loading.width, policyDefault.width)
        XCTAssertLessThan(loading.height, policyDefault.height)
        XCTAssertGreaterThanOrEqual(loading.width, ExtensionActionPopupSupport.popupMinimumSize.width)
        XCTAssertGreaterThanOrEqual(loading.height, ExtensionActionPopupSupport.popupMinimumSize.height)
    }

    // MARK: - ExtensionActionPopupSupport: gating (zero coverage before this file)

    func test_canShowActionIcon_requiresAPersistentSession() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowActionIcon(
                extensionID: "abcdefghijklmnopabcdefghijklmnop",
                isEnabled: true,
                hasToolbarAction: true,
                manifestKey: nil,
                actionPopupPath: "popup.html",
                sessionIsPersistent: false
            ),
            "An incognito-shaped session must never show a popup icon it cannot host -- chrome-extension:// navigations there answer ERR_BLOCKED_BY_CLIENT."
        )
    }

    func test_canShowActionIcon_requiresANonEmptyPopupPath() {
        XCTAssertFalse(ExtensionActionPopupSupport.canShowActionIcon(
            extensionID: "abcdefghijklmnopabcdefghijklmnop", isEnabled: true, hasToolbarAction: true,
            manifestKey: nil, actionPopupPath: nil, sessionIsPersistent: true
        ))
        XCTAssertFalse(ExtensionActionPopupSupport.canShowActionIcon(
            extensionID: "abcdefghijklmnopabcdefghijklmnop", isEnabled: true, hasToolbarAction: true,
            manifestKey: nil, actionPopupPath: "", sessionIsPersistent: true
        ))
    }

    func test_canShowActionIcon_requiresEnabledAndAToolbarAction() {
        XCTAssertFalse(ExtensionActionPopupSupport.canShowActionIcon(
            extensionID: "abcdefghijklmnopabcdefghijklmnop", isEnabled: false, hasToolbarAction: true,
            manifestKey: nil, actionPopupPath: "popup.html", sessionIsPersistent: true
        ))
        XCTAssertFalse(ExtensionActionPopupSupport.canShowActionIcon(
            extensionID: "abcdefghijklmnopabcdefghijklmnop", isEnabled: true, hasToolbarAction: false,
            manifestKey: nil, actionPopupPath: "popup.html", sessionIsPersistent: true
        ))
    }

    func test_isExtensionIDAddressable_rejectsAnIDThatDoesNotMatchItsOwnManifestKey() {
        XCTAssertFalse(ExtensionActionPopupSupport.isExtensionIDAddressable(
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            manifestKey: "not-a-real-key"
        ))
        XCTAssertFalse(ExtensionActionPopupSupport.isExtensionIDAddressable(
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            manifestKey: nil
        ))
    }

    func test_actionIconChoice_prefersActionIconThenExtensionIconThenGeneric() {
        XCTAssertEqual(ExtensionActionPopupSupport.actionIconChoice(hasActionIcon: true, hasExtensionIcon: true), .actionIcon)
        XCTAssertEqual(ExtensionActionPopupSupport.actionIconChoice(hasActionIcon: false, hasExtensionIcon: true), .extensionIcon)
        XCTAssertEqual(ExtensionActionPopupSupport.actionIconChoice(hasActionIcon: false, hasExtensionIcon: false), .genericGlyph)
    }

    func test_requiresRestartToActivate_isTheInverseOfIsActivatedInTheRunningEngine() {
        XCTAssertTrue(ExtensionActionPopupSupport.requiresRestartToActivate(isActivatedInRunningEngine: false))
        XCTAssertFalse(ExtensionActionPopupSupport.requiresRestartToActivate(isActivatedInRunningEngine: true))
    }

    func test_optionsPagePresentation_mapsTheManifestFlagToTabOrPanel() {
        XCTAssertEqual(ExtensionActionPopupSupport.optionsPagePresentation(optionsOpenInTab: true), .tab)
        XCTAssertEqual(ExtensionActionPopupSupport.optionsPagePresentation(optionsOpenInTab: false), .panel)
    }

    func test_settingsOptionsPageURL_isNilUntilTheExtensionIsActivatedInTheRunningEngine() {
        XCTAssertNil(ExtensionActionPopupSupport.settingsOptionsPageURL(
            extensionID: "abcdefghijklmnopabcdefghijklmnop", isEnabled: true, isActivatedInRunningEngine: false,
            manifestKey: nil, optionsPagePath: "options.html", sessionIsPersistent: true
        ))
    }

    // MARK: - ExtensionActionPopupModel: failure and teardown (complements the sizing-contract file)

    func test_model_setsAReadableFailureMessage_combiningHeadlineAndDetail() throws {
        let contents = MockWebContents()
        let model = makeModel(contents: contents)
        model.start()
        let error = EngineError(code: .engineUnavailable, underlyingDescription: "no route")

        contents.delegate?.webContents(contents, didFailLoading: error)

        let failure = try XCTUnwrap(model.loadFailure)
        XCTAssertTrue(failure.contains(error.headline))
        XCTAssertTrue(failure.contains("no route"))
    }

    func test_model_teardownIsSafeToCallTwice_andClearsContents() {
        let contents = MockWebContents()
        let model = makeModel(contents: contents)
        model.start()
        XCTAssertNotNil(model.contents)

        model.teardown()
        XCTAssertNil(model.contents)
        XCTAssertTrue(contents.isClosed)

        model.teardown()
    }

    // MARK: - ExtensionActionPopupView: rendered frame tracks model.contentSize exactly
    // ExtensionActionPopupSizingTests.swift proves model.contentSize is correct;
    // these prove the *view* renders at that size, not a larger fixed frame.

    func test_view_beforeAnyReport_rendersExactlyAtThePopupLoadingSize() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let contents = MockWebContents()
            let model = makeModel(contents: contents)
            model.start()
            let rendered = render(
                ExtensionActionPopupView(model: model).background(Color.red),
                size: CGSize(width: 500, height: 500),
                appearance: appearance
            )
            let box = rendered.boundingBoxOfContent()
            XCTAssertEqual(box?.width ?? -1, ExtensionActionPopupSupport.popupLoadingSize.width, accuracy: 1, "appearance \(appearance.rawValue)")
            XCTAssertEqual(box?.height ?? -1, ExtensionActionPopupSupport.popupLoadingSize.height, accuracy: 1, "appearance \(appearance.rawValue)")
        }
    }

    func test_view_afterAToggleSizedPreferredSizeReport_rendersExactlyThatFrame() {
        let contents = MockWebContents()
        let model = makeModel(contents: contents)
        model.start()
        contents.reportPreferredSize(CGSize(width: 180, height: 64))
        XCTAssertEqual(model.contentSize, CGSize(width: 180, height: 64), "precondition: the model itself must have adopted the report")

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                ExtensionActionPopupView(model: model).background(Color.red),
                size: CGSize(width: 500, height: 500),
                appearance: appearance
            )
            let box = rendered.boundingBoxOfContent()
            XCTAssertEqual(
                box?.width ?? -1, 180, accuracy: 1,
                "The rendered popup did not shrink to the reported content size in \(appearance.rawValue) -- exactly the class of defect where a popup keeps rendering at a large fixed frame regardless of tiny real content."
            )
            XCTAssertEqual(box?.height ?? -1, 64, accuracy: 1)
        }
    }

    func test_view_afterAGrowingReport_growsToTheLargerFrame_matchingChromesOwnBehaviour() {
        let contents = MockWebContents()
        let model = makeModel(contents: contents)
        model.start()
        contents.reportPreferredSize(CGSize(width: 200, height: 120))
        contents.reportPreferredSize(CGSize(width: 200, height: 340))

        let rendered = render(ExtensionActionPopupView(model: model).background(Color.red), size: CGSize(width: 500, height: 500), appearance: .darkAqua)
        let box = rendered.boundingBoxOfContent()
        XCTAssertEqual(box?.height ?? -1, 340, accuracy: 1, "A popup that grows after its first report (e.g. an async list rendering) must render at the grown size, not the stale first one.")
    }

    func test_view_rendersTheFailureMessage() {
        let contents = MockWebContents()
        let model = makeModel(contents: contents)
        model.start()
        contents.delegate?.webContents(contents, didFailLoading: EngineError(code: .engineUnavailable, underlyingDescription: "no route"))

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(ExtensionActionPopupView(model: model), size: CGSize(width: 320, height: 220), appearance: appearance)
            XCTAssertNotNil(rendered.boundingBoxOfContent(), "appearance \(appearance.rawValue)")
        }
    }

    func test_view_failureMessage_reportsThePopupMessageWidth() {
        let contents = MockWebContents()
        let model = makeModel(contents: contents)
        model.start()
        contents.delegate?.webContents(contents, didFailLoading: EngineError(code: .engineUnavailable, underlyingDescription: "no route"))

        let rendered = render(ExtensionActionPopupView(model: model).background(Color.red), size: CGSize(width: 500, height: 500), appearance: .darkAqua)
        let box = rendered.boundingBoxOfContent()
        XCTAssertEqual(box?.width ?? -1, ExtensionActionPopupSupport.popupMessageWidth, accuracy: 1)
    }

    // MARK: - ExtensionPendingActivationView (zero coverage before this file)
    // Shares ExtensionPopupMessageView with the load-failure state above, so
    // both are asserted against the same width token, keeping popup states visually consistent.

    func test_pendingActivationView_paintsSomethingInBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                ExtensionPendingActivationView(extensionName: "Test Extension"),
                size: CGSize(width: 300, height: 260),
                appearance: appearance
            )
            XCTAssertNotNil(rendered.boundingBoxOfContent(), "appearance \(appearance.rawValue)")
        }
    }

    func test_pendingActivationView_sharesThePopupMessageWidthWithTheFailureState() {
        let rendered = render(
            ExtensionPendingActivationView(extensionName: "Test Extension").background(Color.red),
            size: CGSize(width: 500, height: 500),
            appearance: .darkAqua
        )
        let box = rendered.boundingBoxOfContent()
        XCTAssertEqual(box?.width ?? -1, ExtensionActionPopupSupport.popupMessageWidth, accuracy: 1)
    }

    // MARK: - OrbitToggle: guards Orbit's own toggle against the "wildly out of scale" class of defect
    // The reported toggle was extension web content (fixed at the model/view
    // layer above), but the same defect class applies to Orbit's own OrbitToggle.

    func test_orbitToggle_onAndOffTracksAreVisuallyDistinct() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let size = CGSize(width: OrbitControlMetrics.toggleWidth, height: OrbitControlMetrics.toggleHeight)
            let on = render(OrbitToggle(accessibilityLabel: "t", isOn: .constant(true)), size: size, appearance: appearance)
            let off = render(OrbitToggle(accessibilityLabel: "t", isOn: .constant(false)), size: size, appearance: appearance)

            let sampleRect = CGRect(x: 2, y: 2, width: 6, height: OrbitControlMetrics.toggleHeight - 4)
            let onSample = on.averageColor(in: sampleRect)
            let offSample = off.averageColor(in: sampleRect)

            XCTAssertGreaterThan(
                Self.distance(onSample, offSample), 0.08,
                "On vs off must read as visually distinct at the toggle's own leading edge (appearance \(appearance.rawValue))."
            )
        }
    }

    func test_orbitToggle_neverRendersWiderOrTallerThanItsDeclaredMetrics() {
        let cases: [(width: CGFloat, height: CGFloat, isCompact: Bool)] = [
            (OrbitControlMetrics.toggleWidth, OrbitControlMetrics.toggleHeight, false),
            (OrbitControlMetrics.toggleCompactWidth, OrbitControlMetrics.toggleCompactHeight, true),
        ]
        for testCase in cases {
            let rendered = render(
                OrbitToggle(accessibilityLabel: "t", isOn: .constant(true), isCompact: testCase.isCompact).background(Color.red),
                size: CGSize(width: 200, height: 200),
                appearance: .darkAqua
            )
            let box = rendered.boundingBoxOfContent()
            XCTAssertEqual(
                box?.width ?? -1, testCase.width, accuracy: 1,
                "OrbitToggle (isCompact: \(testCase.isCompact)) rendered at a different width than its own declared metric -- exactly the 'wildly out of scale' class of defect reported for a toggle inside a popup."
            )
            XCTAssertEqual(box?.height ?? -1, testCase.height, accuracy: 1)
        }
    }

    // MARK: - Colour distance

    private static func distance(_ a: RGBA, _ b: RGBA) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        let da = a.a - b.a
        return (dr * dr + dg * dg + db * db + da * da).squareRoot()
    }
}
