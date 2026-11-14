import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// ImageRenderer does not rasterise ScrollView, NSViewRepresentable, .draggable or .dropDestination, so compositions below swap the ScrollView for a VStack around the real subviews.
@MainActor
final class ScreenshotGenerationNewSurfacesTests: XCTestCase {

    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrbitAppTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("refs/screenshots", isDirectory: true)
    }

    private static let onboardingSize = CGSize(width: 880, height: 560)
    private static let devtoolsSize = CGSize(width: 760, height: 620)
    private static let windowSize = CGSize(width: 1320, height: 840)

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PeekState.shared.dismiss()
    }

    // Welcome is the real OnboardingView, whose column ScrollView renders blank; the other steps use ScreenshotOnboardingComposition.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_onboardingSteps_welcomeToFinish_darkAndLight
    func test_onboardingSteps_welcomeToFinish_darkAndLight() async {
        let env = self.env
        let welcome: () -> AnyView = {
            AnyView(OnboardingView(onFinished: {}).environment(env))
        }
        let welcomeDark = await renderAndSave(welcome(), name: "onboarding-welcome-dark", size: Self.onboardingSize, appearance: .darkAqua)
        let welcomeLight = await renderAndSave(welcome(), name: "onboarding-welcome-light", size: Self.onboardingSize, appearance: .aqua)
        XCTAssertTrue(
            Self.rendersDiffer(welcomeDark, welcomeLight, size: Self.onboardingSize),
            "Onboarding welcome rendered pixel-identical in dark and light."
        )

        let steps: [(OnboardingStep, String)] = [
            (.importBrowser, "onboarding-import-idle"),
            (.spaces, "onboarding-spaces"),
            (.shortcuts, "onboarding-shortcuts"),
            (.finish, "onboarding-finish"),
        ]
        for (step, name) in steps {
            let dark = await renderAndSave(
                ScreenshotOnboardingComposition(step: step), name: "\(name)-dark",
                size: Self.onboardingSize, appearance: .darkAqua
            )
            let light = await renderAndSave(
                ScreenshotOnboardingComposition(step: step), name: "\(name)-light",
                size: Self.onboardingSize, appearance: .aqua
            )
            XCTAssertTrue(
                Self.rendersDiffer(dark, light, size: Self.onboardingSize),
                "Onboarding \(step.title) rendered pixel-identical in dark and light."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_onboardingImport_midProgress_darkAndLight
    func test_onboardingImport_midProgress_darkAndLight() async {
        var progress = ImportProgress()
        let events: [ImportProgressEvent] = [
            .planned(.spaces, total: 3), .finished(.spaces, completed: 3),
            .planned(.tabs, total: 18), .advanced(.tabs, completed: 18), .finished(.tabs, completed: 18),
            .planned(.bookmarks, total: 240), .advanced(.bookmarks, completed: 150),
            .planned(.history, total: 12_000), .advanced(.history, completed: 3_000),
        ]
        for event in events { progress.apply(event) }

        // Spaces and tabs are finished, bookmarks and history are partway: the weighted bar is strictly between 0 and 1.
        XCTAssertGreaterThan(progress.overallFraction, 0)
        XCTAssertLessThan(progress.overallFraction, 1)
        XCTAssertFalse(progress.isFinished)
        XCTAssertEqual(progress.items.count, 4)

        func scene() -> ScreenshotOnboardingComposition {
            ScreenshotOnboardingComposition(
                step: .importBrowser,
                selectedImport: .arc,
                importState: .importing(.arc),
                importProgress: progress
            )
        }
        let dark = await renderAndSave(scene(), name: "onboarding-import-progress-dark", size: Self.onboardingSize, appearance: .darkAqua)
        let light = await renderAndSave(scene(), name: "onboarding-import-progress-light", size: Self.onboardingSize, appearance: .aqua)
        XCTAssertTrue(Self.rendersDiffer(dark, light, size: Self.onboardingSize), "Import progress rendered identically in dark and light.")

        let idle = await renderAndSave(
            ScreenshotOnboardingComposition(step: .importBrowser, selectedImport: .arc),
            name: "onboarding-import-selected-idle-dark", size: Self.onboardingSize, appearance: .darkAqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(dark, idle, size: Self.onboardingSize),
            "Mid-import rendered the same as an idle import step: progress rows are not reaching the screen."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_onboardingSpaces_twoDrafts_darkAndLight
    func test_onboardingSpaces_twoDrafts_darkAndLight() async {
        var drafts = [
            OnboardingSpaceDraft(name: "Personal", emoji: "🏡"),
            OnboardingSpaceDraft(name: "Work", emoji: "💼"),
        ]
        let themes = OnboardingCommit.resolvedThemes(for: drafts)
        for index in drafts.indices { drafts[index].theme = themes[index] }
        XCTAssertEqual(drafts.count, 2)
        XCTAssertNotEqual(drafts[0].theme, drafts[1].theme, "Two drafts must resolve to two distinct themes.")

        let dark = await renderAndSave(
            ScreenshotOnboardingComposition(step: .spaces, drafts: drafts),
            name: "onboarding-spaces-two-drafts-dark", size: Self.onboardingSize, appearance: .darkAqua
        )
        let light = await renderAndSave(
            ScreenshotOnboardingComposition(step: .spaces, drafts: drafts),
            name: "onboarding-spaces-two-drafts-light", size: Self.onboardingSize, appearance: .aqua
        )
        XCTAssertTrue(Self.rendersDiffer(dark, light, size: Self.onboardingSize), "Spaces step rendered identically in dark and light.")
    }

    // GlyphPlanetView drives itself from a TimelineView read once here; whether the Metal effect rasterised is logged as [ONBOARDING-ART], not asserted.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_onboardingShortcuts_oneTried_darkAndLight
    func test_onboardingShortcuts_oneTried_darkAndLight() async {
        var primer = OnboardingShortcutPrimer()
        XCTAssertTrue(primer.record(.newTabCommandBar), "The first press of a taught shortcut must be recorded.")
        XCTAssertEqual(primer.triedCount, 1)
        XCTAssertFalse(primer.isComplete)

        let dark = await renderAndSave(
            ScreenshotOnboardingComposition(step: .shortcuts, primer: primer),
            name: "onboarding-shortcuts-one-tried-dark", size: Self.onboardingSize, appearance: .darkAqua
        )
        let light = await renderAndSave(
            ScreenshotOnboardingComposition(step: .shortcuts, primer: primer),
            name: "onboarding-shortcuts-one-tried-light", size: Self.onboardingSize, appearance: .aqua
        )
        XCTAssertTrue(Self.rendersDiffer(dark, light, size: Self.onboardingSize), "Shortcuts step rendered identically in dark and light.")

        let untried = await renderAndSave(
            ScreenshotOnboardingComposition(step: .shortcuts),
            name: "onboarding-shortcuts-none-tried-dark", size: Self.onboardingSize, appearance: .darkAqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(dark, untried, size: Self.onboardingSize),
            "One shortcut tried rendered the same as none tried: the tick (and the planet's tilt) are not showing."
        )

        let stage = CGRect(x: 440, y: 0, width: 440, height: Self.onboardingSize.height)
        let stageBackground = dark.color(atX: Int(Self.onboardingSize.width) - 2, y: 2)
        let painted = dark.containsNonBackgroundPixels(in: stage.insetBy(dx: 60, dy: 60), background: stageBackground, tolerance: 0.05)
        print("[ONBOARDING-ART] glyph planet colorEffect captured by ImageRenderer: \(painted)")
    }

    // The report is a fixed LHReport placed on the session's own lighthouse model, the one the real pane reads.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_devtoolsLighthouse_report_darkAndLight
    func test_devtoolsLighthouse_report_darkAndLight() throws {
        try withInspectSession { session in
            let report = Self.lighthouseReport()
            session.panel = .lighthouse
            session.pageURL = report.url
            session.pageTitle = report.pageTitle
            session.lighthouse.currentReport = report
            session.lighthouse.history = [report]
            session.lighthouse.runState = .done
            session.lighthouse.toggleExpanded(auditID: "render-blocking-resources")

            XCTAssertEqual(session.lighthouse.viewingReport?.id, report.id)
            XCTAssertEqual(OrbitLighthouseLogic.rankedOpportunities(report.audits).first?.id, "render-blocking-resources",
                           "The fixture's largest saving (1,150 ms) must rank first.")

            func pane() -> some View { ScreenshotLighthouseComposition(session: session) }
            let dark = await self.renderAndSave(pane(), name: "devtools-lighthouse-dark", size: Self.devtoolsSize, appearance: .darkAqua)
            let light = await self.renderAndSave(pane(), name: "devtools-lighthouse-light", size: Self.devtoolsSize, appearance: .aqua)
            XCTAssertTrue(Self.rendersDiffer(dark, light, size: Self.devtoolsSize), "Lighthouse pane rendered identically in dark and light.")

            // Taller than the 620pt panel so the whole report is visible in one image.
            _ = await self.renderAndSave(
                pane(), name: "devtools-lighthouse-full-dark",
                size: CGSize(width: Self.devtoolsSize.width, height: 1_100), appearance: .darkAqua
            )
        }
    }

    // The model's TLS state is private(set) and fed only by a live WKWebView, so the composition takes the evaluated report directly.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_devtoolsSecurity_report_darkAndLight
    func test_devtoolsSecurity_report_darkAndLight() throws {
        try withInspectSession { session in
            let report = OrbitSecurityLogic.evaluate(Self.securityInput())
            session.panel = .security
            session.pageURL = report.pageURL
            if let firstProblem = report.checks.first(where: { $0.state == .fail }) {
                session.security.toggleExpanded(checkID: firstProblem.id)
            }

            // A password form over plain HTTP with no frame-ancestors guarantees a fail and a warning; the trusted chain gives a pass.
            XCTAssertGreaterThan(report.failCount, 0, "A password form posting over http must fail a check.")
            XCTAssertGreaterThan(report.passCount, 0, "A trusted HTTPS connection must pass a check.")
            XCTAssertNotEqual(report.overall, .secure)
            XCTAssertFalse(report.cookieRows.isEmpty)
            XCTAssertEqual(report.certificates.count, 3)

            func pane() -> some View { ScreenshotSecurityComposition(session: session, report: report) }
            let dark = await self.renderAndSave(pane(), name: "devtools-security-dark", size: Self.devtoolsSize, appearance: .darkAqua)
            let light = await self.renderAndSave(pane(), name: "devtools-security-light", size: Self.devtoolsSize, appearance: .aqua)
            XCTAssertTrue(Self.rendersDiffer(dark, light, size: Self.devtoolsSize), "Security pane rendered identically in dark and light.")

            _ = await self.renderAndSave(
                pane(), name: "devtools-security-full-dark",
                size: CGSize(width: Self.devtoolsSize.width, height: 1_500), appearance: .darkAqua
            )
        }
    }

    // The view is framed at 320 inside a wider transparent canvas, so any overflow shows as ink right of x = 320.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_devtoolsTabStrip_at320_doesNotClip
    func test_devtoolsTabStrip_at320_doesNotClip() throws {
        try withInspectSession { session in
            session.panel = .lighthouse
            session.pageURL = "https://shop.example.com/checkout"

            for width in [CGFloat(320), CGFloat(280)] {
                let canvas = CGSize(width: 640, height: 220)
                let measured = await renderForScreenshot(
                    OrbitInspectView(session: session).frame(width: width, height: canvas.height, alignment: .topLeading),
                    size: canvas, appearance: .darkAqua
                )
                guard let content = measured.boundingBoxOfContent() else {
                    XCTFail("The inspector shell at \(Int(width))pt drew nothing.")
                    continue
                }
                XCTAssertLessThanOrEqual(content.maxX, width + 0.5, "The inspector at \(Int(width))pt drew out to x = \(content.maxX): the tab strip clips or spills.")
                XCTAssertGreaterThanOrEqual(content.minX, 0)
                XCTAssertGreaterThan(content.width, width * 0.8, "The inspector at \(Int(width))pt barely drew anything; the measurement proves nothing.")
            }

            let dark = await self.renderAndSave(
                OrbitInspectView(session: session), name: "devtools-tabstrip-320-dark",
                size: CGSize(width: 320, height: 220), appearance: .darkAqua
            )
            let light = await self.renderAndSave(
                OrbitInspectView(session: session), name: "devtools-tabstrip-320-light",
                size: CGSize(width: 320, height: 220), appearance: .aqua
            )
            XCTAssertTrue(Self.rendersDiffer(dark, light, size: CGSize(width: 320, height: 220)), "Inspector shell rendered identically in dark and light.")
        }
    }

    // The store gives every item "now" as its start time, so rows read "Just now"; the relative-time render backdates them.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_downloadsFlyout_overBottomBar_onSpaceThemes
    func test_downloadsFlyout_overBottomBar_onSpaceThemes() async throws {
        let env = self.env
        let items = try seedFlyoutDownloads(env)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(DownloadsFlyoutSelection.visible(from: env.downloadStore.downloads).count, 4)

        let blue = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.16, green: 0.22, blue: 0.42)], followsSystemAppearance: false)
        let sand = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.93, green: 0.86, blue: 0.74)], followsSystemAppearance: false)
        let size = CGSize(width: 260, height: 520)

        let blueFlyout = await renderAndSave(
            ScreenshotFlyoutScene(theme: blue, width: size.width, showsFlyout: true).environment(env),
            name: "downloads-flyout-blue-260", size: size, appearance: .darkAqua
        )
        let blueBare = await renderAndSave(
            ScreenshotFlyoutScene(theme: blue, width: size.width, showsFlyout: false).environment(env),
            name: "downloads-flyout-blue-260-bar-only", size: size, appearance: .darkAqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(blueFlyout, blueBare, size: size),
            "The flyout rendered the same as the bare bottom bar: the panel is not painting above it."
        )

        let sandFlyout = await renderAndSave(
            ScreenshotFlyoutScene(theme: sand, width: size.width, showsFlyout: true).environment(env),
            name: "downloads-flyout-sand-260", size: size, appearance: .aqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(blueFlyout, sandFlyout, size: size),
            "Two different Space themes painted the same flyout: it is not following the Space theme."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_downloadsFlyout_relativeTimes_onSpaceTheme
    func test_downloadsFlyout_relativeTimes_onSpaceTheme() async throws {
        let env = self.env
        let stored = try seedFlyoutDownloads(env)
        let now = Date()
        // Same ids as the stored items, so the real row still finds each completed file on disk; only the clock fields change.
        let ages: [TimeInterval] = [20, 4 * 60, 3 * 3_600, 2 * 86_400]
        var backdated = stored
        for index in backdated.indices {
            backdated[index].startedAt = now.addingTimeInterval(-ages[index])
            if backdated[index].finishedAt != nil {
                backdated[index].finishedAt = now.addingTimeInterval(-ages[index])
            }
        }

        let texts = backdated.map { DownloadsPreviewRow.detailText(for: $0, fileExists: true, now: now, locale: Locale(identifier: "en_US")) }
        XCTAssertTrue(texts.contains { $0.contains("4 minutes ago") }, "A completed download finished 4 minutes ago must read '4 minutes ago'; got \(texts).")
        XCTAssertTrue(texts.contains { $0.hasPrefix("Cancelled") && $0.contains("3 hours ago") }, "Got \(texts).")

        let theme = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.16, green: 0.22, blue: 0.42)], followsSystemAppearance: false)
        let size = CGSize(width: 260, height: 420)
        let image = await renderAndSave(
            ScreenshotBackdatedFlyoutRows(items: backdated, theme: theme, width: size.width).environment(env),
            name: "downloads-flyout-relative-times-260", size: size, appearance: .darkAqua
        )
        XCTAssertNotNil(image.boundingBoxOfContent())
    }

    // The Library list sits in a ScrollView and the detail is an NSViewRepresentable, so those regions may be blank.

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_libraryMode_fullWindow_downloadsAndSpaces
    func test_libraryMode_fullWindow_downloadsAndSpaces() async {
        let env = self.env
        OrbitScreenshotFixtures.configure(env)
        func window() -> some View {
            BrowserWindowView(skipOnboarding: true)
                .environment(env)
                .orbitScreenshotDragDisabled()
        }

        let browsing = render(window(), size: Self.windowSize, appearance: .darkAqua)
        XCTAssertFalse(env.libraryRouter.isActive)

        env.openLibrary(section: .downloads)
        XCTAssertTrue(env.libraryRouter.isActive)
        XCTAssertEqual(env.libraryRouter.selectedSection, .downloads)
        let downloads = await renderAndSave(window(), name: "window-library-downloads", size: Self.windowSize, appearance: .darkAqua)
        XCTAssertTrue(
            Self.rendersDiffer(browsing, downloads, size: Self.windowSize),
            "Opening the Library left the window pixel-identical to browsing."
        )

        env.openLibrary(section: .spaces)
        XCTAssertEqual(env.libraryRouter.selectedSection, .spaces)
        let spaces = await renderAndSave(window(), name: "window-library-spaces", size: Self.windowSize, appearance: .darkAqua)
        XCTAssertTrue(
            Self.rendersDiffer(downloads, spaces, size: Self.windowSize),
            "Downloads and Spaces rendered identically in the Library: the section switch is not reaching the screen."
        )
    }

    // MARK: - Fixtures

    private static let fixedNow = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 00:00:00 UTC

    private static func lighthouseReport() -> LHReport {
        LHReport(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            url: "https://shop.example.com/products/trail-runner",
            pageTitle: "Trail Runner 2 - Example Shop",
            timestamp: fixedNow,
            mode: .navigation,
            device: .mobile,
            runCount: 3,
            enabledCategories: LHCategory.allCases,
            scores: LHScores(performance: 62, accessibility: 91, bestPractices: 78, seo: 100, security: 71),
            metrics: LHMetrics(
                fcp: 2_100, lcp: 3_400, lcpElement: "img.hero", tbt: 310, cls: 0.14,
                inp: nil, ttfb: 540, speedIndex: 4_100, longTaskCount: 6
            ),
            audits: [
                LHAuditResult(
                    id: "render-blocking-resources", category: .performance,
                    title: "Eliminate render-blocking resources",
                    description: "Resources are blocking the first paint of your page.",
                    docsURL: "https://developer.chrome.com/docs/lighthouse/performance/render-blocking-resources",
                    status: .fail, score: 0.3, weight: 0, displayValue: "Potential savings of 1,150 ms",
                    items: [
                        LHAuditItem(id: "rb1", url: "https://shop.example.com/static/app.css", wastedBytes: 41_000, wastedMs: 780, transferSize: 41_000),
                        LHAuditItem(id: "rb2", url: "https://fonts.example.net/css?family=Inter", wastedBytes: 3_200, wastedMs: 370, transferSize: 3_200),
                    ],
                    savingsMs: 1_150, savingsBytes: 44_200,
                    savingsNote: "Estimated from transfer size at the mobile link speed. Nothing is throttled on this Mac."
                ),
                LHAuditResult(
                    id: "uses-optimized-images", category: .performance,
                    title: "Properly size images",
                    description: "Serve images that are appropriately sized to save cellular data and improve load time.",
                    status: .fail, score: 0.4, weight: 0, displayValue: "Potential savings of 620 ms",
                    items: [LHAuditItem(id: "im1", selector: "img.hero", url: "https://shop.example.com/img/hero.jpg", wastedBytes: 124_000, transferSize: 310_000)],
                    savingsMs: 620, savingsBytes: 124_000
                ),
                LHAuditResult(
                    id: "unused-javascript", category: .performance,
                    title: "Reduce unused JavaScript",
                    description: "Reduce unused JavaScript and defer loading scripts until they are required.",
                    status: .fail, score: 0.2, weight: 0, displayValue: "Potential savings of 410 ms",
                    items: [LHAuditItem(id: "js1", url: "https://shop.example.com/static/vendor.js", wastedBytes: 82_000, transferSize: 210_000)],
                    savingsMs: 410, savingsBytes: 82_000
                ),
                LHAuditResult(
                    id: "color-contrast", category: .accessibility,
                    title: "Background and foreground colors have a sufficient contrast ratio",
                    description: "Low-contrast text is difficult or impossible for many users to read.",
                    status: .fail, score: 0, weight: 3, displayValue: "2 elements",
                    items: [LHAuditItem(id: "cc1", selector: "p.badge", label: "Contrast 3.1:1, needs 4.5:1", snippet: "<p class=\"badge\">")]
                ),
                LHAuditResult(
                    id: "image-alt", category: .accessibility,
                    title: "Image elements have [alt] attributes",
                    description: "Informative elements should aim for short, descriptive alternative text.",
                    status: .pass, score: 1, weight: 10, displayValue: "", items: []
                ),
                LHAuditResult(
                    id: "meta-description", category: .seo,
                    title: "Document has a meta description",
                    description: "Meta descriptions may be included in search results.",
                    status: .pass, score: 1, weight: 1, displayValue: "", items: []
                ),
            ],
            throttlingNote: "Scores use Lighthouse's mobile curves. This Mac applies no network or CPU throttling."
        )
    }

    private static func securityInput() -> OrbitSecurityInput {
        let now = fixedNow
        let day: TimeInterval = 86_400
        var input = OrbitSecurityInput()
        input.now = now
        input.pageURL = "https://shop.example.com/account/login"
        input.trust = .trusted
        input.hasOnlySecureContent = false
        input.certificates = [
            OrbitSecurityCertificate(
                subject: "shop.example.com", issuer: "Example Issuing CA 1",
                notBefore: now.addingTimeInterval(-43 * day), notAfter: now.addingTimeInterval(47 * day),
                serialNumber: "04:9F:2A:6C:11:B3", subjectAlternativeNames: ["shop.example.com", "*.shop.example.com"],
                keyType: "EC", keySizeBits: 256, signatureAlgorithm: "SHA-256 with ECDSA"
            ),
            OrbitSecurityCertificate(
                subject: "Example Issuing CA 1", issuer: "Example Root CA",
                notBefore: now.addingTimeInterval(-900 * day), notAfter: now.addingTimeInterval(1_800 * day),
                serialNumber: "01:00:00:00:00:01", subjectAlternativeNames: [],
                keyType: "RSA", keySizeBits: 2_048, signatureAlgorithm: "SHA-256 with RSA"
            ),
            OrbitSecurityCertificate(
                subject: "Example Root CA", issuer: "Example Root CA",
                notBefore: now.addingTimeInterval(-3_000 * day), notAfter: now.addingTimeInterval(4_000 * day),
                serialNumber: "00:00:00:00:00:01", subjectAlternativeNames: [],
                keyType: "RSA", keySizeBits: 4_096, signatureAlgorithm: "SHA-256 with RSA"
            ),
        ]
        input.documentHeaders = [
            "strict-transport-security": "max-age=31536000; includeSubDomains",
            "x-content-type-options": "nosniff",
            "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.example.net",
            "referrer-policy": "strict-origin-when-cross-origin",
        ]
        input.requests = [
            OrbitSecurityRequest(url: "https://shop.example.com/static/app.js", type: "script"),
            OrbitSecurityRequest(url: "http://img.cdn.example.net/banner.png", type: "image"),
        ]
        input.forms = [
            OrbitSecurityForm(action: "http://shop.example.com/session", method: "post", hasPassword: true, nodeID: 41, selector: "form#login"),
        ]
        input.cookies = [
            OrbitApplicationLogic.CookieRecord(
                id: "sid|shop.example.com|/", name: "sid", value: "abc123", domain: "shop.example.com", path: "/",
                expiresDate: nil, isHTTPOnly: true, isSecure: true, sameSite: "Lax", partitionKey: "", priority: ""
            ),
            OrbitApplicationLogic.CookieRecord(
                id: "theme|shop.example.com|/", name: "theme", value: "dark", domain: "shop.example.com", path: "/",
                expiresDate: now.addingTimeInterval(180 * day), isHTTPOnly: false, isSecure: false, sameSite: "", partitionKey: "", priority: ""
            ),
        ]
        return input
    }

    // Oldest first, so the newest ends at index 0 of the store: in progress, completed, cancelled, interrupted.
    private func seedFlyoutDownloads(_ env: AppEnvironment) throws -> [DownloadItem] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-flyout-screenshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = URL(string: "https://downloads.example.com/files")!

        func begin(_ name: String, mime: String, total: Int64) -> DownloadItem {
            env.downloadStore.beginDownload(
                sourceURL: source.appendingPathComponent(name),
                destinationURL: directory.appendingPathComponent(name),
                suggestedFileName: name, mimeType: mime, totalBytes: total
            )
        }

        let interrupted = begin("backup-2025.zip", mime: "application/zip", total: 400_000_000)
        env.downloadStore.updateProgress(
            id: interrupted.id,
            progress: DownloadProgress(receivedBytes: 120_000_000, totalBytes: 400_000_000, bytesPerSecond: 0, state: .interrupted)
        )

        let cancelled = begin("installer.dmg", mime: "application/x-apple-diskimage", total: 95_000_000)
        env.downloadStore.cancel(cancelled.id)

        let completed = begin("Q4-Roadmap.pdf", mime: "application/pdf", total: 2_400_000)
        try Data(count: 1_024).write(to: completed.destinationURL)
        env.downloadStore.updateProgress(
            id: completed.id,
            progress: DownloadProgress(receivedBytes: 2_400_000, totalBytes: 2_400_000, bytesPerSecond: 0, state: .completed)
        )

        let running = begin("lecture-recording.mov", mime: "video/quicktime", total: 82_000_000)
        env.downloadStore.updateProgress(
            id: running.id,
            progress: DownloadProgress(receivedBytes: 31_000_000, totalBytes: 82_000_000, bytesPerSecond: 2_400_000, state: .inProgress)
        )

        return DownloadsFlyoutSelection.visible(from: env.downloadStore.downloads)
    }


    private func withInspectSession(_ body: @escaping (OrbitInspectSession) async -> Void) throws {
        try WebKitLiveEngineHost.runLive(timeout: 240) {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            await body(session)
        }
    }

    // MARK: - Render + write

    @discardableResult
    private func renderAndSave(
        _ view: some View,
        name: String,
        size: CGSize,
        appearance: NSAppearance.Name = .darkAqua,
        scale: CGFloat = 2.0
    ) async -> RenderedImage {
        let rendered = await renderForScreenshot(view, size: size, appearance: appearance, scale: scale)

        XCTAssertEqual(rendered.bitmap.pixelsWide, Int((size.width * scale).rounded()), "\(name): wrong pixel width.")
        XCTAssertEqual(rendered.bitmap.pixelsHigh, Int((size.height * scale).rounded()), "\(name): wrong pixel height.")
        XCTAssertNotNil(rendered.boundingBoxOfContent(), "\(name): the rendered image is blank.")

        let destination = Self.outputDirectory.appendingPathComponent("\(name).png")
        XCTAssertTrue(rendered.writePNG(to: destination), "\(name): failed to write \(destination.path).")
        return rendered
    }

    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 8
        var x = 0
        while x < Int(size.width) {
            var y = 0
            while y < Int(size.height) {
                let lhs = a.color(atX: x, y: y)
                let rhs = b.color(atX: x, y: y)
                let dr = lhs.r - rhs.r, dg = lhs.g - rhs.g, db = lhs.b - rhs.b, da = lhs.a - rhs.a
                if (dr * dr + dg * dg + db * db + da * da).squareRoot() > 0.04 { return true }
                y += step
            }
            x += step
        }
        return false
    }
}

/// OnboardingView's layout with its ScrollView swapped for a clipped frame and its @State replaced by plain inputs, so any step can be shown.
private struct ScreenshotOnboardingComposition: View {
    var step: OnboardingStep
    var importSources: [ImportableBrowser] = [.safari, .chrome, .arc]
    var selectedImport: ImportableBrowser?
    var importState: OnboardingView.ImportState = .idle
    var importProgress = ImportProgress()
    var drafts: [OnboardingSpaceDraft] = OnboardingView.initialDrafts()
    var primer = OnboardingShortcutPrimer()

    private var phase: OnboardingImportPhase { OnboardingView.phase(of: importState) }
    private var flow: OnboardingFlowState { OnboardingFlowState(step: step, isBusy: phase == .running) }

    private var planetScene: OnboardingPlanetScene {
        OnboardingPlanetScene.scene(
            step: step,
            importPhase: phase,
            hasImportSource: selectedImport != nil,
            importFraction: importProgress.overallFraction,
            spaceTint: drafts.first?.theme?.primary.planetColor,
            shortcutsTried: primer.triedCount
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            column.frame(width: 440)
            OnboardingStageArt(scene: planetScene)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 880, height: 560)
        .background(OrbitNeutral.bg)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingStepRail(state: flow, onSelect: nil)
                .padding(.bottom, 22)
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            navigationRow
                .padding(.top, 16)
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 22)
        .frame(maxHeight: .infinity)
        .background(OrbitNeutral.card)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            EmptyView()
        case .importBrowser:
            OnboardingImportStep(
                sources: importSources,
                hasLoadedSources: true,
                selection: .constant(selectedImport),
                importLoginSessions: .constant(false),
                state: importState,
                progress: importProgress,
                onSelectionChanged: {}
            )
        case .spaces:
            OnboardingSpacesStep(drafts: .constant(drafts), selectedDraftID: .constant(drafts.first?.id))
        case .shortcuts:
            OnboardingShortcutsStep(primer: .constant(primer))
        case .finish:
            OnboardingFinishStep(searchEngine: .constant(.fallback), offersDefaultBrowser: true, onSetDefaultBrowser: {})
        }
    }

    private var navigationRow: some View {
        let hasSource = selectedImport != nil
        let title = flow.primaryTitle(importSourceName: selectedImport?.displayName, importPhase: phase)
        let offersMaybeLater = flow.offersMaybeLater(hasImportSource: hasSource, importPhase: phase)
        return HStack(spacing: 8) {
            Button("Back") {}
                .buttonStyle(OnboardingButtonStyle(variant: .plain))
                .disabled(!flow.canGoBack)
                .opacity(flow.isFirst ? 0 : 1)
            Spacer(minLength: 8)
            if offersMaybeLater {
                Button("Maybe later") {}
                    .buttonStyle(OnboardingButtonStyle(variant: .plain))
                    .disabled(flow.isBusy)
            }
            Button(title) {}
                .buttonStyle(OnboardingButtonStyle(variant: .primary))
                .disabled(flow.isBusy)
        }
    }
}

/// OrbitLighthousePane's report view with its ScrollView and LazyVStack swapped for a plain VStack, reading the same session.lighthouse model.
private struct ScreenshotLighthouseComposition: View {
    var session: OrbitInspectSession

    private var model: OrbitLighthouseModel { session.lighthouse }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let report = model.viewingReport {
                reportBody(report)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(InspectChrome.background)
        .clipped()
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(LHRunMode.allCases, id: \.self) { mode in
                    InspectChip(mode.title, selected: model.runMode == mode) {}
                }
            }
            Divider().frame(height: 16)
            HStack(spacing: 2) {
                ForEach(LHDevice.allCases, id: \.self) { device in
                    InspectChip(device.title, selected: model.device == device) {}
                }
            }
            Spacer(minLength: 0)
            InspectTextButton("Analyze", systemImage: "play.fill", prominent: true) {}
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .frame(height: 36)
    }

    private func reportBody(_ report: LHReport) -> some View {
        let opportunities = OrbitLighthouseLogic.rankedOpportunities(report.audits)
        let scale = opportunities.compactMap(\.savingsMs).max()
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.pageTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OrbitNeutral.ink)
                Text(report.url)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
                Text("\(report.mode.title) · \(report.device.title) curves · median of \(report.runCount)")
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 10)

            HStack(alignment: .top, spacing: 8) {
                ForEach(LHCategory.allCases) { category in
                    VStack(spacing: 4) {
                        LHGaugeView(score: report.scores[category], size: 72, label: category.title)
                        Text(category.title)
                            .font(InspectChrome.caption)
                            .foregroundStyle(OrbitNeutral.ink2)
                        if let score = report.scores[category] {
                            Text(LHStyle.word(score: score))
                                .font(InspectChrome.caption)
                                .foregroundStyle(OrbitNeutral.muted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 8)

            Text(report.throttlingNote)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.bottom, 8)

            Divider()
            InspectSectionHeader("Performance metrics")
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)
            LHMetricTilesView(metrics: report.metrics, device: report.device)
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.bottom, 8)

            Divider()
            InspectSectionHeader("Opportunities", detail: "\(opportunities.count), largest saving first")
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)
            ForEach(opportunities) { audit in
                LHAuditRowView(
                    audit: audit,
                    expanded: model.expandedAuditIDs.contains(audit.id),
                    session: session,
                    savingsScaleMs: scale
                ) {}
            }
        }
    }
}

/// OrbitSecurityPane's content with its ScrollView and LazyVStack swapped for a plain VStack, in the pane's own order.
private struct ScreenshotSecurityComposition: View {
    var session: OrbitInspectSession
    var report: OrbitSecurityReport

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                OrbitSecuritySummaryCard(report: report)
                    .padding(InspectChrome.panelPadding)
                ForEach(OrbitSecuritySection.allCases) { section in
                    sectionView(section)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(InspectChrome.background)
        .clipped()
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                InspectChip("All", selected: true) {}
                InspectChip("Issues", selected: false, count: report.warnCount + report.failCount) {}
                InspectChip("Passed", selected: false, count: report.passCount) {}
            }
            Spacer(minLength: 0)
            InspectIconButton(symbol: "doc.on.doc", help: "Copy security report") {}
            InspectIconButton(symbol: "arrow.clockwise", help: "Refresh security checks") {}
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .frame(height: 36)
    }

    @ViewBuilder
    private func sectionView(_ section: OrbitSecuritySection) -> some View {
        let checks = report.checks(in: section)
        let showsChain = section == .connection && !report.certificates.isEmpty
        let cookies = section == .cookies ? report.cookieRows : []
        if !checks.isEmpty || showsChain || !cookies.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(OrbitNeutral.muted)
                    InspectSectionHeader(section.title)
                }
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)

                ForEach(checks) { check in
                    OrbitSecurityCheckRow(
                        check: check,
                        expanded: session.security.expandedCheckIDs.contains(check.id),
                        session: session
                    ) {}
                }
                if showsChain {
                    OrbitSecurityCertificateChainView(
                        certificates: report.certificates,
                        expanded: session.security.expandedCertificateIndexes,
                        now: Date(timeIntervalSince1970: 1_767_225_600)
                    ) { _ in }
                    .padding(.top, 4)
                }
                if !cookies.isEmpty {
                    OrbitSecurityCookieList(rows: cookies)
                        .padding(.top, 4)
                }
            }
        }
    }
}

/// The real bottom bar on a Space theme with the flyout overlay placed as in production (bottom-leading over a bar-height slot).
private struct ScreenshotFlyoutScene: View {
    var theme: SpaceTheme
    var width: CGFloat
    var showsFlyout: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            SidebarBottomBar(theme: theme)
                .frame(width: width, height: OrbitMetrics.sidebarBottomBarHeight)
                .overlay(alignment: .bottomLeading) {
                    if showsFlyout {
                        DownloadsPreviewOverlay(
                            theme: theme,
                            containerWidth: width,
                            spaceAbove: nil,
                            reduceMotion: true,
                            onHoverChange: { _ in },
                            onDismiss: {}
                        )
                    }
                }
                .padding(.bottom, OrbitMetrics.sidebarInterSectionGap)
        }
        .frame(width: width)
        .background(ThemeBackgroundView(theme: theme, blur: 0))
        .environment(\.orbitScreenshotModeDragDisabled, true)
    }
}

/// env.recentDownloads cannot be backdated, so this lays the real DownloadsPreviewRow in the panel's own surface, without the footer, to show relative times.
private struct ScreenshotBackdatedFlyoutRows: View {
    var items: [DownloadItem]
    var theme: SpaceTheme
    var width: CGFloat

    private var surface: RoundedRectangle {
        RoundedRectangle(cornerRadius: DownloadsPreviewPanel.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                DownloadsPreviewRow(item: item, theme: theme, onDismiss: {})
            }
        }
        .padding(.vertical, OrbitSpacing.sm)
        .frame(width: DownloadsPreviewLayout.placement(containerWidth: width).width)
        .background(
            surface
                .fill(Color(theme.primary.nsColor))
                .overlay(surface.fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity)))
        )
        .overlay(
            surface.strokeBorder(theme.readableForeground.opacity(OrbitMetrics.cardBorderOpacity), lineWidth: OrbitMetrics.cardBorderWidth)
        )
        .padding(DownloadsPreviewLayout.edgeInset)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ThemeBackgroundView(theme: theme, blur: 0))
        .environment(\.orbitScreenshotModeDragDisabled, true)
    }
}

// MARK: - Drag suppression

private extension View {
    func orbitScreenshotDragDisabled() -> some View {
        #if DEBUG
        return self.environment(\.orbitScreenshotModeDragDisabled, true)
        #else
        return self
        #endif
    }
}
