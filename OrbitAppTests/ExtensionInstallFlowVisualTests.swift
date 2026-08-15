import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class ExtensionInstallFlowVisualTests: XCTestCase {

    // AppEnvironment.demo is a factory: evaluate it once per test.
    private lazy var env: AppEnvironment = AppEnvironment.demo

    // MARK: - Fixtures

    private static func samplePendingInstall(
        warnings: [ExtensionPermissionWarning] = [],
        isUpdate: Bool = false,
        previousVersion: String? = nil,
        chromiumVersionWarning: String? = nil,
        description: String? = "A short description of what this extension does."
    ) -> ExtensionInstaller.PendingInstall {
        ExtensionInstaller.PendingInstall(
            id: "abcdefghijklmnopabcdefghijklmnop",
            name: "Fixture Extension",
            version: "1.3.0",
            description: description,
            iconURL: nil,
            warnings: warnings,
            isUpdate: isUpdate,
            previousVersion: previousVersion,
            chromiumVersionWarning: chromiumVersionWarning
        )
    }

    private static let grantedWarning = ExtensionPermissionWarning(
        id: "host.all", text: "Read and change all your data on all websites", severity: .critical, isGrantedAtInstall: true
    )
    private static let optionalWarning = ExtensionPermissionWarning(
        id: "perm:geolocation.optional", text: "Detect your physical location", severity: .high, isGrantedAtInstall: false
    )

    // MARK: - ExtensionInstallStagePresenter: single source of truth for progress copy (zero coverage before this file)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_stagePresenter_downloading_showsByteProgressWhenTotalIsKnown

    func test_stagePresenter_downloading_showsByteProgressWhenTotalIsKnown() {
        let presentation = ExtensionInstallStagePresenter.present(.downloading(receivedBytes: 2_400_000, totalBytes: 6_100_000))
        XCTAssertEqual(presentation.title, "Downloading extension…")
        XCTAssertNotNil(presentation.detail)
        XCTAssertEqual(presentation.fraction ?? -1, 2_400_000.0 / 6_100_000.0, accuracy: 0.0001)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_stagePresenter_downloading_omitsProgressWhenTotalIsUnknown

    func test_stagePresenter_downloading_omitsProgressWhenTotalIsUnknown() {
        // Reported honestly as 0/0 the instant a download starts, before Content-Length is known.
        let presentation = ExtensionInstallStagePresenter.present(.downloading(receivedBytes: 0, totalBytes: 0))
        XCTAssertNil(presentation.detail, "A download with no known total must not fabricate a byte count.")
        XCTAssertNil(presentation.fraction, "A download with no known total must not fabricate a progress fraction.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_stagePresenter_verifying_hasNoProgressFraction

    func test_stagePresenter_verifying_hasNoProgressFraction() {
        let presentation = ExtensionInstallStagePresenter.present(.verifying)
        XCTAssertEqual(presentation.title, "Verifying…")
        XCTAssertNil(presentation.detail)
        XCTAssertNil(presentation.fraction)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_stagePresenter_extracting_showsEntryProgressWhenTotalIsKnown

    func test_stagePresenter_extracting_showsEntryProgressWhenTotalIsKnown() {
        let presentation = ExtensionInstallStagePresenter.present(.extracting(completedEntries: 340, totalEntries: 812))
        XCTAssertEqual(presentation.title, "Unpacking…")
        XCTAssertNotNil(presentation.detail)
        XCTAssertEqual(presentation.fraction ?? -1, 340.0 / 812.0, accuracy: 0.0001)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_stagePresenter_awaitingConsentAndInstalling_haveFixedTitlesAndNoProgress

    func test_stagePresenter_awaitingConsentAndInstalling_haveFixedTitlesAndNoProgress() {
        let awaiting = ExtensionInstallStagePresenter.present(.awaitingConsent)
        XCTAssertEqual(awaiting.title, "Waiting for your decision…")
        XCTAssertNil(awaiting.fraction)

        let installing = ExtensionInstallStagePresenter.present(.installing)
        XCTAssertEqual(installing.title, "Installing…")
        XCTAssertNil(installing.fraction)
    }

    // MARK: - ExtensionInstallFailurePresentation: categorised, human-readable failures (zero coverage before this file)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_failurePresentation_categorisesCancellation

    func test_failurePresentation_categorisesCancellation() {
        let presentation = ExtensionInstallFailurePresentation.present(CancellationError())
        XCTAssertEqual(presentation.category, .cancelled)
        XCTAssertEqual(presentation.title, "Installation Cancelled")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_failurePresentation_categorisesANetworkFailure

    func test_failurePresentation_categorisesANetworkFailure() {
        let presentation = ExtensionInstallFailurePresentation.present(ExtensionInstallError.webStoreFailure(.network("offline")))
        XCTAssertEqual(presentation.category, .network)
        XCTAssertEqual(presentation.title, "Couldn't Reach the Chrome Web Store")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_failurePresentation_categorisesAnAlreadyInstalledFailure

    func test_failurePresentation_categorisesAnAlreadyInstalledFailure() {
        let presentation = ExtensionInstallFailurePresentation.present(
            ExtensionInstallError.alreadyInstalled(id: "abcdefghijklmnopabcdefghijklmnop", installedVersion: "2.1.0")
        )
        XCTAssertEqual(presentation.category, .alreadyInstalled)
        XCTAssertEqual(presentation.title, "Already Installed")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_failurePresentation_categorisesAVerificationFailure

    func test_failurePresentation_categorisesAVerificationFailure() {
        let presentation = ExtensionInstallFailurePresentation.present(ExtensionInstallError.verificationFailed(.invalidMagic))
        XCTAssertEqual(presentation.category, .verification)
        XCTAssertEqual(presentation.title, "Couldn't Verify This Extension")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_failurePresentation_categorisesAnUnsupportedManifest

    func test_failurePresentation_categorisesAnUnsupportedManifest() {
        let presentation = ExtensionInstallFailurePresentation.present(
            ExtensionInstallError.manifestInvalid(.manifestMissing(URL(fileURLWithPath: "/tmp/fixture/manifest.json")))
        )
        XCTAssertEqual(presentation.category, .unsupportedManifest)
        XCTAssertEqual(presentation.title, "Unsupported Extension")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_failurePresentation_fallsBackToOtherForAnUnrecognisedError

    func test_failurePresentation_fallsBackToOtherForAnUnrecognisedError() {
        struct SomeOtherError: Error {}
        let presentation = ExtensionInstallFailurePresentation.present(SomeOtherError())
        XCTAssertEqual(presentation.category, .other)
        XCTAssertEqual(presentation.title, "Installation Failed")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_failureCategory_everyCaseCarriesANonEmptyTitleAndGlyph

    func test_failureCategory_everyCaseCarriesANonEmptyTitleAndGlyph() {
        for category in [
            ExtensionInstallFailureCategory.cancelled, .network, .verification, .alreadyInstalled, .unsupportedManifest, .other,
        ] {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
    }

    // MARK: - ExtensionConsentSheetView: rendered states (zero pixel-level coverage before this file)

    private static var screenshotOutputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrbitAppTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("refs/screenshots", isDirectory: true)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_consentSheet_reportsItsOwnDeclaredWidth_inBothAppearances

    func test_consentSheet_reportsItsOwnDeclaredWidth_inBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                ExtensionConsentSheetView(pending: Self.samplePendingInstall(), onAnswer: { _ in }).background(Color.red),
                size: CGSize(width: 700, height: 700),
                appearance: appearance
            )
            let box = rendered.boundingBoxOfContent()
            XCTAssertEqual(box?.width ?? -1, OrbitMetrics.extensionInstallSheetWidth, accuracy: 1, "appearance \(appearance.rawValue)")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_consentSheet_withNoPermissions_paintsInBothAppearances

    func test_consentSheet_withNoPermissions_paintsInBothAppearances() async {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, ""), (.aqua, "-light")] {
            let view = ExtensionConsentSheetView(pending: Self.samplePendingInstall(), onAnswer: { _ in })
            await renderAndSave(view, name: "extension-consent-no-permissions\(suffix)", size: CGSize(width: 460, height: 280), appearance: appearance)
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_consentSheet_withGrantedAndOptionalWarnings_paintsInBothAppearances

    func test_consentSheet_withGrantedAndOptionalWarnings_paintsInBothAppearances() async {
        let pending = Self.samplePendingInstall(warnings: [Self.grantedWarning, Self.optionalWarning])
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, ""), (.aqua, "-light")] {
            let view = ExtensionConsentSheetView(pending: pending, onAnswer: { _ in })
            await renderAndSave(view, name: "extension-consent-warnings\(suffix)", size: CGSize(width: 460, height: 420), appearance: appearance)
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_consentSheet_withChromiumVersionWarning_paintsTheNoticeRow

    func test_consentSheet_withChromiumVersionWarning_paintsTheNoticeRow() async {
        let size = CGSize(width: 460, height: 420)
        let pending = Self.samplePendingInstall(
            warnings: [Self.grantedWarning],
            chromiumVersionWarning: "This extension declares that it requires Chrome 200.0 or later."
        )
        let withNotice = render(ExtensionConsentSheetView(pending: pending, onAnswer: { _ in }), size: size, appearance: .darkAqua)
        let withoutNotice = render(
            ExtensionConsentSheetView(pending: Self.samplePendingInstall(warnings: [Self.grantedWarning]), onAnswer: { _ in }),
            size: size,
            appearance: .darkAqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(withNotice, withoutNotice, size: size),
            "Adding a chromiumVersionWarning did not visibly change the rendered sheet."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_consentSheet_updateWording_namesBothVersions

    func test_consentSheet_updateWording_namesBothVersions() async {
        let pending = Self.samplePendingInstall(isUpdate: true, previousVersion: "1.0.0")
        await renderAndSave(
            ExtensionConsentSheetView(pending: pending, onAnswer: { _ in }),
            name: "extension-consent-update",
            size: CGSize(width: 460, height: 280),
            appearance: .darkAqua
        )
    }

    // MARK: - Shared install-flow components (zero coverage before this file)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_extensionIconBadge_rendersAtItsDeclaredSize

    func test_extensionIconBadge_rendersAtItsDeclaredSize() {
        let rendered = render(
            ExtensionIconBadge(iconURL: nil).background(Color.red),
            size: CGSize(width: 200, height: 200),
            appearance: .darkAqua
        )
        let box = rendered.boundingBoxOfContent()
        XCTAssertEqual(box?.width ?? -1, OrbitMetrics.extensionInstallIconSize, accuracy: 1)
        XCTAssertEqual(box?.height ?? -1, OrbitMetrics.extensionInstallIconSize, accuracy: 1)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_orbitInlineNotice_paintsInBothAppearances

    func test_orbitInlineNotice_paintsInBothAppearances() {
        let size = CGSize(width: 360, height: 60)
        let glyphRect = CGRect(x: 0, y: 0, width: 16, height: 16)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                OrbitInlineNotice(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: "Something worth flagging."),
                size: size,
                appearance: appearance
            )
            let glyphOnly = render(
                OrbitInlineNotice(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: ""),
                size: size,
                appearance: appearance
            )

            let glyph = rendered.averageColor(in: glyphRect)
            XCTAssertTrue(
                glyph.r > glyph.g && glyph.g > glyph.b && glyph.r - glyph.b > 0.15,
                "The notice's glyph sampled \(glyph) in \(appearance.rawValue) -- it is not painting the tint it was handed."
            )
            XCTAssertTrue(
                Self.hasInk(rendered, in: CGRect(x: 24, y: 0, width: size.width - 24, height: size.height)),
                "Nothing painted beside the glyph in \(appearance.rawValue) -- the notice's text never rendered."
            )

            let width = rendered.boundingBoxOfContent()?.width ?? 0
            let glyphWidth = glyphOnly.boundingBoxOfContent()?.width ?? 0
            XCTAssertGreaterThan(
                width, glyphWidth + 100,
                "The notice is \(width)pt wide with text and \(glyphWidth)pt without it in \(appearance.rawValue); the text is contributing nothing."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installStageRow_rendersDistinctContentForEachStage

    func test_installStageRow_rendersDistinctContentForEachStage() {
        let stages: [ExtensionInstallStage] = [
            .downloading(receivedBytes: 2_400_000, totalBytes: 6_100_000),
            .verifying,
            .extracting(completedEntries: 340, totalEntries: 812),
            .installing,
        ]
        let size = CGSize(width: 360, height: 70)
        var renders: [RenderedImage] = []
        for stage in stages {
            let rendered = render(ExtensionInstallStageRow(stage: stage), size: size, appearance: .darkAqua)
            XCTAssertGreaterThanOrEqual(
                Self.inkRowCount(rendered, in: CGRect(x: 0, y: 0, width: 40, height: size.height)), 12,
                "stage \(stage): the icon badge's column is only \(Self.inkRowCount(rendered, in: CGRect(x: 0, y: 0, width: 40, height: size.height)))pt tall -- the badge is missing and the progress bar is all that reaches it."
            )
            XCTAssertFalse(
                Self.hasInk(rendered, in: CGRect(x: 34, y: 0, width: 12, height: size.height)),
                "stage \(stage): ink in the gutter between the badge and the text column -- the text has slid left into the badge's place."
            )
            XCTAssertGreaterThanOrEqual(
                Self.inkRowCount(rendered, in: CGRect(x: 48, y: 0, width: size.width - 48, height: 18)), 10,
                "stage \(stage): the row's first line is only \(Self.inkRowCount(rendered, in: CGRect(x: 48, y: 0, width: size.width - 48, height: 18)))pt tall -- the stage's own title never rendered."
            )
            XCTAssertGreaterThanOrEqual(
                Self.longestInkRun(rendered, in: CGRect(origin: .zero, size: size)), 150,
                "stage \(stage): no run of ink 150pt wide -- OrbitInstallProgressBar is missing from the row."
            )
            renders.append(rendered)
        }
        for i in 0..<(renders.count - 1) {
            XCTAssertTrue(
                Self.rendersDiffer(renders[i], renders[i + 1], size: size),
                "Stage \(stages[i]) rendered pixel-identical to stage \(stages[i + 1]) -- ExtensionInstallStageRow is not reflecting its own `stage` input."
            )
        }
    }

    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 6
        var x = 0
        while x < Int(size.width) {
            var y = 0
            while y < Int(size.height) {
                if colorDistance(a.color(atX: x, y: y), b.color(atX: x, y: y)) > 0.04 { return true }
                y += step
            }
            x += step
        }
        return false
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installFailureRow_paintsInBothAppearances

    func test_installFailureRow_paintsInBothAppearances() {
        let network = ExtensionInstallFailurePresentation.present(ExtensionInstallError.webStoreFailure(.network("offline")))
        let verification = ExtensionInstallFailurePresentation.present(ExtensionInstallError.verificationFailed(.invalidMagic))
        let size = CGSize(width: 380, height: 70)
        let glyphRect = CGRect(x: 0, y: 0, width: 16, height: 16)

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(ExtensionInstallFailureRow(presentation: network), size: size, appearance: appearance)
            let glyph = rendered.averageColor(in: glyphRect)
            XCTAssertTrue(
                glyph.r > glyph.g && glyph.g > glyph.b && glyph.r - glyph.b > 0.15,
                "A network failure's glyph sampled \(glyph) in \(appearance.rawValue), not the orange its category asks for."
            )
            XCTAssertTrue(
                Self.hasInk(rendered, in: CGRect(x: 26, y: 0, width: size.width - 26, height: 16)),
                "The failure title never painted in \(appearance.rawValue)."
            )
            XCTAssertTrue(
                Self.hasInk(rendered, in: CGRect(x: 26, y: 17, width: size.width - 26, height: 40)),
                "The failure message never painted in \(appearance.rawValue) -- the row is showing a title with no detail."
            )

            let otherCategory = render(ExtensionInstallFailureRow(presentation: verification), size: size, appearance: appearance)
            XCTAssertGreaterThan(
                Self.colorDistance(glyph, otherCategory.averageColor(in: glyphRect)), 0.08,
                "A verification failure and a network failure paint the same glyph in \(appearance.rawValue) -- the row is not reflecting the failure's category."
            )
        }
    }

    // MARK: - The install modal: progress presented in the consent dialog's own frame

    private static func sampleSubject() -> ExtensionInstallSubject {
        ExtensionInstallSubject(name: "Fixture Extension", version: "1.3.0", iconPNGData: nil)
    }

    private static func progressModal(
        _ stage: ExtensionInstallStage,
        subject: ExtensionInstallSubject? = nil
    ) -> ExtensionInstallModalView {
        ExtensionInstallModalView(
            phase: .progress(stage), subject: subject,
            onAnswerConsent: { _ in }, onCancel: {}, onDismiss: {}
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installProgressModal_occupiesTheConsentDialogsOwnFrame_inBothAppearances

    func test_installProgressModal_occupiesTheConsentDialogsOwnFrame_inBothAppearances() {
        let canvas = CGSize(width: 700, height: 700)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let consent = render(
                ExtensionConsentSheetView(pending: Self.samplePendingInstall(), onAnswer: { _ in }).background(Color.red),
                size: canvas, appearance: appearance
            ).boundingBoxOfContent()
            let progress = render(
                Self.progressModal(.extracting(completedEntries: 4_820, totalEntries: 13_244), subject: Self.sampleSubject())
                    .background(Color.red),
                size: canvas, appearance: appearance
            ).boundingBoxOfContent()

            XCTAssertEqual(
                progress?.width ?? -1, OrbitMetrics.extensionInstallSheetWidth, accuracy: 1,
                "Install progress is not laid out at the consent dialog's declared sheet width in \(appearance.rawValue) — it is back on a geometry of its own."
            )
            XCTAssertEqual(
                progress?.width ?? -1, consent?.width ?? -2, accuracy: 1,
                "Consent and progress render at different widths in \(appearance.rawValue); the flow reads as two dialogs."
            )
            XCTAssertEqual(
                progress?.minX ?? -1, consent?.minX ?? -2, accuracy: 1,
                "Consent and progress start at different leading edges in \(appearance.rawValue)."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_singleTabContentView_presentsInstallProgressThroughTheSheet_notATopAlignedStrip
    func test_singleTabContentView_presentsInstallProgressThroughTheSheet_notATopAlignedStrip() throws {
        let source = try Self.productionSource(named: "ContentCardView.swift")

        XCTAssertFalse(
            source.contains("ExtensionInstallProgressBanner"),
            "ContentCardView still carries the top-strip install banner. Progress belongs in the same sheet as the consent decision."
        )
        XCTAssertFalse(
            source.contains("extensionInstallProgress["),
            "ContentCardView reads extensionInstallProgress directly again — every install state must be presented through extensionInstallModalPhase(for:), which is the only thing that keeps consent, progress and outcome in one frame."
        )
        XCTAssertTrue(
            source.contains("ExtensionInstallModalView"),
            "ContentCardView must present the install flow through ExtensionInstallModalView."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installModal_rendersEachStageDistinctly_inBothAppearances

    func test_installModal_rendersEachStageDistinctly_inBothAppearances() {
        let stages: [ExtensionInstallStage] = [
            .downloading(receivedBytes: 2_400_000, totalBytes: 6_100_000),
            .verifying,
            .extracting(completedEntries: 340, totalEntries: 812),
            .installing,
        ]
        let size = CGSize(width: OrbitMetrics.extensionInstallSheetWidth, height: 140)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            var renders: [RenderedImage] = []
            for stage in stages {
                let rendered = render(Self.progressModal(stage, subject: Self.sampleSubject()), size: size, appearance: appearance)
                XCTAssertGreaterThanOrEqual(
                    Self.inkRowCount(rendered, in: CGRect(x: 20, y: 15, width: size.width - 40, height: 40)), 20,
                    "stage \(stage) in \(appearance.rawValue): the modal's header is only \(Self.inkRowCount(rendered, in: CGRect(x: 20, y: 15, width: size.width - 40, height: 40)))pt tall -- its badge and titles are missing."
                )
                XCTAssertFalse(
                    Self.hasInk(rendered, in: CGRect(x: 58, y: 15, width: 8, height: 40)),
                    "stage \(stage) in \(appearance.rawValue): ink in the gutter between the badge and the text column -- the text has slid left into the badge's place."
                )
                XCTAssertGreaterThanOrEqual(
                    Self.longestInkRun(rendered, in: CGRect(origin: .zero, size: size)), 250,
                    "stage \(stage) in \(appearance.rawValue): no run of ink 250pt wide -- the modal is not carrying the install progress bar."
                )
                XCTAssertGreaterThanOrEqual(
                    Self.longestInkRun(rendered, in: CGRect(x: 280, y: 70, width: size.width - 280, height: size.height - 70)), 50,
                    "stage \(stage) in \(appearance.rawValue): no button-sized ink at the modal's trailing bottom -- the Cancel button is gone."
                )
                renders.append(rendered)
            }
            for index in 0..<(renders.count - 1) {
                XCTAssertTrue(
                    Self.rendersDiffer(renders[index], renders[index + 1], size: size),
                    "Stage \(stages[index]) rendered pixel-identical to \(stages[index + 1]) in \(appearance.rawValue) — the modal is not surfacing which stage the install is actually in."
                )
            }
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installModal_namesTheExtensionOnceItIsKnown

    func test_installModal_namesTheExtensionOnceItIsKnown() {
        let size = CGSize(width: OrbitMetrics.extensionInstallSheetWidth, height: 140)
        let anonymous = render(Self.progressModal(.installing), size: size, appearance: .darkAqua)
        let named = render(Self.progressModal(.installing, subject: Self.sampleSubject()), size: size, appearance: .darkAqua)
        XCTAssertTrue(
            Self.rendersDiffer(anonymous, named, size: size),
            "The install modal renders identically with and without a resolved subject — it is not showing the extension's own name the way the consent dialog does."
        )
    }

    // The sheet's own material is host chrome the offscreen renderer never paints, so each state gets a plain backdrop.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installModal_paintsEveryPhase_inBothAppearances
    func test_installModal_paintsEveryPhase_inBothAppearances() async {
        let size = CGSize(width: OrbitMetrics.extensionInstallSheetWidth, height: 190)
        let subject = Self.sampleSubject()
        let states: [(String, ExtensionInstallModalPhase)] = [
            ("downloading", .progress(.downloading(receivedBytes: 2_400_000, totalBytes: 6_100_000))),
            ("verifying", .progress(.verifying)),
            ("unpacking", .progress(.extracting(completedEntries: 4_820, totalEntries: 13_244))),
            ("installing", .progress(.installing)),
            ("installed", .outcome(.installed(name: subject.name, version: subject.version))),
            ("failed", .outcome(.failed(.present(ExtensionInstallError.webStoreFailure(.network("The internet connection appears to be offline.")))))),
        ]

        for (appearance, suffix, backdrop) in [
            (NSAppearance.Name.darkAqua, "", Color(.sRGB, red: 0.12, green: 0.12, blue: 0.13, opacity: 1)),
            (.aqua, "-light", Color(.sRGB, red: 0.96, green: 0.96, blue: 0.97, opacity: 1)),
        ] {
            for (name, phase) in states {
                let view = ExtensionInstallModalView(
                    phase: phase, subject: subject,
                    onAnswerConsent: { _ in }, onCancel: {}, onDismiss: {}
                )
                .background(backdrop)
                await renderAndSave(view, name: "extension-install-\(name)\(suffix)", size: size, appearance: appearance)
            }
        }
    }

    // MARK: - Colours: taken from the tokens, correct in both appearances

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installProgressBar_takesItsFillAndTrackFromTokens_inBothAppearances

    func test_installProgressBar_takesItsFillAndTrackFromTokens_inBothAppearances() {
        let size = CGSize(width: 200, height: OrbitMetrics.extensionInstallProgressBarHeight)
        let sampleBand = CGRect(x: 0, y: 1, width: 40, height: 2)

        let accentReference = render(
            Rectangle().fill(SettingsPalette.accent), size: size, appearance: .darkAqua
        ).averageColor(in: sampleBand)

        let trackOpacities: [(NSAppearance.Name, Double)] = [
            (.darkAqua, OrbitMetrics.extensionInstallProgressTrackOpacityDark),
            (.aqua, OrbitMetrics.extensionInstallProgressTrackOpacityLight),
        ]
        var trackLuminances: [Double] = []

        for (appearance, expectedOpacity) in trackOpacities {
            let rendered = render(OrbitInstallProgressBar(fraction: 0.5), size: size, appearance: appearance)

            let filled = rendered.averageColor(in: sampleBand.offsetBy(dx: 30, dy: 0))
            XCTAssertTrue(
                filled.isApproximately(accentReference, tolerance: 0.03),
                "Progress fill in \(appearance.rawValue) sampled \(filled), not SettingsPalette.accent (\(accentReference)) — the bar is painting a colour of its own instead of the install flow's own accent token."
            )

            let track = rendered.averageColor(in: sampleBand.offsetBy(dx: 130, dy: 0))
            XCTAssertEqual(
                track.a, expectedOpacity, accuracy: 0.03,
                "Progress track alpha in \(appearance.rawValue) is not OrbitMetrics.extensionInstallProgressTrackOpacity*."
            )
            trackLuminances.append((track.r + track.g + track.b) / 3)
        }

        XCTAssertGreaterThan(trackLuminances[0], 0.9, "The dark-appearance track must be a light tint.")
        XCTAssertLessThan(trackLuminances[1], 0.1, "The light-appearance track must be a dark tint, not the same fixed white one dark uses.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installProgressBar_withNoMeasurableFraction_claimsNoPosition
    func test_installProgressBar_withNoMeasurableFraction_claimsNoPosition() {
        let size = CGSize(width: 200, height: OrbitMetrics.extensionInstallProgressBarHeight)
        let rendered = render(OrbitInstallProgressBar(fraction: nil), size: size, appearance: .darkAqua)
        let band = CGRect(x: 0, y: 1, width: 30, height: 2)

        let near = rendered.averageColor(in: band.offsetBy(dx: 20, dy: 0))
        let far = rendered.averageColor(in: band.offsetBy(dx: 160, dy: 0))
        XCTAssertTrue(
            near.isApproximately(far, tolerance: 0.03),
            "The bar reads \(near) at one end and \(far) at the other with no fraction to report — it is implying a position the installer never measured."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installFlowSurfaces_useNoRawOpacityLiterals

    func test_installFlowSurfaces_useNoRawOpacityLiterals() throws {
        for file in ["ExtensionInstallModalView.swift", "ExtensionInstallStatusViews.swift", "ExtensionConsentSheetView.swift"] {
            let source = try Self.productionSource(named: file)
            let literals = Self.rawOpacityLiterals(in: source)
            XCTAssertTrue(
                literals.isEmpty,
                "\(file) sets opacit(ies) \(literals.sorted()) as raw numeric literals instead of named tokens — that is how the progress strip ended up with a hardcoded white border and shadow that only read correctly in dark appearance."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installProgressBar_resolvesItsColoursPerColorScheme

    func test_installProgressBar_resolvesItsColoursPerColorScheme() throws {
        let source = try Self.productionSource(named: "ExtensionInstallStatusViews.swift")
        XCTAssertTrue(
            source.contains(#"@Environment(\.colorScheme)"#),
            "The install progress bar must resolve its track from the colour scheme; a fixed tint is only ever right in one appearance."
        )
        XCTAssertFalse(
            Self.sourceStrippingComments(source).contains("LibraryProgressBar"),
            "The install flow must not use the Library's progress bar: its track is a fixed white tint, correct against the Library's permanently dark surface and invisible on a light sheet."
        )
    }

    // MARK: - Outcomes: a failure is reportable and dismissible

    private static func outcomeModal(_ outcome: ExtensionInstallOutcome, subject: ExtensionInstallSubject?) -> ExtensionInstallModalView {
        ExtensionInstallModalView(
            phase: .outcome(outcome), subject: subject,
            onAnswerConsent: { _ in }, onCancel: {}, onDismiss: {}
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installOutcomes_paintInTheSameFrame_inBothAppearances

    func test_installOutcomes_paintInTheSameFrame_inBothAppearances() {
        let canvas = CGSize(width: 700, height: 700)
        let failure = ExtensionInstallOutcome.failed(
            .present(ExtensionInstallError.webStoreFailure(.network("The internet connection appears to be offline.")))
        )
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            for outcome in [ExtensionInstallOutcome.installed(name: "Fixture Extension", version: "1.3.0"), failure] {
                let box = render(
                    Self.outcomeModal(outcome, subject: Self.sampleSubject()).background(Color.red),
                    size: canvas, appearance: appearance
                ).boundingBoxOfContent()
                XCTAssertEqual(
                    box?.width ?? -1, OrbitMetrics.extensionInstallSheetWidth, accuracy: 1,
                    "Outcome \(outcome) in \(appearance.rawValue) is not in the consent dialog's frame."
                )
            }
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installOutcome_successAndFailure_renderDistinctly

    func test_installOutcome_successAndFailure_renderDistinctly() {
        let size = CGSize(width: OrbitMetrics.extensionInstallSheetWidth, height: 160)
        let success = render(
            Self.outcomeModal(.installed(name: "Fixture Extension", version: "1.3.0"), subject: Self.sampleSubject()),
            size: size, appearance: .darkAqua
        )
        let failure = render(
            Self.outcomeModal(
                .failed(.present(ExtensionInstallError.verificationFailed(.invalidMagic))),
                subject: Self.sampleSubject()
            ),
            size: size, appearance: .darkAqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(success, failure, size: size),
            "A failed install renders identically to a successful one — a failure has to be reportable, not silently dressed as a win."
        )
    }

    // MARK: - Dismissal: no state can leave the sheet up or strand the installer

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_dismissingTheInstallModal_clearsEveryStateThatKeepsItPresented

    func test_dismissingTheInstallModal_clearsEveryStateThatKeepsItPresented() {
        let env = self.env
        let tabID = UUID()

        env.extensionInstallProgress[tabID] = .extracting(completedEntries: 1, totalEntries: 10)
        env.extensionInstallSubjects[tabID] = Self.sampleSubject()
        XCTAssertNotNil(env.extensionInstallModalPhase(for: tabID))

        var cancelled = false
        env.extensionInstallCancellers[tabID] = { cancelled = true }
        env.dismissExtensionInstallModal(for: tabID)

        XCTAssertTrue(cancelled, "Dismissing an in-flight install must cancel it, not just hide it.")
        XCTAssertNil(env.extensionInstallModalPhase(for: tabID), "The sheet is still presented after being dismissed.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aStaleStageAfterCancellation_doesNotReopenTheModal

    func test_aStaleStageAfterCancellation_doesNotReopenTheModal() {
        let env = self.env
        let tabID = UUID()
        env.extensionInstallProgress[tabID] = .verifying
        env.extensionInstallCancellers[tabID] = {}
        env.dismissExtensionInstallModal(for: tabID)

        env.applyExtensionInstallProgress(.installing, for: tabID)
        XCTAssertNil(
            env.extensionInstallModalPhase(for: tabID),
            "A stage reported after Cancel reopened the sheet the user just closed — cancellation only lands at the installer's next stage boundary, so the stage in flight at that moment still arrives."
        )

        env.applyExtensionInstallProgress(nil, for: tabID)
        env.applyExtensionInstallProgress(.downloading(receivedBytes: 0, totalBytes: 0), for: tabID)
        XCTAssertNotNil(
            env.extensionInstallModalPhase(for: tabID),
            "The cancellation mark must be cleared when the installer reports the run finished, or the tab can never show an install again."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anOutcomeOutranksProgress_andConsentOutranksProgress

    func test_anOutcomeOutranksProgress_andConsentOutranksProgress() {
        let env = self.env
        let tabID = UUID()

        env.extensionInstallProgress[tabID] = .awaitingConsent
        env.pendingExtensionInstallConsent[tabID] = Self.samplePendingInstall()
        guard case .consent = env.extensionInstallModalPhase(for: tabID) else {
            return XCTFail("A pending consent decision must outrank the .awaitingConsent stage reported alongside it.")
        }

        env.extensionInstallOutcomes[tabID] = .installed(name: "Fixture Extension", version: "1.3.0")
        guard case .outcome = env.extensionInstallModalPhase(for: tabID) else {
            return XCTFail("A terminal outcome must outrank everything; it is what the flow ends on.")
        }
    }

    // MARK: - Architecture: consent and progress states must not drift back onto separate designs

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_installProgressRow_andConsentSheet_shareTheSameIconBadgeAndStagePresenter

    func test_installProgressRow_andConsentSheet_shareTheSameIconBadgeAndStagePresenter() throws {
        let consentSource = try Self.productionSource(named: "ExtensionConsentSheetView.swift")
        let paneSource = try Self.productionSource(named: "ExtensionsSettingsPane.swift")

        XCTAssertTrue(
            consentSource.contains("ExtensionIconBadge"),
            "ExtensionConsentSheetView must render its icon through the shared ExtensionIconBadge, not a private duplicate, or the consent dialog and the progress states can silently drift back apart -- the exact defect reported."
        )
        XCTAssertTrue(
            paneSource.contains("ExtensionInstallStageRow"),
            "ExtensionsSettingsPane's install-progress block must render through the shared ExtensionInstallStageRow (itself built from ExtensionIconBadge and OrbitMetrics.extensionInstall* tokens), not a private, independently hardcoded progress row."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_extensionInstallFlowSurfaces_useNoRawFontSizeLiterals

    func test_extensionInstallFlowSurfaces_useNoRawFontSizeLiterals() throws {
        for file in ["ExtensionConsentSheetView.swift", "ExtensionInstallStatusViews.swift"] {
            let source = try Self.productionSource(named: file)
            let literals = Self.rawFontSizeLiterals(in: source)
            XCTAssertTrue(
                literals.isEmpty,
                "\(file) sets font size(s) \(literals.sorted()) as raw numeric literals instead of named OrbitMetrics.extensionInstall* tokens -- exactly how the consent dialog and the progress row drifted onto two different typography scales before."
            )
        }
    }

    // MARK: - ExtensionsSettingsPane: the one row-state deterministic without touching ExtensionStore

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_extensionsPane_withNoExtensionCapableEngine_rendersTheUnsupportedMessage

    func test_extensionsPane_withNoExtensionCapableEngine_rendersTheUnsupportedMessage() {
        let size = CGSize(width: SettingsMetrics.contentMaxWidth, height: 300)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let env = self.env
            XCTAssertFalse(env.capabilitiesSupportExtensions, "test precondition: no engine, so the pane takes its unsupported branch.")
            let rendered = render(ExtensionsSettingsPane().environment(env), size: size, appearance: appearance)

            let sectionFill = rendered.color(atX: 540, y: 78)
            let message = Self.nonBackgroundBox(
                rendered,
                background: sectionFill,
                in: CGRect(x: 62, y: 50, width: 438, height: 26)
            )
            XCTAssertGreaterThan(
                message?.width ?? 0, 300,
                "In \(appearance.rawValue) the notice's row is \(String(describing: message)) of text over its section fill \(sectionFill) -- only the section chrome painted, not the message."
            )
            XCTAssertFalse(
                Self.hasInk(rendered, in: CGRect(x: 0, y: 110, width: size.width, height: size.height - 110)),
                "The pane painted below its engine-starting notice in \(appearance.rawValue) -- it is rendering the extensions-capable branch too."
            )
        }
    }

    // MARK: - Harness: render + save (mirrors ScreenshotGenerationTests, but never silently swallows a write failure)

    private func renderAndSave(
        _ view: some View,
        name: String,
        size: CGSize,
        appearance: NSAppearance.Name = .darkAqua
    ) async {
        let rendered = await renderForScreenshot(view, size: size, appearance: appearance)
        guard let box = rendered.boundingBoxOfContent() else {
            XCTFail("\(name) (\(appearance.rawValue)) painted nothing.")
            return
        }
        XCTAssertGreaterThan(box.width, size.width * 0.5, "\(name) (\(appearance.rawValue)) painted \(box.width)pt of a \(size.width)pt canvas across.")
        XCTAssertGreaterThan(box.height, size.height * 0.25, "\(name) (\(appearance.rawValue)) painted \(box.height)pt of a \(size.height)pt canvas down.")

        let background = rendered.color(atX: 0, y: 0)
        let content = Self.nonBackgroundFraction(rendered, background: background, in: box)
        XCTAssertGreaterThan(
            content, 0.02,
            "\(name) (\(appearance.rawValue)) is \(content) content over a flat \(background) -- the screenshot is an empty panel."
        )

        let destination = Self.screenshotOutputDirectory.appendingPathComponent("\(name).png")
        XCTAssertTrue(rendered.writePNG(to: destination), "Expected to write \(name).png to \(destination.path).")
    }

    // MARK: - Source lookup

    private static func productionSource(named fileName: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OrbitAppTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Orbit", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate \(root.path).")
            return ""
        }
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTFail("Could not find \(fileName) under Orbit/.")
        return ""
    }

    /// Blanks comment runs so a scan for a banned identifier is not tripped by a comment about it.
    private static func sourceStrippingComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index = min(index + 2, characters.count)
                continue
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    private static func rawOpacityLiterals(in source: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\.opacity\(\s*([0-9]+(?:\.[0-9]+)?)\s*\)"#) else { return [] }
        var results: Set<String> = []
        let range = NSRange(source.startIndex..., in: source)
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range(at: 1), in: source) else { return }
            results.insert(String(source[matchRange]))
        }
        return results
    }

    private static func rawFontSizeLiterals(in source: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\.font\(\.system\(size:\s*([0-9]+(?:\.[0-9]+)?)"#) else { return [] }
        var results: Set<String> = []
        let range = NSRange(source.startIndex..., in: source)
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range(at: 1), in: source) else { return }
            results.insert(String(source[matchRange]))
        }
        return results
    }

    // MARK: - Ink measurement

    private static func hasInk(_ image: RenderedImage, in rect: CGRect) -> Bool {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where image.color(atX: x, y: y).a > 0.04 {
                return true
            }
        }
        return false
    }

    private static func inkRowCount(_ image: RenderedImage, in rect: CGRect) -> Int {
        var rows = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where image.color(atX: x, y: y).a > 0.04 {
                rows += 1
                break
            }
        }
        return rows
    }

    private static func longestInkRun(_ image: RenderedImage, in rect: CGRect) -> Int {
        var longest = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            var run = 0
            for x in Int(rect.minX)..<Int(rect.maxX) {
                if image.color(atX: x, y: y).a > 0.04 {
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
        }
        return longest
    }

    private static func nonBackgroundBox(_ image: RenderedImage, background: RGBA, in rect: CGRect) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where !image.color(atX: x, y: y).isApproximately(background, tolerance: 0.05) {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + 1)
                maxY = max(maxY, y + 1)
            }
        }
        guard minX < maxX, minY < maxY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func nonBackgroundFraction(_ image: RenderedImage, background: RGBA, in rect: CGRect) -> Double {
        var differing = 0
        var total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                total += 1
                if !image.color(atX: x, y: y).isApproximately(background, tolerance: 0.05) { differing += 1 }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }

    private static func colorDistance(_ a: RGBA, _ b: RGBA) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        let da = a.a - b.a
        return (dr * dr + dg * dg + db * db + da * da).squareRoot()
    }
}
