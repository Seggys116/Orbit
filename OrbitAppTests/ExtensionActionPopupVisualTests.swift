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

    // Toggle-sized popups must survive clamping unchanged.
    func test_clampedPopupSize_passesThroughAGenuinelyToggleSizedPopupUnchanged() {
        let toggleSized = CGSize(width: 180, height: 64)
        XCTAssertEqual(ExtensionActionPopupSupport.clampedPopupSize(toggleSized), toggleSized)
    }

    func test_popupLoadingSize_isSmallerThanThePopupDefaultSize() {
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
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let detailed = renderFailure(detail: "no route", appearance: appearance)
            let sameAgain = renderFailure(detail: "no route", appearance: appearance)
            let otherDetail = renderFailure(
                detail: "the staging directory disappeared while the popup was still opening",
                appearance: appearance
            )
            let canvas = CGRect(origin: .zero, size: Self.failureCanvas)

            XCTAssertFalse(
                Self.regionsDiffer(detailed, sameAgain, in: canvas),
                "Two renders of the same failure differ, so nothing below is a reliable signal (appearance \(appearance.rawValue))."
            )

            let bands = Self.inkBands(detailed)
            guard let glyphBand = bands.first else {
                XCTFail("The failure popup painted nothing at all in \(appearance.rawValue).")
                continue
            }
            XCTAssertGreaterThanOrEqual(
                bands.count, 2,
                "The failure popup painted one band of ink -- its warning glyph and no message, so model.loadFailure never reached the screen (appearance \(appearance.rawValue))."
            )

            let glyph = CGRect(x: 0, y: 0, width: Self.failureCanvas.width, height: CGFloat(glyphBand.upperBound))
            let message = CGRect(
                x: 0, y: CGFloat(glyphBand.upperBound),
                width: Self.failureCanvas.width, height: Self.failureCanvas.height - CGFloat(glyphBand.upperBound)
            )
            XCTAssertFalse(
                Self.regionsDiffer(detailed, otherDetail, in: glyph),
                "The warning glyph itself moved with the failure detail in \(appearance.rawValue); the comparison below no longer isolates the message."
            )
            XCTAssertTrue(
                Self.regionsDiffer(detailed, otherDetail, in: message),
                "Two different failure details render identical pixels below the glyph in \(appearance.rawValue) -- the popup is not painting model.loadFailure."
            )
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

    // MARK: - ExtensionPendingActivationView

    func test_pendingActivationView_paintsSomethingInBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                ExtensionPendingActivationView(extensionName: "Test Extension"),
                size: Self.pendingCanvas,
                appearance: appearance
            )
            let renamed = render(
                ExtensionPendingActivationView(extensionName: "A Quite Differently Named Extension"),
                size: Self.pendingCanvas,
                appearance: appearance
            )

            let bands = Self.inkBands(rendered)
            guard let glyphBand = bands.first, let controlBand = bands.last, bands.count >= 3 else {
                XCTFail("The pending-activation popup painted \(bands.count) band(s) of ink in \(appearance.rawValue); it needs a glyph, a message and the Restart Orbit button.")
                continue
            }

            let glyph = Self.bandMetrics(rendered, glyphBand)
            XCTAssertGreaterThan(
                glyph.chroma, 0.1,
                "The pending-activation glyph sampled \(glyph.averageColor) in \(appearance.rawValue) -- it is not painting the .orange tint that marks this state apart from a plain failure."
            )

            let control = Self.bandMetrics(rendered, controlBand)
            XCTAssertGreaterThan(
                control.density, 0.8,
                "The last band of ink in \(appearance.rawValue) is \(control.density) filled -- that is another line of text, not the filled Restart Orbit button."
            )
            XCTAssertGreaterThanOrEqual(control.longestRun, 50, "The Restart Orbit button's fill runs only \(control.longestRun)pt wide in \(appearance.rawValue).")
            XCTAssertGreaterThan(control.chroma, 0.1, "The Restart Orbit button sampled \(control.averageColor) in \(appearance.rawValue), not a primary accent fill.")

            let glyphRect = CGRect(x: 0, y: 0, width: Self.pendingCanvas.width, height: CGFloat(glyphBand.upperBound))
            let messageRect = CGRect(
                x: 0, y: CGFloat(glyphBand.upperBound),
                width: Self.pendingCanvas.width, height: Self.pendingCanvas.height - CGFloat(glyphBand.upperBound)
            )
            XCTAssertFalse(
                Self.regionsDiffer(rendered, renamed, in: glyphRect),
                "The glyph moved with the extension name in \(appearance.rawValue); the comparison below no longer isolates the message."
            )
            XCTAssertTrue(
                Self.regionsDiffer(rendered, renamed, in: messageRect),
                "Renaming the extension changed nothing below the glyph in \(appearance.rawValue) -- the notice never names the extension it is about."
            )
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

    // MARK: - OrbitToggle

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

    // MARK: - Ink measurement

    private static let failureCanvas = CGSize(width: 320, height: 220)
    private static let pendingCanvas = CGSize(width: 300, height: 260)

    private func renderFailure(detail: String, appearance: NSAppearance.Name) -> RenderedImage {
        let contents = MockWebContents()
        let model = makeModel(contents: contents)
        model.start()
        contents.delegate?.webContents(contents, didFailLoading: EngineError(code: .engineUnavailable, underlyingDescription: detail))
        return render(ExtensionActionPopupView(model: model), size: Self.failureCanvas, appearance: appearance)
    }

    private static func inkBands(_ image: RenderedImage) -> [Range<Int>] {
        var bands: [Range<Int>] = []
        var start: Int?
        for y in 0..<Int(image.pointSize.height) {
            var hasInk = false
            for x in 0..<Int(image.pointSize.width) where image.color(atX: x, y: y).a > 0.04 {
                hasInk = true
                break
            }
            if hasInk, start == nil { start = y }
            if !hasInk, let began = start {
                bands.append(began..<y)
                start = nil
            }
        }
        if let began = start { bands.append(began..<Int(image.pointSize.height)) }
        return bands
    }

    private static func bandMetrics(
        _ image: RenderedImage,
        _ band: Range<Int>
    ) -> (density: Double, longestRun: Int, averageColor: RGBA, chroma: Double) {
        var minX = Int.max
        var maxX = 0
        var ink = 0
        var longestRun = 0
        for y in band {
            var run = 0
            for x in 0..<Int(image.pointSize.width) {
                if image.color(atX: x, y: y).a > 0.04 {
                    ink += 1
                    run += 1
                    longestRun = max(longestRun, run)
                    minX = min(minX, x)
                    maxX = max(maxX, x + 1)
                } else {
                    run = 0
                }
            }
        }
        guard minX < maxX else { return (0, 0, .clear, 0) }
        let average = image.averageColor(in: CGRect(x: minX, y: band.lowerBound, width: maxX - minX, height: band.count))
        return (
            Double(ink) / Double(band.count * (maxX - minX)),
            longestRun,
            average,
            max(average.r, max(average.g, average.b)) - min(average.r, min(average.g, average.b))
        )
    }

    private static func regionsDiffer(_ a: RenderedImage, _ b: RenderedImage, in rect: CGRect) -> Bool {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where !a.color(atX: x, y: y).isApproximately(b.color(atX: x, y: y), tolerance: 0.02) {
                return true
            }
        }
        return false
    }

    private static func distance(_ a: RGBA, _ b: RGBA) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        let da = a.a - b.a
        return (dr * dr + dg * dg + db * db + da * da).squareRoot()
    }
}
